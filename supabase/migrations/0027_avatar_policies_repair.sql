-- ============================================================
-- avatars バケットのポリシー修復(何度実行しても安全)
-- ------------------------------------------------------------
-- 症状: アイコン画像のアップロードで
--   new row violates row-level security policy
-- が出る = storage.objects への INSERT がRLSで弾かれている。
--
-- 原因として多いのは、0025 の create policy が
--   ・別の実行で同名ポリシーが既にあり "already exists" で全体が中断した
--   ・schema-all.sql をまとめて流して途中で失敗し、列だけ作られた
-- といった理由で「avatar_path 列はあるがポリシーが無い」状態になること。
-- アプリ自体は動くのでアップロード時にだけ表面化する。
--
-- そのため、ここではバケットとポリシーを drop → create で作り直す。
-- 既に正しく入っていても同じ結果になるので、安心して再実行できる。
-- ============================================================

-- ------------------------------------------------------------
-- バケット(無ければ作る / あれば制限値を今の仕様に揃える)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 3145728,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
-- ポリシー(本人フォルダ配下 {auth.uid()}/... のみ書き込み可)
-- ------------------------------------------------------------
drop policy if exists "avatars_insert_own" on storage.objects;
drop policy if exists "avatars_update_own" on storage.objects;
drop policy if exists "avatars_delete_own" on storage.objects;

create policy "avatars_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- upsert(上書き保存)では UPDATE も通る必要がある。
-- using だけだと更新後の行が検査されないため with check も明示する。
create policy "avatars_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 公開バケットなので表示(公開URL)にselectポリシーは不要。

-- ------------------------------------------------------------
-- 0025 が中断していた場合に備えて、列と関数も無ければ作る。
-- (既にあれば何もしない)
-- ------------------------------------------------------------
alter table public.profiles
  add column if not exists avatar_path text;

create or replace function public.set_avatar(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if split_part(p_path, '/', 1) <> v_uid::text then
    raise exception 'FORBIDDEN_PATH';
  end if;
  update public.profiles set avatar_path = p_path where id = v_uid;
end;
$$;

revoke all on function public.set_avatar(text) from public;
grant execute on function public.set_avatar(text) to authenticated;

create or replace function public.clear_avatar()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  update public.profiles set avatar_path = null where id = v_uid;
end;
$$;

revoke all on function public.clear_avatar() from public;
grant execute on function public.clear_avatar() to authenticated;
