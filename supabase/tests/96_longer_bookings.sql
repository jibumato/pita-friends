-- 30分刻み・最長4時間の予約(0041)の検証。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f0000000-0000-0000-0000-0000000000a1'::uuid),
  ('f0000000-0000-0000-0000-0000000000b1'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('f0000000-0000-0000-0000-0000000000a1'::uuid, '長時間メイト'),
  ('f0000000-0000-0000-0000-0000000000b1'::uuid, '長時間ゲスト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f0000000-0000-0000-0000-0000000000a1'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('f0000000-0000-0000-0000-0000000000a1'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000, trial_discount_percent = 0;
-- 0044でコインロットは削除保護がかかっているため、明示的に解除して掃除する
set app.ledger_override = 'on';
delete from public.coin_lots where user_id = 'f0000000-0000-0000-0000-0000000000b1'::uuid;
reset app.ledger_override;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('f0000000-0000-0000-0000-0000000000b1'::uuid, 'paid', 50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id = 'f0000000-0000-0000-0000-0000000000b1'::uuid;

set test.uid = 'f0000000-0000-0000-0000-0000000000b1';

\echo '=== 1. 90分(旧3択に無かった長さ)が予約できる ==='
do $$
declare v_id uuid; b public.bookings;
begin
  v_id := public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 90, 'v2',
    date_trunc('hour', now()) + interval '1 day');
  select * into b from public.bookings where id = v_id;
  if b.duration_minutes <> 90 then raise exception 'FAIL 90分になっていない: %', b.duration_minutes; end if;
  -- 時給1000 → 90分は1500コイン
  if b.coins <> 1500 then raise exception 'FAIL 90分の料金が1500でない: %', b.coins; end if;
  raise notice 'OK 90分 = 1500コインで予約できた';
end $$;

\echo '=== 2. 上限の240分まで予約できる ==='
do $$
declare v_id uuid;
begin
  v_id := public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 240, 'v2',
    date_trunc('hour', now()) + interval '2 days');
  raise notice 'OK 240分(4時間)も予約できた';
end $$;

\echo '=== 3. 上限超え・刻み外・短すぎは弾く ==='
do $$
begin
  begin
    perform public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 270, 'v2', null);
    raise exception 'FAIL 270分(上限超え)が通ってしまった';
  exception when others then
    if sqlerrm <> 'INVALID_DURATION' then raise; end if;
    raise notice 'OK 上限超えは INVALID_DURATION';
  end;
  begin
    perform public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 45, 'v2', null);
    raise exception 'FAIL 45分(30の倍数でない)が通ってしまった';
  exception when others then
    if sqlerrm <> 'INVALID_DURATION' then raise; end if;
    raise notice 'OK 30分刻みでないものは INVALID_DURATION';
  end;
  begin
    perform public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 0, 'v2', null);
    raise exception 'FAIL 0分が通ってしまった';
  exception when others then
    if sqlerrm <> 'INVALID_DURATION' then raise; end if;
    raise notice 'OK 0分は INVALID_DURATION';
  end;
end $$;

\echo '=== 4. 予約できる先が14日に延びている(8日先が通り、15日先は弾かれる) ==='
do $$
begin
  perform public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2', now() + interval '8 days');
  raise notice 'OK 8日先が予約できた(旧7日上限では弾かれていた)';
  begin
    -- 上限は platform_pricing から読む(0061で14→35に延ばした)。数字を直に
    -- 書くと、上限を変えるたびにここが落ちて「壊れた」ように見える。
    perform public.create_booking('f0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2',
      now() + make_interval(days => (select max_lead_days + 1 from public.platform_pricing where id = 1)));
    raise exception 'FAIL 上限より先が通ってしまった';
  exception when others then
    if sqlerrm <> 'START_TOO_FAR' then raise; end if;
    raise notice 'OK 上限より先は START_TOO_FAR';
  end;
end $$;
