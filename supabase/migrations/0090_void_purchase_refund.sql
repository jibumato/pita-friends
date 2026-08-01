-- ============================================================
-- 0090: 購入の取消しと、あんしんサポート料の返還(G5)
--
-- 規約 第7条の3第5項:
--   購入の効力が失われた場合、当社は**あんしんサポート料も返還**する。
--
-- 税理士 第2回回答 Q14(c):
--   「**サポート料も含めて全額返金することを推奨。**
--     ①未成年者取消し(民法5条2項)は契約全体を取り消すもので、コイン購入
--       契約が取り消されるならサポート料の法的根拠も失われるのが自然な帰結。
--       『サポート料だけ返さない』は法的に維持しにくい
--     ②金額が小さいのに紛争時のコストが桁違い
--     ③税務上は不利益がない」
--   あわせて「**一切の例外を認めない不返金条項は、無効と判断される
--   リスクがあります**」(消費者契約法10条)。
--
-- ■ ここで扱うのは「チャージバック以外」の取消し
--   チャージバックはカード会社が決済ごと戻すので、サポート料も一緒に
--   戻っている。**別に返金すると二重返金になる。**
--   この関数が要るのは、**当社が自ら購入を取り消す場面**
--   (未成年者取消しの申出を受けた、誤課金 等)。
--
-- ■ 3つを1つの操作にまとめる
--   ①未使用のコインを取り消す(第8条の6第2項「遡って付与されなかった
--     ものとして取り扱う」と同じ扱い)
--   ②コイン代金とサポート料を**金銭返金の債務**として立てる
--   ③本人に通知する
--   バラバラに手作業でやると、必ずどれかが抜ける。
--
-- ■ 消費済みのコインは追いかけない
--   Q14(a)のとおり、消費済み分は**回収不能の損失**として処理する。
--   ピタメイトからの回収は第8条の6(0088)の相殺で、**異議が成立した
--   購入に限って**行う。ここから自動では起こさない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 取消しの記録
--
-- **coin_purchases に列を足して更新しない。** 購入履歴は追記専用の
-- 台帳(0044)で、UPDATE は原則禁止。取消しは「後から起きた別の事実」
-- なので、**行を1本足す**形にする。台帳の原則を曲げずに済む。
-- ------------------------------------------------------------
create table if not exists public.purchase_voids (
  purchase_id uuid primary key references public.coin_purchases (id),
  voided_at timestamptz not null default now(),
  voided_by uuid references auth.users (id),
  reason text not null,
  voided_coins int not null default 0,
  refund_yen int not null default 0
);

comment on table public.purchase_voids is
  '当社が購入を取り消した記録(規約第7条の3第5項)。チャージバックによる失効はここには入らない(カード会社が決済ごと戻すため)。';

alter table public.purchase_voids enable row level security;

create policy "purchase_voids_select_own"
  on public.purchase_voids for select
  to authenticated
  using (exists (select 1 from public.coin_purchases cp
                 where cp.id = purchase_id and cp.user_id = auth.uid()));

create policy "purchase_voids_select_admin"
  on public.purchase_voids for select
  to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- 返金の事由を増やす。**科目が違うので1つにまとめない**
alter table public.cash_refunds drop constraint if exists cash_refunds_cause_check;
alter table public.cash_refunds add constraint cash_refunds_cause_check
  check (cause in (
    -- 0085: 無帰責の返還で消滅した分(規約第9条5の3)
    'host_fault', 'host_no_show', 'support', 'system',
    -- 0090: 購入の取消し(規約第7条の3第5項)。**コイン代金とサポート料を分ける**
    'purchase_void_coins', 'purchase_void_fee'));

