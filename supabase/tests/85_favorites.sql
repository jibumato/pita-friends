-- お気に入り(推し登録・0053)の検証。
--
-- 重点は**「誰が誰を推しているかが漏れないこと」**。
-- 推しの一覧が他人に見えると、行動の追跡や付きまといの材料になる。
-- 推された側にも人数だけを返し、名前は返さない。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('c5000000-0000-0000-0000-000000000001'::uuid),  -- 推す人A
  ('c5000000-0000-0000-0000-000000000002'::uuid),  -- 推す人B
  ('c5000000-0000-0000-0000-000000000009'::uuid),  -- 推されるピタメイト
  ('c5000000-0000-0000-0000-00000000000b'::uuid)   -- ブロック関係の相手
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('c5000000-0000-0000-0000-000000000001'::uuid, '推す人A'),
  ('c5000000-0000-0000-0000-000000000002'::uuid, '推す人B'),
  ('c5000000-0000-0000-0000-000000000009'::uuid, '推されメイト'),
  ('c5000000-0000-0000-0000-00000000000b'::uuid, 'ブロック相手')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id in ('c5000000-0000-0000-0000-000000000009'::uuid,
                    'c5000000-0000-0000-0000-00000000000b'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('c5000000-0000-0000-0000-000000000009'::uuid, true, 1200),
  ('c5000000-0000-0000-0000-00000000000b'::uuid, true, 1200)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1200;

\echo '=== 1. 推し登録できる / 二重登録にならない ==='
set test.uid = 'c5000000-0000-0000-0000-000000000001';
select public.set_favorite('c5000000-0000-0000-0000-000000000009'::uuid, true);
select public.set_favorite('c5000000-0000-0000-0000-000000000009'::uuid, true);
do $$
begin
  if (select count(*) from public.my_favorites()) <> 1 then
    raise exception 'FAIL: 件数が1でない';
  end if;
  if not (select is_active from public.my_favorites()) then
    raise exception 'FAIL: 掲載中なのに is_active が false';
  end if;
end $$;

\echo '=== 2. 自分自身は推せない ==='
do $$
begin
  begin
    perform public.set_favorite('c5000000-0000-0000-0000-000000000001'::uuid, true);
    raise exception 'FAIL: 自分を推せてしまった';
  exception when others then
    if sqlerrm not like '%CANNOT_FAVORITE_SELF%' then raise; end if;
  end;
end $$;

\echo '=== 3. 他人の推しは見えない ==='
-- Bも同じ相手を推す。AからはBの行が見えないこと(件数が増えないこと)を確かめる。
set test.uid = 'c5000000-0000-0000-0000-000000000002';
select public.set_favorite('c5000000-0000-0000-0000-000000000009'::uuid, true);
set test.uid = 'c5000000-0000-0000-0000-000000000001';
do $$
begin
  if (select count(*) from public.my_favorites()) <> 1 then
    raise exception 'FAIL: 他人の推しが自分の一覧に混ざっている';
  end if;
end $$;

-- テーブルを直接読む経路も自分の行だけであること。
-- ここは実際に select して確かめられない。ローカルの検証用DBには
-- Supabaseが本番で自動的に付けるテーブル権限が無く、authenticated ロールに
-- 切り替えると権限エラーになるため(postgresで読むとRLSを素通りする)。
-- 代わりに、ポリシーが「自分の行だけ」の3本から増えていないことを確かめる。
do $$
declare
  v text;
begin
  select string_agg(polname, ', ' order by polname) into v
  from pg_policy where polrelid = 'public.favorites'::regclass;
  if v is distinct from 'favorites_delete_own, favorites_insert_own, favorites_select_own' then
    raise exception 'FAIL: 想定外のポリシーがある: %', coalesce(v, '(なし)');
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.favorites'::regclass) then
    raise exception 'FAIL: RLSが無効';
  end if;
  -- select ポリシーの条件が user_id = auth.uid() であること
  if (select pg_get_expr(polqual, polrelid) from pg_policy
      where polrelid='public.favorites'::regclass and polname='favorites_select_own')
     !~ 'user_id = auth\.uid\(\)' then
    raise exception 'FAIL: selectポリシーが自分の行に限定されていない';
  end if;
end $$;

\echo '=== 4. 推された側には人数だけが返る ==='
set test.uid = 'c5000000-0000-0000-0000-000000000009';
do $$
begin
  if public.my_favorite_count() <> 2 then
    raise exception 'FAIL: 人数が2でない(実際: %)', public.my_favorite_count();
  end if;
  -- 推された側に「誰が」を返す口が無いこと。人数を返す関数しか公開していない。
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname like '%favorite%'
      and p.proname not in ('set_favorite','my_favorites','my_favorite_count')
  ) then
    raise exception 'FAIL: 想定外のお気に入り関数がある';
  end if;
