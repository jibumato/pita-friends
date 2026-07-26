\set ON_ERROR_STOP on
insert into auth.users (id) values
  ('d1111111-1111-1111-1111-111111111111'),
  ('d2222222-2222-2222-2222-222222222222'),
  ('d3333333-3333-3333-3333-333333333333');
insert into public.profiles (id, nickname) values
  ('d1111111-1111-1111-1111-111111111111','ぬし'),
  ('d2222222-2222-2222-2222-222222222222','さんか1'),
  ('d3333333-3333-3333-3333-333333333333','さんか2')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('d2222222-2222-2222-2222-222222222222','d3333333-3333-3333-3333-333333333333');

set test.uid = 'd1111111-1111-1111-1111-111111111111';
insert into public.board_posts (creator_id, game, when_text, capacity, verified_only)
values ('d1111111-1111-1111-1111-111111111111','Apex','今夜 22:00〜', 4, true)
returning id as pid \gset

\echo '=== 参加者を2人つける ==='
set test.uid = 'd2222222-2222-2222-2222-222222222222';
select public.join_board_post(:'pid');
set test.uid = 'd3333333-3333-3333-3333-333333333333';
select public.join_board_post(:'pid');
select count(*) as participants from public.board_participants where post_id = :'pid';

\echo '=== 他人は取り消せないか(ONLY_CREATOR_CAN_CANCEL を期待) ==='
do $$ begin
  perform set_config('test.uid','d2222222-2222-2222-2222-222222222222', false);
  begin
    perform public.cancel_board_post((select id from public.board_posts limit 1), 'いたずら');
    raise notice 'NG: 他人が取り消せてしまった';
  exception when others then
    raise notice 'OK: 他人の取り消しは拒否された (%)', sqlerrm;
  end;
end $$;

\echo '=== 作成者が取り消す ==='
set test.uid = 'd1111111-1111-1111-1111-111111111111';
select public.cancel_board_post(:'pid', '人数が集まらなかったため');
select status, cancelled_at is not null as cancelled, cancel_reason
from public.board_posts where id = :'pid';

\echo '=== 参加者に通知が届いたか ==='
select u.user_id, n.type, n.title, n.body
from public.notifications n
join (select user_id from public.board_participants where post_id = :'pid') u
  on u.user_id = n.user_id
where n.type = 'board_cancelled';

\echo '=== 二重取り消しでエラーにならないか(連打対策) ==='
select public.cancel_board_post(:'pid', 'again');
select count(*) as notifications_after_second_call
from public.notifications where type = 'board_cancelled';
\echo '(2件のまま増えていなければOK)'

\echo '=== 直接UPDATEのポリシーが外れているか ==='
select count(*) as update_policies
from pg_policies where schemaname='public' and tablename='board_posts' and cmd='UPDATE';
\echo '(0件ならOK。UPDATEポリシーが無いので authenticated からは1行も更新できない)'
