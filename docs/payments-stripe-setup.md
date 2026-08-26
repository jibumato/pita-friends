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

### 前提: **リポジトリのあるフォルダで打つこと**

`supabase functions deploy` は、**いま居るフォルダの
`supabase/functions/<関数名>/index.ts` を読んで送ります。**
`C:\Users\自分` のようなフォルダで打つと、こう出ます。

```
WARN: failed to read file: open supabase/functions/create-checkout-session/index.ts:
      no such file or directory
unexpected deploy status 400: {"message":"Entrypoint path does not exist - ...}
```

**「ファイルが無い」= フォルダが違う**という意味です。ソースを PC に置いてから
そこへ移動して打ちます。

```powershell
cd $HOME
git clone https://github.com/jibumato/pita-friends.git
cd pita-friends
supabase link --project-ref ここにプロジェクトRef
```

> - `git` が無ければ GitHub の緑の **Code → Download ZIP** で落として展開し、
>   展開先のフォルダへ `cd` しても同じです。
> - **`<...>` を付けたまま打たない。** PowerShell では `<` `>` が予約語なので
>   `演算子 '<' は、今後の使用のために予約されています。` で止まります。
>   山かっこを消して、Ref そのものだけを書きます。
> - `supabase link` でデータベースのパスワードを聞かれたら、**空のまま Enter**
>   で構いません(Function のデプロイに DB 接続は不要です)。
> - **`WARNING: Docker is not running` は無視してよい**警告です。いまの CLI は
>   Function をクラウド側でビルドするので、Docker は要りません。
> - 更新を反映するときは、次から `cd pita-friends` して `git pull` してから
>   デプロイします(**古いソースを送っても CLI は何も警告しません**)。

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
| 2026-07-31 | **新規ユーザーの購入上限**(規約第8条の6第5項1号・`0087`) | `create-checkout-session` | **上限が一切かからない。**登録直後のアカウントが50,000円まで買える |

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

> 📌 **上の引用の「7日保留」は 2026-07-30 時点の記録で、現状ではありません。**
> その後 新規ユーザーの購入上限(`0087`)・新規原資の30日換金保留(`0088`)・
> 係争中の報酬凍結(`0077`)・相殺(`0088`)を実装しました。
> **現在地は `docs/chargeback-defense.md`** にまとめてあります。
> 引用そのものは当時の記録なので書き換えません。

### 離脱率とのトレードオフ

認証を挟むぶん、購入の途中離脱は増えます。数字を見て緩める場合は
`supabase secrets set STRIPE_3DS=automatic` で Stripe の判断に任せられます。

> ⚠️ **緩めるときは、上の①②③が変わったかを必ず確認してください。**
> 変わっていないなら、離脱率だけを理由に緩めるのは割に合いません。

## 5-c. PayPay を追加する

コード側は環境変数だけで切り替わります。手順は3つ。

1. **Stripe ダッシュボード → 設定 → 決済手段** で **PayPay** を有効化
   （サンドボックスと本番は別々に有効化が要ります。本番は審査が入ることがあります）
2. Supabase に決済手段を設定
   ```bash
   supabase secrets set STRIPE_PAYMENT_METHODS=card,paypay
   ```
   > 未設定なら Stripe ダッシュボードの設定に任せます。
   > **ここに書いた手段を Stripe 側で有効化していないと、セッション作成が失敗します**
   > （購入ボタンでエラーになる）。必ず1を先にやること。
3. 反映
   ```bash
   supabase functions deploy create-checkout-session
   ```

3DSの指定(`payment_method_options.card`)はカードにしか効かないので、
PayPay を足しても既存のカード決済の挙動は変わりません。

### ★未設定のままにしないこと（2026-08-26 追記）

`STRIPE_PAYMENT_METHODS` が未設定だと、**Stripe ダッシュボードの設定がそのまま
出ます。** 既定では自動で多くの手段が有効になるため、サンドボックスの決済画面に
カード・PayPay・Google Pay・Apple Pay・Link に加えて **WeChat Pay・Alipay** まで
並ぶことがあります（実際に並びました）。

