-- ============================================================
-- 0053_favorites.sql
-- お気に入り(推し登録)
-- ------------------------------------------------------------
-- これまで「気になるピタメイトを見つけた」あと、その人にたどり着く手段が
-- 予約するか名前を覚えて検索し直すかしかなかった。
-- 「見つける → 気に留める → 予約する」の真ん中が無い状態。
--
-- プライバシーの方針(ここが設計の中心):
--   ・**誰が誰を推しているかは、本人以外に見えない。** 推しの一覧が他人に
--     見えると、行動の追跡や付きまといの材料になる。
--   ・推された側には**人数だけ**返す。励みにはなるが、誰かは分からない。
--   ・ブロック関係があれば、どちら向きでも一覧から外す。
--
-- 相手が掲載をやめた場合は、一覧から黙って消さずに「いまは募集していない」
-- と分かる形で残す。黙って消えると、推していた人には理由が分からない。
-- ============================================================

create table if not exists public.favorites (
  -- 推している人(この行を作った本人)
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 推されているピタメイト
  host_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, host_id),
  constraint favorites_no_self check (user_id <> host_id)
);

comment on table public.favorites is
  'お気に入り(推し登録)。誰が誰を推しているかは本人以外に見えない。推された側には人数のみ返す。';

-- 「自分を推している人数」を数えるための索引
create index if not exists favorites_host_idx on public.favorites (host_id);

alter table public.favorites enable row level security;

-- 自分の推しだけを読み書きできる。他人の推しは一切見えない。
drop policy if exists "favorites_select_own" on public.favorites;
create policy "favorites_select_own"
  on public.favorites for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "favorites_insert_own" on public.favorites;
create policy "favorites_insert_own"
  on public.favorites for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "favorites_delete_own" on public.favorites;
create policy "favorites_delete_own"
  on public.favorites for delete
  to authenticated
  using (user_id = auth.uid());

-- ------------------------------------------------------------
-- set_favorite(): 推し登録の追加・解除
-- ------------------------------------------------------------
drop function if exists public.set_favorite(uuid, boolean);

create or replace function public.set_favorite(p_host_id uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_host_id = v_me then
    raise exception 'CANNOT_FAVORITE_SELF';
  end if;

  if not p_on then
    delete from public.favorites where user_id = v_me and host_id = p_host_id;
    return;
  end if;

  -- ブロック関係があるなら登録させない。解除は上で済ませているので、
  -- 「ブロックしたが推しには残っている」状態は作れない。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_me and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_me)
  ) then
    raise exception 'BLOCKED';
  end if;

  if not exists (select 1 from public.profiles where id = p_host_id) then
    raise exception 'HOST_NOT_FOUND';
  end if;

  insert into public.favorites (user_id, host_id)
  values (v_me, p_host_id)
  on conflict (user_id, host_id) do nothing;
end;
$$;

comment on function public.set_favorite(uuid, boolean) is
  '推し登録の追加(p_on=true)と解除(false)。ブロック関係があると登録できない。';

revoke all on function public.set_favorite(uuid, boolean) from public;
grant execute on function public.set_favorite(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- my_favorites(): 自分が推しているピタメイトの一覧
-- ------------------------------------------------------------
drop function if exists public.my_favorites();

create or replace function public.my_favorites()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  manner_score numeric,
  review_count int,
  is_verified boolean,
  /** いま予約を受け付けているか。false なら「募集を休んでいる」と出す。 */
  is_active boolean,
  favorited_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select f.host_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         coalesce(h.hourly_rate, 0),
         coalesce(h.games, '{}'),
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         coalesce(h.is_host, false)
           and coalesce(ts.is_verified, false)
           and coalesce(sp.discoverable, true),
         f.created_at
  from public.favorites f
  join public.profiles p on p.id = f.host_id
  left join public.host_settings h on h.user_id = f.host_id
  left join public.profile_trust_stats ts on ts.user_id = f.host_id
  left join public.safety_prefs sp on sp.user_id = f.host_id
  where f.user_id = auth.uid()
    -- ブロックした/された相手は出さない
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = f.host_id)
         or (b.blocker_id = f.host_id and b.blocked_id = auth.uid())
    )
  order by f.created_at desc;
$$;

comment on function public.my_favorites() is
  '自分が推しているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からないため)。';

revoke all on function public.my_favorites() from public;
grant execute on function public.my_favorites() to authenticated;

-- ------------------------------------------------------------
-- my_favorite_count(): 自分を推している人数
-- ------------------------------------------------------------
-- **人数だけ**を返す。誰が推しているかは返さない。
drop function if exists public.my_favorite_count();

create or replace function public.my_favorite_count()
returns int
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(count(*), 0)::int
  from public.favorites f
  where f.host_id = auth.uid();
$$;

comment on function public.my_favorite_count() is
  '自分を推している人数。誰かは返さない(推している側の行動を相手に知らせない)。';

revoke all on function public.my_favorite_count() from public;
grant execute on function public.my_favorite_count() to authenticated;
