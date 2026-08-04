-- ============================================================
-- 27: 利用料は「実際に受け取った額」からだけ引かれる(0103)
-- ------------------------------------------------------------
-- 保留を一部返還で解除すると status が 'completed' になり、完了時の
-- 利用料トリガーが走る。0103 より前は基準が予約の全額だったため、
--   ・50%返還  → 受取1,000に控除400(実効40%)
--   ・100%返還 → 受取0なのに、**別の予約で稼いだ残高から**控除
-- という取りすぎが起きていた(規約 第8条の2第2項に反する)。
--
-- 固定するのは4つ:
--   ・通常の完了は従来どおり(全額×ティア)
--   ・一部返還つきの保留解除は、**ホストへ渡る分だけ**が基準
--   ・全額返還なら、控除も明細も発生しない
--   ・明細(platform_fees)の gross/net が実際の受取と一致する
--
-- ⚠️ トリガーは deferrable initially deferred なので、残高の検証は
--    **コミット後に別の文で**行う。do ブロックの中で読むと控除前の
--    値が見える(97 が取りこぼした理由がまさにこれ)。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('27000000-0000-0000-0000-000000000001'),  -- ゲスト
  ('27000000-0000-0000-0000-000000000002'),  -- ピタメイト
  ('27000000-0000-0000-0000-0000000000ad');  -- 運営
insert into public.profiles (id, nickname) values
  ('27000000-0000-0000-0000-000000000001','ゲスト'),
  ('27000000-0000-0000-0000-000000000002','ピタメイト'),
  ('27000000-0000-0000-0000-0000000000ad','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('27000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id = '27000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('27000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;
insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('27000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 100000
  where user_id = '27000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 通常の完了は従来どおり(2,000×20%%=400) ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '27000000-0000-0000-0000-000000000001';
select public.create_booking('27000000-0000-0000-0000-000000000002', 60, 'v1') as b1 \gset
set test.uid = '27000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b1');
set test.uid = '27000000-0000-0000-0000-000000000001';
select public.complete_booking(:'b1');

do $$
declare v_fee int; v_earned int;
begin
  select fee_coins into v_fee from public.platform_fees
    where host_id = '27000000-0000-0000-0000-000000000002';
  if v_fee <> 400 then
    raise exception 'FAIL 通常完了の控除が変わった: %(400のはず)', v_fee;
  end if;
  select earned_balance into v_earned from public.coin_wallets
    where user_id = '27000000-0000-0000-0000-000000000002';
  if v_earned <> 1600 then
    raise exception 'FAIL 通常完了の手取りが変わった: %(1600のはず)', v_earned;
  end if;
  raise notice 'OK 通常の完了は 2,000−400=1,600 のまま(0091の挙動を維持)';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 一部返還つきの保留解除: 渡る分だけが基準 ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '27000000-0000-0000-0000-000000000001';
select public.create_booking('27000000-0000-0000-0000-000000000002', 60, 'v1') as b2 \gset
set test.uid = '27000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b2');
set test.uid = '27000000-0000-0000-0000-0000000000ad';
select public.hold_booking(:'b2', 'claim');
select public.release_hold_and_refund(:'b2', 50, '半額返還(テスト)');

-- ↑ ここでコミットされ、遅延トリガーが走った。別の文で読む
do $$
declare v_gross int; v_fee int; v_net int; v_earned int; v_repeat boolean;
begin
  select gross_coins, fee_coins, net_coins, repeat_discounted
    into v_gross, v_fee, v_net, v_repeat
    from public.platform_fees
    where host_id = '27000000-0000-0000-0000-000000000002'
    order by created_at desc limit 1;

  -- 2,000の予約を50%返還 → ホストへ渡るのは1,000。基準はその1,000。
  -- 2回目の同じゲストなのでリピート割引(20%-3pt=17%)が効く
  if v_gross <> 1000 then
    raise exception 'FAIL 基準が予約の全額のまま: %(1000のはず)', v_gross;
  end if;
  if not v_repeat then
    raise exception 'FAIL 完了済みが1件あるのにリピート割引が効いていない';
  end if;
  if v_fee <> 170 then
    raise exception 'FAIL 控除がおかしい: %(1000×17%%=170のはず)', v_fee;
  end if;
  if v_net <> 830 then
    raise exception 'FAIL 明細のnetがおかしい: %', v_net;
  end if;

  -- 実際の残高とも一致すること: 1(1,600) + 今回(1,000−170=830)
  select earned_balance into v_earned from public.coin_wallets
    where user_id = '27000000-0000-0000-0000-000000000002';
  if v_earned <> 2430 then
    raise exception 'FAIL 残高が明細と食い違う: %(1600+830=2430のはず)', v_earned;
  end if;
  raise notice 'OK 渡った1,000だけに17%%(リピート)がかかり170。明細と残高が一致';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 全額返還なら、控除も明細も発生しない ==='; end $$;
-- ------------------------------------------------------------
-- 0103より前はここで**別の予約で稼いだ残高**から控除されていた
set test.uid = '27000000-0000-0000-0000-000000000001';
select public.create_booking('27000000-0000-0000-0000-000000000002', 60, 'v1') as b3 \gset
set test.uid = '27000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b3');
set test.uid = '27000000-0000-0000-0000-0000000000ad';
select public.hold_booking(:'b3', 'claim');
select public.release_hold_and_refund(:'b3', 100, '全額返還(テスト)');

do $$
declare v_n int; v_earned int;
begin
  select count(*) into v_n from public.platform_fees
    where host_id = '27000000-0000-0000-0000-000000000002';
  if v_n <> 2 then
    raise exception 'FAIL 受取0なのに明細ができた(%件。2件のはず)', v_n;
  end if;
  select earned_balance into v_earned from public.coin_wallets
    where user_id = '27000000-0000-0000-0000-000000000002';
  if v_earned <> 2430 then
    raise exception 'FAIL 受け取っていないのに残高が減った: %(2430のまま)', v_earned;
  end if;
  raise notice 'OK 1コインも受け取っていない予約からは、1コインも引かれない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 全額での保留解除(申し出を退ける)は従来どおり ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '27000000-0000-0000-0000-000000000001';
select public.create_booking('27000000-0000-0000-0000-000000000002', 60, 'v1') as b4 \gset
set test.uid = '27000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b4');
set test.uid = '27000000-0000-0000-0000-0000000000ad';
select public.hold_booking(:'b4', 'claim');
select public.release_hold_and_complete(:'b4', '申し出を退けた(テスト)');

do $$
declare v_gross int; v_fee int;
begin
  select gross_coins, fee_coins into v_gross, v_fee
    from public.platform_fees
    where host_id = '27000000-0000-0000-0000-000000000002'
    order by created_at desc limit 1;
  -- 全額2,000が基準。リピートなので17%
  if v_gross <> 2000 or v_fee <> 340 then
    raise exception 'FAIL 全額解除の控除が変わった: gross=% fee=%(2000/340のはず)',
      v_gross, v_fee;
  end if;
  raise notice 'OK 申し出を退けた場合は全額2,000×17%%=340(従来どおり)';
end $$;

do $$ begin raise notice '==== 27: すべて通過 ===='; end $$;
