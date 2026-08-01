-- ============================================================
-- 0091: 料率の遡及適用を止める(G3)
--
-- 規約 第8条の2:
--   3の2 予約は**30%**、ギフトは**40%**を超えない
--   4項   変更は**30日前まで**に、**理由を明らかにして**通知する。
--         不利益となる変更は**あわせて個別に通知**する
--   5項   **変更前に成立した予約およびギフトには、変更前の率を適用する**
--   5の2  通知後に離脱しても、変更前に成立した分は従前の条件で確定・換金
--
-- ■ 何が合っていなかったか
--   料率(host_fee_tiers)は**現在値が1組あるだけ**で、「いつからの率か」
--   を持っていなかった。しかも手数料は**予約の成立時ではなく、報酬の
--   確定時に現在値を読む。** したがって料率を変えると、
--   **変更前に成立していた予約にも新料率がかかる**(5項違反)。
--   30日前通知の仕組みも無く、上限(3の2)も紳士協定だった。
--
--   ここまで顕在化していないのは、**料率を一度も変えていないから**。
--   変える日が来た瞬間に債務不履行になる。
--
-- ■ 直しかた
--   ①料率に **effective_from** を持たせ、**成立日時で引く**
--   ②上限を**制約**にする(規約が画した数値を運用で越えられなくする)
--   ③変更は**30日以上先の日付でしか予約できない**関数に寄せ、
--     予約と同時にピタメイト全員へ**個別通知**する
--
--   ②③は 0083(ボーナス0)・0087(換金保留は最長30日)と同じ手口。
--   **条文の数値は、コードではなく制約で守る。**
--
-- ■ 弁護士の指摘(論点3)
--   「**上限のない変更権は『青天井』と評価される最大の弱点**」
--   「**実質的な離脱の自由は『辞めても、稼いだ分は従前の条件で
--     回収できる』ことで初めて担保される**」
-- ============================================================

-- ------------------------------------------------------------
-- 1. 料率に「いつからの率か」を持たせる
-- ------------------------------------------------------------
alter table public.host_fee_tiers
  add column if not exists effective_from timestamptz not null default '2000-01-01T00:00:00Z';

alter table public.host_fee_tiers drop constraint if exists host_fee_tiers_pkey;
alter table public.host_fee_tiers
  add constraint host_fee_tiers_pkey primary key (effective_from, step);

-- 規約 第8条の2第3の2項。**30%を超える率を入れられなくする**
alter table public.host_fee_tiers drop constraint if exists host_fee_tiers_cap_check;
alter table public.host_fee_tiers
  add constraint host_fee_tiers_cap_check check (rate >= 0 and rate <= 0.30);

comment on column public.host_fee_tiers.effective_from is
  '規約第8条の2第5項。この日時以降に成立した予約に適用する。過去の組は消さない(旧料率の適用に要る)。';

-- ギフトの率も表に出す。**関数の中の定数のままでは effective_from を持てない**
create table if not exists public.gift_fee_rates (
  effective_from timestamptz primary key,
  -- 規約 第8条の2第3の2項
  rate numeric(4, 3) not null check (rate >= 0 and rate <= 0.40)
);

comment on table public.gift_fee_rates is
  'ありがとうギフトの利用料の率(規約第8条の2)。上限40%は第3の2項。';

insert into public.gift_fee_rates (effective_from, rate)
values ('2000-01-01T00:00:00Z', 0.350)
on conflict (effective_from) do nothing;

alter table public.gift_fee_rates enable row level security;

-- 料率は開示する情報なので誰でも読める(第3項「本サービス上に表示します」)
create policy "gift_fee_rates_select_all"
  on public.gift_fee_rates for select
  to anon, authenticated
  using (true);

-- 変更の理由を残す。**4項が「理由を明らかにして」と約束している**
create table if not exists public.fee_change_notices (
  effective_from timestamptz primary key,
  announced_at timestamptz not null default now(),
  announced_by uuid references auth.users (id),
  reason text not null,
  notified_hosts int not null default 0
);

