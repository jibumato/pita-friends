-- ============================================================
-- ホスト手数料(超過累進ティア + 指名リピート割引)の導入
-- ------------------------------------------------------------
-- これまでホストは消費されたコインを100%受け取っており、運営の収益は
-- 換金手数料(300コイン/回)とコインの購入・失効差分だけだった。
-- ここでプラットフォーム手数料を導入する。
--
-- ■ 料率(超過累進。所得税と同じで、超えた分にだけ高い率がかかるのではなく
--   「各段の範囲にその段の率」がかかる)
--     〜30,000コイン      20%
--     30,000〜100,000     17%
--     100,000〜300,000    14%
--     300,000〜           12%
--   判定の母数は「その月に確定した予約(チケット)売上」。ギフトは含めない。
--
-- ■ 指名リピート割引
--   同じゲストからの2回目以降の予約は、その予約に適用される料率から3pt引く。
--   ただし下限10%。ホストが自分の顧客を育てるほど手取りが増える設計。
--
-- ■ ギフト
--   累進の対象外で一律30%。金額が任意で青天井になりうるため、
--   ティア判定に混ぜると料率設計が歪むため分けている。
--
-- ■ 月内の整合性(ここが実装上の肝)
--   超過累進を「確定のたびに」適用するので、確定時点の限界料率だけで引くと
--   月末に遡及補正が必要になる。それを避けるため、各確定では
--     手数料 = 累進手数料(確定後の月間GMV) − 累進手数料(確定前の月間GMV)
--   を引く。こうすると月末時点の合計が必ず累進計算と一致し、補正がいらない。
--
-- ⚠️ 法務: 手数料の導入は規約(第8条)・特商法表記への反映が必要。
--    収納代行の整理(弁護士Q1)自体は、プラットフォームが仲介手数料を
--    取ること自体で崩れるものではないが、料率と控除の明示は必要。
--    docs/open-issues.md の E-11 を参照。
-- ============================================================

-- ------------------------------------------------------------
-- 料率マスタ(将来の改定はこの表を差し替えるだけで済むようにする)
-- ------------------------------------------------------------
create table public.host_fee_tiers (
  step smallint primary key,
  -- その段の上限(コイン)。null は上限なし
  upper_bound int,
  rate numeric(4, 3) not null check (rate >= 0 and rate <= 1)
);

comment on table public.host_fee_tiers is
  'ホスト手数料の超過累進ティア。月間の予約売上(ギフト除く)に対して、各段の範囲にその段の率をかける。';

insert into public.host_fee_tiers (step, upper_bound, rate) values
  (1, 30000, 0.200),
  (2, 100000, 0.170),
  (3, 300000, 0.140),
  (4, null, 0.120);

alter table public.host_fee_tiers enable row level security;

-- 料率は利用者に開示する情報なので誰でも読める
create policy "host_fee_tiers_select_all"
  on public.host_fee_tiers for select
  to authenticated
  using (true);

-- ------------------------------------------------------------
-- 手数料の明細(ダッシュボードの内訳・運営の突合に使う)
-- ------------------------------------------------------------
create table public.platform_fees (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('booking', 'gift')),
  booking_id uuid references public.bookings (id) on delete set null,
  gift_id uuid references public.gifts (id) on delete set null,
  gross_coins int not null check (gross_coins >= 0),
  fee_coins int not null check (fee_coins >= 0),
  net_coins int not null check (net_coins >= 0),
  -- 実際に適用された率(gross に対する fee の比)。表示用
  applied_rate numeric(5, 4) not null,
  -- 指名リピート割引が効いたか
  repeat_discounted boolean not null default false,
  created_at timestamptz not null default now()
);

comment on table public.platform_fees is
  'ホストから控除したプラットフォーム手数料の明細。ダッシュボードの内訳表示と、運営の突合に使う。';

alter table public.platform_fees enable row level security;

create policy "platform_fees_select_own"
  on public.platform_fees for select
  to authenticated
  using (host_id = auth.uid());

create index platform_fees_host_idx on public.platform_fees (host_id, created_at desc);

-- coin_transactions に手数料の控除を記録できるようにする
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus',
    'booking_earned', 'payout', 'expire',
    'gift_sent', 'gift_received',
    'platform_fee'
  ));

-- ------------------------------------------------------------
-- host_progressive_fee: 月間GMVに対する累進手数料の累計額
-- ------------------------------------------------------------
create function public.host_progressive_fee(p_gmv int)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_fee numeric := 0;
  v_prev int := 0;
  v_tier record;
