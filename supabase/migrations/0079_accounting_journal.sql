-- ============================================================
-- 0079: 仕訳の自動生成(accounting_journal)
--
-- ねらい:
--   0070→0076→0078 で「残高」と「損益」は出せるようになった。
--   だが**帳簿に入れるのは仕訳**であって、残高一覧ではない。
--   毎月これを手で起票するのは、件数が増えた時点で確実に破綻する。
--
--   この関数は、期間を渡すと**会計ソフトにそのまま取り込める仕訳**を返す。
--   運営コンソールの「会計」タブが呼び、CSVに落とす。
--
-- 設計の判断:
--   1. **単純仕訳しか出さない。** 1行 = 借方1・貸方1・金額1。
--      複合仕訳にすると取込形式がソフトごとに割れるうえ、
--      「1行ずつ貸借が合っている」ことが目視で確認できなくなる。
--      購入のように借方が2つに割れるものは、2行に分けて出す。
--   2. **元帳(coin_transactions / payouts / coin_lot_consumptions)から引く。**
--      集計値(coin_wallets 等)からは引かない。集計値は事故で狂うが、
--      元帳は 0044 で追記専用になっている。
--   3. **1コイン = 1円。** 全額を円で出す。
--   4. **税区分は会計ソフトの名称で出す**(弥生の名称に合わせる。
--      freee・マネーフォワードはいずれも弥生形式を取り込める)。
--      不課税取引は、会計ソフト上は「対象外」で入力する。
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
--
-- 無償コインの扱い(税理士の第4回回答):
--   無償コインで予約が成立すると、**現金は1円も受け取っていないのに
--   ピタメイトへの支払は発生する**。前受金を立てていない以上、
--   どこかで費用にしないと借方が埋まらない。科目は税理士の指定どおり
--   「販売促進費」。計上は**付与時ではなく消費時**にしている
--   (付与時にすると、使われずに失効したボーナスまで費用になる)。
--
--   税理士の推奨は**純額処理**(販売促進費82 / 預り金82)。両建てにすると
--   **課税売上高が水増しされ、免税判定と簡易課税判定が実態より早く来る**。
--   ただし取引ごとの仕訳を純額で作ると、利用料の売上が取引単位で
--   歯抜けになって追いにくい。そこで
--     ・取引ごとの仕訳は**両建てで素直に作る**
--     ・区分「純額調整」の行で、無償コイン起因の利用料を売上から落とす
--   の2段構えにした。純額処理を採らない場合は、この区分を外して出力する。
-- ============================================================

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

  order by 1, 2, 10;
end;
$$;

comment on function public.accounting_journal(date, date) is
  '期間内の取引を会計ソフト取込用の単純仕訳(1行=借方1・貸方1)にして返す(運営のみ)。1コイン=1円。読み取りのみ。Stripeの着金・決済手数料と、経費・按分はここには出ない(明細から別途起票する)。';

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;

-- ------------------------------------------------------------
-- accounting_journal_check: 仕訳の自己検証
--
-- **合わないことに気づけない自動化は、手作業より危ない。**
-- 生成した仕訳を科目ごとに集計し、元帳の残高と突き合わせる。
-- 期首から当期末までの全期間で呼ぶ前提(累計で比べるため)。
-- ------------------------------------------------------------
create or replace function public.accounting_journal_check(p_from date, p_to date)
returns table (
  項目 text,
  仕訳から円 bigint,
  元帳から円 bigint,
  差額円 bigint,
  判定 text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_j_zen_coin bigint;      -- 前受金(コイン)の仕訳純増
  v_j_escrow bigint;        -- 前受金(予約エスクロー)の仕訳純増
  v_j_azukari bigint;       -- 預り金(ピタメイト報酬)の仕訳純増
  v_l_zen_coin bigint;
  v_l_escrow bigint;
  v_l_azukari bigint;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  -- 仕訳側: 貸方に立った額 − 借方に立った額(負債なので貸方が増加)
  select
    coalesce(sum(case when j.貸方科目 = '前受金' and j.貸方補助 = 'コイン' then j.金額円 else 0 end), 0)
      - coalesce(sum(case when j.借方科目 = '前受金' and j.借方補助 = 'コイン' then j.金額円 else 0 end), 0),
    coalesce(sum(case when j.貸方科目 = '前受金' and j.貸方補助 = '予約エスクロー' then j.金額円 else 0 end), 0)
      - coalesce(sum(case when j.借方科目 = '前受金' and j.借方補助 = '予約エスクロー' then j.金額円 else 0 end), 0),
    coalesce(sum(case when j.貸方科目 = '預り金' and j.貸方補助 = 'ピタメイト報酬' then j.金額円 else 0 end), 0)
      - coalesce(sum(case when j.借方科目 = '預り金' and j.借方補助 = 'ピタメイト報酬' then j.金額円 else 0 end), 0)
  into v_j_zen_coin, v_j_escrow, v_j_azukari
  from public.accounting_journal(p_from, p_to) j;

  -- 元帳側
  -- **expires_at で絞らない。** 仕訳の側は expire_coins() が走って
  -- 初めて前受金を取り崩す(J16)。期限は過ぎたが処理待ちのロットを
  -- ここで除くと、失効処理の遅れが「仕訳の誤り」に見えてしまう。
  -- 貸借対照表の金額(accounting_balances)とは目的が違う。
  select coalesce(sum(l.remaining), 0)::bigint into v_l_zen_coin
  from public.coin_lots l
  where l.kind = 'paid' and l.remaining > 0;

  select coalesce(sum(b.coins), 0)::bigint into v_l_escrow
  from public.bookings b
  where b.status in ('requested', 'confirmed');

  select coalesce(sum(w.earned_balance), 0)::bigint into v_l_azukari
  from public.coin_wallets w;

  return query
  select '前受金(コイン)'::text, v_j_zen_coin, v_l_zen_coin,
         v_j_zen_coin - v_l_zen_coin,
         case when v_j_zen_coin = v_l_zen_coin then 'OK' else 'NG' end
  union all
  select '前受金(予約エスクロー)'::text, v_j_escrow, v_l_escrow,
         v_j_escrow - v_l_escrow,
         case when v_j_escrow = v_l_escrow then 'OK' else 'NG' end
  union all
  select '預り金(ピタメイト報酬)'::text, v_j_azukari, v_l_azukari,
         v_j_azukari - v_l_azukari,
         case when v_j_azukari = v_l_azukari then 'OK' else 'NG' end;
end;
$$;

comment on function public.accounting_journal_check(date, date) is
  '生成した仕訳を科目ごとに積み上げ、元帳の残高と突き合わせる(運営のみ)。**開業日から当日まで**の全期間で呼ぶこと。差額が出たら仕訳生成側の漏れを疑う。';

revoke all on function public.accounting_journal_check(date, date) from public;
grant execute on function public.accounting_journal_check(date, date) to authenticated;
