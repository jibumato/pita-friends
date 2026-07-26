\set ON_ERROR_STOP on
insert into auth.users (id) values
  ('44444444-4444-4444-4444-444444444444'),
  ('55555555-5555-5555-5555-555555555555');
insert into public.profiles (id, nickname) values
  ('44444444-4444-4444-4444-444444444444','ゲスト'),
  ('55555555-5555-5555-5555-555555555555','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '55555555-5555-5555-5555-555555555555';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('55555555-5555-5555-5555-555555555555', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('44444444-4444-4444-4444-444444444444','paid', 5000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 5000
  where user_id = '44444444-4444-4444-4444-444444444444';

set test.uid = '44444444-4444-4444-4444-444444444444';
select public.create_booking('55555555-5555-5555-5555-555555555555', 60, '2026-07-26') as bid \gset

\echo '--- E-1: 同意したポリシー版が予約に記録されるか ---'
select policy_version, policy_agreed_at is not null as agreed_recorded
from public.bookings where id = :'bid';

\echo '--- ホストが承諾(この時点で scheduled_at = now() になる) ---'
set test.uid = '55555555-5555-5555-5555-555555555555';
select public.approve_booking(:'bid');
select to_char(scheduled_at,'HH24:MI:SS') as approved_at, status
from public.bookings where id = :'bid';

\echo '--- ★ゲストが承諾直後にキャンセルすると返金されるか ---'
set test.uid = '44444444-4444-4444-4444-444444444444';
select public.cancel_booking(:'bid', 'test');
select status, coins from public.bookings where id = :'bid';
select balance as guest_balance from public.coin_wallets
where user_id = '44444444-4444-4444-4444-444444444444';
\echo '(購入5000 → 1000消費。返金されれば5000、没収なら4000)'

select case when (select balance from public.coin_wallets
                  where user_id='44444444-4444-4444-4444-444444444444') = 4000
            then '没収された(=「開始1時間前まで全額再付与」は発生しない)'
            else '返金された' end as 実際の挙動;

\echo '--- E-2: 立証材料ビュー ---'
select booking_id is not null as has_row, forfeited_coins, policy_version,
       seconds_after_approval, elapsed_ratio
from public.guest_cancellation_evidence;