comment on table public.fee_change_notices is
  '料率変更の予告(規約第8条の2第4項)。30日前までの通知と、理由の記録。';

alter table public.fee_change_notices enable row level security;

create policy "fee_change_notices_select_all"
  on public.fee_change_notices for select
  to anon, authenticated
  using (true);

-- ------------------------------------------------------------
-- 2. 「その時点で適用される料率の組」を引く
-- ------------------------------------------------------------
create or replace function public.fee_effective_from(p_at timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public
as $$
  select max(t.effective_from) from public.host_fee_tiers t
  where t.effective_from <= p_at
$$;

comment on function public.fee_effective_from(timestamptz) is
  'その時点で適用される料率の組(規約第8条の2第5項)。';

-- ------------------------------------------------------------
-- 3. 累進手数料を「成立日時の料率」で計算する
--
-- ⚠️ 1引数版は**落としてから**2引数版を作る。既定値つきで増やすと
--    1引数の呼び出しが両方に一致して「function is not unique」になる。
-- ------------------------------------------------------------
drop function if exists public.host_progressive_fee(int);

create function public.host_progressive_fee(p_gmv int, p_at timestamptz default now())
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_fee numeric := 0;
  v_prev int := 0;
  v_tier record;
  v_eff timestamptz;
begin
  if p_gmv is null or p_gmv <= 0 then
    return 0;
  end if;

  -- **p_at の時点で有効だった組を使う。** 現在値ではない
  v_eff := public.fee_effective_from(p_at);

  for v_tier in
    select upper_bound, rate from public.host_fee_tiers
    where effective_from = v_eff
    order by step
  loop
    exit when p_gmv <= v_prev;
    v_fee := v_fee + (least(p_gmv, coalesce(v_tier.upper_bound, p_gmv)) - v_prev) * v_tier.rate;
    v_prev := coalesce(v_tier.upper_bound, p_gmv);
  end loop;
  return v_fee;
end;
$$;

comment on function public.host_progressive_fee(int, timestamptz) is
  '月間の予約売上に対する累進手数料の累計額。p_at の時点で有効な料率の組を使う(規約第8条の2第5項)。';

-- ------------------------------------------------------------
-- 4. ギフトの率
-- ------------------------------------------------------------
create or replace function public.gift_fee_rate(p_at timestamptz default now())
returns numeric
language sql
stable
set search_path = public
as $$
  select r.rate from public.gift_fee_rates r
  where r.effective_from <= p_at
  order by r.effective_from desc
  limit 1
$$;

comment on function public.gift_fee_rate(timestamptz) is
  'ありがとうギフトの利用料の率。p_at の時点で有効な値(規約第8条の2第5項)。';

-- ------------------------------------------------------------
-- 5. 予約の手数料: **成立日時**の料率で引く
--
-- 本文は 0033 のままで、料率を引く時点を渡すようにしただけ。
-- 成立日時は confirmed_at(承諾された時刻)。まだ無ければ作成時刻。
-- ------------------------------------------------------------
create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c_repeat_discount constant numeric := 0.03;
  c_rate_floor constant numeric := 0.10;
  v_gmv_before int;
  v_gmv_after int;
  v_base_fee numeric;
  v_rate numeric;
  v_discount numeric := 0;
  v_is_repeat boolean := false;
  v_fee int;
  -- 0091: **予約が「成立」した時点。**確定した時点ではない(規約第8条の2第5項)
  v_agreed timestamptz;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  v_agreed := coalesce(new.confirmed_at, new.created_at, now());

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(new.host_id, new.scheduled_at, new.id);
  v_gmv_after := v_gmv_before + new.coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after, v_agreed)
              - public.host_progressive_fee(v_gmv_before, v_agreed);
  v_rate := v_base_fee / new.coins;

  -- 指名リピート: 同じゲストと過去に完了した予約があるか
  select exists (
    select 1 from public.bookings b
    where b.host_id = new.host_id
      and b.guest_id = new.guest_id
      and b.status = 'completed'
      and b.id <> new.id
      and b.scheduled_at < new.scheduled_at
  ) into v_is_repeat;

  if v_is_repeat then
    v_discount := least(c_repeat_discount, greatest(0, v_rate - c_rate_floor)) * new.coins;
  end if;

  v_fee := least(greatest(0, round(v_base_fee - v_discount))::int, new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (new.host_id, -v_fee, 'platform_fee', new.id, 'booking_fee');
  end if;

  insert into public.platform_fees (
    host_id, kind, booking_id, gross_coins, fee_coins, net_coins, applied_rate, repeat_discounted)
  values (
    new.host_id, 'booking', new.id, new.coins, v_fee, new.coins - v_fee,
    round(v_fee::numeric / new.coins, 4), v_is_repeat);

  return new;
end;
$$;

revoke all on function public._apply_booking_fee() from public, anon;

-- ------------------------------------------------------------
-- 6. ギフトの手数料: 表から引く(定数をやめる)
-- ------------------------------------------------------------
create or replace function public._apply_gift_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 0091: 定数をやめて表から引く。ギフトは成立=作成なので now() でよい
  v_rate numeric := public.gift_fee_rate(now());
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;
  v_fee := least(greatest(round(new.coins * v_rate)::int, 0), new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.receiver_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (new.receiver_id, -v_fee, 'platform_fee', 'gift_fee:' || new.id);
  end if;

  insert into public.platform_fees (
    host_id, kind, gift_id, gross_coins, fee_coins, net_coins, applied_rate)
  values (new.receiver_id, 'gift', new.id, new.coins, v_fee, new.coins - v_fee, v_rate);

  return new;
end;
$$;

revoke all on function public._apply_gift_fee() from public, anon;

-- ------------------------------------------------------------
-- 7. 表示(第3項)は「いま有効な組」を出す
-- ------------------------------------------------------------
create or replace function public.fee_rates()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'bookingTiers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'upperBound', t.upper_bound,
               'percent', round(t.rate * 100, 1)
             ) order by t.step), '[]'::jsonb)
      from public.host_fee_tiers t
      where t.effective_from = public.fee_effective_from(now())
    ),
    'repeatDiscountPoints', 3,
    'floorPercent', 10,
    -- 0091: 定数をやめて表から引く
    'giftPercent', round(public.gift_fee_rate(now()) * 100, 1),
    -- 規約 第8条の2第3の2項の上限。**画面に出せる形で返す**
    'bookingCapPercent', 30,
    'giftCapPercent', 40,
    -- 予定されている変更(第4項の予告)。無ければ null
    'scheduledChange', (
      select jsonb_build_object(
               'effectiveFrom', n.effective_from,
               'reason', n.reason,
               'bookingTiers', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'upperBound', t2.upper_bound,
                          'percent', round(t2.rate * 100, 1)
                        ) order by t2.step), '[]'::jsonb)
                 from public.host_fee_tiers t2
                 where t2.effective_from = n.effective_from
               ),
               'giftPercent', (
                 select round(r.rate * 100, 1) from public.gift_fee_rates r
                 where r.effective_from = n.effective_from
               )
             )
      from public.fee_change_notices n
      where n.effective_from > now()
      order by n.effective_from
      limit 1
    )
  );
