# バックエンドのセットアップ（Supabase）

このリポジトリはPhase 1〜2の間、バックエンドなしで全画面をモックデータ駆動で操作できるプロトタイプとして作られてきました（README参照）。Phase 3から、[Supabase](https://supabase.com/)（PostgreSQL + 認証 + リアルタイム + ストレージ）をバックエンドとして接続します。

**環境変数を設定しない限り、アプリは今までどおりモックデータのデモモードで動作します。** バックエンドを試したい場合のみ、以下の手順で接続してください。

---

## 1. Supabaseプロジェクトを作成する

1. [supabase.com](https://supabase.com/) でアカウントを作成し、新規プロジェクトを作成
2. プロジェクトの `Settings > API` から以下をコントロールしまう:
   - `Project URL`
   - `anon public` キー

## 2. マイグレーションを適用する

`supabase/migrations/` に、テーブル・RLS（行レベルセキュリティ）ポリシー・関数を定義したSQLファイルが番号順に置かれています。Supabase CLIを使うのが最も簡単です。

```bash
npm install -g supabase
supabase login
supabase link --project-ref <あなたのプロジェクトref>
supabase db push
```

`supabase db push` は `supabase/migrations/` 内のSQLファイルを**ファイル名の昇順**で実行します。番号を変更・挿入する場合は、既存ファイルより後ろの番号にしてください（依存関係が壊れます）。

CLIを使わない場合は、Supabaseダッシュボードの `SQL Editor` に各ファイルの中身を**番号順にそのまま貼り付けて実行**しても同じ結果になります。

## 3. 環境変数を設定する

```bash
cp .env.example .env.local
```

`.env.local` に、手順1で控えた値を設定:

```
VITE_SUPABASE_URL=https://xxxxxxxx.supabase.co
VITE_SUPABASE_ANON_KEY=eyJxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

`.env.local` は `.gitignore` 対象なのでコミットされません。

## 4. 開発サーバーを再起動

```bash
npm run dev
```

コンソールに`[pita-friends] ... デモモードで起動します`のメッセージが**出なければ**、Supabaseへの接続設定が読み込まれています。

---

## スキーマの設計方針

`supabase/migrations/` の各ファイルとその範囲:

| ファイル | 内容 |
|---|---|
| `0001_extensions.sql` | 拡張機能・共通トリガー関数 |
| `0002_profiles.sql` | プロフィール・信頼スタッツ・安心設定・本人確認 |
| `0003_coins_and_hosting.sql` | コインウォレット・ホスト設定・予約(コイン消費) |
| `0004_matching.sql` | 誘う・受け取った誘い・約束 |
| `0005_trust_safety.sql` | ブロック・レビュー・通報・マナースコア再計算 |

**重要な設計上の判断**:

- **お金が絡む値（コイン残高・マナースコア）はクライアントから直接書き込めません。** `coin_wallets.balance` や `profile_trust_stats.manner_score` にはUPDATEポリシーを意図的に作らず、`create_booking` / `cancel_booking` / `recompute_manner_score` などの `SECURITY DEFINER` 関数からのみ変更できるようにしています。ユーザーが自分のスコアや残高を勝手に書き換えられる抜け道を防ぐためです。
- **`purchase_coins` と `resolve_report` は `authenticated` ロールに実行権限を与えていません。** 前者は実際の決済確認（決済代行事業者は未選定、[`coin-economy-legal-review.md`](legal/coin-economy-legal-review.md) §2.1）が前提のため、後者は運営の審査オペレーション（[`operations-legal-qa.md`](legal/operations-legal-qa.md) Q2/Q3）のため、どちらも信頼できるサーバー環境（決済Webhook・管理画面などが `service_role` キーで実行）からのみ呼び出す想定です。
- **安心設定（`safety_prefs.contact_scope`）は誘いの送信自体をDBレベルでブロックします。** `invites` テーブルのINSERTポリシーが、受信者の `contact_scope`（本人確認済みのみ／同性のみ／全員）を満たさない誘いをそもそも作成させません。女性ファースト安全設計の中核コントロールをアプリ層任せにせず、データベース層で強制しています。
- **本人確認書類の画像は保存しません。** `identity_verifications` テーブルは結果（`is_adult`・ベンダー参照ID）のみを保持します（[`operations-legal-qa.md`](legal/operations-legal-qa.md) Q6）。

## 認証UIについて

`signUp` / `signIn` 画面（`src/screens/SignUp.tsx` / `SignIn.tsx`）を追加し、ウェルカム画面（`PRESS START` / `ログイン`）から実際にSupabase Authへ接続できます。バックエンド未接続時は、これらの画面を経由せず従来のデモ動線（PRESS START→安心設定、ログイン→ホーム）のままです。

- サインアップ時、Supabaseプロジェクトで「メール確認」が有効な場合は確認メールの送信案内を表示し、確認後に改めてログインする流れになります
- アプリ起動時に既存セッションがあれば自動的にホーム画面へ遷移します（`getSession()`）
- 設定画面の「アカウント」セクションに「ログアウト」を追加（バックエンド接続時のみ表示）

## 実データ配線について

サインイン/サインアップ成功時、およびアプリ起動時に既存セッションが見つかった場合、`src/lib/queries.ts` の `fetchAccountBundle()` でプロフィール・安心設定・ホスト設定・コイン残高・信頼スタッツをまとめて取得し、ローカル状態を上書きします（`App.tsx` の `hydrateAccount()`）。

- ニックネーム・性別（`Setup.tsx`）、安心設定（`SafetyPreferences.tsx`）、ホスト設定（`HostSettingsScreen.tsx`）の変更は、楽観的にローカル状態を更新したうえでSupabaseへ書き込みます。書き込みに失敗した場合はローカル状態を元に戻します（`console.warn` でログ出力。ユーザー向けのエラー表示は現状ホスト設定の「本人確認が必要」ケースのみ実装）
- **コインの購入はできません。** `purchase_coins` 関数はクライアント(`authenticated`ロール)に実行権限を与えていないため（決済確認前提の設計）、バックエンド接続時はウォレット画面で「決済連携は準備中です」と表示し、購入ボタンを無効化します
- **ホストとして掲載するには本人確認が必要です。** `check_host_requires_verification` トリガーにより、`profile_trust_stats.is_verified = true` でないと `is_host = true` への更新が拒否されます。本人確認は下記のとおり運営の手動審査で完了させられます
- **さがす画面・予約は実データに接続済みです。** `fetchDiscoverableHosts()` が `host_settings`（`is_host=true`）＋`profiles`＋`profile_trust_stats` を取得して一覧表示し、予約確定は `create_booking` RPCを呼びます（コイン消費・残高チェックはサーバー側でアトミックに実行）。本人確認が完了したホストがいなければ一覧は空になります。埋め込みリレーション（`select`内のネスト構文）は手書きDatabase型が`Relationships`メタデータを持たないため使わず、3テーブルを個別に取得してJS側で結合しています
- **本人確認は運営の手動審査です（初期フェーズ）、審査はアプリ内の管理画面から行えます。** `Verify.tsx` で書類・顔写真を撮影/選択すると、非公開のSupabase Storageバケット `identity-documents`（本人のみ読み書き可）にアップロードし、`identity_verifications` に審査待ち行を作成します。`admins` テーブルに登録された運営アカウントには設定画面に「管理者メニュー」が表示され、`AdminVerifications.tsx` から画像を見て承認/却下できます（判断と同時に画像は自動削除）。**初回の管理者登録だけはSupabaseダッシュボードでの手動SQLが必要**です。手順は [`docs/manual-verification-review.md`](manual-verification-review.md) を参照してください

## まだ設計・実装していないもの

- **相性スコア算出ロジック** — マッチングエンジンが未設計のため、さがす画面の実データ表示では相性%の代わりにマナースコアを表示している
- **よく遊ぶゲーム・プレイスタイル**（`profiles.favorite_games` / `play_style`）の実データ配線 — セッション内の「今回選択中のゲーム」(`state.game`)とは別概念のため、今回は意図的に見送り
- `promises` のライフサイクル遷移（`joined` / `completed` への移行、フレンドコード開示のタイミング）— 現状は `scheduled` で作られるのみ
- リアルタイムチャット（トークルーム）— Supabase Realtimeの利用を想定しているが未実装
- 決済代行事業者との連携（`purchase_coins` を呼ぶWebhook/Edge Function）
- eKYCベンダーとの連携（審査件数が増えた場合の、手動審査からの移行先）
- 通報の運営審査オペレーション画面（`resolve_report` を呼ぶ管理画面。本人確認の審査画面とは別。現状はQ&A文書のSQL運用で当面代替）

これらはこのドキュメントとROADMAPのPhase 3〜5に追って反映していきます。

## 既知の落とし穴: `npm run lint` の型チェックが機能していなかった問題

このプロジェクトのルート `tsconfig.json` はプロジェクト参照のみ（`"files": []`）で、`tsc --noEmit` を素朴に実行しても実質何もチェックされません。`package.json` の `lint` スクリプトを `tsc -b` に修正済みです。あわせて、`src/lib/database.types.ts` が `@supabase/supabase-js`（postgrest-js）の要求する `Relationships` / `Views` フィールドを持っていなかったため、`SupabaseClient<Database>` のジェネリクス解決が `never` に崩れ、`.select()` / `.update()` の戻り値の型チェックが素通りしてしまう不具合があり、これも修正済みです。型定義を手動更新する際は、この2点に注意してください。