begin
  if p_gmv is null or p_gmv <= 0 then
    return 0;
  end if;
  for v_tier in select upper_bound, rate from public.host_fee_tiers order by step loop
    exit when p_gmv <= v_prev;
    v_fee := v_fee + (least(p_gmv, coalesce(v_tier.upper_bound, p_gmv)) - v_prev) * v_tier.rate;
    v_prev := coalesce(v_tier.upper_bound, p_gmv);
  end loop;
  return v_fee;
end;
$$;

comment on function public.host_progressive_fee(int) is
  '月間の予約売上に対する累進手数料の累計額。各確定では「確定後 − 確定前」の差分を引くことで、月末に遡及補正が要らないようにしている。';

-- ------------------------------------------------------------
-- host_monthly_ticket_gmv: JSTの当月に確定した予約売上(自分がホストの分)
-- p_exclude_booking を指定すると、その予約を除いた額を返す(確定前の額を出す用)
-- ------------------------------------------------------------
create function public.host_monthly_ticket_gmv(
  p_host_id uuid,
  p_at timestamptz default now(),
  p_exclude_booking uuid default null
)
returns int
language sql
stable
set search_path = public
as $$
  select coalesce(sum(b.coins), 0)::int
  from public.bookings b
  where b.host_id = p_host_id
    and b.status = 'completed'
    and date_trunc('month', (b.scheduled_at at time zone 'Asia/Tokyo'))
        = date_trunc('month', (p_at at time zone 'Asia/Tokyo'))
    and (p_exclude_booking is null or b.id <> p_exclude_booking);
$$;

-- ------------------------------------------------------------
-- 手数料の控除はトリガーで行う。
--
-- 報酬を付与している関数(complete_booking / auto_complete_bookings /
-- send_gift)はいずれも長く、send_gift は 0019→0022 で4回作り直している。
-- これらを丸ごと複製して手数料版に差し替えると、以後の改修でロジックが
-- 二重管理になりズレる。そこで既存関数は「満額を付与する」ままにしておき、
-- 直後にトリガーで手数料ぶんを引き戻す形にする。
-- 取引履歴も booking_earned(満額) + platform_fee(控除) の2行になり、
-- ホストから見て「いくら稼いで、いくら引かれたか」がそのまま読める。
-- ------------------------------------------------------------

-- 予約が completed になったときに手数料を引く
create function public._apply_booking_fee()
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
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(new.host_id, new.scheduled_at, new.id);
  v_gmv_after := v_gmv_before + new.coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after)
              - public.host_progressive_fee(v_gmv_before);
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

-- 「完了になった瞬間」だけを拾う。再実行や他の更新では発火させない。
--
-- ⚠️ deferrable initially deferred にしているのは必須。
--    complete_booking は「bookings を completed にする」→「報酬を満額付与する」
--    の順で書かれているため、通常の AFTER UPDATE では**付与より前**に
--    トリガーが走ってしまい、まだ残高が無いところから手数料を引こうとして
--    控除が丸ごと消える(実際に検証で1件目の手数料400コインが消えた)。
--    トランザクション終了時まで遅延させることで、付与済みの残高から引ける。
create constraint trigger bookings_apply_fee
  after update on public.bookings
  deferrable initially deferred
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function public._apply_booking_fee();

-- ギフト受領時に一律30%を引く
create function public._apply_gift_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c_gift_rate constant numeric := 0.30;
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;
  v_fee := least(greatest(round(new.coins * c_gift_rate)::int, 0), new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.receiver_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (new.receiver_id, -v_fee, 'platform_fee', 'gift_fee:' || new.id);
  end if;

  insert into public.platform_fees (
    host_id, kind, gift_id, gross_coins, fee_coins, net_coins, applied_rate)
  values (new.receiver_id, 'gift', new.id, new.coins, v_fee, new.coins - v_fee, c_gift_rate);

  return new;
end;
$$;

create trigger gifts_apply_fee
  after insert on public.gifts
  for each row
  execute function public._apply_gift_fee();

-- ------------------------------------------------------------
-- 手数料をかけない経路(意図的)
--   ・直前キャンセルの没収分(ゲスト都合・開始後)は、役務の対価ではなく
--     機会損失の補償なので手数料を取らない。
--     そもそもこの没収の設計自体が見直し対象(open-issues.md の E-10)。
--   ・換金申請が却下されて戻る分(return_payout)は再付与なので対象外。
-- ------------------------------------------------------------
