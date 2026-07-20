-- ============================================================
-- エスクロー予約決済 + Stripe Connect によるホストへの実際の振込
-- ------------------------------------------------------------
-- 方針(重要・法務上の設計判断):
--   ・「購入したコイン」(coin_wallets.balance)と「予約完了で得た
--     報酬コイン」(coin_wallets.earned_balance)を別会計にする。
--     換金(Stripeへの実振込)できるのは earned_balance のみ。
--     balance を換金可能にしてしまうと、盗難クレジットカード等で
--     購入したコインを即座に現金化できてしまい、マネーロンダリング・
--     チャージバック詐欺の温床になるため、意図的に分離する。
--   ・予約確定(create_booking)時点では、これまでどおりゲストの
--     balance のみを減らす(ホストへは何も渡さない=事実上のエスクロー)。
--   ・「プレイ完了」でゲストが解放操作を行って初めて、対応するコイン数が
--     ホストの earned_balance に加算される(ゲストの検収 = 支払い確定、
--     フリマアプリの「受け取り評価」と同じ考え方。ホストが自分で
--     一方的に解放できないようにする)。
--   ・実際の現金化はホストがStripe Connect(Express)アカウントを
--     開設した上で、earned_balance の範囲でのみ請求できる。実際の
--     Stripe Transfer実行はEdge Function(service_role)が行う。
--
--   ⚠️ この設計(ゲストからホストへの実質的な送金の仲介)は、
--   資金決済法上「収納代行」として扱えるか「資金移動業」に該当するか、
--   具体的な運用(コインの有効期限・購入と予約のひも付き方等)次第で
--   判断が分かれる可能性がある。本番投入前に必ず弁護士レビューを
--   受けること(docs/legal/coin-economy-legal-review.md 追記分を参照)。
-- ============================================================

-- ------------------------------------------------------------
-- coin_wallets: ホストの報酬用の別残高を追加
-- ------------------------------------------------------------
alter table public.coin_wallets
  add column earned_balance int not null default 0 check (earned_balance >= 0);

comment on column public.coin_wallets.balance is
  '購入したコインの残高。予約の支払いに使える。換金は不可(前払式支払手段としての性質を維持するため)。';
comment on column public.coin_wallets.earned_balance is
  'ホストとして完了した予約から得た報酬コインの残高。Stripe Connect経由でのみ換金できる。購入コイン(balance)とは会計を分離している。';

-- coin_transactions.type に完了報酬/払い出しの区分を追加
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in ('purchase', 'booking_spend', 'refund', 'bonus', 'booking_earned', 'payout'));

-- ------------------------------------------------------------
-- complete_booking: ゲストが「プレイ完了」を確定し、エスクローを解放する。
-- ゲスト本人のみが呼べる(ホストが自分で解放することはできない)。
-- ------------------------------------------------------------
create function public.complete_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_COMPLETE';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_CONFIRMABLE';
  end if;

  update public.bookings set status = 'completed' where id = p_booking_id;

  update public.coin_wallets
    set earned_balance = earned_balance + v_booking.coins
    where user_id = v_booking.host_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'complete_booking');
end;
$$;

revoke all on function public.complete_booking(uuid) from public;
grant execute on function public.complete_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- host_payout_accounts: ホストのStripe Connect(Express)アカウント
-- ------------------------------------------------------------
create table public.host_payout_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  stripe_account_id text not null unique,
  payouts_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.host_payout_accounts enable row level security;

create policy "host_payout_accounts_select_own"
  on public.host_payout_accounts for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEは意図的にポリシーを作らない(create-connect-account /
-- stripe-webhook Edge Function が service_role で行う)。

create trigger host_payout_accounts_set_updated_at
  before update on public.host_payout_accounts
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- payouts: 換金(Stripe Transfer)の履歴
-- ------------------------------------------------------------
create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  coins int not null check (coins > 0),
  amount_yen int not null check (amount_yen > 0),
  stripe_transfer_id text,
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed')),
  failure_reason text,
  created_at timestamptz not null default now()
);

alter table public.payouts enable row level security;

create policy "payouts_select_own"
  on public.payouts for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEは意図的にポリシーを作らない(request-payout Edge Function
-- が下記RPC経由(service_role)でのみ行う)。

-- ------------------------------------------------------------
-- reserve_payout: 換金リクエストの残高チェック+仮確保をアトミックに行う。
-- 実際のStripe Transfer実行はEdge Function側で行い、成功/失敗に応じて
-- finalize_payout / fail_payout を呼ぶ。service_role専用(clientから直接
-- 呼べない。実際の送金なしに残高だけ動かせてしまうため)。
-- ------------------------------------------------------------
create function public.reserve_payout(p_user_id uuid, p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance int;
  v_payouts_enabled boolean;
  v_payout_id uuid;
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select coalesce(payouts_enabled, false) into v_payouts_enabled
  from public.host_payout_accounts where user_id = p_user_id;
  if not coalesce(v_payouts_enabled, false) then
    raise exception 'PAYOUTS_NOT_ENABLED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = p_user_id for update;
  if v_balance is null or v_balance < p_coins then
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = p_user_id;

  insert into public.payouts (user_id, coins, amount_yen, status)
    values (p_user_id, p_coins, p_coins, 'pending')
    returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, -p_coins, 'payout', 'reserve_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

revoke all on function public.reserve_payout(uuid, int) from public;
-- authenticatedには意図的にgrantしない(service_role専用)。

create function public.finalize_payout(p_payout_id uuid, p_stripe_transfer_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.payouts
    set status = 'paid', stripe_transfer_id = p_stripe_transfer_id
    where id = p_payout_id and status = 'pending';
end;
$$;

revoke all on function public.finalize_payout(uuid, text) from public;

create function public.fail_payout(p_payout_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payout public.payouts;
begin
  select * into v_payout from public.payouts where id = p_payout_id and status = 'pending' for update;
  if v_payout.id is null then
    return;
  end if;

  update public.payouts set status = 'failed', failure_reason = p_reason where id = p_payout_id;

  -- 送金に失敗したので確保していたコインを払い戻す
  update public.coin_wallets set earned_balance = earned_balance + v_payout.coins where user_id = v_payout.user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_payout.user_id, v_payout.coins, 'refund', 'fail_payout:' || p_payout_id);
end;
$$;

revoke all on function public.fail_payout(uuid, text) from public;
