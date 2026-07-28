-- まとめ予約(0061)の検証。
--
-- 重点は**全部通るか、1件も作らないか**。3週目だけ埋まっていたときに
-- 1・2・4週目だけ作ると、ゲストは頼んでいない組み合わせに払わされる。
-- コインが減っていないところまで確かめる。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d1000000-0000-0000-0000-000000000001'::uuid),  -- 予約する人
  ('d1000000-0000-0000-0000-000000000002'::uuid),  -- 3週目を先に取る人
  ('d1000000-0000-0000-0000-000000000009'::uuid)   -- ピタメイト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('d1000000-0000-0000-0000-000000000001'::uuid, '毎週の人'),
  ('d1000000-0000-0000-0000-000000000002'::uuid, '横取り'),
  ('d1000000-0000-0000-0000-000000000009'::uuid, '毎週メイト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'd1000000-0000-0000-0000-000000000009'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate)
  values ('d1000000-0000-0000-0000-000000000009'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.coin_wallets (user_id, balance) values
  ('d1000000-0000-0000-0000-000000000001'::uuid, 100000),
  ('d1000000-0000-0000-0000-000000000002'::uuid, 100000)
  on conflict (user_id) do update set balance = 100000;

\echo '=== 1. 予約できる先が35日に延びている(4回分が入る) ==='
do $$
begin
  if (select max_lead_days from public.platform_pricing where id = 1) < 35 then
    raise exception 'FAIL: 35日に延びていない';
  end if;
end $$;

\echo '=== 2. 4回分をまとめて押さえられる ==='
set test.uid = 'd1000000-0000-0000-0000-000000000001';
do $$
declare v_ids uuid[]; v_start timestamptz;
begin
  v_start := date_trunc('hour', now()) + interval '2 days';
  v_ids := public.create_booking_series(
    'd1000000-0000-0000-0000-000000000009'::uuid, 60, null, v_start, 4);
  if array_length(v_ids, 1) <> 4 then
    raise exception 'FAIL: 4件でない: %', array_length(v_ids, 1);
  end if;
  -- 1週間ずつ離れていること
  if (select count(*) from public.bookings
      where id = any (v_ids) and requested_start_at = v_start + interval '21 days') <> 1 then
    raise exception 'FAIL: 4回目が3週間後になっていない';
  end if;
end $$;

\echo '=== 3. 途中が埋まっていたら1件も作らない ==='
-- 後片付けしてから、3週目だけ別の人に取らせる
set app.ledger_override = 'on';
delete from public.coin_transactions where user_id::text like 'd1000000-%';
delete from public.bookings where guest_id::text like 'd1000000-%';
reset app.ledger_override;
update public.coin_wallets set balance = 100000 where user_id::text like 'd1000000-%';

set test.uid = 'd1000000-0000-0000-0000-000000000002';
do $$
begin
  perform public.create_booking('d1000000-0000-0000-0000-000000000009'::uuid, 60, null,
    date_trunc('hour', now()) + interval '2 days' + interval '14 days');
end $$;

set test.uid = 'd1000000-0000-0000-0000-000000000001';
do $$
declare v_before int; v_after int; v_n int;
begin
  select balance into v_before from public.coin_wallets
    where user_id = 'd1000000-0000-0000-0000-000000000001'::uuid;
  begin
    perform public.create_booking_series(
      'd1000000-0000-0000-0000-000000000009'::uuid, 60, null,
      date_trunc('hour', now()) + interval '2 days', 4);
    raise exception 'FAIL: 埋まっているのに通ってしまった';
  exception when others then
    if sqlerrm not like '%HOST_SLOT_TAKEN%' then raise; end if;
    -- 何回目で落ちたかが分かること
    if sqlerrm not like '%3回目/4%' then
      raise exception 'FAIL: 何回目で落ちたかが分からない: %', sqlerrm;
    end if;
  end;

  -- **1件も残っていないこと**
  select count(*) into v_n from public.bookings
    where guest_id = 'd1000000-0000-0000-0000-000000000001'::uuid;
  if v_n <> 0 then
    raise exception 'FAIL: 途中まで作られている(%件)', v_n;
  end if;
  -- **コインも減っていないこと**
  select balance into v_after from public.coin_wallets
    where user_id = 'd1000000-0000-0000-0000-000000000001'::uuid;
  if v_after <> v_before then
    raise exception 'FAIL: コインが減っている(% → %)', v_before, v_after;
  end if;
end $$;

\echo '=== 4. コインが足りなければ1件も作らない ==='
update public.coin_wallets set balance = 1500, bonus_balance = 0
  where user_id = 'd1000000-0000-0000-0000-000000000001'::uuid;
do $$
declare v_n int;
begin
  begin
    perform public.create_booking_series(
      'd1000000-0000-0000-0000-000000000009'::uuid, 60, null,
      date_trunc('hour', now()) + interval '3 days', 4);
    raise exception 'FAIL: 残高不足なのに通った';
  exception when others then
    if sqlerrm not like '%INSUFFICIENT_COINS%' then raise; end if;
  end;
  select count(*) into v_n from public.bookings
    where guest_id = 'd1000000-0000-0000-0000-000000000001'::uuid;
  if v_n <> 0 then
    raise exception 'FAIL: 残高不足でも途中まで作られた(%件)', v_n;
  end if;
end $$;
update public.coin_wallets set balance = 100000
  where user_id = 'd1000000-0000-0000-0000-000000000001'::uuid;

\echo '=== 5. 回数は2〜4回まで ==='
do $$
declare v int;
begin
  foreach v in array array[1, 5, 0, -1] loop
    begin
      perform public.create_booking_series(
        'd1000000-0000-0000-0000-000000000009'::uuid, 60, null,
        date_trunc('hour', now()) + interval '4 days', v);
      raise exception 'FAIL: %回が通ってしまった', v;
    exception when others then
      if sqlerrm not like '%INVALID_SERIES_COUNT%' then raise; end if;
    end;
  end loop;
end $$;

\echo '=== 6. 開始時刻の指定が要る(「今すぐ」を4回は意味が通らない) ==='
do $$
begin
  begin
    perform public.create_booking_series(
      'd1000000-0000-0000-0000-000000000009'::uuid, 60, null, null, 2);
    raise exception 'FAIL: 開始時刻なしで通った';
  exception when others then
    if sqlerrm not like '%SERIES_NEEDS_START%' then raise; end if;
  end;
end $$;

\echo '=== 7. 未ログインでは呼べない ==='
do $$
begin
  if has_function_privilege('anon',
      'public.create_booking_series(uuid, integer, text, timestamptz, integer)', 'execute') then
    raise exception 'FAIL: anonが呼べる';
  end if;
end $$;

reset test.uid;
set app.ledger_override = 'on';
delete from public.coin_transactions where user_id::text like 'd1000000-%';
delete from public.bookings where guest_id::text like 'd1000000-%' or host_id::text like 'd1000000-%';
reset app.ledger_override;
delete from public.host_settings where user_id::text like 'd1000000-%';
delete from public.coin_wallets where user_id::text like 'd1000000-%';
delete from public.profiles where id::text like 'd1000000-%';
delete from auth.users where id::text like 'd1000000-%';

\echo '=== 78_booking_series: 全項目OK ==='