コインの付与は決済手段によらず動くので**壊れはしません**
（`payment_method` は自由記述で、webhook が `payment_method_details.type` を
そのまま書きます）。問題は次の3点です。

| 論点 | 中身 |
|---|---|
| **3DS** | `payment_method_options.card` は**カードにしか効きません**。Apple Pay / Google Pay / Link は実質カードなので対象ですが、ウォレット系（PayPay・WeChat・Alipay）は通りません。チャージバック防御の中心が3DSなので、どの手段にそれが無いのかを把握しておくこと（※これらの手段にそもそも異議申立てがあるかは、Stripeの仕様を一次情報で確認） |
| **居住地** | 規約 第3条3項は「日本国内に居住する個人に限る」で、`0081` が本人確認の提出を止めます。**WeChat Pay・Alipay は中国本土のウォレット**で、その前提と噛み合いません |
| **料率** | 分別管理規程 第7条1号の試算は **Stripe のカード 3.6%** を前提に「サポート料5% ＞ 実質負担3.78%」で成り立っています。**料率の高い手段が混ざると、分別口座への実着金が前受金を下回り、1号の補填義務が発動します。** 足すなら、その手段の料率を先に確認すること |

**当面の推奨は `card,paypay` です。**

```bash
supabase secrets set STRIPE_PAYMENT_METHODS=card,paypay
supabase functions deploy create-checkout-session
```

明示しておくと、**ダッシュボードを触ったときに決済手段が黙って変わることが
なくなります。** 増やすときは、上の3点を確認してから足してください。

### ⚠️ PayPay を足すと弱くなるもの: 自作自演の検知(0080・E-9)

**カードのフィンガープリントは PayPay 払いには存在しません。**
0080 でこれを最重要の手掛かりに据えたのは、
「端末IDは消せる、IPは変わる、**カードは同じ実カードである限り変わらない**」
という理由でした。PayPay で買われた分には、この手掛かりがありません。

危ないのは検知が弱くなること自体より、**弱くなったことが見えないこと**です。
換金画面に「カード共有 0件」と出ていれば、運営は「調べた結果シロ」と読みます。
実際には「調べようがなかった」かもしれない。この2つは意味が違います。

そこで **0096** で購入ごとに決済手段を記録し、換金画面に
「このピタメイトの購入のうち N 件はPayPay等で、カードの共有では判定できません」
と出すようにしてあります。**0096 を適用しないまま PayPay を有効にしないでください。**
記録が始まらないので、判定できない購入が黙って混ざります。

IP の共有判定(0022 `ip_flagged`)は PayPay でも従来どおり効きます。

### 期待できること: チャージバックの構造的リスクが減る

§5-b のとおり、この事業の最大の穴は
「申立期限120日 対 防御7日」という**期間の桁違い**です。
PayPay のようなウォレット決済は、カードのような異議申立て(チャージバック)の
仕組みを持たないのが一般的で、そうであればこの穴は PayPay で買われた分には
開きません。決済手数料もカードより低いのが通例です。

> **ただし私の知識では断定できません。**
> Stripe の決済手段一覧で PayPay の項の **「Disputes(異議申立て)」の欄**を
> 見て、対応の有無を確認してください。ここが「あり」なら、上の期待は成り立ちません。

## 6. 動作確認(テストモード)

1. アプリを起動 → ログイン → マイページ → コインウォレット → パックを選択
2. Stripe のテストカードで決済:
   - カード番号 `4242 4242 4242 4242` / 有効期限は未来の任意 / CVC 任意
3. 決済完了で `?checkout=success` としてアプリに戻り、数秒後に残高が増えます
4. うまくいかないときの確認ポイント:
   - Supabase → Edge Functions → Logs(`stripe-webhook` にエラーが出ていないか)
   - Stripe → Webhook → 該当エンドポイントの「送信済みイベント」が 200 を返しているか
   - `coin_purchases` に行が入っているか / `coin_transactions` に `purchase` が記録されているか

