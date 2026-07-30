-- お気に入りに入れている人への「枠を開けました」通知(0054)の検証。
--
-- 重点は**通知が多すぎないこと**。枠の編集は続けて何度も行われるので、
-- 素直に流すとお気に入り1人あたり1日に何通も届き、通知そのものが無視されるようになる。
--   ・増えた枠があるときだけ送る(減らしただけでは送らない)
--   ・24時間に1回まで
--   ・掲載していないうちは送らない
-- あわせて、誰がお気に入りにしているかがピタメイト側に漏れないことも確かめる。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d4000000-0000-0000-0000-000000000001'::uuid),  -- ファンA
  ('d4000000-0000-0000-0000-000000000002'::uuid),  -- ファンB
  ('d4000000-0000-0000-0000-000000000009'::uuid)   -- ピタメイト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('d4000000-0000-0000-0000-000000000001'::uuid, 'ファンA'),
  ('d4000000-0000-0000-0000-000000000002'::uuid, 'ファンB'),
  ('d4000000-0000-0000-0000-000000000009'::uuid, '枠メイト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;

-- 2人がお気に入りに入れる
set test.uid = 'd4000000-0000-0000-0000-000000000001';
select public.set_favorite('d4000000-0000-0000-0000-000000000009'::uuid, true);
set test.uid = 'd4000000-0000-0000-0000-000000000002';
select public.set_favorite('d4000000-0000-0000-0000-000000000009'::uuid, true);

delete from public.notifications where user_id::text like 'd4000000-%';

\echo '=== 1. 掲載していないうちは通知しない ==='
set test.uid = 'd4000000-0000-0000-0000-000000000009';
insert into public.host_settings (user_id, is_host, hourly_rate)
  values ('d4000000-0000-0000-0000-000000000009'::uuid, false, 1000)
  on conflict (user_id) do update set is_host = false;
select public.set_host_availability('[{"weekday":6,"hour":22}]'::jsonb);
do $$
begin
  if exists (select 1 from public.notifications where type = 'host_slots_opened') then
    raise exception 'FAIL: 掲載していないのに通知が飛んだ';
  end if;
end $$;

\echo '=== 2. 掲載中に枠を増やすと、お気に入りに入れている全員へ届く ==='
update public.profile_trust_stats set is_verified = true
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
update public.host_settings set is_host = true
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
select public.set_host_availability('[{"weekday":6,"hour":22},{"weekday":0,"hour":21}]'::jsonb);
do $$
declare v_n int;
begin
  select count(*) into v_n from public.notifications where type = 'host_slots_opened';
  if v_n <> 2 then
    raise exception 'FAIL: お気に入りに入れている2人に届いていない(実際: %)', v_n;
  end if;
  if not exists (
    select 1 from public.notifications
    where type = 'host_slots_opened' and title like '枠メイトさんが枠を開けました') then
    raise exception 'FAIL: 見出しが想定と違う';
  end if;
end $$;

\echo '=== 3. 24時間以内の再編集では送らない ==='
select public.set_host_availability('[{"weekday":6,"hour":22},{"weekday":0,"hour":21},{"weekday":3,"hour":20}]'::jsonb);
do $$
begin
  if (select count(*) from public.notifications where type = 'host_slots_opened') <> 2 then
    raise exception 'FAIL: 24時間以内なのに追加で送られた';
  end if;
end $$;

\echo '=== 4. 24時間経てば、また送れる ==='
update public.host_settings set slots_notified_at = now() - interval '25 hours'
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
select public.set_host_availability(
  '[{"weekday":6,"hour":22},{"weekday":0,"hour":21},{"weekday":3,"hour":20},{"weekday":5,"hour":23}]'::jsonb);
do $$
begin
  if (select count(*) from public.notifications where type = 'host_slots_opened') <> 4 then
    raise exception 'FAIL: 24時間経過後に送られていない';
  end if;
end $$;

\echo '=== 5. 枠を減らしただけでは送らない ==='
update public.host_settings set slots_notified_at = now() - interval '25 hours'
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
select public.set_host_availability('[{"weekday":6,"hour":22}]'::jsonb);
do $$
begin
  if (select count(*) from public.notifications where type = 'host_slots_opened') <> 4 then
    raise exception 'FAIL: 減らしただけなのに送られた';
  end if;
end $$;

\echo '=== 6. 同じ枠を出し直しただけでも送らない ==='
update public.host_settings set slots_notified_at = now() - interval '25 hours'
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
select public.set_host_availability('[{"weekday":6,"hour":22}]'::jsonb);
do $$
begin
  if (select count(*) from public.notifications where type = 'host_slots_opened') <> 4 then
    raise exception 'FAIL: 増えていないのに送られた';
  end if;
end $$;

\echo '=== 7. ブロック関係には送らない ==='
insert into public.blocks (blocker_id, blocked_id)
  values ('d4000000-0000-0000-0000-000000000002'::uuid, 'd4000000-0000-0000-0000-000000000009'::uuid)
  on conflict do nothing;
delete from public.notifications where user_id::text like 'd4000000-%';
update public.host_settings set slots_notified_at = null
  where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
select public.set_host_availability('[{"weekday":6,"hour":22},{"weekday":1,"hour":19}]'::jsonb);
do $$
begin
  if exists (
    select 1 from public.notifications
    where type = 'host_slots_opened' and user_id = 'd4000000-0000-0000-0000-000000000002'::uuid) then
    raise exception 'FAIL: ブロックした相手にも送られた';
  end if;
  if not exists (
    select 1 from public.notifications
    where type = 'host_slots_opened' and user_id = 'd4000000-0000-0000-0000-000000000001'::uuid) then
    raise exception 'FAIL: ブロックしていないファンに届いていない';
  end if;
end $$;

\echo '=== 8. 枠の保存は「誰がお気に入りにしているか」を返さない ==='
-- 戻り値は保存した枠数のみ。通知した人数を返すと、お気に入りに入れている人数が漏れる。
do $$
declare v_ret int;
begin
  update public.host_settings set slots_notified_at = null
    where user_id = 'd4000000-0000-0000-0000-000000000009'::uuid;
  select public.set_host_availability('[{"weekday":6,"hour":22},{"weekday":2,"hour":18}]'::jsonb) into v_ret;
  if v_ret <> 2 then
    raise exception 'FAIL: 戻り値が保存した枠数(2)でない: %', v_ret;
  end if;
end $$;

reset test.uid;
delete from public.notifications where user_id::text like 'd4000000-%';
delete from public.blocks where blocker_id::text like 'd4000000-%';
delete from public.favorites where user_id::text like 'd4000000-%';
delete from public.host_availability where user_id::text like 'd4000000-%';
delete from public.host_settings where user_id::text like 'd4000000-%';
delete from public.profiles where id::text like 'd4000000-%';
delete from auth.users where id::text like 'd4000000-%';

\echo '=== 84_favorite_slot_notify: 全項目OK ==='
