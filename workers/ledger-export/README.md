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
| 全量 | `bookings` / `payouts` / `coin_lots` / `coin_wallets` / `coin_lot_consumptions` / `ledger_audit` / `account_anonymizations` | 毎日 19:23 UTC | 最大24時間 |

状態が変わるテーブル(予約・換金・ロット)は差分では追えないので、毎日丸ごと取ります。
金額に関わるものだけに絞ってあるので、件数が少ないうちはこれで十分軽く済みます。

**PITR より優れている点**: PITR は Supabase 内部の機能なので、
アカウント凍結・請求トラブル・誤ってプロジェクトを削除、といった
「Supabase ごと失う」事故には効きません。別事業者に置くこちらは効きます。

**PITR に劣る点**: 巻き戻しの粒度が1時間(PITR は数分)。
プロフィール・メッセージ・画像は対象外(Pro の日次バックアップに任せる)。

## セットアップ

### 1. R2 バケットを作る

Cloudflare ダッシュボード → R2 → Create bucket → 名前 `pita-ledger`
(別名にする場合は `wrangler.jsonc` の `bucket_name` も合わせる)

### 2. Supabase の URL を書く

`wrangler.jsonc` の `vars.SUPABASE_URL` を実際の値に置き換えます。
この値は公開されても問題ありません。

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
