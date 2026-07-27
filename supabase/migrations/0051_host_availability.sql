-- ============================================================
-- 0051_host_availability.sql
-- ピタメイトが「いつ募集しているか」を持ち、空き状況を誰でも見られるようにする
-- ------------------------------------------------------------
-- これまで、ピタメイトが**いつ遊べるのか**を表す情報がどこにもありませんでした。
-- `booking_busy_slots`(0049)が返すのは「予約が入っている時間」だけで、
-- 空いている時間が「募集しているから空いている」のか「そもそも出ていない」のか
-- を区別できません。ゲストから見ると、深夜3時に申し込んでよいのか分かりません。
--
-- 【持ち方】
-- 曜日 × 時 の1時間単位で持ちます。日付ごとではなく**毎週くり返し**にするのは、
-- ピタメイトが毎週メンテナンスする負担をなくすためです。
--
-- 1時間単位にしたのは、週のタイル(7日 × 24時間 = 168枠)として一望できる
-- 粒度がここだからです。30分にすると336枠になり、一覧の意味が薄れます。
-- 予約自体は従来どおり30分刻みで、開いている枠の中なら :30 開始もできます。
--
-- 曜日と時は**日本時間(Asia/Tokyo)**で解釈します。
--
-- 【募集枠の外は予約できるのか】
--   ・1枠も設定していないピタメイト → 従来どおり、いつでも申し込める
--   ・1枠でも設定したピタメイト     → その枠の中だけ申し込める
-- 設定していない人をいきなり予約不可にすると、既存のピタメイトが黙って
-- 消えてしまいます。「設定したら効く」なら、そのピタメイトの意思表示に沿います。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 募集枠
-- ------------------------------------------------------------
create table if not exists public.host_availability (
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 0=日曜 〜 6=土曜(日本時間)
  weekday smallint not null check (weekday between 0 and 6),
  hour smallint not null check (hour between 0 and 23),
  primary key (user_id, weekday, hour)
);

comment on table public.host_availability is
  'ピタメイトが募集している曜日・時(日本時間・1時間単位・毎週くり返し)。1枠も無い場合は「いつでも可」として扱う。';

alter table public.host_availability enable row level security;

-- 誰でも見られる。これが「みんなが見れるスケジュール」の土台。
drop policy if exists "host_availability_select_all" on public.host_availability;
create policy "host_availability_select_all"
  on public.host_availability for select
  to authenticated
  using (true);

-- 書き込みは本人のみ。
drop policy if exists "host_availability_write_own" on public.host_availability;
create policy "host_availability_write_own"
  on public.host_availability for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ------------------------------------------------------------
-- 2. まとめて保存する
--    画面はタイルを塗る操作なので、1枠ずつではなく全体を置き換える。
--    p_slots は [{"weekday":1,"hour":20}, ...] の形。
-- ------------------------------------------------------------
create or replace function public.set_host_availability(p_slots jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if jsonb_typeof(coalesce(p_slots, '[]'::jsonb)) <> 'array' then
    raise exception 'INVALID_SLOTS';
  end if;

  delete from public.host_availability where user_id = v_uid;

  insert into public.host_availability (user_id, weekday, hour)
  select distinct v_uid,
         (s->>'weekday')::smallint,
         (s->>'hour')::smallint
  from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) s
  where (s->>'weekday')::int between 0 and 6
    and (s->>'hour')::int between 0 and 23;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.set_host_availability(jsonb) is
  '自分の募集枠をまとめて置き換える。[{"weekday":1,"hour":20},...] を渡す。';

revoke all on function public.set_host_availability(jsonb) from public;
grant execute on function public.set_host_availability(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 3. 募集枠を設定しているか(判定を1か所に集約する)
-- ------------------------------------------------------------
create or replace function public.host_has_availability(p_host_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.host_availability where user_id = p_host_id);
$$;

-- 指定の時刻(日本時間で解釈)が募集枠に入っているか。
-- 枠を1つも設定していないピタメイトは常に true(従来どおり)。
create or replace function public.host_is_open_at(p_host_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not public.host_has_availability(p_host_id) then true
    else exists (
      select 1 from public.host_availability a
      where a.user_id = p_host_id
        and a.weekday = extract(dow from (p_at at time zone 'Asia/Tokyo'))::smallint
        and a.hour = extract(hour from (p_at at time zone 'Asia/Tokyo'))::smallint
    )
  end;
$$;

comment on function public.host_is_open_at(uuid, timestamptz) is
  'その時刻が募集枠の中か。枠を設定していないピタメイトは常に受け付ける(true)。';

-- ------------------------------------------------------------
-- 4. 誰でも見られるスケジュール
--    これから p_days 日ぶんを1時間ごとに返す。画面はこれをタイルに並べるだけ。
--
--    state:
--      past   … 過ぎた
--      closed … 募集していない
--      booked … 予約が入っている
--      open   … 募集していて空いている
--
--    予約の中身(相手が誰か・何コインか)は返しません。
-- ------------------------------------------------------------
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
      -- 「今の時間」から始める(過ぎた枠も1日目の頭に出して、位置がずれないように)
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
      else 'open'
    end as state
  from slots s
  order by s.slot_at;
$$;

comment on function public.host_schedule(uuid, int) is
  'ピタメイトの空き状況を1時間ごとに返す(past/closed/booked/open)。誰でも見られる。予約の中身は返さない。';

revoke all on function public.host_schedule(uuid, int) from public;
grant execute on function public.host_schedule(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 5. 募集枠の外は予約できないようにする
--    枠を設定していないピタメイトは従来どおり(host_is_open_at が true を返す)。
--    プレイ時間の全体が枠に収まっている必要がある。
-- ------------------------------------------------------------
create or replace function public.booking_fits_availability(
  p_host_id uuid,
  p_start timestamptz,
  p_minutes int
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_at timestamptz;
  v_end timestamptz;
begin
  if not public.host_has_availability(p_host_id) then
    return true;
  end if;

  v_at := date_trunc('hour', p_start);
  v_end := p_start + make_interval(mins => p_minutes);

  -- 開始の属する時間から、終了の直前の時間まで、すべて開いていること
  while v_at < v_end loop
    if not public.host_is_open_at(p_host_id, v_at) then
      return false;
    end if;
    v_at := v_at + interval '1 hour';
  end loop;
  return true;
end;
$$;

comment on function public.booking_fits_availability(uuid, timestamptz, int) is
  'プレイ時間の全体が募集枠に収まっているか。枠を設定していないピタメイトは常にtrue。';

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

  -- 募集していない時間帯には申し込めない(0051)。
  -- 枠を1つも設定していないピタメイトは従来どおり制限なし。
  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 枠の検査。ロックを取ってから調べる(同時申し込みで両方通るのを防ぐ)
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
-- 6. さがす画面などで「いま募集中か」をひと目で出せるように
-- ------------------------------------------------------------
create or replace function public.host_open_now(p_host_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.host_is_open_at(p_host_id, now())
     and public._booking_slot_conflict(p_host_id, now(), 60) is null;
$$;

comment on function public.host_open_now(uuid) is
  'いま募集枠の中で、かつ直近1時間に予約が入っていないか。「いま遊べる」表示に使う。';

revoke all on function public.host_open_now(uuid) from public;
grant execute on function public.host_open_now(uuid) to authenticated;