## 6-b. ⚠️ 「決済ページの準備に失敗しました [401]」——Stripeではなく Supabase の署名鍵

2026-08-04、この 401 に半日を溶かした。**Stripe側の設定はすべて正しく、一度もやり直していない。**
同じ疑いに入る人のために、切り分けの順序ごと残す。

### 症状

- 購入ボタンで `決済ページの準備に失敗しました [401]`
- **画面の他の部分はふつうに動く。** プロフィールも通知もトークも読める
- OPTIONS(プリフライト)は 200。落ちるのは POST だけ

### 見るべき1か所

F12 → Network → `create-checkout-session` の **POST の行**(OPTIONSの行ではない) → Response。

| 本文 | 意味 | 対処 |
|---|---|---|
| `{"error":"unauthorized"}` | 関数の中まで届いている。`getUser()` が失敗 | ログインし直す |
| `{"code":"UNAUTHORIZED_LEGACY_JWT",...}` | **ゲートウェイが弾いている。関数は走っていない** | 下記 |

画面のメッセージだけでは区別できない。`unauthorized` なら
「ログインの有効期限が切れています」と出るように書いてある(`src/lib/queries.ts:330`)。
**コード名の無い裸の `[401]` が出たら、それは Supabase 側からの応答**だと読む。

### UNAUTHORIZED_LEGACY_JWT の正体

Edge Functions のゲートウェイは、プロジェクトの**公開鍵(JWKS)でJWTを検証する。**
署名鍵が `HS256 (Shared Secret)` = 共通鍵だと、公開鍵の相方が存在しないので検証しようがなく、
「レガシー」として拒否される。**エラー名に反して、古い鍵かどうかは関係ない。**
対称鍵で署名されたJWTは、たとえ現行鍵でも通らない。

**Settings → JWT Keys** で CURRENT KEY の TYPE を見る。
`HS256 (Shared Secret)` なら、これが原因。

### 直し方

1. **CREATE STANDBY KEY** → **ES256 (ECC)** を選ぶ(RECOMMENDED。HS256は選ばない)
2. STANDBY として一覧に出て、数分待つ
3. **Rotate signing key**。確認ダイアログの3つ目に
   「The following Edge Functions may stop functioning ... : `create-checkout-session`」
   と名指しが出る。**これが出れば原因の確定**
4. **Edge Function を再デプロイする**(新しい検証方法を拾わせるため)
5. アプリで **ログアウト → ログイン**。強制リロードでは駄目。セッションが作り直されない

確認は、pitafure.com のコンソールで:

```js
(() => {
  const k = Object.keys(localStorage).find(x => x.includes('auth-token'));
  console.log(JSON.parse(atob(JSON.parse(localStorage[k]).access_token.split('.')[0])));
})()
```

`alg` が `ES256` になっていれば切り替わっている。`HS256` のままなら、まだ古いセッション。

> **Revoke は押さないこと。** 古い鍵は「Previously used keys」に残したまま検証に使われる。
> まだ有効なトークンを持つ利用者がいる段階で取り消すと、その人たちは強制ログアウトになる。

### 公開キーも新形式にしておく

`.env.production` の `VITE_SUPABASE_ANON_KEY` は、`Settings → API Keys` の
**Publishable key**(`sb_publishable_...`)を使う。レガシーの anon キー(`eyJ...`)は、
いずれ同じところで弾かれる。

### なぜ切り分けに時間がかかったか

**PostgREST(テーブルの読み書き)は同じトークンで通っていた。** 画面がふつうに動くので、
「決済まわりだけが壊れている」= Stripeの設定を疑う、という方向に引っ張られた。
実際にはこの署名鍵は**10日前**に ECC → HS256 へローテートされており、その時点から
Edge Functions は誰が呼んでも通らない状態だった。今日はじめて決済を通そうとしたので、
今日壊れたように見えただけだった。

**教訓: Edge Function だけが落ちるときは、まず Response の本文を見る。**
`Sb-Error-Code` ヘッダーに答えが書いてある。

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