$$;

comment on function public.fee_rates() is
  '手数料の率(表示用)。規約 第8条の2第3項の「本サービス上に表示します」を満たす。いま有効な組と、予告されている変更を返す。';

revoke all on function public.fee_rates() from public;
grant execute on function public.fee_rates() to anon, authenticated;

-- ------------------------------------------------------------
-- 8. 料率の変更は「30日以上先」でしか予約できない(第4項)
--
-- **即時に変えられる経路を残さない。** UPDATE で今の行を書き換えれば
-- 30日前通知を飛ばせてしまうので、変更はこの関数だけを通す。
-- ------------------------------------------------------------
create or replace function public.admin_schedule_fee_change(
  p_effective_from timestamptz,
  p_reason text,
  -- [{"upperBound": 30000, "percent": 20.0}, ...] 上限 null は「それ以上」
  p_booking_tiers jsonb,
  p_gift_percent numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_step smallint := 0;
  v_n int := 0;
  v_hosts int := 0;
  v_min_days int := 30;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  -- 4項「変更の内容および理由を明らかにして」
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  -- 4項「変更の30日前までに」
  if p_effective_from < now() + make_interval(days => v_min_days) then
    raise exception 'NOTICE_PERIOD_TOO_SHORT';
  end if;
  if exists (select 1 from public.fee_change_notices n
             where n.effective_from = p_effective_from) then
    raise exception 'ALREADY_SCHEDULED';
  end if;
  if p_booking_tiers is null or jsonb_array_length(p_booking_tiers) = 0 then
    raise exception 'TIERS_REQUIRED';
  end if;

  for v_row in select * from jsonb_array_elements(p_booking_tiers)
  loop
    v_step := v_step + 1;
    -- 上限(3の2)は制約が最終的に止めるが、ここでも分かりやすい名前で落とす
    if (v_row ->> 'percent')::numeric > 30 then
      raise exception 'BOOKING_RATE_OVER_CAP';
    end if;
    insert into public.host_fee_tiers (effective_from, step, upper_bound, rate)
    values (p_effective_from, v_step,
            nullif(v_row ->> 'upperBound', '')::int,
            round((v_row ->> 'percent')::numeric / 100, 3));
    v_n := v_n + 1;
  end loop;

  if p_gift_percent > 40 then
    raise exception 'GIFT_RATE_OVER_CAP';
  end if;
  insert into public.gift_fee_rates (effective_from, rate)
  values (p_effective_from, round(p_gift_percent / 100, 3));

  -- 4項「不利益となる変更については、あわせて**個別に**通知します」
  -- 有利・不利の判定は率の組み合わせで一概に言えないので、**全員に個別通知**する。
  -- 送りすぎて困ることはないが、送り漏れると条文違反になる
  insert into public.notifications (user_id, type, title, body)
  select h.user_id, 'system',
    'プラットフォーム利用料の率が変わります('
      || to_char(p_effective_from, 'YYYY年MM月DD日') || 'から)',
    '理由: ' || p_reason
      || ' / **' || to_char(p_effective_from, 'YYYY年MM月DD日')
      || 'より前に成立した予約・ギフトには、変更前の率をそのまま適用します**'
      || '(利用規約 第8条の2第5項)。新しい率はコインウォレットの料率表示で'
      || 'ご確認いただけます。'
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  where h.is_host and p.withdrawn_at is null;
  get diagnostics v_hosts = row_count;

  insert into public.fee_change_notices
    (effective_from, announced_by, reason, notified_hosts)
  values (p_effective_from, auth.uid(), p_reason, v_hosts);

  perform public._log_admin_action('schedule_fee_change', null,
    to_char(p_effective_from, 'YYYY-MM-DD') || ' ' || p_reason
      || ' / ' || v_hosts || '名へ通知');

  return jsonb_build_object(
    'effective_from', p_effective_from,
    'tiers', v_n,
    'notified_hosts', v_hosts
  );
end;
$$;

comment on function public.admin_schedule_fee_change(timestamptz, text, jsonb, numeric) is
  '料率の変更を予約する(規約第8条の2第4項)。30日以上先の日付でしか登録できず、ピタメイト全員へ個別に通知する。';

revoke all on function public.admin_schedule_fee_change(timestamptz, text, jsonb, numeric) from public, anon;
grant execute on function public.admin_schedule_fee_change(timestamptz, text, jsonb, numeric) to authenticated;

-- ------------------------------------------------------------
-- 9. 運営コンソール用の一覧
-- ------------------------------------------------------------
create or replace function public.admin_fee_schedules()
returns table (
  effective_from timestamptz,
  is_current boolean,
  is_future boolean,
  reason text,
  announced_at timestamptz,
  notified_hosts int,
  booking_tiers jsonb,
  gift_percent numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  select s.eff,
         s.eff = public.fee_effective_from(now()),
         s.eff > now(),
         n.reason,
         n.announced_at,
         n.notified_hosts,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'upperBound', t.upper_bound,
                   'percent', round(t.rate * 100, 1)) order by t.step), '[]'::jsonb)
          from public.host_fee_tiers t where t.effective_from = s.eff),
         (select round(r.rate * 100, 1) from public.gift_fee_rates r
          where r.effective_from = s.eff)
  from (
    select distinct effective_from as eff from public.host_fee_tiers
    union
    select distinct effective_from from public.gift_fee_rates
  ) s
  left join public.fee_change_notices n on n.effective_from = s.eff
  order by s.eff desc;
