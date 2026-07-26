-- ============================================================
-- 0049_booking_slot_conflict.sql
-- 上限を10時間にし、予約時間帯の重複を防ぐ(E-13)
-- ------------------------------------------------------------
-- `create_booking` には**予約の時間帯が他の予約と重なっていないかの検査が
-- ありませんでした**。最長4時間のうちは衝突が稀で表面化しませんでしたが、
-- 長時間の予約は1件で1日の枠の大半を占めます。同じピタメイトに同じ時間帯の
-- 予約が2件入ると、どちらかは必ず反故になります。ゲスト側も同じです。
--
-- 【どの予約が枠を占めるか】
--   status が 'requested' か 'confirmed' のもの。
--   開始時刻は coalesce(requested_start_at, scheduled_at) で見ます。
--   「今すぐ」の申し込みは requested_start_at が null で、この場合
--   scheduled_at は作成時刻(既定値)なので、実質「申し込んだ時点から
--   duration 分」を押さえていることになります。承諾で正式な開始時刻に
--   置き換わります。
--
-- 【同時申し込みへの対処】
--   検査してから INSERT するまでの間に他のトランザクションが割り込むと、
--   両方とも検査を通ってしまいます(TOCTOU)。当事者2人の user_id で
--   トランザクション内アドバイザリロックを取り、同じ人が絡む予約作成を
--   直列化します。デッドロックを避けるため、必ず**同じ順序**で取ります。
--
-- 【承諾時にも検査が要る理由】
--   「今すぐ」や希望時刻つきのリクエストは、承諾されるまで枠が確定しません。
--   リクエスト中に別の予約が確定していると、承諾した瞬間に重なります。
--   approve_booking でも同じ検査をします。
--
-- 【延長時にも検査が要る理由】
--   延長は終了時刻を後ろにずらすので、次の予約に食い込みます。
--
-- 【どの状態を「ふさがっている」と見るかは、場面で変える】
--   ・新規の申し込み … 申請中 + 成立済み
--       先に申し込んだ人の枠を守る。コインは申込時点で確保されているので、
--       申請中でも「押さえた」と扱うのが筋。
--   ・承諾 / 延長  … 成立済みのみ
--       申請中まで見ると、同じ枠に2件のリクエストが並んだときに
--       **どちらも承諾できなくなります**。申請は希望であって確約ではないので、
--       承諾の可否を縛るべきではありません。先に1件を承諾すれば、もう1件は
--       承諾の時点で弾かれ、全額返還されます。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 上限を10時間(600分)にする
-- ------------------------------------------------------------
update public.platform_pricing set max_duration_minutes = 600 where id = 1;

-- ------------------------------------------------------------
-- 2. 予約が占める時間帯
--    ビューにしておくと、検査・一覧・デバッグで同じ定義を使い回せる。
-- ------------------------------------------------------------
create or replace view public.booking_slots
with (security_invoker = true) as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.status,
  coalesce(b.requested_start_at, b.scheduled_at) as starts_at,
  coalesce(b.requested_start_at, b.scheduled_at)
    + make_interval(mins => b.duration_minutes) as ends_at
from public.bookings b
where b.status in ('requested', 'confirmed');

comment on view public.booking_slots is
  '枠を占めている予約(申請中・成立済み)の時間帯。重複検査と空き状況の表示で使う。';

