# セキュリティ点検の記録

最終実施: 2026-07-30

公開前の点検です。**未ログイン(anon)で実際に再現できたものだけを「発見」として扱い**、
「たぶん危ない」で終わらせないようにしています。再現手順は
`supabase/tests/74_anon_surface.sql` にテストとして残してあり、
塞いだ穴が開き直したらテストが落ちます。

---

## 修正したもの

### 1. 他人の予約表が未ログインで読めた（高）— 0065で修正

`_booking_slot_conflict(相手, 開始時刻, 分)` が PUBLIC に開いていました。
SECURITY DEFINER なので **RLS を飛び越え**、指定した相手がその時間に
予約を持っていれば予約IDを返します。時刻をずらして繰り返せば
任意の相手の予約表が復元できます。

相手のUUIDは `public_host_cards()`（未ログインで見える掲載一覧）が返しているので、
**掲載中のピタメイト全員の稼働予定が外から読める状態**でした。

再現（`anon` ロールで実行）:

```
bookings を直接 select   → ERROR: permission denied ✅（ここは塞がっていた）
_booking_slot_conflict() → 8c23b9d3-... ❌（予約IDが返る）
```

このサービスで「誰がいつ誰と遊ぶか」は最も漏らしてはいけない情報で、
出会い系非該当の実態維持にも関わります。

### 2. 監査台帳に未ログインで嘘を書けた（高）— 0065で修正

`_ledger_record_bypass(表, 操作, 旧, 新)` が PUBLIC に開いていました。
0044 の追記専用台帳（`ledger_audit`）へ引数そのままの行を差し込めます。

再現: 未ログインで「payouts を 9,999,999 円に更新した」という記録を作成できました。

金銭トラブルの立証や税務で使う記録なので、汚染されると価値が消えます。
無制限に積めるため保管費用にも影響します。

### 3. 根本原因と再発防止

**PostgreSQL は関数を作ると既定で PUBLIC に EXECUTE を与えます。**
`revoke all ... from public` を書かなかった関数はすべて未ログインに開きます。
テーブル権限とRLSは正しく張れていた（anon はどのテーブルにも `grant` が無い）のに、
SECURITY DEFINER 関数1本でそれが迂回されていました。

0065 で内部用の補助関数・トリガー関数・計算関数から PUBLIC を取り上げ、
未ログインに残すのは掲載一覧に必要な4本だけにしました。

| 未ログインに残した関数 | 理由 |
|---|---|
| `public_host_cards(int)` | 未ログインのトップに掲載一覧を出す（0052） |
| `host_ranking(text, int)` | ランキング（金額は含めない：弁護士Q11(d)） |
| `host_repeat_guests(uuid)` | リピーター人数。一覧にも出ている |
| `host_repeat_stats(uuid[])` | 同上を一括で |

`74_anon_surface.sql` が**この一覧を固定**します。関数を足して revoke を忘れると落ちます。

> ⚠️ このテストが落ちたとき、期待値の側を直す前に
> 「その関数を未ログインに見せてよいか」を必ず考えること。

### 4. CSP と HSTS が無かった（中）— `public/_headers` / `vercel.json` に追加

差し込まれたスクリプトを止める手立てがありませんでした。`script-src 'self'` で
インラインスクリプトを禁じ、通信先を Supabase とフォントに限定しています。

- `style-src` に `'unsafe-inline'` が必要です。このアプリは全画面を
  style属性（CSS-in-JS）で組んでいるので外せません
- `frame-ancestors 'none'` で埋め込みを禁止（`X-Frame-Options` の後継）
- HSTS に **preload は入れていません**。プリロードリストは事実上取り消せず、
  将来サブドメインでHTTPを使えなくなります
- ⚠️ **Stripe Elements を埋め込むなら `frame-src` の追加が必要**です。
  いまは `window.location.href` で決済ページへ遷移するので不要

実機のCSPで全画面を歩き、違反もJSエラーも0件、サービスワーカーの登録も成功、
Supabase とフォントへのリクエストが止められていないことを確認済みです。

