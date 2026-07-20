-- ============================================================
-- 決済(Stripe)連携: コインパック定義 と 購入履歴(冪等)
-- ------------------------------------------------------------
-- 方針:
--   ・コインの付与はサーバー(Stripe Webhook → service_role → purchase_coins)
--     経由でのみ行う。クライアントは coin_wallets を書けない(0003)。
--   ・パックの価格・付与数は coin_packs(サーバー権威)で確定する。
--     クライアントが送るのは pack_id のみで、金額やコイン数は信用しない。
--   ・二重付与を防ぐため coin_purchases に stripe_session_id の一意制約を置く。
-- 法務: 有償コインは前払式支払手段(資金決済法)。売上開始時の表示義務・
--       基準日残高1,000万円超で届出/供託(docs/legal/coin-economy-legal-review.md §2)。
-- ============================================================

-- ------------------------------------------------------------
-- coin_packs: 販売中のコインパック(公開・読み取りのみ)
-- ------------------------------------------------------------
create table public.coin_packs (
  id text primary key,
  coins int not null check (coins > 0),
  bonus_coins int not null default 0 check (bonus_coins >= 0),
  price_yen int not null check (price_yen > 0),
  sort int not null default 0,
  active boolean not null default true
);

alter table public.coin_packs enable row level security;

-- 誰でも(未ログインでも)一覧を見られる。書き込みは service_role のみ(ポリシー無し)。
create policy "coin_packs_select_all"
  on public.coin_packs for select
  using (active = true);

insert into public.coin_packs (id, coins, bonus_coins, price_yen, sort) values
  ('pack_300', 300, 0, 300, 1),
  ('pack_1000', 1000, 50, 1000, 2),
  ('pack_3000', 3000, 300, 3000, 3),
  ('pack_6000', 6000, 900, 6000, 4);

-- ------------------------------------------------------------
-- coin_purchases: 購入履歴 兼 冪等キー
--   Webhook が checkout.session.completed を受けたときに1行 insert する。
--   stripe_session_id の unique 制約で、同じ決済の二重付与を防ぐ。
-- ------------------------------------------------------------
create table public.coin_purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  pack_id text references public.coin_packs (id),
  coins_credited int not null check (coins_credited > 0),
  price_yen int not null check (price_yen >= 0),
  stripe_session_id text not null unique,
  stripe_payment_intent text,
  created_at timestamptz not null default now()
);

alter table public.coin_purchases enable row level security;

-- 本人は自分の購入履歴のみ閲覧可。書き込みは service_role のみ(ポリシー無し)。
create policy "coin_purchases_select_own"
  on public.coin_purchases for select
  to authenticated
  using (user_id = auth.uid());

-- ------------------------------------------------------------
-- credit_coins_for_purchase: Webhook から呼ぶ冪等な付与関数
--   ・stripe_session_id が既にあれば何もしない(二重付与防止)
--   ・無ければ coin_purchases に記録し、coin_wallets に加算する
--   service_role からのみ呼ばれる想定(authenticated へは grant しない)。
-- ------------------------------------------------------------
create function public.credit_coins_for_purchase(
  p_user_id uuid,
  p_pack_id text,
  p_coins int,
  p_price_yen int,
  p_session_id text,
  p_payment_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 既に処理済みのセッションなら冪等に終了
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets set balance = balance + p_coins where user_id = p_user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$$;

-- authenticated には付与関数を公開しない(サーバーのservice_role専用)。
revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, text, text) from public;
