-- ============================================================
-- 通知: 誘い受信/承認・新着メッセージ・本人確認結果・募集参加を
-- 実際にDBへ記録し、通知画面で表示できるようにする。
-- ============================================================

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  type text not null check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined'
  )),
  title text not null,
  body text not null default '',
  related_id uuid,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.notifications enable row level security;

create policy "notifications_select_own"
  on public.notifications for select
  to authenticated
  using (user_id = auth.uid());

create policy "notifications_update_own"
  on public.notifications for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- INSERTポリシーは意図的に作らない(下記のSECURITY DEFINERトリガー/関数経由のみ)。

create index notifications_user_created_idx on public.notifications (user_id, created_at desc);

alter publication supabase_realtime add table public.notifications;

-- ------------------------------------------------------------
-- 誘いを受け取った時に通知する
-- ------------------------------------------------------------
create function public.notify_invite_received()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  select nickname into v_name from public.profiles where id = new.from_user;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    new.to_user,
    'invite_received',
    coalesce(nullif(v_name, ''), '誰か') || 'さんから誘いが届きました',
    new.game || ' · ' || new.when_text,
    new.id
  );
  return new;
end;
$$;

create trigger invites_notify_received
  after insert on public.invites
  for each row execute function public.notify_invite_received();

-- ------------------------------------------------------------
-- 誘いが承認された時に、送った側へ通知する
-- ------------------------------------------------------------
create function public.notify_invite_approved()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if new.status = 'approved' and old.status <> 'approved' then
    select nickname into v_name from public.profiles where id = new.to_user;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      new.from_user,
      'invite_approved',
      coalesce(nullif(v_name, ''), '相手') || 'さんが誘いを承認しました',
      new.game || ' · ' || new.when_text,
      new.id
    );
  end if;
  return new;
end;
$$;

create trigger invites_notify_approved
  after update on public.invites
  for each row execute function public.notify_invite_approved();

-- ------------------------------------------------------------
-- 新着メッセージをトーク相手に通知する
-- ------------------------------------------------------------
create function public.notify_message_received()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promise public.promises;
  v_recipient uuid;
  v_name text;
begin
  select * into v_promise from public.promises where id = new.promise_id;
  v_recipient := case when v_promise.user_a = new.sender_id then v_promise.user_b else v_promise.user_a end;
  select nickname into v_name from public.profiles where id = new.sender_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_recipient,
    'message_received',
    coalesce(nullif(v_name, ''), '相手') || 'さんからメッセージ',
    left(new.body, 60),
    new.promise_id
  );
  return new;
end;
$$;

create trigger messages_notify_received
  after insert on public.messages
  for each row execute function public.notify_message_received();

-- ------------------------------------------------------------
-- 募集への参加を、募集の作成者に通知する
-- ------------------------------------------------------------
create function public.notify_board_joined()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post public.board_posts;
  v_name text;
begin
  select * into v_post from public.board_posts where id = new.post_id;
  select nickname into v_name from public.profiles where id = new.user_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_joined',
    coalesce(nullif(v_name, ''), '誰か') || 'さんが募集に参加しました',
    v_post.game || ' · ' || v_post.when_text,
    new.post_id
  );
  return new;
end;
$$;

create trigger board_participants_notify_joined
  after insert on public.board_participants
  for each row execute function public.notify_board_joined();

-- ------------------------------------------------------------
-- 本人確認の承認/却下でも通知する(0008の関数にnotifications挿入を追加)。
-- それ以外のロジックは0008から変更しない。
-- ------------------------------------------------------------
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

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_row.user_id, 'verification_approved', '本人確認が完了しました', 'プロフィールに確認済みバッジが表示されます', p_verification_id);
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

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_row.user_id, 'verification_rejected', '本人確認が承認されませんでした', '書類・写真を選び直して再提出してください', p_verification_id);
end;
$$;

grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- notification_prefs: 通知の受け取り設定(設定画面のトグルを実データに)
-- ------------------------------------------------------------
create table public.notification_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  notify_invites boolean not null default true,
  notify_online_friends boolean not null default true,
  notify_recommendations boolean not null default false
);

alter table public.notification_prefs enable row level security;

create policy "notification_prefs_select_own"
  on public.notification_prefs for select
  to authenticated
  using (user_id = auth.uid());

create policy "notification_prefs_update_own"
  on public.notification_prefs for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- INSERTポリシーは意図的に作らない(新規ユーザー作成時のトリガーのみが作成する)。

create function public.handle_new_user_notification_prefs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_prefs (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created_notification_prefs
  after insert on auth.users
  for each row execute function public.handle_new_user_notification_prefs();

-- ------------------------------------------------------------
-- account_requests: アカウント削除・データダウンロード請求
-- 実際の削除/エクスポート処理は運営が手動で行う(初期フェーズ、
-- docs/manual-verification-review.md と同様の運用)。ここではまず
-- 「実際にリクエストが記録される」ことを保証する。
-- ------------------------------------------------------------
create table public.account_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  type text not null check (type in ('data_export', 'account_deletion')),
  status text not null default 'pending' check (status in ('pending', 'processing', 'completed')),
  created_at timestamptz not null default now()
);

alter table public.account_requests enable row level security;

create policy "account_requests_select_own"
  on public.account_requests for select
  to authenticated
  using (user_id = auth.uid());

create policy "account_requests_insert_own"
  on public.account_requests for insert
  to authenticated
  with check (user_id = auth.uid());

-- ステータス更新(処理完了)は運営(service_role)のみ。authenticatedへのUPDATEポリシーは作らない。
