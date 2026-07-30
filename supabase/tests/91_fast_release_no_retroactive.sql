-- ============================================================
-- 91: 検収期間の短縮設定が遡らないこと(0072)
-- ------------------------------------------------------------
-- 弁護士の指摘(Q28): 「短縮設定の変更は既存の進行中予約には及ばず、
-- 変更後に成立した予約に適用される」。**遡って検収期間が縮むのは
-- 利用者の不利益変更で、消費者契約法10条の議論を自ら招く。**
--
-- 0062は判定を自動確定の実行時に読んでいたため、ONにした瞬間に
-- 既存の予約も縮んでいた。0072で「予約成立時点で有効だった設定に
-- だけ従う」ようにしたので、それを固定する。
-- ============================================================
insert into auth.users (id) values
  ('f2000000-0000-0000-0000-000000000001'),
  ('f2000000-0000-0000-0000-000000000002');
insert into public.profiles (id, nickname) values
  ('f2000000-0000-0000-0000-000000000001','ゲスト'),
  ('f2000000-0000-0000-0000-000000000002','ピタメイト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f2000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id,is_host,hourly_rate) values
  ('f2000000-0000-0000-0000-000000000002', true, 100)
  on conflict (user_id) do update set is_host=true, hourly_rate=100;
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('f2000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='f2000000-0000-0000-0000-000000000001';

-- 3回遊んだ実績を作る(短縮設定の前提)
insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status, scheduled_at)
select 'f2000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000002',
       60, 100, 100, 0, 'completed', now() - interval '30 days'
from generate_series(1,3);

-- 「40時間前に終わった予約」を作る(24hなら確定・72hなら未確定の位置)
insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status, scheduled_at, created_at)
values ('f2000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000002',
        60, 100, 100, 0, 'confirmed', now() - interval '41 hours', now() - interval '42 hours');

\echo '=== 1. 予約より【後】に短縮設定をONにしても、その予約は確定しない ==='
set test.uid = 'f2000000-0000-0000-0000-000000000001';
select public.set_fast_release('f2000000-0000-0000-0000-000000000002'::uuid, 24);
do $$
declare v_n int; v_st text;
begin
  v_n := public.auto_complete_bookings();
  select status into v_st from public.bookings
   where status in ('confirmed','completed') and scheduled_at > now() - interval '42 hours'
   order by created_at desc limit 1;
  if v_st <> 'confirmed' then
    raise exception 'FAIL: 設定を後からONにしたのに、既存の予約が確定してしまった(不利益の遡及)';
  end if;
  raise notice 'OK: 後からONにしても既存の予約は confirmed のまま(自動確定%件)', v_n;
end $$;

\echo '=== 2. 設定が【先】にあった予約は、短縮が効いて確定する ==='
-- 設定より後に成立した予約を足す
insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status, scheduled_at, created_at)
values ('f2000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000002',
        60, 200, 200, 0, 'confirmed', now() - interval '41 hours', now());
do $$
declare v_st text;
begin
  perform public.auto_complete_bookings();
  select status into v_st from public.bookings where coins = 200;
  if v_st <> 'completed' then
    raise exception 'FAIL: 設定後に成立した予約が24時間で確定していない(実際: %)', v_st;
  end if;
  raise notice 'OK: 設定後に成立した予約は24時間で確定した';
end $$;

\echo '=== 3. 設定を外すと、既存の予約も即座に72時間へ戻る(有利な方向は即時) ==='
set test.uid = 'f2000000-0000-0000-0000-000000000001';
select public.set_fast_release('f2000000-0000-0000-0000-000000000002'::uuid, null);
do $$
declare v_n int;
begin
  -- 41時間前に終わった confirmed の予約は、72時間なら確定しないはず
  v_n := public.auto_complete_bookings();
  if exists (select 1 from public.bookings where coins = 100 and status = 'completed'
               and scheduled_at > now() - interval '42 hours') then
    raise exception 'FAIL: 設定を外したのに24時間で確定した';
  end if;
  raise notice 'OK: 外したあとは72時間扱い(確定%件)', v_n;
end $$;

\echo '=== 91 すべて通過 ==='
