-- 本人確認の承認/却下RPCの修正
-- 問題: 0007の approve/reject 関数は、判定後に storage.objects から画像を
-- 直接 delete していた。SECURITY DEFINER関数の実行ロール(postgres)は
-- storage.objects への DELETE 権限を持たず、42501(insufficient_privilege)
-- → PostgRESTが 403 Forbidden を返し、承認そのものが失敗していた。
--
-- 修正方針:
--   1. RPCはDBの更新(identity_verifications / profile_trust_stats)のみ行う。
--   2. 画像の削除は、判定後にクライアント(管理者のブラウザ)から
--      Storage API 経由で行う。そのための「管理者は identity-documents を
--      削除できる」RLSポリシーを追加する。

-- ============================================================
-- 承認/却下関数を、画像削除なしのDB更新のみに置き換える
-- ============================================================
create or replace function public.approve_identity_verification(p_verification_id uuid, p_is_adult boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'verified', is_adult = p_is_adult, verified_at = now()
    where id = p_verification_id;

  update public.profile_trust_stats
    set is_verified = true, updated_at = now()
    where user_id = v_row.user_id;
end;
$$;

create or replace function public.reject_identity_verification(p_verification_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'rejected', rejected_reason = p_reason
    where id = p_verification_id;
end;
$$;

grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;

-- ============================================================
-- 管理者は identity-documents バケットの画像を削除できる
-- (判定後にクライアントから Storage API で削除するため)
-- ============================================================
create policy "identity_documents_delete_admin"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and exists (select 1 from public.admins where user_id = auth.uid())
  );
