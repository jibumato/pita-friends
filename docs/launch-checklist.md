# 本番公開チェックリスト

上から順に進めれば公開できる構成にしてあります。コードは全機能実装済みなので、
残りは **(A)ホスティング → (B)Supabase本番設定 → (C)Stripe本番化 → (D)法務ゲート** の4つです。

> **残論点の全体像は [open-issues.md](open-issues.md) にまとめてあります。**
> 「いま何が全体を止めているか」「どれから着手すべきか」を知りたい場合は
> そちらを先に読んでください。本ファイルは各項目の手順書です。

> 凡例: ☐ 未着手 / 項目末尾の(必須)は公開のブロッカー、(推奨)は後追い可

---

## A. ホスティング(Cloudflare で稼働中)

> 当初はVercelを想定していましたが、**実際にはCloudflareで運用しています**
> (2026-07-26に実態へ合わせて更新)。`wrangler.jsonc` の `assets` 設定による
> 静的配信で、Workerスクリプトは使っていません。

1. ✅ Cloudflare へのデプロイ(`main` にマージすると反映される)
2. ✅ 環境変数 `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` の設定
   ※この2つは公開されても安全な値です(service_roleキーは**絶対に**入れない)
3. ✅ **独自ドメインの取得・接続**: `https://pitafure.com`(2026-07-26)
   - 特商法表記の販売URL・index.html の OGP も差し替え済み
4. ☐ **`www.pitafure.com` の扱いを決める**
   - 現在 `www` は名前解決しない。`www` 付きで来た利用者がエラーになる
   - Cloudflare で `www` の CNAME を追加し、リダイレクトルールで
     apex(`pitafure.com`)へ 301 させるのが一般的
5. ☐ スマホ実機で「ホーム画面に追加」(PWA)が動くか確認

## B. Supabase 本番設定

1. ◑ **マイグレーション適用**: 0001〜0036は適用済み(2026-07-26)。
   **以下2つが未適用**。Supabase SQL Editorで番号順に実行してください
   (手順: `docs/apply-migrations.md`)
   - `0037_ranking_avatar.sql` … ランキングにプロフィール写真が出ない不具合の修正
     (`host_ranking()`がavatar_pathを返すよう変更)
   - `0038_host_trial_discount.sql` … ホストが設定する初回お試し割引
     (`create_booking`/`extend_booking`を差し替える。**適用するまで
     ホスト設定の割引率は保存できず、予約も割引されない**)
   - `0039_extension_full_price.sql` … 初回お試し割引を「最初に予約した分」
     だけに限定し、延長分は通常価格にする(`extend_booking`を差し替え)
2. ☐ **メール確認を再有効化**: Authentication → Providers → Email →
   「Confirm email」を**ON**に戻す(テスト用にOFFにしていた場合)
3. ✅ **リダイレクトURLの登録**(2026-07-26): Authentication → URL Configuration
   - Site URL: `https://pitafure.com` / Redirect URLs: `https://pitafure.com/**`
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
   supabase secrets set APP_URL=https://pitafure.com
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

1. ◑ ドラフト4点の `【　】` を埋める(すべて `docs/legal/`):
   - **技術・方針で確定できる項目は記入済み**(動作環境・保持年数3年・変更周知2週間・賠償上限・管轄=所在地基準・販売数量など)
   - 事業形態は**個人事業主で確定**(2026-07-23)。事業者名＝本名
   - **残るのは実情報が必要な項目のみ** → `docs/legal/RELEASE-fill-in.md` の記入ガイド参照
     (氏名 / 専用問い合わせメール / 独自ドメインの販売URL / 所在地・電話〔弁護士確認まで保留〕 / 制定日〔施行日〕)
   - **個人の自宅住所を出したくない場合**はバーチャルオフィス等の可否を弁護士に確認(住所・電話は保留中)
2. ◑ **弁護士レビューを依頼**:
   - 構造面(Q1〜Q11・収納代行整理/コイン有効期限/ギフトの適法性など)は
     `docs/legal/lawyer-review-package.md` を渡して**回答済み**(`lawyer-review-answers-2026-07-21.md`)。
     指摘事項はすべて規約・実装に反映済み
   - **残り: ドラフト4点そのものの文言査読(前回ご指定のQ9)を未依頼** →
     `docs/legal/lawyer-review-round2-request.md` を渡す(Q12〜Q23のQ&A形式・そのまま貼り付け可)
   - 送付前の事前検討と、そこで判明した**実装の要修正点**は
     `docs/legal/lawyer-review-answers-round2-draft.md` に記録済み
     (⚠️ 返金コインの有効期限が当初発行日から通算6か月を超えうる件。Q18の回答待ち)
3. ☐ 弁護士レビューまでの暫定運用(コードは対応済み・運用で担保):
   - コイン販売は開始してよいか自体も確認事項に含める
   - **換金(ホストへの振込)は弁護士OKまで実行しない**
     (申請は溜まるが、振込実行(②総合振込)を行わなければ資金移動は発生しない)
4. ✅ **コインの有効期限は「取得日から6か月未満」に決定・実装済み**(弁護士回答Q7 → 案A):
   前払式支払手段の**適用除外**(表示・届出・供託が不要)を狙う設計。ロット単位の
   失効を `0018_coin_expiry.sql` で実装済み。最終文言のみ弁護士Q10で確定する。
   **注意: 有効期限を延長するキャンペーンは適用除外が外れるため行わない**
5. ☐ (適用除外が認められなかった場合のみ)前払式支払手段の残高監視: 基準日(3/31・9/30)の
   未使用残高が**1,000万円超**なら財務局へ届出+1/2供託(`coin-economy-legal-review.md` §4.1)
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
