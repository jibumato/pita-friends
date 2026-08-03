-- ============================================================
-- 0096: コイン購入の決済手段を記録する（PayPay導入に伴う）
-- ------------------------------------------------------------
-- PayPay を決済手段に追加すると、**0080(E-9)のカード共有検知が効かない
-- 購入が生まれる。**
--
-- 0080 でカードのフィンガープリントを最重要の手掛かりに据えたのは、
-- 「端末IDは消せる、IPは変わる、カードは同じ実カードである限り変わらない」
-- という理由だった。PayPay 払いにはカードが無いので、その手掛かりが無い。
--
-- 厄介なのは**検知が弱くなること自体ではなく、弱くなったことが見えないこと**。
-- 換金画面に「カード共有 0件」と出ていると、運営は「調べた結果シロだった」と
-- 読む。実際には「調べようがなかった」かもしれない。この2つは意味が違う。
--
-- そこで購入ごとに決済手段を残し、換金画面で
-- 「この人の購入にはカードで判定できないものが N 件ある」と出せるようにする。
-- 遮断はしない。PayPay で買うこと自体は正当なので、目視の材料にとどめる
-- （0080・0022 と同じ扱い）。
--
-- 会計上も効く。カードと PayPay で決済手数料の料率が違うため、
-- 手数料の内訳を後から説明できる。
-- ============================================================

-- ------------------------------------------------------------
-- 1) coin_purchases.payment_method
-- ------------------------------------------------------------
-- **null を許す。** 0096 より前の購入には決済手段が入らないが、
-- 当時はカードしか有効化していなかったので、null は「カード」と読んでよい。
-- 遡って 'card' で埋めない——「記録が無い」と「カードだった」は別の事実で、
-- 埋めてしまうと後から区別がつかなくなる。
alter table public.coin_purchases
  add column if not exists payment_method text;

comment on column public.coin_purchases.payment_method is
  'Stripe の payment_method_details.type（card / paypay 等）。0096より前の購入は null（当時はカードのみ有効）。stripe-webhook が決済成立後に書き込む。';

-- ------------------------------------------------------------
-- 2) admin_pending_payouts に「カードで判定できない購入の件数」を足す
-- ------------------------------------------------------------
-- 返す列が増えるので create or replace では差し替えられない
drop function if exists public.admin_pending_payouts(int);

create function public.admin_pending_payouts(p_limit int default 100)
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  coins int,
  amount_yen int,
  fee_yen int,
  created_at timestamptz,
  bank_name text,
  bank_code text,
  branch_name text,
  branch_code text,
  account_type text,
  account_number text,
  account_holder_kana text,
  is_verified boolean,
  shared_card_count int,
  flagged_gift_count int,
  non_card_purchase_count int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*) into v_n from public.payouts p where p.status = 'pending';
  perform public._log_admin_action('view_pending_payouts', null, v_n || '件の口座情報を表示');

  return query
  select p.id, p.user_id,
         coalesce(nullif(pf.nickname, ''), '(不明)'),
         p.coins, p.amount_yen, p.fee_yen, p.created_at,
         p.bank_name, p.bank_code, p.branch_name, p.branch_code,
         p.account_type, p.account_number, p.account_holder_kana,
         coalesce(ts.is_verified, false),
         -- このピタメイトとカードを共有している**他の**アカウントの数
         (select count(distinct b.user_id)::int
            from public.user_payment_cards a
            join public.user_payment_cards b
              on b.fingerprint = a.fingerprint and b.user_id <> a.user_id
           where a.user_id = p.user_id),
         -- 受け取ったギフトのうち、IPまたはカードの共有で印が付いたもの
         (select count(*)::int from public.gifts g
           where g.receiver_id = p.user_id
             and (g.ip_flagged or g.card_flagged)),
         -- カードのフィンガープリントで判定できない購入(PayPay等)の件数。
         -- null は 0096 以前＝当時カードのみなので数えない。
         (select count(*)::int from public.coin_purchases cp
           where cp.user_id = p.user_id
             and cp.payment_method is not null
             and cp.payment_method <> 'card')
  from public.payouts p
  left join public.profiles pf on pf.id = p.user_id
  left join public.profile_trust_stats ts on ts.user_id = p.user_id
  where p.status = 'pending'
  order by p.created_at
  limit greatest(1, least(p_limit, 500));
end;
$$;

comment on function public.admin_pending_payouts(int) is
  '未振込の換金申請と振込先(運営のみ)。0080でカード共有件数と要確認ギフト件数、0096でカード判定できない購入の件数を追加した(資金が出る瞬間に目に入るようにするため)。閲覧は操作記録に残る。';

revoke all on function public.admin_pending_payouts(int) from public;
grant execute on function public.admin_pending_payouts(int) to authenticated;
