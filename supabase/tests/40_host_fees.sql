\set ON_ERROR_STOP on
insert into auth.users (id) values
  ('a1111111-1111-1111-1111-111111111111'),
  ('b2222222-2222-2222-2222-222222222222');
insert into public.profiles (id, nickname) values
  ('a1111111-1111-1111-1111-111111111111','ゲスト'),
  ('b2222222-2222-2222-2222-222222222222','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'b2222222-2222-2222-2222-222222222222';
insert into public.host_settings (user_id,is_host,hourly_rate) values
  ('b2222222-2222-2222-2222-222222222222', true, 2000)
  on conflict (user_id) do update set is_host=true, hourly_rate=2000;
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('a1111111-1111-1111-1111-111111111111','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='a1111111-1111-1111-1111-111111111111';

\echo '=== 1件目(新規ゲスト・20%ティア) ==='
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.create_booking('b2222222-2222-2222-2222-222222222222', 60, 'v1') as b1 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.approve_booking(:'b1');
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.complete_booking(:'b1');
select gross_coins, fee_coins, net_coins, applied_rate, repeat_discounted
from public.platform_fees where booking_id = :'b1';
\echo '(2000コイン × 20% = 400 が手数料。手取り1600)'

\echo '=== 2件目(同じゲスト = 指名リピート。20%-3pt=17%) ==='
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.create_booking('b2222222-2222-2222-2222-222222222222', 60, 'v1') as b2 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.approve_booking(:'b2');
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.complete_booking(:'b2');
select gross_coins, fee_coins, net_coins, applied_rate, repeat_discounted
from public.platform_fees where booking_id = :'b2';
\echo '(2000 × 17% = 340。割引が効いていれば repeat_discounted = t)'

\echo '=== ホストの報酬残高(満額付与 − 手数料控除の結果) ==='
select earned_balance from public.coin_wallets
where user_id='b2222222-2222-2222-2222-222222222222';
\echo '(1600 + 1660 = 3260 が期待値)'

\echo '=== 取引履歴(満額と控除が両方残るか) ==='
select type, amount, note from public.coin_transactions
where user_id='b2222222-2222-2222-2222-222222222222' order by created_at;

\echo '=== ギフト(一律35%・0063で30%から変更) ==='
-- 完了した予約があるのでギフトを贈れる
select id as pid from public.promises where booking_id = :'b1' \gset
set test.uid = 'a1111111-1111-1111-1111-111111111111';
select public.send_gift(:'pid', 1000, null, null) is not null as gift_sent;
select gross_coins, fee_coins, net_coins, applied_rate
from public.platform_fees where kind='gift';
\echo '(1000 × 35% = 350 が手数料。手取り650)'

\echo '=== ティア跨ぎ(月間GMVが3万を越える予約) ==='
-- 既存の完了予約を積み増して、境界をまたぐ1件の手数料を見る
insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status, scheduled_at)
select 'a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222',
       60, 26000, 26000, 0, 'confirmed', now();
update public.bookings set status='completed'
  where coins = 26000 and status='confirmed';
select gross_coins, fee_coins, round(applied_rate*100,2) as pct
from public.platform_fees where gross_coins = 26000;
\echo '(確定前GMV=4000, 確定後=30000。26000全部が20%帯 → 5200。リピートなので-3pt → 4420)'