-- ------------------------------------------------------------
-- 3. 重複の検査。ぶつかった予約のidを返す(無ければ null)
-- ------------------------------------------------------------
create or replace function public._booking_slot_conflict(
  p_user_id uuid,
  p_start timestamptz,
  p_minutes int,
  p_exclude_booking_id uuid default null,
  p_statuses text[] default array['requested', 'confirmed']
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select b.id
  from public.bookings b
  where b.status = any (p_statuses)
    and (b.guest_id = p_user_id or b.host_id = p_user_id)
    and (p_exclude_booking_id is null or b.id <> p_exclude_booking_id)
    and tstzrange(
          coalesce(b.requested_start_at, b.scheduled_at),
          coalesce(b.requested_start_at, b.scheduled_at)
            + make_interval(mins => b.duration_minutes),
          '[)')
        && tstzrange(p_start, p_start + make_interval(mins => p_minutes), '[)')
  limit 1;
$$;

comment on function public._booking_slot_conflict(uuid, timestamptz, int, uuid, text[]) is
  '指定の時間帯に、その人の予約が既に入っているかを調べる。'
  '見る状態は呼び出し側が選ぶ(新規申込は申請中も含め、承諾・延長は成立済みのみ)。';

-- ------------------------------------------------------------
-- 4. 当事者2人ぶんのロック。順序を固定してデッドロックを避ける
-- ------------------------------------------------------------
create or replace function public._lock_booking_slots(p_a uuid, p_b uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_first uuid;
  v_second uuid;
begin
  -- uuid の大小で順序を決める。どのトランザクションでも同じ順で取れば
  -- 相互待ちにならない。
  if p_a <= p_b then
    v_first := p_a; v_second := p_b;
  else
    v_first := p_b; v_second := p_a;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_first::text, 0));
  if v_second is distinct from v_first then
    perform pg_advisory_xact_lock(hashtextextended(v_second::text, 0));
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 5. 空き状況の照会(画面用)
--    ピタメイトの埋まっている時間帯と、自分の予約で埋まっている時間帯を返す。
--    どちらも新しい予約を弾く要因なので、まとめて返して画面で灰色にする。
--    他人の予約の中身(相手が誰か・何コインか)は返さない。
-- ------------------------------------------------------------
create or replace function public.booking_busy_slots(
  p_host_id uuid,
  p_days int default 14
)
returns table (starts_at timestamptz, ends_at timestamptz, who text)
language sql
stable
security definer
set search_path = public
as $$
  select s.starts_at, s.ends_at,
         case when s.guest_id = auth.uid() or s.host_id = auth.uid()
              then 'me' else 'host' end as who
  from public.booking_slots s
  where (s.host_id = p_host_id or s.guest_id = p_host_id
         or s.guest_id = auth.uid() or s.host_id = auth.uid())
    and s.ends_at > now()
    and s.starts_at < now() + make_interval(days => greatest(p_days, 1))
  order by s.starts_at;
$$;

comment on function public.booking_busy_slots(uuid, int) is
  'そのピタメイトと自分の、埋まっている時間帯。予約画面で選べない時刻を示すために使う。相手が誰か等は返さない。';

revoke all on function public.booking_busy_slots(uuid, int) from public;
grant execute on function public.booking_busy_slots(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 6. create_booking: 重複検査を入れる
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
as $$
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

  -- 枠の検査。ロックを取ってから調べる(同時申し込みで両方通るのを防ぐ)
  v_start := coalesce(p_scheduled_at, now());
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

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

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
$$;

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 7. approve_booking: 承諾の瞬間にも重複を検査する
--    リクエスト中に別の予約が確定していると、承諾した瞬間に重なるため。
-- ------------------------------------------------------------
create or replace function public.approve_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
  v_start timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 指定があればその時刻、無ければ従来どおり承諾時点が開始時刻。
  -- 承諾時刻は別に持つ(キャンセル猶予の起点になるため。0040以前は
  -- scheduled_at が承諾時刻を兼ねていた)。
  v_start := coalesce(v_booking.requested_start_at, now());

  -- ここで見るのは**成立済み(confirmed)だけ**。
  -- 申請中の予約まで見ると、同じ枠に2件のリクエストが並んだときに
  -- ピタメイトが**どちらも承諾できなくなります**。申請は「希望」であって
  -- 確約ではないので、承諾の可否を縛るべきではありません。
  -- (先に1件を承諾すれば、もう1件はここで弾かれて全額返還されます。)
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_start, v_booking.duration_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(
       v_booking.guest_id, v_start, v_booking.duration_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  update public.bookings
    set status = 'confirmed', scheduled_at = v_start, confirmed_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ピタメイト') || 'さんが予約を承諾しました',
    case when v_booking.requested_start_at is null
         then 'トークが始まりました。プレイの準備をしましょう'
         else to_char(v_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜 で成立しました' end,
    v_promise_id
  );

  return v_promise_id;
end;
$$;

revoke all on function public.approve_booking(uuid) from public;
grant execute on function public.approve_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. extend_booking: 延長で次の予約に食い込まないようにする
-- ------------------------------------------------------------
create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
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

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

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
$$;

revoke all on function public.extend_booking(uuid, int) from public;
grant execute on function public.extend_booking(uuid, int) to authenticated;

-- 検査を効かせるための索引(開始時刻で絞ってから範囲を見る)
create index if not exists bookings_slot_idx
  on public.bookings (host_id, scheduled_at)
  where status in ('requested', 'confirmed');
create index if not exists bookings_slot_guest_idx
  on public.bookings (guest_id, scheduled_at)
  where status in ('requested', 'confirmed');
