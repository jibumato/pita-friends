# アイコン画像・ボイスプロフィールの Edge Function デプロイ手順

## なぜ Edge Function 経由なのか

ブラウザから直接 Storage に保存する実装（`storage.upload()`）が、
`avatars` バケットの RLS で必ず拒否される事象に遭遇したため。

切り分けで以下をすべて確認したうえで、それでも拒否された。

| 確認項目 | 結果 |
| --- | --- |
| ポリシーの中身（`bucket_id` と `auth.uid()` の比較） | 正しい |
| ポリシーの `roles` / `permissive` | `{authenticated}` / PERMISSIVE のみ |
| バケット設定（public・3MB・image/jpeg,png,webp） | 正しい |
| ログインセッション・トークンの有効性 | 有効 |
| `Authorization` ヘッダ | 本人のJWTが送られている |
| 保存先パスの uid と JWT の `sub` | 完全一致 |
| 他テーブル（`profiles`）への書き込み | 成功する |
| 「誰でも insert 可」の一時ポリシー（`to public`） | **入れても拒否される** |

最後の行が決定的で、`storage.objects` のポリシーとは無関係に拒否されている。
JWT署名方式（ES256→HS256）の切り戻しでも解消しなかった。
アプリ側・DB設定側で打てる手が無いため、Storage の RLS を経由しない方式にした。

## 安全性

service role は RLS を素通りするため、Edge Function 側で以下を強制している。

- `Authorization` の JWT を検証して本人（uid）を特定する
- **保存先パスはサーバ側で `{uid}/avatar.webp` を組み立てる**（クライアントからパスを受け取らない）
- MIME（jpeg/png/webp）とサイズ（3MBまで）をサーバ側で再検証する

したがって、他人のフォルダへの書き込み・削除はできない。

## デプロイ

2つの関数はどちらも1ファイルで完結している(共有ファイルを import していない)ため、
**ダッシュボードから貼り付けるだけでデプロイできる**。CLI でも可。

### 方法A: ダッシュボード(おすすめ・CLI不要)

1. Supabase ダッシュボード → 左メニュー **Edge Functions**
2. 右上の **「Deploy a new function」→「Via Editor」**
3. 関数名に `avatar-upload` を入力
4. エディタの中身を全部消し、`supabase/functions/avatar-upload/index.ts` の中身を貼り付け
5. **Deploy** を押す
6. 同じ手順で残りの3つも作る
   - `avatar-delete` … アイコンを既定に戻す
   - `voice-upload` … ボイスプロフィールの保存
   - `voice-delete` … ボイスプロフィールの削除

### 方法B: CLI

```bash
supabase functions deploy avatar-upload
supabase functions deploy avatar-delete
supabase functions deploy voice-upload
supabase functions deploy voice-delete
```

### 重要: Verify JWT を OFF にする

デプロイ後、**4つすべての関数で必ず設定を変更する**。

1. Edge Functions → 対象の関数 → **Settings** タブ
2. **「Verify JWT with legacy secret」を OFF** にして保存

これをしないと **401 Unauthorized** で必ず失敗する。
このプロジェクトでは JWT 署名鍵を新方式へローテーションした影響で、
**Storage と Edge Function のプラットフォーム側 JWT 検証が機能していない**
(PostgREST=DB操作だけは正常に動くため気づきにくい)。

OFF にしても安全性は落ちない。関数の中で
`auth.getUser(token)` により Auth API でトークンを検証しており、
そこで特定した uid 以外のパスには書き込めないようにしているため。

### 必要なシークレット

いずれも Supabase が自動で注入する標準の環境変数のため、**追加設定は不要**。

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

`APP_URL`（CORS の許可オリジン）を設定している場合はそのまま使われる。
未設定ならワイルドカードになる。

```bash
# 必要なら
supabase secrets set APP_URL=https://pita-friends.example.com
```

## トラブルシューティング

### 401 Unauthorized になる

上の「Verify JWT を OFF にする」を実施したか確認する。
それでも 401 の場合は関数の **Logs** に `[avatar-upload] auth ...` が出ているか見る。

- **ログがある** → 関数内の検証で弾かれている。メッセージが原因
- **ログが無い**(booted/shutdown のみ) → プラットフォーム側で弾かれている。
  Verify JWT の設定を再確認する

### 参考: 過去にはまった実装ミス

`auth.getUser()` を**引数なし**で呼ぶと、クライアント自身が保持するセッション
(サーバ環境では常に空)を見にいくため、必ず 401 になる。
必ず `auth.getUser(token)` とトークンを明示的に渡すこと。

## 動作確認

アイコン画像:

1. アプリにログイン
2. マイページのアイコン、またはプロフィール編集画面からアイコン画像を選ぶ
3. 画像が即座に差し替わること
4. 「既定に戻す」で頭文字＋カラーに戻ること
5. リロードしても状態が保たれること

ボイスプロフィール:

1. マイページの「声を録音する」で録音（マイク許可が必要）
2. 「この挨拶を公開」で保存できること
3. 再生できること
4. 「削除」で消えること

失敗する場合は Edge Function のログを確認する。

```bash
supabase functions logs avatar-upload
```

## 元の方式に戻す場合

Supabase 側で Storage の RLS 問題が解消したら、`src/lib/queries.ts` の
`uploadAvatar` / `deleteAvatar` を `storage.upload()` / `storage.remove()` 直接呼び出しに
戻せる（`0025` と `0027` のポリシーはそのまま残してある）。
