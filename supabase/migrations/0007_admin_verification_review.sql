-- 本人確認のアプリ内審査(管理画面)
-- 方針: 「初期のみ運営が見て審査する」を、Supabaseダッシュボードでの
-- 手動SQL操作(0006 / docs/manual-verification-review.md)から、
-- アプリ内の管理画面での承認/却下に置き換える。
--
-- 権限モデル: admins テーブルへの行の有無で管理者を判定する。
-- admins への書き込みポリシーはクライアントに一切与えない
-- (初回管理者の付与は、運営がSupabaseダッシュボードのSQL Editorで
-- 1回だけ手動で行う。docs/manual-verification-review.md 参照)。

-- ============================================================
-- admins: 管理者フラグ
-- ============================================================
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

-- 自分が管理者かどうかはUIの出し分けのため確認できてよい。
-- 他人の管理者権限の有無は見せない。
create policy "admins_select_self"
  on public.admins for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATE/DELETEポリシーは意図的に作らない。

-- ============================================================
-- identity_verifications / storage.objects: 管理者への閲覧権限追加
-- (既存の「本人のみ閲覧可」ポリシーに、管理者向けポリシーを追加する。
-- RLSの複数のpermissiveポリシーはOR結合されるため、一般ユーザーは
-- 従来どおり自分の行だけ、管理者は全件が見えるようになる)
-- ============================================================
create policy "identity_verifications_select_admin"
  on public.identity_verifications for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "identity_documents_select_admin"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and exists (select 1 from public.admins where user_id = auth.uid())
  );

-- ============================================================
-- approve_identity_verification / reject_identity_verification
-- 呼び出し元がadminsに登録されているかを関数内で検証するため、
-- authenticatedロールへ広くEXECUTEを許可してよい
-- (管理者以外が呼んでもNOT_ADMINで失敗するだけ)。
-- 判定後は画像を削除し、docs/legal/operations-legal-qa.md Q6の
-- 「審査完了後は速やかに削除」を自動化する。
-- ============================================================
create function public.approve_identity_verification(p_verification_id uuid, p_is_adult boolean default true)
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

  delete from storage.objects
    where bucket_id = 'identity-documents'
      and name in (v_row.document_path, v_row.selfie_path);
end;
$$;

revoke all on function public.approve_identity_verification(uuid, boolean) from public;
grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;

create function public.reject_identity_verification(p_verification_id uuid, p_reason text default null)
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

  delete from storage.objects
    where bucket_id = 'identity-documents'
      and name in (v_row.document_path, v_row.selfie_path);
end;
$$;

revoke all on function public.reject_identity_verification(uuid, text) from public;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;
