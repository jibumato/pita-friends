-- ============================================================
-- 0076: 会計集計を税理士の第2回回答(Q7)に合わせる
-- ------------------------------------------------------------
-- 0070 で作った集計に、税理士の第2回回答が3点の修正と4点の追加を求めた。
--
-- ■ 修正1: 「未払金(換金申請中)」という科目名をやめる (Q7-a)
--   「『未払金』は通常、費用の発生や資産の購入に対応する債務を指します。
--     ここで計上されるのは**預り金の一部が支払段階に進んだもの**であり、
--     性質が違います。推奨: **『預り金(ホスト報酬)』の下位に
--     『うち換金申請中』を持つ**。理由は、**『預り金(ホスト報酬)の合計＝
--     分別口座で守るべき額』という管理式が崩れないから**です。」
--
-- ■ 修正2: 換金手数料300コインの置き場所 (Q7-b) ★実際に穴が空いていた
--   「『未払金(換金申請中)』を手数料控除後の純額で計上すると、**申請時点で
--     手数料300コインがどの勘定にもいない状態**が生じます。負債合計が申請の
--     前後で300コイン減るので、分別管理で守るべき額の計算がずれます。」
--
--   実装を確認したところ、そのとおりだった:
--     request_bank_payout は earned_balance を **申請額の全額**(5,000)
--     減らし、payouts には **手数料控除後**(4,700)を入れる。
--     → 差額の300が、振込が完了するまでどの集計にも現れない。
--   税理士の推奨に従い **仮受金(換金手数料)** として明示的に積む。
--   (テーブルは変えない。payouts.fee_yen から集計できる。)
--
-- ■ 修正3: 「分別対象額の合計」を出す
--   運用規程 第4条「分別口座および支払口座の残高の合計額が、常時、
--   分別対象額以上」を確認するには、**足し算済みの1行**が要る。
--   毎月これを手で足すのは、月次照合の事故のもと。
--
-- ■ 追加(Q7): 残高だけでは月次仕訳を機械的に起こせない。フローを4つ足す
--   ①当期のコイン販売額(有償・総額) … 決済手数料の総額処理(Q10-c)の検算
--   ②当期の失効額(有償・無償の別)   … 無償分は雑収入に計上しないが内訳が要る
--   ③当期の返金・取消額              … チャージバック(Q14)の把握
--   ④期末をまたぐ予約エスクローの件数・金額 … 「決算で必ず聞かれます」
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 残高サマリー(0070を差し替え)
-- ------------------------------------------------------------
create or replace function public.accounting_balances()
returns table (
  区分 text,
  勘定科目 text,
  金額円 bigint,
  備考 text
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
  -- 未使用の有償コイン = 前受金。現金を受け取っている分だけを負債に立てる
  select '負債'::text, '前受金(コイン)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '未使用の有償コイン。1コイン=1円。照合式: 帳簿残高 = 有償ロットの残コイン数 × 1円'::text
  from public.coin_lots l
  where l.kind = 'paid' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 予約成立済み・完了未確定 = まだ誰の収益にもなっていない。
  -- **独立科目として持つ**(Q7-c)。コイン残高は失効の対象だが
  -- エスクローは失効せず、完了すれば売上になる。性質が違う。
  select '負債'::text, '前受金(予約エスクロー)'::text,
         coalesce(sum(b.coins), 0)::bigint,
         '予約成立済み・プレイ完了未確定(' || count(*) || '件)。確定時に利用料と報酬に分かれる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')

  union all
  -- 確定済み・未換金のホスト報酬。**換金申請済みの分はここから抜けている**
  -- (request_bank_payout が申請時に earned_balance を減らすため)。
  -- 下の2行と合わせて「預り金(ホスト報酬)」の全体になる。
  select '負債'::text, '預り金(ホスト報酬・未申請)'::text,
         coalesce(sum(w.earned_balance), 0)::bigint,
         '確定済み・換金未申請の報酬コイン。**失効しない**(0018)'::text
  from public.coin_wallets w

  union all
  -- 0070では「未払金(換金申請中)」としていた。税理士の指摘(Q7-a)により
  -- 預り金の下位に置き直す。金額の中身は変えていない。
  select '負債'::text, '預り金(ホスト報酬・うち換金申請中)'::text,
         coalesce(sum(p.amount_yen), 0)::bigint,
         '換金申請済み・未振込の振込予定額(手数料控除後)'::text
  from public.payouts p
  where p.status = 'pending'

  union all
  -- ★0076で追加。ここが無いと申請の前後で負債合計が300コイン減る(Q7-b)
  select '負債'::text, '仮受金(換金手数料)'::text,
         coalesce(sum(p.fee_yen), 0)::bigint,
         '換金申請時に控除済み・振込未完了。**振込完了時に売上へ振り替える**'::text
  from public.payouts p
  where p.status = 'pending'

  union all
  -- ★0076で追加。運用規程 第4条の確認に使う1行
  select '合計'::text, '分別対象額(第4条)'::text,
         (
           coalesce((select sum(l.remaining) from public.coin_lots l
                      where l.kind = 'paid' and l.remaining > 0 and l.expires_at > now()), 0)
         + coalesce((select sum(b.coins) from public.bookings b
                      where b.status in ('requested', 'confirmed')), 0)
         + coalesce((select sum(w.earned_balance) from public.coin_wallets w), 0)
         + coalesce((select sum(p.amount_yen) from public.payouts p where p.status = 'pending'), 0)
         + coalesce((select sum(p.fee_yen) from public.payouts p where p.status = 'pending'), 0)
         )::bigint,
         '**分別口座＋支払口座の残高が常時この額以上**であること。無償コインは含めない'::text

  union all
  -- ここから下は負債ではない参考値
  select '参考'::text, '無償コイン残(ボーナス)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '**前受金に含めない**(現金を受け取っていない)。将来の値引き原資'::text
  from public.coin_lots l
  where l.kind = 'bonus' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 期限切れで未処理のロット。ここが0でないと失効処理が追いついていない
  select '要確認'::text, '期限切れ・失効処理待ち'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '0でなければ expire_coins() が動いていない。雑収入の計上漏れになる'::text
  from public.coin_lots l
  where l.remaining > 0 and l.expires_at <= now();
