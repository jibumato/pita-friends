\set ON_ERROR_STOP on
\i supabase/tests/_fixture_host.sql

\echo '=== 延長(進行中の予約に+30分) ==='
set test.uid = 'c3333333-3333-3333-3333-333333333333';
select public.create_booking('b2222222-2222-2222-2222-222222222222', 60, 'v1') as e1 \gset
set test.uid = 'b2222222-2222-2222-2222-222222222222';
select public.approve_booking(:'e1');
set test.uid = 'c3333333-3333-3333-3333-333333333333';
select duration_minutes, coins, paid_coins from public.bookings where id = :'e1';
\echo '(延長前: 60分 2000コイン)'
select public.extend_booking(:'e1', 30) as added_coins;
select duration_minutes, coins, paid_coins from public.bookings where id = :'e1';
\echo '(延長後: 90分 3000コイン)'

\echo '=== 延長分もロット記録に残るか(0030の返金で期限を引き継ぐために必須) ==='
select count(*) as consumption_rows, sum(coins) as total_recorded
from public.coin_lot_consumptions where booking_id = :'e1';
\echo '(2行・合計3000 が期待値)'

\echo '=== 完了時の手数料は延長後の総額にかかるか ==='
select public.complete_booking(:'e1');
select gross_coins, fee_coins, round(applied_rate*100,1) as pct
from public.platform_fees where booking_id = :'e1';
\echo '(3000コインに対して手数料がかかっていればOK)'

\echo '=== 完了後は延長できないか(BOOKING_NOT_EXTENDABLE を期待) ==='
-- 以前はここで素の select を投げ、**出た例外を目で見て正しさを判断**していた。
-- そのままだと psql が異常終了するので、自動で流すと必ず失敗として数えられる。
-- 期待している例外なら通す形に変える(他のテストと同じ書き方に揃える)。
-- psql の :'e1' は $$ ... $$ の中では展開されないので、設定値として渡す
select set_config('test.booking_id', :'e1', false);
do $$
begin
  begin
    perform public.extend_booking(current_setting('test.booking_id')::uuid, 30);
    raise exception 'FAIL 完了後なのに延長できてしまった';
  exception when others then
    if sqlerrm not like '%BOOKING_NOT_EXTENDABLE%' then raise; end if;
  end;
  raise notice 'OK 完了後は BOOKING_NOT_EXTENDABLE で止まる';
end $$;
