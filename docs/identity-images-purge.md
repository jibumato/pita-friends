# 本人確認画像の削除(identity-images-purge)の設定

規約 第3条5項は「本人確認のために取得した書類・顔写真の画像は、照合の完了後
すみやかに削除」と約束しています。これを**サーバー側で確実に**行う仕組みです(`0129`)。

| いつ | 何をするか |
|---|---|
| 運営が承認・却下した直後 | その申請の画像を消し、`identity_verifications.images_deleted_at` に日時を入れる |
| 毎日 03:41(JST) | ①判定済みなのに消えていない画像 ②どの審査待ちの申請にも紐づかない画像(24時間以上たったもの) ③退会者のファイル(本人確認・アバター・声)を消し、結果を運営コンソールの「健全性」に出す |

審査待ちの画像は、運営が見るために残します。審査待ちが7日を超えると「健全性」に
warn が出ます(画像を預かり続けている状態なので、早めに審査してください)。

## 以前の作りの問題(なぜ作り直したか)

- 削除は運営のブラウザから行い、**失敗しても握りつぶし、記録も無かった**
  (しかも `remove()` は失敗を例外ではなく戻り値で返すので、そもそも拾えていなかった)
- 申請の作成に失敗すると、画像だけが残り続けた
- 退会時の `anonymize_user` は SQL で `storage.objects` を消していたが、
  `0008` で同じやり方が本番では権限エラーになった記録があり、**匿名化そのものが失敗する**おそれがあった

## 設定の手順(本番で1回だけ)

### 1. マイグレーション `0129` を当てる

`docs/apply-migrations.md` の方法A。`supabase/apply/0096-0129/part5_0129-0129.sql` です
(`0128` まで当たっていれば、これだけ)。

### 2. 秘密を設定する

毎日の掃除を呼ぶための合言葉です。`Project Settings → Edge Functions → Secrets` で:

| 名前 | 値 |
|---|---|
| `IDENTITY_PURGE_SECRET` | 長いランダムな文字列(例: パスワード生成で40文字) |

`SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` は Supabase が自動で入れます。

### 3. Edge Function をデプロイする

```bash
supabase functions deploy identity-images-purge --no-verify-jwt
```

`--no-verify-jwt` が要ります(毎日の掃除はログイントークン無しで呼ぶため)。
運営の画面からの呼び出しは、関数の中でトークンと運営権限を確かめています。
ダッシュボードの「Via Editor」で作る場合は、`index.ts` の中身だけを貼ってください
(`purge.test.ts` と `test-import-map.json` は手元の確認用で、デプロイ不要)。

### 4. 毎日の掃除を登録する

`docs/check-cron.sql` 末尾の「直しかた」にある `purge-identity-images` の SQL を、
`<PROJECT-REF>` と秘密を実際の値に置き換えて SQL Editor で実行します。
**秘密が入るので、実行後の SQL をどこかに貼り残さないこと。**

### 5. 確かめる

- `docs/check-cron.sql` で `purge-identity-images` が ✅
- 翌日、運営コンソールの「健全性」に「本人確認画像の削除」が出て OK になっている
- `docs/check-identity-images.sql` で、「審査待ち」以外の画像が 0 枚

すぐ確かめたい場合は、手で1回呼べます(秘密を履歴に残さないよう注意):

```bash
curl -X POST 'https://<PROJECT-REF>.supabase.co/functions/v1/identity-images-purge' \
  -H 'Content-Type: application/json' -H 'x-purge-secret: <秘密>' -d '{}'
```

## 手元での確認

```bash
deno test --node-modules-dir=none --allow-env --allow-net --allow-read \
  --import-map supabase/functions/identity-images-purge/test-import-map.json \
  supabase/functions/identity-images-purge/purge.test.ts
```

Supabase(認証・テーブル・ストレージ)を模して、判定直後の削除・審査待ちを消さないこと・
権限のない呼び出しを弾くこと・失敗を成功扱いにしないこと・毎日の掃除の対象を確かめます。
DB 側は `supabase/tests/49_identity_image_purge.sql`。
