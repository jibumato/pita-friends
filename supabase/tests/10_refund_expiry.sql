\set ON_ERROR_STOP on
-- ゲストとホストを用意
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.profiles (id, nickname) values
  ('11111111-1111-1111-1111-111111111111','ゲスト'),
  ('22222222-2222-2222-2222-222222222222','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.coin_wallets (user_id, balance, bonus_balance) values
  ('11111111-1111-1111-1111-111111111111', 0, 0)
  on conflict (user_id) do update set balance = 0, bonus_balance = 0;
update public.profile_trust_stats set is_verified = true
  where user_id = '22222222-2222-2222-2222-222222222222';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('22222222-2222-2222-2222-222222222222', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- 「5か月前に購入した」ロットを作る(期限は購入から6か月-1日 = あと約1か月)
insert into public.coin_lots (user_id, kind, remaining, expires_at, created_at)
values ('11111111-1111-1111-1111-111111111111','paid', 2000,
        public.coin_expiry_from(now() - interval '5 months'),
        now() - interval '5 months');
update public.coin_wallets set balance = 2000
  where user_id = '11111111-1111-1111-1111-111111111111';

\echo '--- 購入直後のロット(期限は約1か月後) ---'
select kind, remaining, to_char(expires_at,'YYYY-MM-DD') as expires
from public.coin_lots where user_id='11111111-1111-1111-1111-111111111111';

-- ゲストとして予約(1000コイン消費)
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.create_booking('22222222-2222-2222-2222-222222222222', 60) as booking_id \gset

\echo '--- 消費の記録(当初の期限が保存されているか) ---'
select kind, coins, to_char(expires_at,'YYYY-MM-DD') as original_expires, restored_at
from public.coin_lot_consumptions where booking_id = :'booking_id';

-- ホストが辞退 → 返金
set test.uid = '22222222-2222-2222-2222-222222222222';
select public.decline_booking(:'booking_id');

\echo '--- 返金後のロット(★当初の期限を引き継いでいるか) ---'
select kind, remaining, to_char(expires_at,'YYYY-MM-DD') as expires
from public.coin_lots where user_id='11111111-1111-1111-1111-111111111111' and remaining > 0
order by expires_at;

\echo '--- 残高 ---'
select balance, bonus_balance from public.coin_wallets
where user_id='11111111-1111-1111-1111-111111111111';

\echo '--- 判定: 返金分の期限が「今から6か月後」なら不合格 / 「約1か月後」なら合格 ---'
select
  case when max(expires_at) < now() + interval '2 months'
       then 'PASS: 当初の発行日基準を維持(通算6か月以内)'
       else 'FAIL: 期限が振り直されている' end as verdict
from public.coin_lots
where user_id='11111111-1111-1111-1111-111111111111' and remaining > 0;
