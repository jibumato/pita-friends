-- ============================================================
-- 募集板: 実際に募集を作成・一覧・参加できるようにする
-- ============================================================

create table public.board_posts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users (id) on delete cascade,
  game text not null,
  mood text not null default 'エンジョイ' check (mood in ('エンジョイ', 'ランク上げ', 'ガチ')),
  when_text text not null,
  capacity int not null default 2 check (capacity between 1 and 4),
  vc text not null default 'どちらでも' check (vc in ('必須', 'どちらでも', 'なし')),
  audience text not null default '全員' check (audience in ('全員', '同性のみ')),
  verified_only boolean not null default true,
  note text not null default '',
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),
  created_at timestamptz not null default now()
);

alter table public.board_posts enable row level security;

-- 一覧はブロック関係にない相手の募集のみ見える(0005のprofiles方針と揃える)。
create policy "board_posts_select_not_blocked"
  on public.board_posts for select
  to authenticated
  using (
    creator_id = auth.uid()
    or not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = board_posts.creator_id)
         or (b.blocker_id = board_posts.creator_id and b.blocked_id = auth.uid())
    )
  );

create policy "board_posts_insert_own"
  on public.board_posts for insert
  to authenticated
  with check (creator_id = auth.uid());

-- 作成者は自分の募集を閉じる(キャンセル)ことができる。定員等の直接改変は不可。
create policy "board_posts_update_own_status"
  on public.board_posts for update
  to authenticated
  using (creator_id = auth.uid())
  with check (creator_id = auth.uid());

create index board_posts_status_created_idx on public.board_posts (status, created_at desc);

-- ------------------------------------------------------------
-- board_participants: 参加者(作成者本人は含めない)
-- ------------------------------------------------------------
create table public.board_participants (
  post_id uuid not null references public.board_posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.board_participants enable row level security;

create policy "board_participants_select_related"
  on public.board_participants for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.board_posts bp where bp.id = post_id and bp.creator_id = auth.uid())
  );

-- INSERTは join_board_post 関数経由のみ(定員・条件チェックをアトミックに行うため)。

-- ------------------------------------------------------------
-- join_board_post: 参加表明。定員・本人確認要件・同性のみ要件・
-- ブロック関係をサーバー側でアトミックに検証してから参加者を追加する。
-- ------------------------------------------------------------
create function public.join_board_post(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post public.board_posts;
  v_me uuid := auth.uid();
  v_me_verified boolean;
  v_me_gender text;
  v_creator_gender text;
  v_joined_count int;
begin
  if v_me is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_me then
    raise exception 'CANNOT_JOIN_OWN_POST';
  end if;
  if exists (select 1 from public.board_participants where post_id = p_post_id and user_id = v_me) then
    raise exception 'ALREADY_JOINED';
  end if;
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_me and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_me)
  ) then
    raise exception 'BLOCKED';
  end if;

  select count(*) into v_joined_count from public.board_participants where post_id = p_post_id;
  if v_joined_count >= v_post.capacity then
    raise exception 'POST_FULL';
  end if;

  if v_post.verified_only then
    select is_verified into v_me_verified from public.profile_trust_stats where user_id = v_me;
    if not coalesce(v_me_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_me_gender from public.profiles where id = v_me;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_me_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  insert into public.board_participants (post_id, user_id) values (p_post_id, v_me);

  -- 定員に達したら自動的にクローズする
  if v_joined_count + 1 >= v_post.capacity then
    update public.board_posts set status = 'closed' where id = p_post_id;
  end if;
end;
$$;

revoke all on function public.join_board_post(uuid) from public;
grant execute on function public.join_board_post(uuid) to authenticated;
