-- ============================================================
-- プロフィールのアイコン画像(アバター)。ボイス挨拶(0024)と同じB方式。
-- ------------------------------------------------------------
-- 頭文字＋カラーの既定アバターに加え、任意で画像をアップロードできる。
-- 画像はテキストの自動みまもりが効かないため、
--   ・アップロード時に注意書き(他人の写真・不適切画像の禁止)を表示
--   ・即時公開し、通報があれば管理者が削除(admin_clear_avatar)
-- とするB方式。avatar_path が null のときは従来の頭文字＋カラーで表示する。
-- ============================================================

-- ------------------------------------------------------------
-- Storageバケット: avatars(公開・3MBまで・画像のみ)
-- パスは {auth.uid()}/avatar.webp 形式。公開URLで表示する。
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 3145728,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

create policy "avatars_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_update_own"
  on storage.objects for update
  to authenticated
  using (
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
-- profiles: アイコン画像のパス(null=頭文字＋カラーの既定アバター)
-- ------------------------------------------------------------
alter table public.profiles
  add column avatar_path text;

comment on column public.profiles.avatar_path is
  'avatarsバケット内のアイコン画像のパス({uid}/avatar.webp)。null なら頭文字＋カラーの既定アバター。';

-- ------------------------------------------------------------
-- set_avatar: 本人のアイコン画像を設定(アップロード後に呼ぶ)
-- ------------------------------------------------------------
create function public.set_avatar(p_path text)
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
  -- パスは必ず本人フォルダ配下
  if split_part(p_path, '/', 1) <> v_uid::text then
    raise exception 'FORBIDDEN_PATH';
  end if;
  update public.profiles set avatar_path = p_path where id = v_uid;
end;
$$;

revoke all on function public.set_avatar(text) from public;
grant execute on function public.set_avatar(text) to authenticated;

-- ------------------------------------------------------------
-- clear_avatar: 本人が自分のアイコン画像を削除(既定アバターに戻す)
-- ------------------------------------------------------------
create function public.clear_avatar()
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

-- ------------------------------------------------------------
-- admin_clear_avatar: 管理者による削除(通報対応・B方式の要)
-- ------------------------------------------------------------
create function public.admin_clear_avatar(p_user_id uuid)
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
  if not exists (select 1 from public.admins where user_id = v_uid) then
    raise exception 'FORBIDDEN';
  end if;
  update public.profiles set avatar_path = null where id = p_user_id;
end;
$$;

revoke all on function public.admin_clear_avatar(uuid) from public;
grant execute on function public.admin_clear_avatar(uuid) to authenticated;
