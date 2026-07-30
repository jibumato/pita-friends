-- ============================================================
-- 0078: 「PF利用料のうち無償コイン起因の額」を集計に足す
-- ------------------------------------------------------------
-- ■ 税理士の第4回回答(2026-07-30・事業計画書の評価)より
--
--   「当職の説明不足を1件お詫びします。**無償コイン消費時の借方科目を、
--     第2回回答Q8-bで書いていませんでした。**『負債に立てない』『利用料は
--     通常どおり売上計上』だけだと**仕訳の借方が埋まりません。**
--     **推奨は純額処理(販売促進費82 / 預り金82)**で、両建てにすると
--     **課税売上高が水増しされ、免税判定と簡易課税判定が実態より早く到来
--     します。** Q7の集計に『**PF利用料のうち無償コイン起因の額**』を
--     1項目追加していただければ、どちらの処理も選べます。」
--
-- ■ 何が問題か(具体例)
--   無償100コインが単価100コインの予約に使われ、利用料が20%だったとき:
--
--   | 処理 | 仕訳 | 課税売上高への影響 |
--   |---|---|---|
--   | 両建て | 販売促進費100 / 売上20・預り金80 | **売上が20増える** |
--   | 純額(推奨) | 販売促進費80 / 預り金80 | 売上は増えない |
--
--   両建ては、現金を1円も受け取っていない取引で課税売上高を膨らませる。
--   **1,000万円の判定が実態より早く来る**ため、免税事業者でいられる期間が
--   短くなり、簡易課税の届出期限も前倒しになる。
--
-- ■ この集計の使い方
--   純額処理を採るなら、期間の「PF利用料」から**この行を差し引いた額**が
--   売上になる。両建てを採るなら差し引かない。
--   **どちらを採るかは会計ソフト側の運用で、この関数は素材を出すだけ。**
--
-- ■ 計算のしかた
--   予約は有償コインと無償コインが混ざって支払われる(bookings.paid_coins /
--   bonus_coins)。利用料は合計額に対してかかるので、**無償の割合で按分**する。
--
--       無償起因の利用料 = fee_coins × bonus_coins / coins
--
--   端数は切り捨てず round する(集計の用途なので1円の丸めは問題にならない)。
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
-- ============================================================

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
  -- 申請時点では「仮受金(換金手数料)」に載っている。
  select '売上'::text, '換金手数料(振込完了分)'::text,
         coalesce(sum(p.fee_yen), 0)::bigint, '課税10%'::text
  from public.payouts p
  where p.status = 'paid'
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all
  -- ★0078で追加。**上の「PF利用料(予約)」の内数。**
  -- 純額処理を採るなら、この額を差し引いた額が売上になる。
  -- 両建てにすると、現金を受け取っていない取引で課税売上高が膨らみ、
  -- **1,000万円の判定が実態より早く来る**(税理士の第4回回答)。
  select '内数(控除の候補)'::text, 'PF利用料のうち無償コイン起因'::text,
         coalesce(sum(round(f.fee_coins::numeric * b.bonus_coins / nullif(b.coins, 0))), 0)::bigint,
         '純額処理なら売上から控除'::text
  from public.platform_fees f
  join public.bookings b on b.id = f.booking_id
  where f.kind = 'booking'
    and coalesce(b.bonus_coins, 0) > 0
    and f.created_at >= p_from and f.created_at < (p_to + 1)

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
  -- 無償分の失効は**会計上は何も起きない**(負債を立てていない)。
  -- それでも内訳を出すのは、税務調査で「失効益が過少では」と問われたときに
  -- **有償と無償の内訳を即座に出せることが答えになる**から(Q8-c)。
  select '参考(売上でない)'::text, 'コイン失効額(無償・会計処理なし)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '—'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'bonus'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- 決済手数料の総額処理(Q10-c)の検算に使う
  select '参考(売上でない)'::text, 'コイン販売額(有償・総額)'::text,
         coalesce(sum(cp.price_yen), 0)::bigint, '不課税'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- **予約キャンセルによるコインの返還は含めない。**
  -- あれは前受金の中での移動であって、前受金の減少ではない。
  select '参考(売上でない)'::text, '返金・チャージバック確定額'::text,
         coalesce(sum(d.amount_yen), 0)::bigint, '前受金の減少'::text
  from public.payment_disputes d
  where d.status = 'lost'
    and d.created_at >= p_from and d.created_at < (p_to + 1)

  union all
  -- 「期ずれの説明資料。決算で必ず聞かれます」
  select '参考(期ずれ)'::text,
         '期末をまたぐ予約エスクロー(' || count(*) || '件)'::text,
         coalesce(sum(b.coins), 0)::bigint, '翌期の売上になる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')
    and b.created_at < (p_to + 1);
end;
$$;

comment on function public.accounting_revenue(date, date) is
  '期間の売上サマリー(運営のみ)。0078で「PF利用料のうち無償コイン起因」を内数として追加(純額処理を採る場合の控除額)。読み取りのみ。';

revoke all on function public.accounting_revenue(date, date) from public;
grant execute on function public.accounting_revenue(date, date) to authenticated;