end $$;

\echo '=== 5. 解除できる ==='
set test.uid = 'c5000000-0000-0000-0000-000000000002';
select public.set_favorite('c5000000-0000-0000-0000-000000000009'::uuid, false);
set test.uid = 'c5000000-0000-0000-0000-000000000009';
do $$
begin
  if public.my_favorite_count() <> 1 then
    raise exception 'FAIL: 解除が反映されていない';
  end if;
end $$;

\echo '=== 6. 掲載をやめても一覧からは消えず、is_active が false になる ==='
update public.host_settings set is_host = false
  where user_id = 'c5000000-0000-0000-0000-000000000009'::uuid;
set test.uid = 'c5000000-0000-0000-0000-000000000001';
do $$
begin
  if (select count(*) from public.my_favorites()) <> 1 then
    raise exception 'FAIL: 掲載をやめた相手が一覧から黙って消えた';
  end if;
  if (select is_active from public.my_favorites()) then
    raise exception 'FAIL: 掲載をやめたのに is_active が true';
  end if;
end $$;
update public.host_settings set is_host = true
  where user_id = 'c5000000-0000-0000-0000-000000000009'::uuid;

\echo '=== 7. ブロック関係では推せない・一覧にも出ない ==='
insert into public.blocks (blocker_id, blocked_id)
  values ('c5000000-0000-0000-0000-000000000001'::uuid, 'c5000000-0000-0000-0000-00000000000b'::uuid)
  on conflict do nothing;
do $$
begin
  begin
    perform public.set_favorite('c5000000-0000-0000-0000-00000000000b'::uuid, true);
    raise exception 'FAIL: ブロックした相手を推せてしまった';
  exception when others then
    if sqlerrm not like '%BLOCKED%' then raise; end if;
  end;
end $$;
-- 先に推してからブロックした場合も一覧から外れること
delete from public.blocks where blocker_id = 'c5000000-0000-0000-0000-000000000001'::uuid;
select public.set_favorite('c5000000-0000-0000-0000-00000000000b'::uuid, true);
insert into public.blocks (blocker_id, blocked_id)
  values ('c5000000-0000-0000-0000-000000000001'::uuid, 'c5000000-0000-0000-0000-00000000000b'::uuid);
do $$
begin
  if exists (select 1 from public.my_favorites()
             where host_id = 'c5000000-0000-0000-0000-00000000000b'::uuid) then
    raise exception 'FAIL: ブロック後もブロック相手が一覧に残っている';
  end if;
end $$;

\echo '=== 8. 未ログインでは何もできない ==='
do $$
begin
  if has_function_privilege('anon', 'public.my_favorites()', 'execute') then
    raise exception 'FAIL: anonが推し一覧を引ける';
  end if;
  if has_function_privilege('anon', 'public.set_favorite(uuid, boolean)', 'execute') then
    raise exception 'FAIL: anonが推し登録できる';
  end if;
  if exists (
    select 1 from pg_policy pol join pg_class c on c.oid = pol.polrelid
    where c.relname = 'favorites'
      and 'anon' = any (select rolname from pg_roles where oid = any (pol.polroles))
  ) then
    raise exception 'FAIL: favorites に anon 向けポリシーがある';
  end if;
end $$;

reset test.uid;
delete from public.blocks where blocker_id::text like 'c5000000-%';
delete from public.favorites where user_id::text like 'c5000000-%';
delete from public.host_settings where user_id::text like 'c5000000-%';
delete from public.profiles where id::text like 'c5000000-%';
delete from auth.users where id::text like 'c5000000-%';

\echo '=== 85_favorites: 全項目OK ==='
