# 本番公開チェックリスト

上から順に進めれば公開できる構成にしてあります。コードは全機能実装済みなので、
残りは **(A)ホスティング → (B)Supabase本番設定 → (C)Stripe本番化 → (D)法務ゲート** の4つです。

> 凡例: ☐ 未着手 / 項目末尾の(必須)は公開のブロッカー、(推奨)は後追い可

---

## A. ホスティング(Vercel推奨・無料枠で可)

1. ☐ [vercel.com](https://vercel.com) にGitHubでサインアップ
2. ☐ 「Add New → Project」で `jibumato/pita-friends` をインポート
   - Framework: **Vite**(自動検出)。Build Command `npm run build` / Output `dist` のままでOK
3. ☐ Environment Variables に以下を設定(必須):
   ```
   VITE_SUPABASE_URL      = https://<プロジェクトRef>.supabase.co
   VITE_SUPABASE_ANON_KEY = <anonキー>
   ```
   ※この2つは公開されても安全な値です(service_roleキーは**絶対に**入れない)
4. ☐ Deploy → `https://<プロジェクト名>.vercel.app` で表示確認
5. ☐ (推奨)独自ドメインを購入し、Vercelの Domains で接続(例: pitafure.jp)
   - ドメインは特商法表記・規約の「販売URL」にも記載するので早めに確定
6. ☐ スマホ実機で「ホーム画面に追加」(PWA)が動くか確認

## B. Supabase 本番設定

1. ☐ **マイグレーション全適用**: SQL Editorで `supabase/schema-all.sql`(0001〜0015)
   を未適用分まで実行(手順: `docs/apply-migrations.md`)
2. ☐ **メール確認を再有効化**: Authentication → Providers → Email →
   「Confirm email」を**ON**に戻す(テスト用にOFFにしていた場合)
3. ☐ **リダイレクトURLの登録**: Authentication → URL Configuration →
   Site URL と Redirect URLs に本番ドメインを追加
4. ☐ **pg_cron の確認**: Database → Extensions で `pg_cron` が有効か確認
   (プレイ完了の72時間自動確定に使用。0015参照)
5. ☐ (推奨)Database → Backups でバックアップ設定を確認(Pro планなら日次)
6. ☐ (推奨)本人確認画像バケットのストレージポリシーを再確認
   (`docs/manual-verification-review.md`)

## C. Stripe 本番化(コイン購入)

1. ☐ Stripeの**本番利用申請**を完了(事業内容・銀行口座の登録)
   - 事業内容は「ゲーム仲間マッチングサービス内で使うポイントの販売」等、
     **非出会い系であることが伝わる説明**にする(審査対策。規約・特商法表記のURLを添える)
2. ☐ 本番APIキーで Secrets を更新:
   ```bash
   supabase secrets set STRIPE_SECRET_KEY=sk_live_xxx
   supabase secrets set APP_URL=https://<本番ドメイン>
   ```
3. ☐ 本番用Webhookエンドポイントを追加(`checkout.session.completed`)し、
   `STRIPE_WEBHOOK_SECRET=whsec_xxx`(本番用)を設定
4. ☐ Edge Functionを再デプロイ:
   ```bash
   supabase functions deploy create-checkout-session
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
5. ☐ 本番カードで少額(¥300)の実購入テスト → コイン付与を確認 → 必要なら返金

## D. 法務ゲート(公開前に必須)

1. ☐ ドラフト4点の `【　】` を埋める(すべて `docs/legal/`):
   - 利用規約 / プライバシーポリシー / 特商法表記 / 資金決済法表示
   - 埋める項目: 事業者名(個人なら本名)・住所・連絡先・管轄裁判所・制定日
   - **個人の自宅住所を出したくない場合**はバーチャルオフィス等の可否を弁護士に確認
2. ☐ **弁護士レビューを依頼**: `docs/legal/lawyer-review-package.md` を渡す
   (論点・質問リスト・資金フロー図をまとめてあります)
3. ☐ 弁護士レビューまでの暫定運用(コードは対応済み・運用で担保):
   - コイン販売は開始してよいか自体も確認事項に含める
   - **換金(ホストへの振込)は弁護士OKまで実行しない**
     (申請は溜まるが、振込実行(②総合振込)を行わなければ資金移動は発生しない)
4. ☐ **コインの有効期限の設計を確定**(弁護士回答Q7・最重要):
   「発行日から6か月未満」にすれば前払式支払手段の**適用除外**(表示・届出・供託がすべて
   不要)になりうる。案A(適用除外)/案B(180日・通常の自家型)のどちらを取るか、
   次回の弁護士相談で推奨を確認して規約第7条5項を確定する
5. ☐ (案Bの場合のみ)前払式支払手段の残高監視: 基準日(3/31・9/30)の未使用残高が
   **1,000万円超**なら財務局へ届出+1/2供託(`coin-economy-legal-review.md` §4.1)
6. ☐ **分別管理用の専用口座を開設**(弁護士回答Q2(c)・強い推奨):
   コイン購入代金と報酬振込の原資を事業資金と分けて管理
7. ☐ **税理士に確認**(弁護士回答Q5): ホスト報酬の支払調書・プラットフォーム
   情報報告制度の動向・インボイス制度上の取扱い
8. ☐ 運用上の約束事(弁護士回答Q6・出会い系非該当の実態を保つ):
   検索・レコメンドで異性を優先表示しない / プロフィールの性的アピールは削除運用 /
   通報対応ログを保存 / **オフライン会場提供への事業拡大はしない**(風営法リスクが一変)

## E. 公開後の運用ルーティン

| 頻度 | 作業 | 手順書 |
|---|---|---|
| 随時 | 本人確認の審査(承認/却下) | `docs/manual-verification-review.md` |
| 随時 | 通報の審査・対応 | `docs/trust-safety-spec.md` |
| 月次 | 換金の締め→総合振込→消し込み | `docs/payouts-bank-operations.md` |
| 月次 | Stripe入金と`coin_purchases`の突合 | — |
| 半期 | 前払式残高の確認(3/31・9/30基準日) | `coin-economy-legal-review.md` §4.1 |

## 公開判定(最終確認)

- ☐ A〜Dのすべての(必須)が完了している
- ☐ 実機で: 新規登録→本人確認→コイン購入→予約→トーク→完了→レビューが一周する
- ☐ 規約・プライバシー・特商法・資金決済法表示がアプリ内から開ける(設定画面)
- ☐ 換金は弁護士OKが出るまで「振込実行しない」運用を関係者が理解している
