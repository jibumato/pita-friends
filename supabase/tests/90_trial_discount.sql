-- 初回お試し割引(0038)の検証。
-- ホストが自分で決めた割引率が、初回のゲストにだけ適用され、
-- 手数料も割引後の金額にかかることを確認する。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d0000000-0000-0000-0000-00000000ff01'::uuid),
  ('d0000000-0000-0000-0000-00000000ff11'::uuid),
  ('d0000000-0000-0000-0000-00000000ff22'::uuid)
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('d0000000-0000-0000-0000-00000000ff01'::uuid, '割引ホスト'),
  ('d0000000-0000-0000-0000-00000000ff11'::uuid, 'ゲスト1'),
  ('d0000000-0000-0000-0000-00000000ff22'::uuid, 'ゲスト2')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id = 'd0000000-0000-0000-0000-00000000ff01'::uuid;

-- 30分1000コイン(時給2000)・初回30%OFF
insert into public.host_settings (user_id, is_host, hourly_rate, trial_discount_percent)
values ('d0000000-0000-0000-0000-00000000ff01'::uuid, true, 2000, 30)
on conflict (user_id) do update
  set is_host = true, hourly_rate = 2000, trial_discount_percent = 30;

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('d0000000-0000-0000-0000-00000000ff11'::uuid, 'paid', 50000, public.coin_expiry_from(now())),
  ('d0000000-0000-0000-0000-00000000ff22'::uuid, 'paid', 50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id in ('d0000000-0000-0000-0000-00000000ff11'::uuid,
                    'd0000000-0000-0000-0000-00000000ff22'::uuid);

\echo '=== 1. 初回のゲストは割引価格で予約できる(60分 2000 → 1400) ==='
set test.uid = 'd0000000-0000-0000-0000-00000000ff11';
select public.create_booking('d0000000-0000-0000-0000-00000000ff01'::uuid, 60, 'v1') as t1 \gset

do $$
declare b public.bookings; v_bal int;
begin
  select * into b from public.bookings
    where guest_id = 'd0000000-0000-0000-0000-00000000ff11'::uuid order by created_at desc limit 1;
  if b.list_coins <> 2000 then raise exception 'FAIL 定価が2000でない: %', b.list_coins; end if;
  if b.discount_percent <> 30 then raise exception 'FAIL 割引率が30でない: %', b.discount_percent; end if;
  if b.coins <> 1400 then raise exception 'FAIL 請求額が1400でない: %', b.coins; end if;

  select balance into v_bal from public.coin_wallets
    where user_id = 'd0000000-0000-0000-0000-00000000ff11'::uuid;
  if v_bal <> 50000 - 1400 then raise exception 'FAIL 残高が割引後で引かれていない: %', v_bal; end if;
  raise notice 'OK 定価2000 / 30%% OFF / 請求1400・残高も1400だけ減っている';
end $$;

\echo '=== 2. 手数料は割引後(1400)にかかる。定価(2000)ではない ==='
set test.uid = 'd0000000-0000-0000-0000-00000000ff01';
select public.approve_booking(:'t1');
set test.uid = 'd0000000-0000-0000-0000-00000000ff11';
select public.complete_booking(:'t1');

do $$
declare v_gross int;
begin
  select gross_coins into v_gross from public.platform_fees where booking_id = (
    select id from public.bookings where guest_id = 'd0000000-0000-0000-0000-00000000ff11'::uuid
    order by created_at desc limit 1);
  if v_gross <> 1400 then
    raise exception 'FAIL 手数料の対象額が1400でない(=%). 割引前で計算されている', v_gross;
  end if;
  raise notice 'OK 手数料は割引後の1400に対してかかっている';
end $$;

\echo '=== 3. 同じホストへの2回目は割引されない(60分 → 2000) ==='
select public.create_booking('d0000000-0000-0000-0000-00000000ff01'::uuid, 60, 'v1') as t2 \gset

do $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = (
    select id from public.bookings where guest_id = 'd0000000-0000-0000-0000-00000000ff11'::uuid
    order by created_at desc limit 1);
  if b.discount_percent <> 0 or b.coins <> 2000 then
    raise exception 'FAIL 2回目に割引が効いてしまった: %%=% coins=%', b.discount_percent, b.coins;
  end if;
  raise notice 'OK 2回目は定価2000';
end $$;

\echo '=== 4. ホスト都合(辞退)で流れた場合は「利用済み」にしない ==='
set test.uid = 'd0000000-0000-0000-0000-00000000ff22';
select public.create_booking('d0000000-0000-0000-0000-00000000ff01'::uuid, 30, 'v1') as t3 \gset
set test.uid = 'd0000000-0000-0000-0000-00000000ff01';
select public.decline_booking(:'t3');
set test.uid = 'd0000000-0000-0000-0000-00000000ff22';

do $$
declare v_pct int;
begin
  v_pct := public.host_trial_discount_for(
    'd0000000-0000-0000-0000-00000000ff01'::uuid,
    'd0000000-0000-0000-0000-00000000ff22'::uuid);
  if v_pct <> 30 then
    raise exception 'FAIL 辞退されたゲストが割引を失っている: %', v_pct;
  end if;
  raise notice 'OK ホストに辞退された後も、まだ初回扱い';
end $$;

\echo '=== 5. 延長分は通常価格。割引は最初に予約した分だけ(0039) ==='
select public.create_booking('d0000000-0000-0000-0000-00000000ff01'::uuid, 30, 'v1') as t4 \gset
set test.uid = 'd0000000-0000-0000-0000-00000000ff01';
select public.approve_booking(:'t4');
set test.uid = 'd0000000-0000-0000-0000-00000000ff22';
select public.extend_booking(:'t4', 30) as added \gset

do $$
declare b public.bookings; v_added int;
begin
  select * into b from public.bookings where id = (
    select id from public.bookings where guest_id = 'd0000000-0000-0000-0000-00000000ff22'::uuid
      and status = 'confirmed' order by created_at desc limit 1);
  -- 最初の30分は割引後700、延長30分は通常価格1000 → 合計1700 / 定価は2000
  if b.coins <> 1700 then
    raise exception 'FAIL 延長後の請求が1700でない(=%). 延長にも割引が効いている', b.coins;
  end if;
  if b.list_coins <> 2000 then raise exception 'FAIL 延長後の定価が2000でない: %', b.list_coins; end if;
  raise notice 'OK 延長分は通常価格1000(最初の30分だけ700)';
end $$;

\echo '=== 5b. 最初から長めに予約したほうが安くなること ==='
do $$
declare v_upfront int; v_split int;
begin
  -- 最初から60分: 定価2000 → 30%OFF → 1400
  v_upfront := greatest(1, round(2000 * 70 / 100.0));
  -- 30分+延長30分: 700 + 1000(通常価格) = 1700
  v_split := greatest(1, round(1000 * 70 / 100.0)) + 1000;
  if v_upfront >= v_split then
    raise exception 'FAIL 分割したほうが安い/同額になっている(一括% / 分割%)', v_upfront, v_split;
  end if;
  raise notice 'OK 一括60分=% < 30分+延長=% (差%コイン)', v_upfront, v_split, v_split - v_upfront;
end $$;

\echo '=== 6. 割引率は0〜90%%しか設定できない ==='
do $$
begin
  begin
    update public.host_settings set trial_discount_percent = 100
      where user_id = 'd0000000-0000-0000-0000-00000000ff01'::uuid;
    raise exception 'FAIL 100%%(無料)が設定できてしまった';
  exception when check_violation then
    raise notice 'OK 100%% は制約で弾かれる';
  end;
end $$;
