-- ============================================================
-- 0128: 予約時にゲスト側の本人確認も検査する
--
-- 規約 第3条1項は「本サービスの利用には……本人確認……の完了が必要」と
-- 定めており、**ホストとゲストを区別していない。**
--
-- ところが `create_booking` はホストの `is_verified` しか見ていなかった。
-- アプリの通常導線(signUp→consent→verify→setup)を経由すれば未確認のまま
-- 予約画面には到達しないが、**RPCを直接叩けば未確認のゲストでも予約できる**
-- 状態だった。「規約に書いてあるのに実装が無い」ものを全体的に洗い出す中で
-- 見つけた（`docs/legal/terms-implementation-matrix.md` 第3条1項の注記）。
--
-- ホスト側と同じ検査を1つ足すだけ。**予約を作る経路はここに集約されている**
-- (`create_booking_from_board`・`create_booking_from_request`・
-- `create_paired_booking` はいずれもこの関数を呼ぶだけで、検査を作り直して
-- いない)ので、直すのはここ1か所で足りる。
--
-- ⚠️ 本体は適用済みのDBから取り出したもの。差分はゲスト側の検査1つだけ。
-- ============================================================

create or replace function public.create_booking(p_host_id uuid, p_duration_minutes integer, p_policy_version text, p_scheduled_at timestamp with time zone, p_pair_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_verified boolean;
  v_guest_verified boolean;
  v_coins int;
  v_list_coins int;
  v_discount int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_lead int;
  v_start timestamptz;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  -- 0121: ブロック関係があれば予約させない。
  -- **0116 が「ブロック＝予約もトークも不可」と書いているのに、
  --   ここには検査が無かった。** create_booking_from_board(0113)だけが
  --   独自に見ていたので、板を経由しない経路は全部素通りだった。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_guest_id and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_guest_id)
  ) then
    raise exception 'BLOCKED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_lead) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hs.hourly_rate, hs.is_host into v_hourly_rate, v_is_host
  from public.host_settings hs where hs.user_id = p_host_id for share;
  if not coalesce(v_is_host, false) or v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  select pts.is_verified into v_verified
  from public.profile_trust_stats pts where pts.user_id = p_host_id;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  -- 0128: 規約第3条1項は「利用には本人確認の完了が必要」と定めており、
  -- ホスト・ゲストを区別していない。ところがここではホストの本人確認しか
  -- 見ておらず、**アプリの通常導線(signUp→consent→verify→setup)を経由すれば
  -- 未確認では予約画面に到達しないが、RPCを直接叩けば未確認のゲストでも
  -- 予約できていた。** ホスト側と同じ検査をゲスト側にも足すだけ。
  select pts.is_verified into v_guest_verified
  from public.profile_trust_stats pts where pts.user_id = v_guest_id;
  if not coalesce(v_guest_verified, false) then
    raise exception 'GUEST_NOT_VERIFIED';
  end if;

  v_start := coalesce(p_scheduled_at, now());

  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 常連への先行予約(0057)。開始まで遠い枠は、一緒に遊んだことのある人だけ。
  if not public.slot_open_to(p_host_id, v_guest_id, v_start) then
    raise exception 'REGULARS_FIRST';
  end if;

  perform public._lock_booking_slots(v_guest_id, p_host_id);

  if public._booking_slot_conflict(p_host_id, v_start, p_duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペア予約(同じゲスト・同じ時間で2人のホストに同時に申し込む)は、
  -- ここが無いと**自分自身の、もう片方への申し込み**を「重複」として
  -- 弾いてしまう。p_pair_id が同じ予約(=ペアの相方)だけ、この検査から除く
  -- (他のゲストの予約や、別のペアとは今までどおり衝突させる)。
  -- **_booking_slot_conflict は1件しか返さない**ので、ここは書き直さず
  -- 素の exists で「相方以外との重なり」だけを見る。
  if exists (
    select 1 from public.bookings b
    where b.status = any (array['requested', 'confirmed'])
      and (b.guest_id = v_guest_id or b.host_id = v_guest_id)
      and (p_pair_id is null or b.from_pair_id is distinct from p_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes),
            '[)')
          && tstzrange(v_start, v_start + make_interval(mins => p_duration_minutes), '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;
  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 有償を先に使い切るのではなく、**有効期限の早いロットから**充当する。
  -- 同一期限内では有償が先。詳細は 0082 の冒頭を参照。
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_guest_id, v_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, policy_version, policy_agreed_at,
    list_coins, discount_percent, requested_start_at, from_pair_id
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at, p_pair_id
  )
  returning id into v_booking_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$$;

comment on function public.create_booking(uuid, integer, text, timestamptz, uuid) is
  '予約の確定+コイン消費(0003)。0126でp_pair_idを追加、0128でゲスト側の本人確認検査を追加'
  '(規約第3条1項はホスト・ゲストを区別していない。ホスト側の検査しか無かった)。'
  '**単独では呼ばない。** create_paired_booking / create_booking_from_board / '
  'create_booking_from_request からだけ使う内部経路。';

revoke all on function public.create_booking(uuid, integer, text, timestamptz, uuid) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz, uuid) to authenticated;
