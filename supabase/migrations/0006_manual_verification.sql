-- 本人確認の手動審査運用(初期フェーズ)
-- 方針: 「初期のみ運営(あなた)が目視で審査する」ため、eKYCベンダーとは
-- 異なり、審査担当が実際に画像を確認できる必要がある。そのため、
-- 0002_profiles.sql の設計方針(画像は照合後すぐ削除、結果のみ保持)を
-- 一部緩め、審査が完了するまでの間だけ Supabase Storage に画像を
-- 保持する。審査完了後は運営側で画像を削除する運用とする
-- (docs/manual-verification-review.md 参照)。

alter table public.identity_verifications
  add column document_path text,
  add column selfie_path text;

comment on column public.identity_verifications.document_path is
  '審査完了までの一時保存(Storage: identity-documents/{user_id}/...)。承認/却下後は運営が削除する。';
comment on column public.identity_verifications.selfie_path is
  '審査完了までの一時保存(Storage: identity-documents/{user_id}/...)。承認/却下後は運営が削除する。';

-- ============================================================
-- Storageバケット: identity-documents(非公開)
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('identity-documents', 'identity-documents', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- パスは必ず {auth.uid()}/ファイル名 の形式にし、本人のフォルダにのみ
-- 読み書きできるようにする。運営(Supabaseダッシュボード経由の審査)は
-- service_role相当のアクセスとしてRLSをバイパスするため、別途「審査者用」
-- ポリシーは不要。
create policy "identity_documents_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'identity-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "identity_documents_select_own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "identity_documents_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