end;
$$;

comment on function public.accounting_balances() is
  '月次の記帳・照合用の残高サマリー(運営のみ)。0076で「未払金」を預り金の下位に改め、仮受金(換金手数料)と分別対象額の合計を追加。読み取りのみ。';

revoke all on function public.accounting_balances() from public;
grant execute on function public.accounting_balances() to authenticated;

-- ------------------------------------------------------------
-- 2. 期間の損益サマリー(0070を差し替え)
-- ------------------------------------------------------------
create or replace function public.accounting_revenue(p_from date, p_to date)
returns table (
  区分 text,
  科目 text,
  金額円 bigint,
  消費税 text
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
  -- プラットフォーム利用料(予約) … 完了確定時に platform_fees へ記録される
  select '売上'::text, 'PF利用料(予約)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'booking'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  select '売上'::text, 'PF利用料(ギフト)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'gift'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  -- あんしんサポート料。購入時に売上計上する(税理士 §1-4)
  select '売上'::text, 'あんしんサポート料(購入時)'::text,
         coalesce(sum(cp.safety_fee_yen), 0)::bigint, '課税10%'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- 換金手数料。**振込完了時に売上計上**(Q7-b で時期を確認済み)。
  -- 申請時点では上の「仮受金(換金手数料)」に載っている。
  select '売上'::text, '換金手数料(振込完了分)'::text,
         coalesce(sum(p.fee_yen), 0)::bigint, '課税10%'::text
  from public.payouts p
  where p.status = 'paid'
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all
  -- コイン失効益。**有償分のみ**が雑収入になる(Q8-c)。
  -- expire_coins() は note に 'lot:<ロットID>' を書くだけで種別を持たないため、
  -- ロットに join して有償・無償を分ける。**失効した時点の取引で数える**
  -- (expires_at で数えると、期限は来たが処理が走っていない分まで入る)。
  select '雑収入'::text, 'コイン失効益(有償)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '不課税'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'paid'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- ★0076で追加。無償分の失効は**会計上は何も起きない**(負債を立てていない)。
  -- それでも内訳を出すのは、税務調査で「失効益が過少では」と問われたときに
  -- **有償と無償の内訳を即座に出せることが答えになる**から(Q8-c)。
  -- 「記録がないと、『無償分も本当は前受金だったのでは』という議論に
  --   発展しかねません」
  select '参考(売上でない)'::text, 'コイン失効額(無償・会計処理なし)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '—'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'bonus'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- ★0076で追加(Q7)。決済手数料の総額処理の検算に使う
  select '参考(売上でない)'::text, 'コイン販売額(有償・総額)'::text,
         coalesce(sum(cp.price_yen), 0)::bigint, '不課税'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- ★0076で追加(Q7)。**予約キャンセルによるコインの返還は含めない。**
  -- あれは前受金の中での移動であって、前受金の減少ではない。
  -- ここに出すのは現金が出ていく方向のもの(チャージバックの確定分)。
  select '参考(売上でない)'::text, '返金・チャージバック確定額'::text,
         coalesce(sum(d.amount_yen), 0)::bigint, '前受金の減少'::text
  from public.payment_disputes d
  where d.status = 'lost'
    and d.created_at >= p_from and d.created_at < (p_to + 1)

  union all
  -- ★0076で追加(Q7)。「期ずれの説明資料。決算で必ず聞かれます」
  select '参考(期ずれ)'::text,
         '期末をまたぐ予約エスクロー(' || count(*) || '件)'::text,
         coalesce(sum(b.coins), 0)::bigint, '翌期の売上になる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')
    and b.created_at < (p_to + 1);
end;
$$;

comment on function public.accounting_revenue(date, date) is
  '期間の売上サマリー(運営のみ)。0076でフロー4項目(販売額・失効の有償無償別・返金確定額・期末をまたぐエスクロー)を追加。読み取りのみ。';

revoke all on function public.accounting_revenue(date, date) from public;
grant execute on function public.accounting_revenue(date, date) to authenticated;
