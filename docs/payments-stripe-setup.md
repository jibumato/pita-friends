# コイン決済(Stripe)セットアップ手順

コインの購入を Stripe Checkout で実装しました。ホストへの報酬振込は **自社の銀行振込
(総合振込)** で行います(2026-07-21決定。Stripe Connect は料金面の理由で不採用 —
入金ごと0.25%+¥250、有効アカウントごと月¥200)。
この文書は、あなたの手元での設定手順です。サンドボックス環境からはあなたの Supabase / Stripe に
接続できないため、**デプロイと設定はあなたの手元で行ってください。**

## 全体像

**① コイン購入(ゲスト → 当社、Stripe)**
```
[ユーザー] ─購入─▶ [アプリ] ─invoke─▶ [create-checkout-session] ─▶ Stripe決済ページ
                                                                        │
                                                              決済完了  ▼
[コイン付与] ◀─ credit_coins_for_purchase(冪等) ◀─ [stripe-webhook] ◀─ Stripe
```

**② ホストへの報酬振込(当社 → ホスト、自社銀行振込)**
```
[ホスト] ─口座登録(ホスト設定)─▶ host_bank_accounts
[ホスト] ─換金申請(ウォレット)─▶ request_bank_payout ─▶ payouts(pending)
                                                             │
[運営] 月次で締め ─ 振込リストをSQLで出力 ─ 総合振込を実行 ─ mark_payout_paid/failed
```
運用手順の詳細は **`docs/payouts-bank-operations.md`** を参照してください。

- **コインの付与・換金はすべてサーバー(Edge Function/webhook/RPC)経由でのみ**行われます。クライアントは残高を書けません(改ざん防止)。
- 金額・付与数は `coin_packs` テーブル(サーバー権威)で確定します。クライアントは `pack_id` しか送りません。
- 同じ決済の二重付与は `coin_purchases.stripe_session_id` の一意制約で防ぎます。
- **購入コイン(`balance`)と報酬コイン(`earned_balance`)は別会計**です。換金できるのは報酬コインのみ(詳細は§7)。

---

## ⚠️ 始める前に(法務・②を使う場合は特に重要)

有償コインは**前払式支払手段(資金決済法)**です。**販売を開始したら**以下が必要です:

- 資金決済法・特商法に基づく**表示**(発行者名、有効期限、利用範囲、未使用残高の払戻し方針など)
- 各基準日(3/31・9/30)の**未使用残高が1,000万円を超えたら、届出＋残高の1/2以上を供託**
- **購入したコイン(`balance`)は現金に払い戻せる設計にしない**こと(払い戻せると「資金移動業」になり登録が必要)

詳しくは `docs/legal/coin-economy-legal-review.md` §2 を参照してください。**表示の整備が済むまでは本番公開しないでください。**

**ホストへの報酬振込(②・自社銀行振込)を有効にする場合は、追加で法務レビューが必須です。**
自社振込は**資金移動の実行主体が当社になる**ため、「収納代行として整理できるか/資金移動業の
登録が必要か」「ボーナスコインの原資をどう扱うか」等の論点が Stripe Connect 利用時よりシビアです。
詳しくは `docs/legal/coin-economy-legal-review.md` **§7.2**(2026-07-20追記)を必ず読んでから進めてください。
弁護士レビューが済むまでは、②の機能(口座登録・換金)はコードとしては動きますが、**本番では有効化しないことを推奨します。**

---

## 1. DBマイグレーション(0009, ②を使うなら0013・0014も)を適用

`supabase/schema-all.sql` を全て適用済みなら 0009・0013・0014 も含まれています。追加分だけ適用する場合は
`supabase/migrations/0009_payments.sql`(コイン購入)・`0013_escrow_payouts.sql`+`0014_bank_payouts.sql`
(ホストへの振込、②を使う場合のみ)を SQL Editor で実行してください。

作成物(0009): `coin_packs`(パック定義・4種をseed済み)、`coin_purchases`(購入履歴・冪等キー)、
`credit_coins_for_purchase`(付与関数)。

