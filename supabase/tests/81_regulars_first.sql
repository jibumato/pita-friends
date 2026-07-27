-- 常連への先行予約枠(0057)の検証。
--
-- 重点は**画面で隠すだけになっていないこと**。RPCを直接叩けば取れるようでは
-- 意味がないので、create_booking の中で弾かれることを確かめる。
-- あわせて、N時間を切れば誰でも取れること(枠が死蔵されないこと)も見る。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a8000000-0000-0000-0000-000000000001'::uuid),  -- 常連
  ('a8000000-0000-0000-0000-000000000002'::uuid),  -- 初めての人
  ('a8000000-0000-0000-0000-000000000009'::uuid)   -- ピタメイト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('a8000000-0000-0000-0000-000000000001'::uuid, '常連'),
  ('a8000000-0000-0000-0000-000000000002'::uuid, '初めて'),
  ('a8000000-0000-0000-0000-000000000009'::uuid, '先行メイト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'a8000000-0000-0000-0000-000000000009'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate, regulars_first_hours)
  values ('a8000000-0000-0000-0000-000000000009'::uuid, true, 1000, 48)
  on conflict (user_id) do update
    set is_host = true, hourly_rate = 1000, regulars_first_hours = 48;

-- 常連には過去の完了予約を1件作っておく
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
  values ('a8000000-0000-0000-0000-000000000001'::uuid, 'a8000000-0000-0000-0000-000000000009'::uuid,
          60, 1000, 'completed', now() - interval '7 days', now() - interval '7 days');
reset app.ledger_override;

-- 予約できるだけのコインを両者に持たせる
insert into public.coin_wallets (user_id, balance) values
  ('a8000000-0000-0000-0000-000000000001'::uuid, 50000),
  ('a8000000-0000-0000-0000-000000000002'::uuid, 50000)
  on conflict (user_id) do update set balance = 50000;

\echo '=== 1. 先行期間の枠は、常連には開いていて、初めての人には閉じている ==='
do $$
declare v_far timestamptz := now() + interval '5 days';
begin
  if not public.slot_open_to('a8000000-0000-0000-0000-000000000009'::uuid,
                             'a8000000-0000-0000-0000-000000000001'::uuid, v_far) then
    raise exception 'FAIL: 常連が先行期間に予約できない';
  end if;
  if public.slot_open_to('a8000000-0000-0000-0000-000000000009'::uuid,
                         'a8000000-0000-0000-0000-000000000002'::uuid, v_far) then
    raise exception 'FAIL: 初めての人が先行期間に予約できてしまう';
  end if;
end $$;

\echo '=== 2. 開始が48時間を切れば誰でも取れる(枠が死蔵されない) ==='
do $$
declare v_near timestamptz := now() + interval '10 hours';
begin
  if not public.slot_open_to('a8000000-0000-0000-0000-000000000009'::uuid,
                             'a8000000-0000-0000-0000-000000000002'::uuid, v_near) then
    raise exception 'FAIL: 直前になっても初めての人が取れない';
  end if;
end $$;

\echo '=== 3. 設定していないピタメイトは従来どおり(誰でも・いつでも) ==='
update public.host_settings set regulars_first_hours = 0
  where user_id = 'a8000000-0000-0000-0000-000000000009'::uuid;
do $$
begin
  if not public.slot_open_to('a8000000-0000-0000-0000-000000000009'::uuid,
                             'a8000000-0000-0000-0000-000000000002'::uuid,
                             now() + interval '13 days') then
    raise exception 'FAIL: 無効にしているのに弾かれた';
  end if;
end $$;
update public.host_settings set regulars_first_hours = 48
  where user_id = 'a8000000-0000-0000-0000-000000000009'::uuid;

\echo '=== 4. create_booking が実際に弾く(画面で隠すだけになっていない) ==='
set test.uid = 'a8000000-0000-0000-0000-000000000002';
do $$
begin
  begin
    perform public.create_booking('a8000000-0000-0000-0000-000000000009'::uuid, 60, null,
                                  date_trunc('hour', now()) + interval '5 days');
    raise exception 'FAIL: 初めての人が先行期間の枠を取れてしまった';
  exception when others then
    if sqlerrm not like '%REGULARS_FIRST%' then raise; end if;
  end;
end $$;

\echo '=== 5. 常連は同じ枠を取れる ==='
set test.uid = 'a8000000-0000-0000-0000-000000000001';
do $$
declare v_id uuid;
begin
  v_id := public.create_booking('a8000000-0000-0000-0000-000000000009'::uuid, 60, null,
                                date_trunc('hour', now()) + interval '5 days');
  if v_id is null then raise exception 'FAIL: 常連が取れなかった'; end if;
end $$;

\echo '=== 6. スケジュールでは「常連のみ」として見える ==='
-- 枠を全曜日・全時間に開けて、状態だけを見る
insert into public.host_availability (user_id, weekday, hour)
select 'a8000000-0000-0000-0000-000000000009'::uuid, d, h
from generate_series(0,6) d, generate_series(0,23) h
on conflict do nothing;
set test.uid = 'a8000000-0000-0000-0000-000000000002';
do $$
begin
  if not exists (
    select 1 from public.host_schedule('a8000000-0000-0000-0000-000000000009'::uuid, 7)
    where state = 'regulars') then
    raise exception 'FAIL: 初めての人に「常連のみ」が1つも出ていない';
  end if;
  -- 直前(48時間以内)は open として見えること
  if not exists (
    select 1 from public.host_schedule('a8000000-0000-0000-0000-000000000009'::uuid, 7)
    where state = 'open' and slot_at < now() + interval '48 hours') then
    raise exception 'FAIL: 直前の枠まで「常連のみ」になっている';
  end if;
end $$;
set test.uid = 'a8000000-0000-0000-0000-000000000001';
do $$
begin
  if exists (
    select 1 from public.host_schedule('a8000000-0000-0000-0000-000000000009'::uuid, 7)
    where state = 'regulars') then
    raise exception 'FAIL: 常連にも「常連のみ」が出ている';
  end if;
end $$;

\echo '=== 7. 本人には自分の枠がそのまま見える ==='
set test.uid = 'a8000000-0000-0000-0000-000000000009';
do $$
begin
  if exists (
    select 1 from public.host_schedule('a8000000-0000-0000-0000-000000000009'::uuid, 7)
    where state = 'regulars') then
    raise exception 'FAIL: 本人の画面が「常連のみ」だらけになっている';
  end if;
end $$;

\echo '=== 8. 「誰と誰が何回遊んだか」は外から引けない ==='
do $$
begin
  if has_function_privilege('authenticated', 'public._played_together_count(uuid, uuid)', 'execute') then
    raise exception 'FAIL: 任意の二人の回数が引けてしまう';
  end if;
  if has_function_privilege('anon', 'public.slot_open_to(uuid, uuid, timestamptz)', 'execute') then
    raise exception 'FAIL: anonが枠の可否を引ける';
  end if;
end $$;

reset test.uid;
set app.ledger_override = 'on';
delete from public.coin_transactions where user_id::text like 'a8000000-%';
delete from public.bookings where guest_id::text like 'a8000000-%' or host_id::text like 'a8000000-%';
reset app.ledger_override;
delete from public.host_availability where user_id::text like 'a8000000-%';
delete from public.host_settings where user_id::text like 'a8000000-%';
delete from public.coin_wallets where user_id::text like 'a8000000-%';
delete from public.profiles where id::text like 'a8000000-%';
delete from auth.users where id::text like 'a8000000-%';

\echo '=== 81_regulars_first: 全項目OK ==='