-- ------------------------------------------------------------
-- 2. 取消しの下見(押す前に何が起きるかを出す)
-- ------------------------------------------------------------
create or replace function public.void_purchase_preview(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.coin_purchases;
  v_unused int;
  v_consumed int;
  v_disputed boolean;
  v_voided timestamptz;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.coin_purchases where id = p_purchase_id;
  if v_p.id is null then raise exception 'NOT_FOUND'; end if;

  select v.voided_at into v_voided from public.purchase_voids v
   where v.purchase_id = p_purchase_id;

  select coalesce(sum(l.remaining), 0)::int into v_unused
  from public.coin_lots l where l.purchase_id = p_purchase_id;

  v_consumed := greatest(0, coalesce(v_p.coins_credited, 0) - coalesce(v_unused, 0));

  select exists (
    select 1 from public.payment_disputes d
    where d.stripe_payment_intent = v_p.stripe_payment_intent
  ) into v_disputed;

  return jsonb_build_object(
    'purchase_id', v_p.id,
    'user_id', v_p.user_id,
    'voided_at', v_voided,
    'price_yen', coalesce(v_p.price_yen, 0),
    'safety_fee_yen', coalesce(v_p.safety_fee_yen, 0),
    'refund_total_yen', coalesce(v_p.price_yen, 0) + coalesce(v_p.safety_fee_yen, 0),
    'unused_coins', coalesce(v_unused, 0),
    -- **消費済みは回収不能の損失。**相殺は第8条の6の場面に限る
    'consumed_coins', v_consumed,
    -- チャージバックがある購入は、カード会社が決済ごと戻している。
    -- ここで返金債務を立てると**二重返金**になる
    'has_dispute', coalesce(v_disputed, false),
    'can_void', v_voided is null and not coalesce(v_disputed, false)
  );
end;
$$;

revoke all on function public.void_purchase_preview(uuid) from public, anon;
grant execute on function public.void_purchase_preview(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. 取消しの実行
-- ------------------------------------------------------------
create or replace function public.admin_void_purchase(p_purchase_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p public.coin_purchases;
  v_unused int;
  v_fee int;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  -- **理由なしに購入を取り消させない。** 返金を伴う操作なので、
  -- 後から「なぜ取り消したか」を説明できる必要がある
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_p from public.coin_purchases where id = p_purchase_id;
  if v_p.id is null then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.purchase_voids v where v.purchase_id = p_purchase_id) then
    raise exception 'ALREADY_VOIDED';
  end if;

  -- チャージバックがある購入は、カード会社が決済ごと戻している。
  -- **ここで返金債務を立てると二重返金になる**
  if exists (
    select 1 from public.payment_disputes d
    where d.stripe_payment_intent = v_p.stripe_payment_intent
  ) then
    raise exception 'HAS_DISPUTE';
  end if;

  -- ① 未使用のコインを取り消す(遡って付与されなかった扱い)
  select coalesce(sum(l.remaining), 0)::int into v_unused
  from public.coin_lots l where l.purchase_id = p_purchase_id;

  if coalesce(v_unused, 0) > 0 then
    update public.coin_lots set remaining = 0 where purchase_id = p_purchase_id;
    update public.coin_wallets
      set balance = greatest(0, balance - v_unused)
      where user_id = v_p.user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (v_p.user_id, -v_unused, 'expire', 'purchase_void:' || p_purchase_id::text);
  end if;

  -- ② 金銭返金の債務を立てる。**コイン代金とサポート料を分ける**
  --    (前受金の取崩しと売上の取消しで、会計科目が違う)
  if coalesce(v_p.price_yen, 0) > 0 then
    insert into public.cash_refunds
      (user_id, booking_id, coins, amount_yen, cause)
    values (v_p.user_id, null, coalesce(v_p.coins_credited, v_p.price_yen),
            v_p.price_yen, 'purchase_void_coins');
  end if;

  v_fee := coalesce(v_p.safety_fee_yen, 0);
  if v_fee > 0 then
    insert into public.cash_refunds
      (user_id, booking_id, coins, amount_yen, cause)
    values (v_p.user_id, null, v_fee, v_fee, 'purchase_void_fee');
  end if;

  insert into public.purchase_voids
    (purchase_id, voided_by, reason, voided_coins, refund_yen)
  values (p_purchase_id, auth.uid(), p_reason, coalesce(v_unused, 0),
          coalesce(v_p.price_yen, 0) + v_fee);

  -- ③ 本人に伝える。**黙って残高を減らさない**
  insert into public.notifications (user_id, type, title, body)
  values (v_p.user_id, 'system', 'コインのご購入を取り消しました',
    'ご購入(' || coalesce(v_p.coins_credited, 0) || 'コイン)を取り消しました。'
      || case when coalesce(v_unused, 0) > 0
              then '未使用の' || v_unused || 'コインは残高から取り消しています。' else '' end
      || 'お支払いいただいた' || (coalesce(v_p.price_yen, 0) + v_fee)
      || '円(あんしんサポート料を含みます)は、ご登録の方法で返金します。');

  perform public._log_admin_action('void_purchase', p_purchase_id, p_reason);

  return jsonb_build_object(
    'voided_coins', coalesce(v_unused, 0),
    'refund_yen', coalesce(v_p.price_yen, 0) + v_fee,
    'fee_yen', v_fee
  );
end;
$$;

comment on function public.admin_void_purchase(uuid, text) is
  '購入を取り消し、未使用コインを消して、コイン代金とサポート料を金銭返金の債務にする(規約第7条の3第5項・税理士Q14(c))。';

revoke all on function public.admin_void_purchase(uuid, text) from public, anon;
grant execute on function public.admin_void_purchase(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 4. 運営コンソール用: 直近の購入を引く
-- ------------------------------------------------------------
create or replace function public.admin_recent_purchases(p_limit int default 30)
returns table (
  purchase_id uuid,
  user_id uuid,
  nickname text,
  coins int,
  price_yen int,
  safety_fee_yen int,
  created_at timestamptz,
  voided_at timestamptz,
  has_dispute boolean,
  unused_coins int
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
  select cp.id, cp.user_id, p.nickname,
         coalesce(cp.coins_credited, 0), coalesce(cp.price_yen, 0),
         coalesce(cp.safety_fee_yen, 0),
         cp.created_at, pv.voided_at,
         exists (select 1 from public.payment_disputes d
                 where d.stripe_payment_intent = cp.stripe_payment_intent),
         coalesce((select sum(l.remaining)::int from public.coin_lots l
                   where l.purchase_id = cp.id), 0)
  from public.coin_purchases cp
  left join public.profiles p on p.id = cp.user_id
  left join public.purchase_voids pv on pv.purchase_id = cp.id
  order by cp.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$$;

revoke all on function public.admin_recent_purchases(int) from public, anon;
grant execute on function public.admin_recent_purchases(int) to authenticated;

-- ------------------------------------------------------------
-- 5. 会計仕訳に購入取消しを足す(J25〜J27)
--
-- **科目が違うので J19 とは分ける。**
--   ・コイン代金 … 前受金の取崩し(受け取った代金を返すだけ)
--   ・サポート料 … **売上のマイナス**(税理士 Q14(b))
--   ・未使用コインの取消し … 前受金を落とす側の相手科目を仮受金にして、
--     J25 と二重に落とさないようにする
-- ------------------------------------------------------------
create or replace function public.accounting_journal(p_from date, p_to date)
returns table (
  日付 date,
  区分 text,
  借方科目 text,
  借方補助 text,
  貸方科目 text,
  貸方補助 text,
  金額円 bigint,
  税区分 text,
  摘要 text,
  伝票id text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return query

  -- ------------------------------------------------------------
  -- J1 コイン購入(コイン代金)
  --   Stripe の入金は数日後なので、いったん未収入金で受ける。
  --   実際の着金と決済手数料は Stripe の明細から別途起票する
  --   (ここでは出せない。DB に Stripe の入金データが無いため)。
  -- ------------------------------------------------------------
  select cp.created_at::date, 'コイン購入'::text,
         '未収入金'::text, 'Stripe'::text,
         '前受金'::text, 'コイン'::text,
         cp.price_yen::bigint, '対象外'::text,
         ('コイン購入 ' || coalesce(cp.pack_id, '-') || ' ' || cp.coins_credited || 'コイン')::text,
         cp.id::text
  from public.coin_purchases cp
  where cp.price_yen > 0
    and cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J2 あんしんサポート料(購入時に売上計上・税理士 §1-4)
  -- ------------------------------------------------------------
  select cp.created_at::date, 'コイン購入'::text,
         '未収入金'::text, 'Stripe'::text,
         '売上高'::text, 'あんしんサポート料'::text,
         cp.safety_fee_yen::bigint, '課対売上込10%'::text,
         ('あんしんサポート料 ' || coalesce(cp.pack_id, '-'))::text,
         cp.id::text
  from public.coin_purchases cp
  where coalesce(cp.safety_fee_yen, 0) > 0
    and cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J4 予約成立(有償コイン分) — 前受金がエスクローへ移る
  --   coin_lot_consumptions から引く。bookings.paid_coins は
  --   **延長で積み上がる累計**なので、1件の予約に複数回の消費が
  --   ありうる。消費記録なら1回ずつ正確に取れる。
  -- ------------------------------------------------------------
  select c.created_at::date, '予約成立'::text,
         '前受金'::text, 'コイン'::text,
         '前受金'::text, '予約エスクロー'::text,
         sum(c.coins)::bigint, '対象外'::text,
         ('予約 ' || left(c.booking_id::text, 8) || ' 有償コイン充当')::text,
         c.booking_id::text
  from public.coin_lot_consumptions c
  where c.booking_id is not null and c.kind = 'paid'
    and c.created_at >= p_from and c.created_at < (p_to + 1)
  group by c.created_at::date, c.booking_id

  union all

  -- ------------------------------------------------------------
  -- J5 予約成立(無償コイン分) — ★科目は税理士へ確認中
  --   無償コインには前受金を立てていない(現金を受け取っていない)。
  --   それでもピタメイトへの支払は発生するので、**消費した時点で
  --   費用**にしないと、エスクローの貸方に相手科目が無くなる。
  -- ------------------------------------------------------------
  select c.created_at::date, '予約成立'::text,
         '販売促進費'::text, '無償コイン'::text,
         '前受金'::text, '予約エスクロー'::text,
         sum(c.coins)::bigint, '対象外'::text,
         ('予約 ' || left(c.booking_id::text, 8) || ' 無償コイン充当')::text,
         c.booking_id::text
  from public.coin_lot_consumptions c
  where c.booking_id is not null and c.kind = 'bonus'
    and c.created_at >= p_from and c.created_at < (p_to + 1)
  group by c.created_at::date, c.booking_id

  union all

  -- ------------------------------------------------------------
  -- J6 返金(有償コイン分) — キャンセル・辞退・期限切れ・保留解除
  --   返す枚数の内訳は、どの経路も
  --     有償 = least(bookings.paid_coins, 返還総額)
  --   で決まる(cancel_booking / release_hold_and_refund が同じ式)。
  --   ここで同じ式を引き直しているのは、返還時の内訳が
  --   coin_transactions に残らないため。
  -- ------------------------------------------------------------
  select t.created_at::date, '返金'::text,
         '前受金'::text, '予約エスクロー'::text,
         '前受金'::text, 'コイン'::text,
         least(b.paid_coins, t.amount)::bigint, '対象外'::text,
         ('返金 ' || coalesce(t.note, '') || ' 予約 ' || left(b.id::text, 8))::text,
         t.id::text
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  where t.type = 'refund' and t.amount > 0
    and least(b.paid_coins, t.amount) > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- J7 返金(無償コイン分) — J5 で立てた費用の戻し
  select t.created_at::date, '返金'::text,
         '前受金'::text, '予約エスクロー'::text,
         '販売促進費'::text, '無償コイン'::text,
         (t.amount - least(b.paid_coins, t.amount))::bigint, '対象外'::text,
         ('返金(無償分) ' || coalesce(t.note, '') || ' 予約 ' || left(b.id::text, 8))::text,
         t.id::text
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  where t.type = 'refund' and t.amount > 0
    and (t.amount - least(b.paid_coins, t.amount)) > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J8 報酬確定 — エスクローがピタメイトへの預り金に変わる
  --   完了時とキャンセル没収時の両方がここに入る(どちらも
  --   booking_earned)。**総額で入る**(利用料の控除は J10 で別行)。
  -- ------------------------------------------------------------
  select t.created_at::date, '報酬確定'::text,
         '前受金'::text, '予約エスクロー'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         t.amount::bigint, '対象外'::text,
         ('報酬確定 ' || coalesce(t.note, '') || ' 予約 ' || left(coalesce(t.related_booking_id::text, '-'), 8))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'booking_earned' and t.amount > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J9 ギフト受領
  --   ギフトは**有償コインのみ**で送れる(send_gift が
  --   _consume_coin_lots(..., 'paid', ...) しか呼ばない)ので、
  --   相手科目は前受金(コイン)で確定する。
  -- ------------------------------------------------------------
  select t.created_at::date, 'ギフト'::text,
         '前受金'::text, 'コイン'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         t.amount::bigint, '対象外'::text,
         'ギフト受領'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'gift_received' and t.amount > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J10 プラットフォーム利用料 — ここが売上
  --   note が 'gift_fee:%' ならギフト、それ以外は予約。
  -- ------------------------------------------------------------
  select t.created_at::date, 'PF利用料'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '売上高'::text,
         case when coalesce(t.note, '') like 'gift_fee:%' then 'PF利用料(ギフト)'
              else 'PF利用料(予約)' end,
         (-t.amount)::bigint, '課対売上込10%'::text,
         ('利用料 ' || coalesce(t.note, ''))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'platform_fee' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J11 換金申請(振込予定額) — 預り金の中で区分が変わるだけ
  -- ------------------------------------------------------------
  select p.created_at::date, '換金申請'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '預り金'::text, '換金申請中'::text,
         p.amount_yen::bigint, '対象外'::text,
         ('換金申請 ' || left(p.id::text, 8) || ' ' || p.coins || 'コイン')::text,
         p.id::text
  from public.payouts p
  where p.status in ('pending', 'paid')
    and p.created_at >= p_from and p.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J12 換金申請(事務手数料) — **振込が終わるまで売上にしない**
  --   Q7-b。ここを飛ばすと、申請から振込までの間だけ
  --   負債合計が300コイン足りなくなる。
  -- ------------------------------------------------------------
  select p.created_at::date, '換金申請'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '仮受金'::text, '換金手数料'::text,
         p.fee_yen::bigint, '対象外'::text,
         ('換金事務手数料(未実現) ' || left(p.id::text, 8))::text,
         p.id::text
  from public.payouts p
  where p.status in ('pending', 'paid') and coalesce(p.fee_yen, 0) > 0
    and p.created_at >= p_from and p.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J13 振込完了 — ここで初めて現金が出る
  -- ------------------------------------------------------------
  select p.paid_at::date, '振込'::text,
         '預り金'::text, '換金申請中'::text,
         '普通預金'::text, '支払口座'::text,
         p.amount_yen::bigint, '対象外'::text,
         ('振込 ' || left(p.id::text, 8) || ' ' || coalesce(p.bank_name, '') || ' ' || coalesce(p.account_holder_kana, ''))::text,
         p.id::text
  from public.payouts p
  where p.status = 'paid' and p.paid_at is not null
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all

  -- J14 換金事務手数料の売上振替(振込完了時)
  select p.paid_at::date, '振込'::text,
         '仮受金'::text, '換金手数料'::text,
         '売上高'::text, '換金事務手数料'::text,
         p.fee_yen::bigint, '課対売上込10%'::text,
         ('換金事務手数料 ' || left(p.id::text, 8))::text,
         p.id::text
  from public.payouts p
  where p.status = 'paid' and p.paid_at is not null and coalesce(p.fee_yen, 0) > 0
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J15 振込失敗の戻し
  --   mark_payout_failed は手数料も含めて全額 earned_balance へ返す。
  --   related_booking_id が無いので、J6/J7 とは自然に分かれる。
  -- ------------------------------------------------------------
  select t.created_at::date, '振込失敗'::text,
         '預り金'::text, '換金申請中'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         p.amount_yen::bigint, '対象外'::text,
         ('振込失敗の戻し ' || coalesce(p.failure_reason, ''))::text,
         t.id::text
  from public.coin_transactions t
  join public.payouts p on p.id = nullif(replace(t.note, 'mark_payout_failed:', ''), '')::uuid
  where t.type = 'refund' and t.related_booking_id is null
    and t.note like 'mark_payout_failed:%'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  select t.created_at::date, '振込失敗'::text,
         '仮受金'::text, '換金手数料'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         p.fee_yen::bigint, '対象外'::text,
         ('振込失敗の戻し(手数料) ' || coalesce(p.failure_reason, ''))::text,
         t.id::text
  from public.coin_transactions t
  join public.payouts p on p.id = nullif(replace(t.note, 'mark_payout_failed:', ''), '')::uuid
  where t.type = 'refund' and t.related_booking_id is null
    and t.note like 'mark_payout_failed:%' and coalesce(p.fee_yen, 0) > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J16 コイン失効(有償分のみ) — 雑収入
  --   無償コインの失効は**仕訳なし**。前受金を立てていないので
  --   取り崩すものが無い(J5 で費用にするのは消費した分だけ)。
  --   消費税は不課税。会計ソフト上は「対象外」で入力する。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         'コイン失効(有償・不課税)'::text,
         t.id::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J17 純額処理への調整(**選択制**)
  --   無償コインで成立した予約から生じた利用料は、上の J10 でいったん
  --   売上に立っている。税理士の推奨する純額処理を採る場合は、
  --   ここでその分を売上から落とす。
  --   **両建てのままだと課税売上高が水増しされ、1,000万円の判定が
  --   実態より早く来る**(第4回回答)。
  --   純額処理を採らないなら、区分「純額調整」を除いて出力する。
  --   按分式は 0078 の内数と同じ(fee × bonus_coins / coins)。
  -- ------------------------------------------------------------
  select f.created_at::date, '純額調整'::text,
         '売上高'::text, 'PF利用料(予約)'::text,
         '販売促進費'::text, '無償コイン'::text,
         round(f.fee_coins::numeric * b.bonus_coins / nullif(b.coins, 0))::bigint,
         '課対売上込10%'::text,
         ('純額処理: 無償コイン起因の利用料を売上から控除 予約 ' || left(b.id::text, 8))::text,
         f.id::text
  from public.platform_fees f
  join public.bookings b on b.id = f.booking_id
  where f.kind = 'booking' and coalesce(b.bonus_coins, 0) > 0
    and round(f.fee_coins::numeric * b.bonus_coins / nullif(b.coins, 0)) > 0
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J18 返還時の失効(有償分) — **0085で追加**
  --   返還されるコインは当初の期限を引き継ぐ(第9条5の2)ため、
  --   返還の時点で期限を過ぎていると戻らずに消える。
  --   J6 で前受金(コイン)へ戻した分を、ここで取り崩す。
  --   **これが無いと前受金が過大に残り、突合が合わない。**
  --   無償分(refund_lapsed_bonus)は前受金を立てていないので仕訳なし。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         ('返還時の失効(有償・不課税) 予約 ' || left(coalesce(t.related_booking_id::text, '-'), 8))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'refund_lapsed_paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J19 金銭返金の債務計上(規約第9条5の3・0085)
  --   ゲストに落ち度が無い返還で消えた分は、現金で返す約束をしている。
  --   **J18 で立った失効益を、同額打ち消す。** 手元に残らないので
  --   利益にはならない、というのが経済実態。
  -- ------------------------------------------------------------
  select r.created_at::date, '返金債務'::text,
         '雑収入'::text, 'コイン失効益'::text,
         '未払金'::text, '返金(第9条5の3)'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('無帰責返還の金銭返金 ' || r.cause || ' ' || left(r.id::text, 8))::text,
         r.id::text
  from public.cash_refunds r
  where r.status in ('pending', 'paid')
    -- 0090: 購入の取消しによる返金は科目が違う(J25/J26)ので除く
    and r.cause in ('host_fault', 'host_no_show', 'support', 'system')
    and r.created_at >= p_from and r.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J20 返金の支払 — ここで初めて現金が出る
  -- ------------------------------------------------------------
  select r.resolved_at::date, '返金'::text,
         '未払金'::text, '返金(第9条5の3)'::text,
         '普通預金'::text, '支払口座'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('返金の支払 ' || left(r.id::text, 8) || ' ' || coalesce(r.note, ''))::text,
         r.id::text
  from public.cash_refunds r
  where r.status = 'paid' and r.resolved_at is not null
    and r.resolved_at >= p_from and r.resolved_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J21 返金債務の取消(却下)
  --   運営が理由を付けて却下した場合。**理由は摘要に残す。**
  -- ------------------------------------------------------------
  select r.resolved_at::date, '返金取消'::text,
         '未払金'::text, '返金(第9条5の3)'::text,
         '雑収入'::text, 'コイン失効益'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('返金債務の取消 ' || left(r.id::text, 8) || ' ' || coalesce(r.note, ''))::text,
         r.id::text
  from public.cash_refunds r
  where r.status = 'rejected' and r.resolved_at is not null
    and r.resolved_at >= p_from and r.resolved_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J22 退会によるコイン消滅(有償分) — 0086
  --   第6条の2第3項。返金しないので前受金を取り崩して雑収入にする。
  --   無償分(withdraw_bonus)は前受金を立てていないので仕訳なし。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         '退会によるコイン消滅(有償・不課税)'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'withdraw_paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J23 退会後90日を過ぎた報酬コインの消滅 — 0086
  --   ピタメイトへの**預り金**が、支払わなくてよくなる。
  --   第6条の2第4項。90日という猶予を置いたうえでの消滅なので、
  --   債務免除益として雑収入に振り替える。
  -- ------------------------------------------------------------
  select t.created_at::date, '報酬失効'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '雑収入'::text, '報酬コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         '退会から90日経過による報酬コインの消滅(不課税)'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'withdraw_earned_expired' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J24 チャージバック清算による相殺(規約第8条の6第3項・0088)
  --   ピタメイトへの**預り金が減る**。購入が遡って無効になった以上、
  --   その原資から生じた報酬の支払債務も基礎を失う、という整理。
  --   当社が負担した返金の一部が回収されるので、相手科目は雑収入。
  -- ------------------------------------------------------------
  select t.created_at::date, '相殺'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '雑収入'::text, 'チャージバック清算'::text,
         (-t.amount)::bigint, '対象外'::text,
         ('購入の失効による相殺 ' || coalesce(t.note, ''))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'chargeback_offset' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J25 購入の取消し(コイン代金) — 0090
  --   規約第7条の3第5項。前受金を取り崩して、返す約束(未払金)に振り替える。
  --   **失効益ではない。** 受け取った代金をそのまま返すだけ。
  -- ------------------------------------------------------------
  select r.created_at::date, '購入取消'::text,
         '前受金'::text, 'コイン'::text,
         '未払金'::text, '返金(購入取消)'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('購入の取消しによる返金(コイン代金) ' || left(r.id::text, 8))::text,
         r.id::text
  from public.cash_refunds r
  where r.status in ('pending', 'paid') and r.cause = 'purchase_void_coins'
    and r.created_at >= p_from and r.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J26 購入の取消し(あんしんサポート料) — 0090
  --   **売上のマイナス**(税理士 第2回回答 Q14(b))。
  --   免税事業者である間は単に売上の減少として扱う。
  -- ------------------------------------------------------------
  select r.created_at::date, '購入取消'::text,
         '売上高'::text, 'あんしんサポート料'::text,
         '未払金'::text, '返金(購入取消)'::text,
         r.amount_yen::bigint, '課対売上込10%'::text,
         ('購入の取消しによる返金(サポート料) ' || left(r.id::text, 8))::text,
         r.id::text
  from public.cash_refunds r
  where r.status in ('pending', 'paid') and r.cause = 'purchase_void_fee'
    and r.created_at >= p_from and r.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J27 購入取消しによる未使用コインの取消し — 0090
  --   ロットを0にした分。**J25 で前受金を落としているので、
  --   ここで二重に落とさない**ように、相手科目は前受金ではなく
  --   仮受金(取消しの受け皿)にする。
  --   ※ purchase_void の expire は、J16(lot:...)にも
  --     J18(refund_lapsed_paid)にも当たらないため、ここで拾う。
  -- ------------------------------------------------------------
  select t.created_at::date, '購入取消'::text,
         '仮受金'::text, '購入取消の調整'::text,
         '前受金'::text, 'コイン'::text,
         (-t.amount)::bigint, '対象外'::text,
         '購入取消による未使用コインの取消'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note like 'purchase_void:%' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  order by 1, 2, 10;
end;
$$;

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;
