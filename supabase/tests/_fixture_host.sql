-- ゲスト2人・ホスト1人。1人は2回(リピート)、1人は1回(新規)。1件は辞退。
insert into auth.users (id) values
  ('a1111111-1111-1111-1111-111111111111'),
  ('c3333333-3333-3333-3333-333333333333'),
  ('b2222222-2222-2222-2222-222222222222');
insert into public.profiles (id, nickname) values
  ('a1111111-1111-1111-1111-111111111111','ゲストA'),
  ('c3333333-3333-3333-3333-333333333333','ゲストB'),
  ('b2222222-2222-2222-2222-222222222222','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true where user_id='b2222222-2222-2222-2222-222222222222';
insert into public.host_settings (user_id,is_host,hourly_rate) values ('b2222222-2222-2222-2222-222222222222',true,2000)
  on conflict (user_id) do update set is_host=true, hourly_rate=2000;
insert into public.coin_lots (user_id,kind,remaining,expires_at) values
  ('a1111111-1111-1111-1111-111111111111','paid',50000, public.coin_expiry_from(now())),
  ('c3333333-3333-3333-3333-333333333333','paid',50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=50000
  where user_id in ('a1111111-1111-1111-1111-111111111111','c3333333-3333-3333-3333-333333333333');

-- A: 2回完了(2回目がリピート)
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.create_booking('b2222222-2222-2222-2222-222222222222', 60, 'v1') as x1 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.approve_booking(:'x1');
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.complete_booking(:'x1');
select public.create_booking('b2222222-2222-2222-2222-222222222222', 60, 'v1') as x2 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.approve_booking(:'x2');
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.complete_booking(:'x2');

-- B: 1回完了(新規)
set test.uid = 'c3333333-3333-3333-3333-333333333333';
select public.create_booking('b2222222-2222-2222-2222-222222222222', 30, 'v1') as x3 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.approve_booking(:'x3');
set test.uid = 'c3333333-3333-3333-3333-333333333333';
select public.complete_booking(:'x3');

-- B: 1件は辞退(成約率が1.0にならないように)
select public.create_booking('b2222222-2222-2222-2222-222222222222', 30, 'v1') as x4 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.decline_booking(:'x4');
