-- ============================================================
-- 0104: webhook の購入記録(サポート料・決済手段)が0044に弾かれていた
-- ------------------------------------------------------------
-- ■ 見つかった穴(決済まわりのセキュリティ点検で発見)
--   stripe-webhook はコイン付与のあと、coin_purchases に対して
--     ・safety_fee_yen(あんしんサポート料)      … 素の UPDATE
--     ・payment_method(card / paypay。0096)     … 素の UPDATE
--   を書き込む。ところが 0044 が coin_purchases を**追記専用**にした
--   (UPDATE は app.ledger_override 無しでは常に例外)ため、この2つは
--   **本番で毎回失敗していた。**
--
--   実測: credit_coins_for_purchase → UPDATE safety_fee_yen で
--   `LEDGER_IMMUTABLE: coin_purchases は追記専用です` が出る。
--
-- ■ なぜ誰も気づかなかったか
--   ①webhook は記録の失敗をログに書くだけで 200 を返す(仕様として正しい:
--     ここで 5xx を返すと付与済みなのに Stripe が再送し続ける)。
--     コイン付与は成功するので、画面上は何も欠けて見えない。
--   ②テスト(90)は INSERT 時に safety_fee_yen を直接入れており、
--     webhook と同じ「あとから UPDATE」の経路を通っていなかった。
--
-- ■ 実害
--   ・サポート料の売上が記録されない(会計・税務の集計から欠ける。
--     2026-08-03 のテスト購入 ¥5,250 の ¥250 も記録されていない)
--   ・payment_method が永遠に null → 0096 の「カードの共有では判定
--     できません」警告が一度も出ない。運営コンソールの「非カード購入 0件」が
--     **「調べた結果シロ」ではなく「記録が無かった」**を意味してしまう
--
-- ■ 直し方: coin_purchases 専用の不変トリガーに差し替える
--   payouts が既に同じ形をとっている(0044 の _payout_amount_immutable:
--   「status/振込結果の更新は通常運用なので通す」)。同じ考え方で、
--   coin_purchases も**この2列だけ・書き込みは1回だけ**を通す:
--
--     safety_fee_yen  … 既定値 0 からの変更のみ(上書き不可)
--     payment_method  … null からの変更のみ(上書き不可)
--     それ以外の列    … 従来どおり変更禁止(金額・ユーザー・セッションID)
--     DELETE          … 従来どおり禁止
--     同値の再書き込み … 通す(Stripe の再送で同じ値がもう一度来る)
--
--   関数側(webhook)は**1文字も変えない**。デプロイ済みのコードが
--   このマイグレーションだけで意図どおり動き始める。マイグレーションと
--   関数デプロイの順序事故を避ける(0096 の safety_fee と同じ理由)。
--
-- ■ 適用後の運用メモ
--   既存の本番データ(テスト購入)の safety_fee_yen=0 は、公開前の
--   リセット(docs/reset-before-launch.sql)で消える予定なのでそのまま。
--   残す場合は override を宣言して1回だけ訂正する(ledger_audit に残る)。
-- ============================================================

create or replace function public._purchase_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rest_old jsonb;
  v_rest_new jsonb;
begin
  -- 明示的な解除は従来どおり通す(記録つき)
  if public._ledger_override_on() then
    perform public._ledger_record_bypass(
      TG_TABLE_NAME, TG_OP,
      to_jsonb(OLD),
      case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);
    if TG_OP = 'DELETE' then return OLD; end if;
    return NEW;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases の行は削除できません。訂正が必要な場合は打ち消しの行を追加してください。';
  end if;

  -- webhook が決済成立後に書く2列だけを、書き込み1回に限って通す。
  -- 「同値の再書き込み」を許すのは、Stripe が同じイベントを再送するため
  -- (冪等な再実行を例外にしない)。
  v_rest_old := to_jsonb(OLD) - 'safety_fee_yen' - 'payment_method';
  v_rest_new := to_jsonb(NEW) - 'safety_fee_yen' - 'payment_method';
  if v_rest_old <> v_rest_new then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases は追記専用です(変更できるのは safety_fee_yen と payment_method の初回書き込みだけ)。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。';
  end if;
  if NEW.safety_fee_yen is distinct from OLD.safety_fee_yen
     and OLD.safety_fee_yen <> 0 then
    raise exception 'LEDGER_IMMUTABLE: safety_fee_yen は一度しか書き込めません(現在値 %)', OLD.safety_fee_yen;
  end if;
  if NEW.payment_method is distinct from OLD.payment_method
     and OLD.payment_method is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_method は一度しか書き込めません(現在値 %)', OLD.payment_method;
  end if;

  return NEW;
end;
$$;

comment on function public._purchase_immutable() is
  'coin_purchases の不変トリガー。0044 の全面禁止から、webhook が決済成立後に書く safety_fee_yen / payment_method の初回書き込みだけを通す形に緩めた(0104)。金額・ユーザー・セッションIDは従来どおり変更できない。';

revoke all on function public._purchase_immutable() from public, anon, authenticated;

drop trigger if exists coin_purchases_immutable on public.coin_purchases;
create trigger coin_purchases_immutable
  before update or delete on public.coin_purchases
  for each row execute function public._purchase_immutable();