作成物(0013+0014): `coin_wallets.earned_balance`(報酬コイン残高)、`complete_booking`(ゲストによる
プレイ完了確定)、`host_bank_accounts`(振込先口座)、`payouts`(換金履歴・振込先スナップショット)、
`request_bank_payout`(換金申請・手数料控除)、`mark_payout_paid` / `mark_payout_failed`(運営の消し込み)。
※0014は0013に含まれていたStripe Connect用のテーブル・関数を削除します。

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
supabase functions deploy record-ip
```

> `stripe-webhook` は **`--no-verify-jwt` 必須**です。Stripe は Supabase の JWT を持たずに呼んでくるためです。
> `create-checkout-session` はログインユーザーが呼ぶので JWT 検証あり(既定)のままにします。
> `record-ip`(ギフトのIP監視)もログインユーザーが呼ぶので JWT 検証あり(既定)のまま。
> `SUPABASE_ANON_KEY` は自動注入されるので設定不要。未デプロイでもギフトは動く
> (IP記録だけがスキップされる)。

## 4-b. ⚠️ 再デプロイが必要な変更の履歴

**Edge Function は `main` にマージしても自動では反映されません。**
Cloudflare のフロントだけが自動デプロイで、Supabase の Function は
`supabase functions deploy` を打つまで**古いコードが動き続けます。**

これが厄介なのは、**フロントと Function が食い違っても画面はふつうに動く**
ことです。下の1件目がまさにそれで、購入画面には 21,000円 と出るのに
Stripe は 20,000円しか請求しません。**表示と請求の不一致**になります。

| 日付 | 変更 | どちらの関数 | 反映しないと |
|---|---|---|---|
| 2026-07-2x | **あんしんサポート料を明細に追加**(コイン価格と2行に分けて請求) | `create-checkout-session` / `stripe-webhook` | **画面は21,000円、請求は20,000円。** サポート料が1円も入らない |
| 2026-07-30 | チャージバックの受信(`charge.dispute.*` の処理) | `stripe-webhook` | 異議申立てを受けても**コインの凍結が働かない** |
| 2026-07-30 | **EMV 3-Dセキュア(3DS2)** の要求 | `create-checkout-session` | 不正利用型チャージバックの責任が移らない(§5-b) |
| 2026-07-31 | 決済カードのフィンガープリント記録(E-9) | `stripe-webhook` | 自作自演の検知が端末とIPだけになる |

つまり **`create-checkout-session` と `stripe-webhook` の両方**を
デプロイし直す必要があります。

```bash
supabase functions deploy create-checkout-session
supabase functions deploy stripe-webhook --no-verify-jwt
```

### 反映されたことの確かめかた

**「デプロイした」だけでは確認になりません。** 実際に1件通してください。

1. **テストモードで ¥300 のパックを購入する**
2. Stripe の Checkout 画面に **明細が2行**（コイン代金＋あんしんサポート料）
   出ていること ← ここが1行なら `create-checkout-session` が古いままです
3. 購入後、SQL Editor で次を実行する

```sql
-- 直近の購入が、新しいコードで処理されたかを見る
select
  cp.created_at,
  cp.price_yen                        as "コイン代金",
  cp.safety_fee_yen                   as "サポート料",
  case when cp.safety_fee_yen is null or cp.safety_fee_yen = 0
       then '❌ stripe-webhook が古い(サポート料を記録していない)'
       else '✅' end                   as "webhook",
  case when exists (
         select 1 from public.user_payment_cards c where c.user_id = cp.user_id)
       then '✅' else '❌ カードのフィンガープリントが未記録(0080が未反映)' end
                                       as "カード記録"
