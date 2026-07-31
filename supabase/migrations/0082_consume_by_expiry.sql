-- ============================================================
-- 0082: コインの消費順序を「有効期限の早いもの優先」に改める
--       ★弁護士 第3回回答 論点4
--
-- これまでの順序:
--   ①有償を先に使い切る ②各種別の中では期限の早いロットから
--
-- 何が起きていたか:
--   複数回購入すると、**期限順なら失効しなかったはずの無償コインが
--   失効する**場面が構造的に生じていた。
--
--     | ロット   | 種別 | 期限   |
--     | A-有償   | 有償 | 6月末  |
--     | A-無償   | 無償 | 6月末  |
--     | B-有償   | 有償 | 12月末 |
--
--   旧: A-有償 → **B-有償** → A-無償  ⇒ 6月末に A-無償 が未使用で失効
--   新: A-有償 → A-無償 → B-有償      ⇒ 失効しない
--
-- 弁護士の指摘(要旨):
--   「無償付与分の失効が直ちに消費者契約法10条違反となる可能性は高くないが、
--    問題はむしろ**景品表示法**の方向にある。『ボーナス+100』と表示して
--    購入を誘引しながら、消費順序の仕組み上ボーナスが失効しやすいのであれば、
--    **有利誤認(5条2号)** の議論を招き得る。
--    **避けられる不利益を仕組みが作っている**状態は、どの法枠組みでも
--    説明しづらい。」
--
--   採るべきは二者択一ではなく両者の組み合わせ:
--     **①有効期限の早い順 → ②同一期限内では有償が先**
--   これが利用者にとって支配的に有利になる。失効総額を最小化しつつ、
--   同一期限内では(購入取消し等の場面で意味を持つ)有償分を先に減らす。
--   「期限順・種別問わず」だけにすると、同一期限内で無償を先に使った結果
--   **有償分が失効する**という逆の不利益を作るため劣る。
--
-- 変えていないもの:
--   ・ギフトの原資は有償コインのみ(規約 第7条の2)。send_gift は
--     _consume_coin_lots(..., 'paid', ...) しか呼ばないので影響しない
--   ・ロット内の消費は従来どおり期限の早い順
--
-- ============================================================

-- ------------------------------------------------------------
-- _split_coins_by_expiry: 期限順に見て、有償・無償それぞれ何枚使うかを決める
--
-- **実際に消費はしない。** 枚数を返すだけの純粋な計算。
-- 呼び出し側はこの枚数で _consume_coin_lots_tracked を種別ごとに呼ぶ。
--
-- 種別ごとに分けて消費しても結果が同じになる理由:
--   期限順に並べた列から取るのは、有償列の**先頭からの連続**と
--   無償列の**先頭からの連続**である。したがって
--   「有償をP枚・期限の早い順」「無償をB枚・期限の早い順」と
--   分けて取っても、選ばれるロットは完全に一致する。
-- ------------------------------------------------------------
create or replace function public._split_coins_by_expiry(
  p_user_id uuid,
  p_amount int
)
returns table (paid int, bonus int)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_left int := greatest(0, coalesce(p_amount, 0));
  v_lot record;
  v_take int;
  v_paid int := 0;
  v_bonus int := 0;
begin
  for v_lot in
    select l.kind, l.remaining
    from public.coin_lots l
    where l.user_id = p_user_id and l.remaining > 0 and l.expires_at > now()
    -- ①期限の早い順 ②同じ期限なら有償が先
    order by l.expires_at asc, (l.kind = 'paid') desc, l.id
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.remaining, v_left);
    if v_lot.kind = 'paid' then
      v_paid := v_paid + v_take;
    else
      v_bonus := v_bonus + v_take;
    end if;
    v_left := v_left - v_take;
  end loop;

  -- ロットが足りない場合(0030より前の予約など、ロット記録が無い利用者)は
  -- 残りを有償に寄せる。**残高の判定は呼び出し側で済んでいる**ので、
  -- ここで例外にはしない(判定の二重化は、片方だけ直したときに壊れる)。
  if v_left > 0 then
    v_paid := v_paid + v_left;
  end if;

  paid := v_paid;
  bonus := v_bonus;
  return next;
end;
$fn$;

comment on function public._split_coins_by_expiry(uuid, int) is
  'コインを消費するとき、有償・無償それぞれ何枚使うかを期限順に決める(同一期限内は有償が先)。0082・弁護士 第3回回答 論点4。計算のみで消費はしない。';

revoke all on function public._split_coins_by_expiry(uuid, int) from public;

-- ------------------------------------------------------------
-- create_booking / extend_booking を、上の関数を使うように差し替える
-- **本体のロジックは変えていない。** 充当の内訳を決める2行だけを置き換えた。
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_verified boolean;
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
  if public._booking_slot_conflict(v_guest_id, v_start, p_duration_minutes) is not null then
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
    list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
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
$fn$;

create or replace function public.extend_booking(
  p_booking_id uuid,
  p_additional_minutes int
)
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_max int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
  end if;

  -- 延長は終了時刻を後ろにずらすので、次の予約に食い込まないか確かめる。
  -- ここも成立済みだけを見る。まだ承諾されていない後続のリクエストのために
  -- 進行中のプレイの延長を止めるのは、優先順位が逆。
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(
       v_booking.guest_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 期限の早いロットから充当する(同一期限内は有償が先)
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_uid, v_add_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
  values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$fn$;

comment on function public.create_booking(uuid, int, text, timestamptz) is
  '予約の作成。0082で、コインの充当を「有効期限の早いロット優先(同一期限内は有償が先)」に改めた。';
comment on function public.extend_booking(uuid, int) is
  'プレイ時間の延長。0082で、コインの充当を「有効期限の早いロット優先(同一期限内は有償が先)」に改めた。';
