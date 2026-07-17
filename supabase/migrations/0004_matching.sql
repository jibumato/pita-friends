-- マッチングのコアフロー: 誘う → 承認 → 約束
-- 設計方針: 「誰から誘いを受けるか」は safety_prefs.contact_scope
-- (女性ファースト安全設計の中核コントロール)で本人が決めるため、
-- invites の INSERT ポリシーでこれを強制する(アプリ層任せにしない)。

-- ============================================================
-- invites: 誘う/受け取った誘い
-- ============================================================
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users (id) on delete cascade,
  to_user uuid not null references auth.users (id) on delete cascade,
  game text not null,
  when_text text not null,
  message text not null default '',
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'expired')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (from_user <> to_user)
);

alter table public.invites enable row level security;

create policy "invites_select_participant"
  on public.invites for select
  to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());

-- 送信者は、相手の安心設定(contact_scope)を満たす場合のみ誘いを送れる。
-- (暫定): この時点では blocks テーブルが未作成のため、ブロック確認は
-- 含めない。0005_trust_safety.sql で blocks 作成後にこのポリシーを
-- ブロック確認込みで置き換える。
create policy "invites_insert_within_contact_scope"
  on public.invites for insert
  to authenticated
  with check (
    from_user = auth.uid()
    and exists (
      select 1
      from public.safety_prefs sp
      join public.profiles receiver on receiver.id = sp.user_id
      join public.profiles sender on sender.id = from_user
      left join public.profile_trust_stats sender_stats on sender_stats.user_id = from_user
      where sp.user_id = to_user
        and (
          sp.contact_scope = 'all'
          or (sp.contact_scope = 'verified' and coalesce(sender_stats.is_verified, false))
          or (sp.contact_scope = 'sameGender' and sender.gender = receiver.gender)
        )
    )
  );

-- 応答(承認/辞退)は宛先本人のみ。承認/辞退のロジック自体は下記の
-- approve_invite / decline_invite 関数で行うため、直接UPDATEは許可しない。

-- ============================================================
-- promises: 約束(誘いの承認、またはコイン予約から成立)
-- ============================================================
create table public.promises (
  id uuid primary key default gen_random_uuid(),
  invite_id uuid references public.invites (id) on delete set null,
  booking_id uuid references public.bookings (id) on delete set null,
  user_a uuid not null references auth.users (id) on delete cascade,
  user_b uuid not null references auth.users (id) on delete cascade,
  scheduled_at timestamptz not null default now(),
  status text not null default 'scheduled' check (status in ('scheduled', 'joined', 'completed', 'cancelled')),
  friend_code_revealed boolean not null default false,
  created_at timestamptz not null default now(),
  check ((invite_id is not null)::int + (booking_id is not null)::int = 1),
  check (user_a <> user_b)
);

comment on table public.promises is
  '「約束」ステージ。invite_id(承認された誘い)かbooking_id(コイン予約)のいずれか一方から必ず作られる。';

alter table public.promises enable row level security;

create policy "promises_select_participant"
  on public.promises for select
  to authenticated
  using (user_a = auth.uid() or user_b = auth.uid());

-- INSERT/UPDATEは意図的にポリシーを作らない(approve_invite / create_booking
-- 経由の作成、joining/reviewフローでの状態遷移も専用関数を用意する想定)。

-- ============================================================
-- approve_invite / decline_invite: 誘いへの応答
-- ============================================================
create function public.approve_invite(p_invite_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.invites;
  v_promise_id uuid;
begin
  select * into v_invite from public.invites where id = p_invite_id for update;

  if v_invite.id is null then
    raise exception 'INVITE_NOT_FOUND';
  end if;
  if v_invite.to_user <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if v_invite.status <> 'pending' then
    raise exception 'INVITE_NOT_PENDING';
  end if;

  update public.invites set status = 'approved', responded_at = now() where id = p_invite_id;

  insert into public.promises (invite_id, user_a, user_b)
  values (p_invite_id, v_invite.from_user, v_invite.to_user)
  returning id into v_promise_id;

  return v_promise_id;
end;
$$;

revoke all on function public.approve_invite(uuid) from public;
grant execute on function public.approve_invite(uuid) to authenticated;

create function public.decline_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.invites;
begin
  select * into v_invite from public.invites where id = p_invite_id for update;

  if v_invite.id is null then
    raise exception 'INVITE_NOT_FOUND';
  end if;
  if v_invite.to_user <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if v_invite.status <> 'pending' then
    raise exception 'INVITE_NOT_PENDING';
  end if;

  update public.invites set status = 'declined', responded_at = now() where id = p_invite_id;
end;
$$;

revoke all on function public.decline_invite(uuid) from public;
grant execute on function public.decline_invite(uuid) to authenticated;