end;
$$;

revoke all on function public.admin_fee_schedules() from public, anon;
grant execute on function public.admin_fee_schedules() to authenticated;

-- ------------------------------------------------------------
-- 10. ダッシュボードの見込み表示も、いま有効な組を見る
-- ------------------------------------------------------------
-- 0034 の host_dashboard は host_fee_tiers を直接読んでいる。
-- effective_from を足したので、**組を絞らないと過去と未来の行が混ざる。**
-- 影響するのは「次のティア」の表示だけだが、混ざれば数字が狂う。
create or replace view public.host_fee_tiers_current
  with (security_invoker = true) as
  select t.step, t.upper_bound, t.rate
  from public.host_fee_tiers t
  where t.effective_from = public.fee_effective_from(now());

comment on view public.host_fee_tiers_current is
  'いま有効な料率の組だけ。0034のダッシュボードなど「現在の率」を見る側はこちらを使う。';

-- **anon には開けない。** 未ログインへの公開は fee_rates()(SECURITY DEFINER)
-- だけを窓口にしている(74_anon_surface が固定している面)
grant select on public.host_fee_tiers_current to authenticated;

-- ------------------------------------------------------------
-- 11. ダッシュボードを差し替える
--
-- 本文は 0034 のままで、host_fee_tiers の参照を
-- host_fee_tiers_current(いま有効な組)に向けただけ。
-- **絞らないと過去と未来の組が混ざり、次のティアの表示が狂う。**
-- ------------------------------------------------------------
create or replace function public.host_dashboard(p_at timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_ticket int;
  v_gift int;
  v_fee int;
  v_next_bound int;
  v_cur_rate numeric;
  v_next_rate numeric;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- JSTの当月[start, end)
  v_start := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) at time zone 'Asia/Tokyo');
  v_end   := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) + interval '1 month')
             at time zone 'Asia/Tokyo';

  v_ticket := public.host_monthly_ticket_gmv(v_uid, p_at);

  select coalesce(sum(pf.gross_coins), 0)::int into v_gift
  from public.platform_fees pf
  where pf.host_id = v_uid and pf.kind = 'gift'
    and pf.created_at >= v_start and pf.created_at < v_end;

  select coalesce(sum(pf.fee_coins), 0)::int into v_fee
  from public.platform_fees pf
  where pf.host_id = v_uid
    and pf.created_at >= v_start and pf.created_at < v_end;

  -- 次のティア(超過累進の次の段)
  select t.upper_bound, t.rate into v_next_bound, v_cur_rate
  from public.host_fee_tiers_current t
  where t.upper_bound is null or v_ticket < t.upper_bound
  order by t.step
  limit 1;

  select t.rate into v_next_rate
  from public.host_fee_tiers_current t
  where t.step = (
    select min(step) + 1 from public.host_fee_tiers_current
    where upper_bound is null or v_ticket < upper_bound
  );

  v_result := jsonb_build_object(
    'month_start', v_start,
    'ticket_coins', v_ticket,
    'gift_coins', v_gift,
    'gross_coins', v_ticket + v_gift,
    'fee_coins', v_fee,
    'net_coins', (v_ticket + v_gift) - v_fee,
    'effective_rate', case when (v_ticket + v_gift) > 0
                           then round(v_fee::numeric / (v_ticket + v_gift), 4) else 0 end,
    'tier', jsonb_build_object(
      'current_rate', v_cur_rate,
      'next_bound', v_next_bound,
      'next_rate', v_next_rate,
      'remaining_coins', case when v_next_bound is null then null
                              else greatest(0, v_next_bound - v_ticket) end
    )
  );

  -- 日別の売上(予約の確定額)
  v_result := v_result || jsonb_build_object('daily', coalesce((
    select jsonb_agg(jsonb_build_object('day', d.day, 'coins', d.coins) order by d.day)
    from (
      select extract(day from (b.scheduled_at at time zone 'Asia/Tokyo'))::int as day,
             sum(b.coins)::int as coins
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
      group by 1
    ) d
  ), '[]'::jsonb));

  -- 指名リピート(金額ベース)と人数
  v_result := v_result || (
    select jsonb_build_object(
      'repeat', jsonb_build_object(
        'repeat_coins', coalesce(sum(x.coins) filter (where x.is_repeat), 0)::int,
        'total_coins', coalesce(sum(x.coins), 0)::int,
        'repeat_rate', case when coalesce(sum(x.coins), 0) > 0
          then round(coalesce(sum(x.coins) filter (where x.is_repeat), 0)::numeric / sum(x.coins), 4)
          else 0 end,
        -- 「リピーター」は当月に2回目以降の予約が1件でもあるゲスト。
        -- 「新規」は残り。初回と2回目が同じ月にあるゲストを両方に数えないよう、
        -- 差し引きで出す(単純に filter で数えると二重計上になる)。
        'repeater_guests', count(distinct x.guest_id) filter (where x.is_repeat),
        'new_guests', count(distinct x.guest_id)
                      - count(distinct x.guest_id) filter (where x.is_repeat)
      ))
    from (
      select b.guest_id, b.coins,
             exists (
               select 1 from public.bookings p
               where p.host_id = b.host_id and p.guest_id = b.guest_id
                 and p.status = 'completed' and p.scheduled_at < b.scheduled_at
             ) as is_repeat
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
    ) x
  );

  -- 成約率と初回応答の速さ
  -- 承諾されたかどうかは promises の有無で判定する(promiseは approve_booking でしか作られない)
  v_result := v_result || (
    select jsonb_build_object(
      'response', jsonb_build_object(
        'requests', count(*),
        'approved', count(*) filter (where pr.id is not null),
        'approval_rate', case when count(*) > 0
          then round(count(*) filter (where pr.id is not null)::numeric / count(*), 4) else 0 end,
        'median_reply_seconds', percentile_cont(0.5) within group (
          order by extract(epoch from (b.scheduled_at - b.created_at))
        ) filter (where pr.id is not null)
      ))
    from public.bookings b
    left join public.promises pr on pr.booking_id = b.id
    where b.host_id = v_uid
      and b.created_at >= v_start and b.created_at < v_end
  );

  -- 埋まりやすい時間帯(直近4週に自分へ届いたリクエストの 曜日×時間)
  v_result := v_result || jsonb_build_object('heatmap', coalesce((
    select jsonb_agg(jsonb_build_object('dow', h.dow, 'hour', h.hour, 'count', h.c))
    from (
      select extract(isodow from (b.created_at at time zone 'Asia/Tokyo'))::int as dow,
             extract(hour   from (b.created_at at time zone 'Asia/Tokyo'))::int as hour,
             count(*)::int as c
      from public.bookings b
      where b.host_id = v_uid
        and b.created_at >= p_at - interval '28 days'
      group by 1, 2
    ) h
  ), '[]'::jsonb));

  return v_result;
end;
$$;

revoke all on function public.host_dashboard(timestamptz) from public, anon;
grant execute on function public.host_dashboard(timestamptz) to authenticated;
