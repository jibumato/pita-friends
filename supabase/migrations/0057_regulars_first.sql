-- ============================================================
-- 0057_regulars_first.sql
-- 常連への先行予約枠
-- ------------------------------------------------------------
-- 人気のピタメイトの枠は、早く見つけた人から埋まる。何度も遊んでいる常連が
-- 「気づいたら埋まっていた」を繰り返すと、その人との関係はそこで切れる。
-- ピタメイト側から見ても、続けて来てくれる人を取りこぼしているだけで得がない。
--
-- そこで、**開始の N 時間前までは常連だけが予約できる**枠を持てるようにする。
-- N を過ぎれば誰でも取れるので、埋まらないまま流れることはない。
--
-- 「枠を開けてから N 時間」ではなく「開始まで N 時間」にした理由:
--   ・枠を開けた時刻を持たずに済む(host_availability は曜日×時のくり返し)
--   ・ゲストに説明しやすい(「金曜22時の枠は水曜22時から誰でも」)
--   ・埋まらなかった枠が自動的に全体へ開く。運営が何もしなくてよい
--
-- 値引きではないので、ピタメイトの取り分は1コインも減らない。
-- 減るのは「常連に取られる前に他人に取られる」という取りこぼしだけ。
-- ============================================================

alter table public.host_settings
  add column if not exists regulars_first_hours smallint not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'host_settings_regulars_first_hours_range'
  ) then
    alter table public.host_settings
      add constraint host_settings_regulars_first_hours_range
      -- 上限は72時間。これ以上にすると、常連がいないピタメイトの枠が
      -- ほとんど誰にも見えない状態になり、新規が入る余地が無くなる。
      check (regulars_first_hours between 0 and 72);
  end if;
end $$;

comment on column public.host_settings.regulars_first_hours is
  '常連への先行予約。開始までこの時間数より先の枠は、一緒に遊んだことのある人だけが予約できる。0で無効。';

-- ------------------------------------------------------------
-- 内部ヘルパー: 二人が一緒に遊んだ回数
-- ------------------------------------------------------------
-- 0055 の my_play_history_with は auth.uid() 固定で、他人同士は数えられない。
-- サーバ内の判定では任意の二人を数える必要があるため別に用意する。
--
-- **authenticated には渡さない。** 渡すと「AとBが何回遊んだか」を誰でも
-- 引けることになり、0055で閉じたはずの穴がここから開く。
create or replace function public._played_together_count(p_a uuid, p_b uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.bookings b
  where b.status = 'completed'
    and ((b.guest_id = p_a and b.host_id = p_b)
      or (b.host_id = p_a and b.guest_id = p_b));
$$;

comment on function public._played_together_count(uuid, uuid) is
  '二人が一緒に遊んだ回数(内部用)。任意の二人を数えられるので authenticated には渡さない。';

revoke all on function public._played_together_count(uuid, uuid) from public;

-- ------------------------------------------------------------
-- その枠を、この人がいま予約できるか
-- ------------------------------------------------------------
create or replace function public.slot_open_to(p_host_id uuid, p_guest_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_guest_id is null then false
    -- 先行予約を使っていなければ従来どおり
    when coalesce((select h.regulars_first_hours from public.host_settings h
                   where h.user_id = p_host_id), 0) = 0 then true
    -- 開始が近づいたら誰でも取れる
    when p_at <= now() + make_interval(
           hours => (select h.regulars_first_hours from public.host_settings h
                     where h.user_id = p_host_id)) then true
    else public._played_together_count(p_host_id, p_guest_id) > 0
  end;
$$;

comment on function public.slot_open_to(uuid, uuid, timestamptz) is
  'その時刻の枠を、この人がいま予約できるか。先行予約の期間中は一緒に遊んだことのある人だけ true。';

revoke all on function public.slot_open_to(uuid, uuid, timestamptz) from public;
grant execute on function public.slot_open_to(uuid, uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- スケジュールに「常連のみ」を出す
-- ------------------------------------------------------------
-- 見えないと「募集していない」と誤解され、常連になれば取れることが伝わらない。
-- 状態として見せることで、むしろ「また来よう」の理由になる。
create or replace function public.host_schedule(
  p_host_id uuid,
  p_days int default 7
)
returns table (slot_at timestamptz, state text)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      date_trunc('hour', now()) as from_at,
      date_trunc('day', (now() at time zone 'Asia/Tokyo')
        + make_interval(days => greatest(p_days, 1))) at time zone 'Asia/Tokyo' as to_at
  ),
  slots as (
    select generate_series(
      date_trunc('day', (select from_at from bounds) at time zone 'Asia/Tokyo')
        at time zone 'Asia/Tokyo',
      (select to_at from bounds) - interval '1 hour',
      interval '1 hour') as slot_at
  )
  select
    s.slot_at,
    case
      when s.slot_at < date_trunc('hour', now()) then 'past'
      when exists (
        select 1 from public.booking_slots b
        where (b.host_id = p_host_id or b.guest_id = p_host_id)
          and b.starts_at < s.slot_at + interval '1 hour'
          and s.slot_at < b.ends_at
      ) then 'booked'
      when not public.host_is_open_at(p_host_id, s.slot_at) then 'closed'
      -- 本人には自分の枠をそのまま見せる(自分は予約できないので判定しても意味がない)
      when auth.uid() = p_host_id then 'open'
      when not public.slot_open_to(p_host_id, auth.uid(), s.slot_at) then 'regulars'
      else 'open'
    end as state
  from slots s
  order by s.slot_at;
$$;

comment on function public.host_schedule(uuid, int) is
  'ピタメイトの空き状況を1時間ごとに返す(past/closed/booked/regulars/open)。誰でも見られる。予約の中身は返さない。0057で「常連のみ」を追加。';

revoke all on function public.host_schedule(uuid, int) from public;
grant execute on function public.host_schedule(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 予約時に弾く
-- ------------------------------------------------------------
-- 画面で隠すだけでは足りない。RPCを直接叩けば取れてしまうので、
-- create_booking の中でも同じ判定をする。
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
