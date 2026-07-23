-- ============================================================
-- 声の挨拶(ボイスプロフィール)。B方式=即公開+通報で削除。
-- ------------------------------------------------------------
-- プロフィールに15秒までの音声挨拶を録音・公開できる。
-- 事業判断(2026-07-23): 音声はテキストの自動みまもりが効かないため、
--   ・録音時に注意書き(外部連絡先・出会い目的・不適切表現は禁止)を表示
--   ・即時公開し、通報があれば管理者が削除(admin_clear_voice_greeting)
--   ・15秒上限で悪用余地を最小化
-- 承認制(A方式)はとらず、運用負荷の軽いB方式を採用。将来 文字起こしチェック等へ拡張可。
-- ============================================================

-- ------------------------------------------------------------
-- Storageバケット: voice-greetings(公開・2MBまで・音声のみ)
-- パスは {auth.uid()}/greeting.webm 形式。公開URLで再生する。
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'voice-greetings', 'voice-greetings', true, 2097152,
  array['audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/aac']
)
on conflict (id) do nothing;

create policy "voice_greetings_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'voice-greetings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "voice_greetings_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'voice-greetings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "voice_greetings_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'voice-greetings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 公開バケットなので再生(公開URL)にselectポリシーは不要。

-- ------------------------------------------------------------
-- profiles: 音声挨拶のパスと長さ
-- ------------------------------------------------------------
alter table public.profiles
  add column voice_path text,
  add column voice_seconds int check (voice_seconds is null or voice_seconds between 1 and 30);

comment on column public.profiles.voice_path is
  'voice-greetingsバケット内の音声挨拶のパス({uid}/greeting.webm)。公開URLで再生。';

-- ------------------------------------------------------------
-- set_voice_greeting: 本人の音声挨拶を設定(アップロード後に呼ぶ)
-- ------------------------------------------------------------
create function public.set_voice_greeting(p_path text, p_seconds int)
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
  if p_seconds is null or p_seconds < 1 or p_seconds > 15 then
    raise exception 'INVALID_DURATION';
  end if;
  -- パスは必ず本人フォルダ配下
  if split_part(p_path, '/', 1) <> v_uid::text then
    raise exception 'FORBIDDEN_PATH';
  end if;
  update public.profiles set voice_path = p_path, voice_seconds = p_seconds where id = v_uid;
end;
$$;

revoke all on function public.set_voice_greeting(text, int) from public;
grant execute on function public.set_voice_greeting(text, int) to authenticated;

-- ------------------------------------------------------------
-- clear_voice_greeting: 本人が自分の音声挨拶を削除
-- ------------------------------------------------------------
create function public.clear_voice_greeting()
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
  update public.profiles set voice_path = null, voice_seconds = null where id = v_uid;
end;
$$;

revoke all on function public.clear_voice_greeting() from public;
grant execute on function public.clear_voice_greeting() to authenticated;

-- ------------------------------------------------------------
-- admin_clear_voice_greeting: 管理者による削除(通報対応・B方式の要)
-- ------------------------------------------------------------
create function public.admin_clear_voice_greeting(p_user_id uuid)
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
  update public.profiles set voice_path = null, voice_seconds = null where id = p_user_id;
end;
$$;

revoke all on function public.admin_clear_voice_greeting(uuid) from public;
grant execute on function public.admin_clear_voice_greeting(uuid) to authenticated;
