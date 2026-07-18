# 本人確認の手動審査手順（初期フェーズ）

**方針**: 本人確認（eKYC）はベンダー未選定のため、**初期のみ運営（あなた）が目視で審査**する運用とします。ユーザーが提出した書類・顔写真は、Supabaseダッシュボードから直接確認し、SQLで承認/却下を記録します。

対象コード: `src/screens/Verify.tsx`（提出画面）、`src/lib/queries.ts` の `submitIdentityVerification`（Storage/DB書き込み）、`supabase/migrations/0006_manual_verification.sql`（スキーマ・Storage設定）。

---

## 1. 提出物を確認する

Supabaseダッシュボードにログインし、以下を確認します。

### 1-1. 審査待ち一覧
`Table Editor` → `identity_verifications` テーブル → `status = pending` でフィルタ。各行に `user_id` と `created_at` があります。

### 1-2. 画像を見る
`Storage` → `identity-documents` バケット → `{user_id}` フォルダを開くと、`document-*.jpg`（書類）と `selfie-*.jpg`（顔写真）があります。ファイル名は該当行の `document_path` / `selfie_path` 列と一致します。

**確認すること**:
- 書類の顔写真と、別途提出された顔写真が同一人物か
- 書類に記載の生年月日から **18歳以上**か（`is_adult` 列に反映する）
- 書類が偽造・改変されていないか（明らかな不審点がないか）

---

## 2. 承認する

`SQL Editor` で、対象の `user_id` を差し替えて実行してください（`<USER_ID>` を実際のUUIDに置換）。

```sql
-- 1. 審査結果を記録
update identity_verifications
set status = 'verified', is_adult = true, verified_at = now()
where user_id = '<USER_ID>' and status = 'pending';

-- 2. アプリ全体で参照される「確認済み」フラグを立てる
update profile_trust_stats
set is_verified = true, updated_at = now()
where user_id = '<USER_ID>';
```

これで、当該ユーザーはアプリ内で「✓ 本人確認済み」バッジが表示され、ホストとして掲載できるようになります（`host_settings.is_host` を `true` にする更新が、本人確認済みでないと拒否される仕組みになっています）。

---

## 3. 却下する

```sql
update identity_verifications
set status = 'rejected', rejected_reason = '<却下理由(任意、例: 書類が不鮮明)>'
where user_id = '<USER_ID>' and status = 'pending';
```

ユーザー側の画面には「前回の申請は承認されませんでした。書類・写真を選び直して再提出してください」と表示され、再提出できます。

---

## 4. 画像を削除する（審査後は必ず実施）

判断が済んだら、Storageから画像を削除してください。`Storage` → `identity-documents` → 該当 `{user_id}` フォルダ内のファイルを選択して削除、または以下のSQLで一括削除できます。

```sql
delete from storage.objects
where bucket_id = 'identity-documents'
  and (storage.foldername(name))[1] = '<USER_ID>';
```

**画像を長期保持しないこと**は法務レビュー（`docs/legal/operations-legal-qa.md` Q6）の前提です。手動審査フェーズでは審査完了まで一時的に画像を保持しますが、**判断後は速やかに削除**してください。目安として、週次でまとめて「verified/rejectedになって数日経過した行」の画像を削除する運用でも構いません。

---

## 5. 今後の見直しポイント

- 審査件数が増えてきたら、簡易な管理画面（審査待ち一覧の一覧表示＋承認/却下ボタン）を検討する
- 実際にeKYCベンダーを導入する場合、`identity_verifications.provider` / `provider_reference` 列（ベンダーの参照ID用に用意済み）を使い、`document_path` / `selfie_path` への画像保存自体を廃止できる（ベンダーが判定するため、当社が画像を持つ必要がなくなる）
- 却下時にユーザーへ理由を伝える通知の仕組みは未実装（現状はアプリ再訪問時に画面上で表示されるのみ）

---

*本資料は初期フェーズの運用手順であり、審査件数の増加やeKYCベンダー導入時に見直す前提です。*
