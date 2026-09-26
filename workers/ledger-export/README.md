# 取引データの外部バックアップ(R2)

取引データを Supabase の外へ1時間ごとに写し取る Worker です。
Supabase の PITR($100/月 + Small コンピュート$15/月)を当面見送るための代替で、
**費用は Cloudflare の無料枠に収まります**。

## なぜこれで足りるのか

`0044` で `coin_transactions` / `coin_purchases` が追記専用になっています。
行は増えるだけで書き換わらないので、「`created_at` が前回以降の行」を取るだけで
完全な写しになります。差分検知(CDC)の仕組みが要りません。

| | 対象 | 頻度 | 失う可能性のある時間 |
|---|---|---|---|
| 差分 | `coin_transactions` / `coin_purchases` | 毎時 :07 | 最大1時間 |
| 全量 | 下の表の24テーブル | 毎日 19:23 UTC | 最大24時間 |

状態が変わるテーブル(予約・換金・ロット)は差分では追えないので、毎日丸ごと取ります。
金額・債務・法的な証跡に関わるものだけに絞ってあるので、件数が少ないうちはこれで十分軽く済みます。

| 区分 | テーブル |
|---|---|
| 台帳 | `bookings` `booking_pairs` `payouts` `coin_lots` `coin_wallets` `coin_lot_consumptions` `gifts` `ledger_audit` `account_anonymizations` |
| 当社が負う金銭債務・売上 | `cash_refunds`(金銭返金債務) `platform_fees`(利用料の明細) `purchase_voids` `payment_disputes` `chargeback_offsets` |
| 料率の版 | `host_fee_tiers` `gift_fee_rates` `fee_change_notices` |
| 同意・通知・立証の証跡 | `policy_consents` `monitoring_consents` `residency_declarations` `purchase_evidence` `account_withdrawals` `dormant_account_notices` `admin_actions` |

**入れていないもの**: `host_bank_accounts`(口座番号)と `user_payment_cards`。
別事業者に口座番号を置くと、漏えいしたときの影響が広がるためです。
Supabase ごと失った場合は、ピタメイトに振込先を登録し直してもらうことになります。

> 2026-09-26 に対象を7→24テーブルに広げました。当初(`0047`)の対象は、
> その後にできた金銭返金債務(`0085`)・利用料の明細(`0033`)・チャージバックの
> 相殺(`0088`)・同意の記録(`0106`)などを含んでいませんでした。
> **テーブルを足したら、ここに入れるかどうかを必ず判断すること。**

**PITR より優れている点**: PITR は Supabase 内部の機能なので、
アカウント凍結・請求トラブル・誤ってプロジェクトを削除、といった
「Supabase ごと失う」事故には効きません。別事業者に置くこちらは効きます。

**PITR に劣る点**: 巻き戻しの粒度が1時間(PITR は数分)。
プロフィール・メッセージ・画像は対象外(Pro の日次バックアップに任せる)。

## セットアップ

### 1. R2 バケットを作る

Cloudflare ダッシュボード → R2 → Create bucket → 名前 `pita-ledger`
(別名にする場合は `wrangler.jsonc` の `bucket_name` も合わせる)

### 2. Supabase の URL を確認する

`wrangler.jsonc` の `vars.SUPABASE_URL` に本番の値(`.env.production` と同じ)を
入れてあります。この値は公開されても問題ありません。プロジェクトを作り直した
場合だけ書き換えてください。

### 3. シークレットを登録する

```bash
cd workers/ledger-export

# service_role キー(Supabase → Settings → API → service_role)
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY

# 手動実行用の合言葉(任意。openssl rand -hex 32 などで生成)
npx wrangler secret put TRIGGER_SECRET
```

> ⚠️ `service_role` キーは全てのRLSを迂回します。**フロントには絶対に置かない**でください。
> `wrangler secret` は暗号化して保存され、`wrangler.jsonc` には残りません。

### 4. マイグレーション `0047` を適用する

`ledger_exports`(実行記録)と鮮度チェックが入ります。これが無いと Worker の
書き戻しが失敗します(本体は動きますがログにエラーが出ます)。

### 5. デプロイして動作確認

```bash
npx wrangler deploy

# 手動で1回流してみる
curl -H "Authorization: Bearer $TRIGGER_SECRET" \
  "https://pita-ledger-export.<account>.workers.dev/?kind=snapshot"
```

確認するもの:

- R2 の `ledger/snapshot/YYYY-MM-DD/` にファイルができている
- Supabase で `select * from public.ledger_exports order by ran_at desc limit 5;`
  に `ok = true` の行がある

## 止まったときに気づく仕組み

**止まったことに気づけないバックアップは、無いのと同じです。**
Worker は実行結果を `ledger_exports` に書き戻し、毎日 04:17 UTC の
`check_ledger_export()` がそれを見ます。

| 状態 | 判定 |
|---|---|
| 差分が3時間以上止まっている(2回分の取りこぼしまで許容) | error + 管理者へ通知 |
| 全量が26時間以上止まっている | error + 管理者へ通知 |
| 復旧はしたが直近24時間に失敗がある | warn |

結果は `integrity_latest` に他のチェックと並んで出ます。

**取れた件数が実際の件数より少なければ、その回は失敗として記録します。**
Supabase の「1回に返す最大件数」(Settings → API → Max rows)が1000より
小さいと、1ページ目で打ち切られたまま成功扱いになるためです。
失敗の記録に「◯/◯ 件しか取れなかった」と出たら、Max rows を1000以上に戻してください。

件数が大きく増えて Worker の CPU 時間の上限に当たるようになった場合も、
実行が失敗して上の仕組みで通知されます。そのときは Workers の有料プラン
($5/月)に切り替えるのが最も手軽です。

## 復元するとき

NDJSON なので、そのまま `COPY` で戻せます。差分は窓を重ねているため
同じ行が複数回出ることがありますが、主キーで潰せます。

```bash
# 例: coin_transactions を戻す
cat ledger/incremental/2026/07/*/*-coin_transactions.ndjson \
  | jq -c 'select(.id)' \
  | psql "$DB_URL" -c "copy tmp_tx (data) from stdin"
# → insert into coin_transactions select ... from tmp_tx on conflict (id) do nothing
```

戻すときは `0044` の保護に引っかかるので、`set local app.ledger_override = 'on'`
が要ります(`docs/data-integrity.md` 参照)。

## 費用

| | 無料枠 | この用途での使用量 |
|---|---|---|
| Workers Cron Triggers | 無料 | 1日25回 |
| Workers リクエスト | 10万/日 | 1日あたり数百(Supabase への問い合わせ) |
| R2 ストレージ | 10GB | 当面 数MB/月 |
| R2 書き込み(Class A) | 100万/月 | 1日あたり数十 |

実質 ¥0 です。R2 は下り(egress)が無料なので、復元時にも課金されません。
