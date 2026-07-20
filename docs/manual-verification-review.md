# 本人確認の審査手順（初期フェーズ）

**方針**: 本人確認（eKYC）はベンダー未選定のため、**初期のみ運営（あなた）が目視で審査**する運用とします。ユーザーが提出した書類・顔写真は、アプリ内の管理画面から確認し、その場で承認/却下できます。承認・却下すると画像は自動で削除されます。

対象コード:
- `src/screens/Verify.tsx` — ユーザーの提出画面
- `src/screens/AdminVerifications.tsx` — 運営の審査画面
- `src/lib/queries.ts` の `submitIdentityVerification` / `checkIsAdmin` / `fetchPendingVerifications` / `approveVerification` / `rejectVerification`
- `supabase/migrations/0006_manual_verification.sql`（スキーマ・Storage設定）
- `supabase/migrations/0007_admin_verification_review.sql`（管理者権限・承認/却下RPC）

---

## 0. 最初の1回だけ: 自分を管理者に登録する

管理画面へのアクセス権は `admins` テーブルの有無で判定します。**このテーブルへの書き込みはアプリからはできません**（誰でも自分を管理者にできてしまうと意味がないため、意図的にクライアントからの書き込みポリシーを作っていません）。最初の管理者登録だけは、Supabaseダッシュボードの `SQL Editor` で手動で行ってください。

```sql
insert into public.admins (user_id)
select id from auth.users where email = '<あなたのログインメールアドレス>';
```

これで、そのアカウントでログインすると、**設定画面の一番下に「管理者メニュー」が表示**され、「本人確認の審査」から審査画面に入れます。

以降、他の運営メンバーを追加したい場合も、同じSQLをメールアドレスを変えて実行してください。

---

## 1. 審査する（アプリ内）

1. 管理者アカウントでログイン → 設定 → 「本人確認の審査」
2. 審査待ちの申請が、提出が古い順に一覧表示されます
3. 各申請カードに「本人確認書類」「顔写真」の画像が表示されます（タップで拡大表示）
4. 確認すること:
   - 書類の顔写真と、別途提出された顔写真が同一人物か
   - 書類に記載の生年月日から **18歳以上**か
   - 書類が偽造・改変されていないか（明らかな不審点がないか）
5. 18歳以上であることを確認したら、チェックボックスにチェックを入れて「✓ 承認する」をタップ
6. 承認しない場合は「却下」をタップし、却下理由（運営メモ、ユーザーには表示されません）を入力

承認すると、当該ユーザーは即座にアプリ内で「✓ 本人確認済み」バッジが表示され、ホストとして掲載できるようになります（`host_settings.is_host` を `true` にする更新は、本人確認済みでないと拒否される仕組みになっています）。却下すると、ユーザー側の画面に「前回の申請は承認されませんでした。書類・写真を選び直して再提出してください」と表示され、再提出できます。

**承認・却下のどちらでも、判断と同時に画像はサーバー側で自動的に削除されます。**（`approve_identity_verification` / `reject_identity_verification` 関数内で自動実行、手動でのStorage削除は不要）

---

## 2. アプリを使わず直接SQLで操作したい場合（参考・緊急時用）

管理画面が使えない場合の代替手段です。`<VERIFICATION_ID>` は `identity_verifications.id`、`<USER_ID>` は対象ユーザーのUUID。

```sql
-- 承認
select public.approve_identity_verification('<VERIFICATION_ID>'::uuid, true);

-- 却下
select public.reject_identity_verification('<VERIFICATION_ID>'::uuid, '却下理由');
```

これらの関数は管理画面と同じRPCなので、画像の自動削除も同様に行われます。管理者権限（`admins`テーブルに登録済み）のアカウントでSQL Editorから実行する場合、`auth.uid()`はSQL Editorの実行コンテキストでは通常nullになるため、**この方法は使えません**（`NOT_ADMIN`エラーになります）。真にSQLで直接操作したい場合は、0006の手順にあった通り `identity_verifications` / `profile_trust_stats` を直接UPDATEしてください。

---

## 3. 今後の見直しポイント

- 実際にeKYCベンダーを導入する場合、`identity_verifications.provider` / `provider_reference` 列（ベンダーの参照ID用に用意済み）を使い、`document_path` / `selfie_path` への画像保存自体を廃止できる（ベンダーが判定するため、当社が画像を持つ必要がなくなる）
- 却下時にユーザーへ理由を伝える通知の仕組みは未実装（現状はアプリ再訪問時に画面上で表示されるのみ）
- 審査担当が増える場合、`admins` テーブルに行を追加するだけで対応可能（上記0番の手順と同じ）

---

*本資料は初期フェーズの運用手順であり、審査件数の増加やeKYCベンダー導入時に見直す前提です。*