### 5. `intent://` にクエリ文字列を混ぜていた（低）— `src/lib/install.ts`

アプリ内ブラウザ用の「Chromeで開く」リンクが
`intent://host + pathname + search#Intent;...` を組み立てていました。
`intent://` はフラグメント以降を起動アプリの指定として解釈するため、
URLに攻撃者の文字列が混じると別アプリを起動させられる余地が残ります
（`%23` が `#` として解釈されるかは Android の実装依存）。
開きたいのはトップページだけなので、ホスト名しか入れない形に直しました。

---

## 問題なかったもの（確認済み）

| 項目 | 結果 |
|---|---|
| RLS | public の全テーブルで有効。無効なものは0件 |
| anon のテーブル権限 | 1つも無い（すべてRPC経由） |
| `bookings` のRLS | 当事者のみ（`guest_id = auth.uid() or host_id = auth.uid()`） |
| `ledger_audit` | 運営（`admins`）だけが読める |
| `push_outbox` | ポリシーを1本も作っていない=誰も読めない |
| リポジトリ内の秘密 | 実値の秘密は無し。`.env.production` は anon キーのみ（JWTの `role` が `anon` であることを確認） |
| XSS | `dangerouslySetInnerHTML` / `innerHTML` / `eval` の使用は0件。`Markdown` は規約表示専用で、ユーザー入力を通さず、リンクも描画しない |
| Edge Function の認証 | Verify JWT を OFF にしている前提で、利用者向けの5本すべてが `getUser()` で自前検証。`stripe-webhook` は署名検証、`push-send` は共有秘密 |
| オープンリダイレクト | `window.location.href` への代入は Stripe の決済URL（自前のEdge Functionが返す値）のみ |
| VAPID秘密鍵 | リポジトリに無し。Supabase の Secrets のみ |

---

## 残っている宿題

### vite / esbuild の脆弱性（開発環境のみ）

```
esbuild <=0.24.2  moderate  GHSA-67mh-4wv8-2f99
vite    <=6.4.2   high      （上記のesbuildに依存）
```

**本番には影響しません。** どちらも**開発サーバー**の問題で（悪意あるサイトが
`npm run dev` のサーバーへリクエストを投げて応答を読める）、本番は Cloudflare が
静的ファイルを配信するだけで開発サーバーは動きません。

ただし**開発する人の手元では実在するリスク**です。`npm run dev` を動かしたまま
知らないサイトを開かないこと。

修正には **vite 5 → 8 のメジャー更新**が必要で、ビルド設定の破壊的変更を伴います。
セキュリティ修正のついでにやる規模ではないので、独立した作業として計画してください。

### Edge Function の `APP_URL`

CORSヘッダが `Deno.env.get('APP_URL') ?? '*'` になっています。未設定だと `*` に
落ちます。JWT は localStorage にあり別オリジンからは読めないため実害は小さいですが、
`APP_URL=https://pitafure.com` は設定してください
（Stripe本番化の手順（C-2）にも含まれています）。

### `.env.production` は Git に入る

意図的な運用（どこでビルドしても実データに繋がるように）ですが、
`.gitignore` の対象外なので、**将来ここに秘密を書くと即コミットされます。**
ファイル先頭の警告を消さないでください。

---

## 次に点検するとき

```bash
# 1. 未ログインから届く範囲が変わっていないか
psql ... -f supabase/tests/74_anon_surface.sql

# 2. 依存関係
npm audit

# 3. 未ログインに開いているSECURITY DEFINER関数を目で見る
psql ... -c "select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef
    and has_function_privilege('anon', p.oid, 'execute') order by 1;"

# 4. CSPを入れた状態で画面が壊れていないか（_headers を読ませて配信して確認する）
```

**新しいマイグレーションを書くときの決まり**: 関数を作ったら必ず
`revoke all on function ... from public;` を書き、必要な相手にだけ
`grant execute` する。これを忘れると未ログインに開きます。