from public.coin_purchases cp
order by cp.created_at desc
limit 5;
```

> **カード記録が ❌ でも、決済手段がカードでない場合**（PayPay 等）は正常です。
> カードで買ったのに ❌ なら、`stripe-webhook` が古いか、
> `record_payment_card` の権限が落ちています（`docs/check-cron.sql` の「権限」で確認）。

## 5. Stripe Webhook を登録

1. Stripe ダッシュボード **開発者 → Webhook → エンドポイントを追加**
2. URL:
   ```
   https://<プロジェクトRef>.supabase.co/functions/v1/stripe-webhook
   ```
3. リッスンするイベント: **次の3つを必ず選ぶ**
   - **`checkout.session.completed`** … コインの付与
   - **`charge.dispute.created`** … チャージバックの申立て。**残高を凍結する**
   - **`charge.dispute.closed`** … 決着。当社の主張が通れば自動で解除

   > ⚠️ **dispute の2つを選び忘れると、凍結が働きません。**
   > 税理士の第2回回答(Q14): 「これがないと『**チャージバックを申し立てながら、
   > その間にコインを使い切る**』という極めて単純な不正が通ります。
   > 会計処理をどう決めても、この穴が開いていれば損失は防げません。」
   > **コードだけでは担保できない設定**なので、ここで必ず確認してください。
4. 追加後に表示される **署名シークレット(`whsec_...`)** を控え、Supabase に設定:
   ```bash
   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxx
   ```
   (設定後、webhook を使うので `supabase functions deploy stripe-webhook --no-verify-jwt` を再実行して反映)

## 5-b. EMV 3-Dセキュア(3DS2)

**コード側で `request_three_d_secure: 'any'` を指定済み**です
(`create-checkout-session`)。Stripe ダッシュボード側で追加の設定は原則不要ですが、
**Radar のルールで 3DS を無効化していないか**だけ確認してください。

### なぜ強制するのか

税理士の第4回回答:

> 「**チャージバックの期間が、設計とまったく噛み合っていません。**
>   国際ブランドの申立期限は**取引日から120日程度**です。対する現在の防御は
>   7日保留＋週次振込で、**期間が一桁違います。**
>   規約でピタメイトに返還義務を課すことは可能ですが、**善意の受領者から既払金を
>   回収するのは実務上ほぼ不可能で、規約は防御になりません。**
>   設計で防ぐべきで、**最も効果が大きいのは EMV 3-Dセキュア(3DS2)の適用**です。
>   認証済み取引では不正利用によるチャージバックの**責任がカード発行会社に移転**
>   します(ライアビリティシフト)。」

本サービスは ①換金を伴い ②申立てまでに数か月あり ③回収手段が実質的に無い、
という構造なので、**取りこぼしが致命傷になります。**

### 離脱率とのトレードオフ

認証を挟むぶん、購入の途中離脱は増えます。数字を見て緩める場合は
`supabase secrets set STRIPE_3DS=automatic` で Stripe の判断に任せられます。

> ⚠️ **緩めるときは、上の①②③が変わったかを必ず確認してください。**
> 変わっていないなら、離脱率だけを理由に緩めるのは割に合いません。

## 6. 動作確認(テストモード)

1. アプリを起動 → ログイン → マイページ → コインウォレット → パックを選択
2. Stripe のテストカードで決済:
   - カード番号 `4242 4242 4242 4242` / 有効期限は未来の任意 / CVC 任意
3. 決済完了で `?checkout=success` としてアプリに戻り、数秒後に残高が増えます
4. うまくいかないときの確認ポイント:
   - Supabase → Edge Functions → Logs(`stripe-webhook` にエラーが出ていないか)
   - Stripe → Webhook → 該当エンドポイントの「送信済みイベント」が 200 を返しているか
   - `coin_purchases` に行が入っているか / `coin_transactions` に `purchase` が記録されているか

## 7. ホストへの報酬振込(②・自社銀行振込)を有効にする

**冒頭⚠️の法務レビューが済んでから**進めてください。Stripe側の追加設定は**不要**です
(振込はStripeを使いません)。

1. DBに `0013_escrow_payouts.sql` と `0014_bank_payouts.sql` を適用(手順1)
2. 総合振込(一括振込)が使える法人/事業用のネットバンキング口座を用意
   (ネット銀行は他行宛¥145〜160/件と割安。メガバンクは¥250〜660/件)
3. 動作確認:
   1. 本人確認済みのテストユーザーでログイン → ホスト設定 → 振込先口座を登録
   2. 予約を作成(create_booking)→ トーク画面でゲストが「プレイ完了」を確定 → ホストの `earned_balance` が増える
   3. ホスト側でウォレット画面から換金を申請(5,000コイン以上)→ `payouts` に `status='pending'` の行ができ、
      手数料300コインが控除された `amount_yen` が入っていることを確認
   4. SQL Editor で `select public.mark_payout_paid(id) from public.payouts where status='pending';`
      → ウォレットの履歴が「振込済み」になることを確認

毎月の締め・振込リスト出力・消し込み・エラー対応の手順は
**`docs/payouts-bank-operations.md`** にまとめてあります。

## 8. 本番へ

1. Stripe を**本番モード**に切り替え、本番の `sk_live_...` と本番Webhookの `whsec_...` を設定
2. `APP_URL` を本番ドメインに変更、Webhook URL も本番プロジェクトのものに
3. **法務の表示(手順の前の⚠️)を整えてから**公開
4. ②(換金)を有効にする場合、弁護士レビュー完了と、振込原資の管理(ユーザーのコイン購入代金と
   事業資金の分別)の体制を整えてから

---

## サンドボックス(私)でできること・できないこと

- ✅ できる: Function/SQL/フロントのコード修正、型チェック、ビルド、デモモードでの画面確認
- ❌ できない: あなたの Supabase/Stripe への接続を伴う操作(デプロイ、実決済テスト)— ネットワークポリシーで遮断されているため

エラーが出たら、ログのメッセージを教えていただければ修正します。
