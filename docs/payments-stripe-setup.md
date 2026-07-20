# コイン決済(Stripe)セットアップ手順

コインの購入を Stripe Checkout で実装しました。この文書は、あなたの手元での設定手順です。
サンドボックス環境からはあなたの Supabase / Stripe に接続できないため、**デプロイと設定はあなたの手元で行ってください。**

## 全体像

```
[ユーザー] ─購入─▶ [アプリ] ─invoke─▶ [create-checkout-session] ─▶ Stripe決済ページ
                                                                        │
                                                              決済完了  ▼
[コイン付与] ◀─ credit_coins_for_purchase(冪等) ◀─ [stripe-webhook] ◀─ Stripe
```

- **コインの付与はサーバー(webhook)経由でのみ**行われます。クライアントは残高を書けません(改ざん防止)。
- 金額・付与数は `coin_packs` テーブル(サーバー権威)で確定します。クライアントは `pack_id` しか送りません。
- 同じ決済の二重付与は `coin_purchases.stripe_session_id` の一意制約で防ぎます。

---

## ⚠️ 始める前に(法務)

有償コインは**前払式支払手段(資金決済法)**です。**販売を開始したら**以下が必要です:

- 資金決済法・特商法に基づく**表示**(発行者名、有効期限、利用範囲、未使用残高の払戻し方針など)
- 各基準日(3/31・9/30)の**未使用残高が1,000万円を超えたら、届出＋残高の1/2以上を供託**
- コインを現金に**払い戻せる設計にしない**こと(払い戻せると「資金移動業」になり登録が必要)

詳しくは `docs/legal/coin-economy-legal-review.md` §2 を参照してください。**表示の整備が済むまでは本番公開しないでください。**

---

## 1. DBマイグレーション(0009)を適用

`supabase/schema-all.sql` を全て適用済みなら 0009 も含まれています。追加分だけ適用する場合は
`supabase/migrations/0009_payments.sql` を SQL Editor で実行してください。

作成物: `coin_packs`(パック定義・4種をseed済み)、`coin_purchases`(購入履歴・冪等キー)、
`credit_coins_for_purchase`(付与関数)。

パックの価格を変えたいときは `coin_packs` を UPDATE すれば、アプリ再デプロイ不要で反映されます
(`src/flow.ts` の `COIN_PACKS` は**デモ表示とIDの対応**用。IDと数量はDBと一致させてください)。

## 2. Stripe アカウント

1. https://dashboard.stripe.com でアカウント作成(最初は**テストモード**でOK)
2. **開発者 → APIキー** で `Secret key`(`sk_test_...`)を控える
3. 日本の事業者情報・銀行口座を登録(本番受け取りに必要。テスト中は不要)

## 3. Supabase の Secrets を設定

Supabase CLI で(`supabase link` 済みの前提):

```bash
supabase secrets set STRIPE_SECRET_KEY=sk_test_xxx
supabase secrets set APP_URL=http://localhost:5173     # 本番は https://あなたのドメイン
# STRIPE_WEBHOOK_SECRET は 手順5 で取得してから設定する
```

> `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` は Edge Function 実行時に自動注入されるので設定不要です。

## 4. Edge Function をデプロイ

```bash
supabase functions deploy create-checkout-session
supabase functions deploy stripe-webhook --no-verify-jwt
```

> `stripe-webhook` は **`--no-verify-jwt` 必須**です。Stripe は Supabase の JWT を持たずに呼んでくるためです。
> `create-checkout-session` はログインユーザーが呼ぶので JWT 検証あり(既定)のままにします。

## 5. Stripe Webhook を登録

1. Stripe ダッシュボード **開発者 → Webhook → エンドポイントを追加**
2. URL:
   ```
   https://<プロジェクトRef>.supabase.co/functions/v1/stripe-webhook
   ```
3. リッスンするイベント: **`checkout.session.completed`**
4. 追加後に表示される **署名シークレット(`whsec_...`)** を控え、Supabase に設定:
   ```bash
   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxx
   ```
   (設定後、webhook を使うので `supabase functions deploy stripe-webhook --no-verify-jwt` を再実行して反映)

## 6. 動作確認(テストモード)

1. アプリを起動 → ログイン → マイページ → コインウォレット → パックを選択
2. Stripe のテストカードで決済:
   - カード番号 `4242 4242 4242 4242` / 有効期限は未来の任意 / CVC 任意
3. 決済完了で `?checkout=success` としてアプリに戻り、数秒後に残高が増えます
4. うまくいかないときの確認ポイント:
   - Supabase → Edge Functions → Logs(`stripe-webhook` にエラーが出ていないか)
   - Stripe → Webhook → 該当エンドポイントの「送信済みイベント」が 200 を返しているか
   - `coin_purchases` に行が入っているか / `coin_transactions` に `purchase` が記録されているか

## 7. 本番へ

1. Stripe を**本番モード**に切り替え、本番の `sk_live_...` と本番Webhookの `whsec_...` を設定
2. `APP_URL` を本番ドメインに変更、Webhook URL も本番プロジェクトのものに
3. **法務の表示(手順の前の⚠️)を整えてから**公開

---

## サンドボックス(私)でできること・できないこと

- ✅ できる: Function/SQL/フロントのコード修正、型チェック、ビルド、デモモードでの画面確認
- ❌ できない: あなたの Supabase/Stripe への接続を伴う操作(デプロイ、実決済テスト)— ネットワークポリシーで遮断されているため

エラーが出たら、ログのメッセージを教えていただければ修正します。
