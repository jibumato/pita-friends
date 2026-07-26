\set ON_ERROR_STOP on
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.profiles (id, nickname) values
  ('11111111-1111-1111-1111-111111111111','ゲスト'),
  ('22222222-2222-2222-2222-222222222222','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '22222222-2222-2222-2222-222222222222';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('22222222-2222-2222-2222-222222222222', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- 期限が「あと数時間」のロット(=返金までに切れる想定)
insert into public.coin_lots (user_id, kind, remaining, expires_at, created_at)
values ('11111111-1111-1111-1111-111111111111','paid', 2000,
        now() + interval '2 hours', now() - interval '6 months');
update public.coin_wallets set balance = 2000
  where user_id = '11111111-1111-1111-1111-111111111111';

set test.uid = '11111111-1111-1111-1111-111111111111';
select public.create_booking('22222222-2222-2222-2222-222222222222', 60) as booking_id \gset

-- 返金までの間に期限が過ぎた状況を作る
-- (0044で消費記録は restored_at 以外を変更できないので、明示的に解除する)
set app.ledger_override = 'on';
update public.coin_lot_consumptions set expires_at = now() - interval '1 hour'
  where booking_id = :'booking_id';
reset app.ledger_override;

set test.uid = '22222222-2222-2222-2222-222222222222';
select public.decline_booking(:'booking_id');

\echo '--- 期限切れ分は戻らず、残高から差し引かれているか ---'
select balance, bonus_balance from public.coin_wallets
where user_id='11111111-1111-1111-1111-111111111111';
\echo '(消費前2000 → 1000消費 → 返金1000だが期限切れのため失効 → 期待値 1000)'

\echo '--- 失効の取引履歴 ---'
select type, amount, note from public.coin_transactions
where user_id='11111111-1111-1111-1111-111111111111' order by created_at;

\echo '--- 二重返金の防止(restored_at が入っているか) ---'
select coins, restored_at is not null as restored from public.coin_lot_consumptions
where booking_id = :'booking_id';
