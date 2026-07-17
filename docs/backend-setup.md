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

## まだ設計・実装していないもの

- 実際の認証UI（サインアップ/ログイン画面）— `src/lib/auth.ts` にAPIは用意済みだが、画面への結線は未着手
- `promises` のライフサイクル遷移（`joined` / `completed` への移行、フレンドコード開示のタイミング）— 現状は `scheduled` で作られるのみ
- リアルタイムチャット（トークルーム）— Supabase Realtimeの利用を想定しているが未実装
- 決済代行事業者との連携（`purchase_coins` を呼ぶWebhook/Edge Function）
- 本人確認（eKYC）ベンダーとの連携（`identity_verifications` の `status` を確定させる処理）
- 運営の審査オペレーション画面（`resolve_report` を呼ぶ管理画面）

これらはこのドキュメントとROADMAPのPhase 3〜5に追って反映していきます。
