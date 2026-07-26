-- ============================================================
-- あそぶ時間を30分刻み・最長4時間にし、予約できる先を2週間に延ばす
-- ------------------------------------------------------------
-- ■ あそぶ時間: 30/60/120 の3択 → 30分刻みで 30〜240分
--   ランクを回す・レイドを進める等、実際のプレイは中途半端な長さになる。
--   3択だと「1時間半だけ」が取れず、2時間にするか諦めるかになっていた。
--   上限を4時間に留めるのは、
--     * それ以上は延長(第8条の3)で足せる
--     * 初回に長時間を前払いさせると、直前キャンセル時の没収額が大きくなり
--       消費者契約法9条の論点が重くなる
--   ため。延長を重ねた合計は従来どおり bookings の制約(600分)まで。
--
-- ■ 予約できる先: 7日 → 14日
--   7日だと「再来週の週末」が取れない。一方で1か月先まで開けると、空き時間を
--   管理する仕組みが無い現状ではピタメイトが都合を確認できないまま長い約束を
--   抱えることになり、直前キャンセルが増える。2週間なら「次の週末」と
--   「その次」が収まる。
--
-- 数値はいずれも platform_pricing に置く。運用データを見て変えられるように
-- するため(コード改修が要らない)。
-- ============================================================

alter table public.platform_pricing
  add column if not exists max_duration_minutes int not null default 240;

alter table public.platform_pricing
  drop constraint if exists platform_pricing_max_duration_check;
alter table public.platform_pricing
  add constraint platform_pricing_max_duration_check
  check (max_duration_minutes between 30 and 600 and max_duration_minutes % 30 = 0);

comment on column public.platform_pricing.max_duration_minutes is
  '1件の予約で最初に申し込めるプレイ時間の上限(分)。30の倍数。'
  'これを超える分は延長(第8条の3)で足す。';

-- 既定値だけでなく、すでにある1行も更新する
alter table public.platform_pricing alter column max_lead_days set default 14;
update public.platform_pricing set max_lead_days = 14, max_duration_minutes = 240 where id = 1;

-- ------------------------------------------------------------
-- create_booking: 30分刻み・上限までを受け付ける
--   検査以外は 0040 と同じ。
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
  v_discount int;
  v_list_coins int;
  v_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_guest_name text;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_days int;
  v_max_duration int;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select min_lead_minutes, max_lead_days, max_duration_minutes
    into v_min_lead, v_max_days, v_max_duration
  from public.platform_pricing where id = 1;

  -- 30分刻みで、30分以上、上限まで
  if p_duration_minutes is null
     or p_duration_minutes < 30
     or p_duration_minutes > v_max_duration
     or p_duration_minutes % 30 <> 0 then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_days) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings where user_id = p_host_id for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
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

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at, list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
  )
  returning id into v_booking_id;

  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id, 'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分'
      || case when p_scheduled_at is null then '(今すぐ)'
              else '(' || to_char(p_scheduled_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜)' end
      || '。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

comment on function public.create_booking(uuid, int, text, timestamptz) is
  '予約リクエストを作成し、コインをエスクローする。0041でプレイ時間を30分刻み(上限は platform_pricing.max_duration_minutes)に対応。';
