-- 自動確定の短縮(0062)の検証。
--
-- 重点は**ゲストの権利を勝手に削っていないこと**。
-- 72時間はゲストが申し出(0042の保留)を出す窓でもある。短くできるのは
-- ゲスト本人だけで、いつでも外せて、保留は従来どおり優先される。
-- ピタメイト側から設定も参照もできないことも確かめる。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('e2000000-0000-0000-0000-000000000001'::uuid),  -- 常連のゲスト
  ('e2000000-0000-0000-0000-000000000002'::uuid),  -- 初めてのゲスト
  ('e2000000-0000-0000-0000-000000000009'::uuid)   -- ピタメイト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('e2000000-0000-0000-0000-000000000001'::uuid, '常連ゲスト'),
  ('e2000000-0000-0000-0000-000000000002'::uuid, '初回ゲスト'),
  ('e2000000-0000-0000-0000-000000000009'::uuid, '早期メイト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'e2000000-0000-0000-0000-000000000009'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate)
  values ('e2000000-0000-0000-0000-000000000009'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true;
insert into public.coin_wallets (user_id, balance) values
  ('e2000000-0000-0000-0000-000000000001'::uuid, 0),
  ('e2000000-0000-0000-0000-000000000009'::uuid, 0)
  on conflict (user_id) do update set balance = excluded.balance;

-- 常連は3回遊んでいる
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select 'e2000000-0000-0000-0000-000000000001'::uuid, 'e2000000-0000-0000-0000-000000000009'::uuid,
       60, 1000, 'completed', now() - (i || ' days')::interval, now() - (i || ' days')::interval
from generate_series(10, 12) i;
reset app.ledger_override;

\echo '=== 1. 3回未満の相手には設定できない ==='
set test.uid = 'e2000000-0000-0000-0000-000000000002';
do $$
begin
  begin
    perform public.set_fast_release('e2000000-0000-0000-0000-000000000009'::uuid, 24);
    raise exception 'FAIL: 初めての相手に設定できてしまった';
  exception when others then
    if sqlerrm not like '%NOT_ENOUGH_PLAYS%' then raise; end if;
  end;
  if (public.my_fast_release('e2000000-0000-0000-0000-000000000009'::uuid)->>'eligible')::boolean then
    raise exception 'FAIL: 設定できない相手が eligible になっている';
  end if;
end $$;

\echo '=== 2. 3回以上遊んだ相手には設定できる ==='
set test.uid = 'e2000000-0000-0000-0000-000000000001';
do $$
declare v jsonb;
begin
  perform public.set_fast_release('e2000000-0000-0000-0000-000000000009'::uuid, 24);
  v := public.my_fast_release('e2000000-0000-0000-0000-000000000009'::uuid);
  if (v->>'hours')::int <> 24 then raise exception 'FAIL: 保存されていない: %', v; end if;
  if not (v->>'eligible')::boolean then raise exception 'FAIL: eligible が false'; end if;
end $$;

\echo '=== 3. 24時間未満は認めない(前払いして取り返せないのと区別がつかなくなる) ==='
do $$
begin
  begin
    perform public.set_fast_release('e2000000-0000-0000-0000-000000000009'::uuid, 1);
    raise exception 'FAIL: 1時間が通った';
  exception when others then
    if sqlerrm not like '%FAST_RELEASE_TOO_SHORT%' then raise; end if;
  end;
  -- 0時間も同じ
  begin
    perform public.set_fast_release('e2000000-0000-0000-0000-000000000009'::uuid, 0);
    raise exception 'FAIL: 0時間が通った';
  exception when others then
    if sqlerrm not like '%FAST_RELEASE_TOO_SHORT%' then raise; end if;
  end;
end $$;

\echo '=== 4. 設定どおりに早く確定する ==='
-- 終了から30時間経った予約(既定72時間ならまだ確定しない)
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
values ('e2000000-0000-0000-0000-000000000001'::uuid, 'e2000000-0000-0000-0000-000000000009'::uuid,
        60, 1000, 'confirmed', now() - interval '31 hours', now() - interval '31 hours');
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
values ('e2000000-0000-0000-0000-000000000002'::uuid, 'e2000000-0000-0000-0000-000000000009'::uuid,
        60, 1000, 'confirmed', now() - interval '31 hours', now() - interval '31 hours');
reset app.ledger_override;
do $$
declare v_n int;
begin
  v_n := public.auto_complete_bookings();
  -- 設定した常連の分だけが確定する。設定していない初回ゲストの分は残る
  if (select status from public.bookings
      where guest_id = 'e2000000-0000-0000-0000-000000000001'::uuid
        and status <> 'completed' and scheduled_at > now() - interval '2 days') is not null then
    raise exception 'FAIL: 設定した相手の予約が確定していない';
  end if;
  if (select status from public.bookings
      where guest_id = 'e2000000-0000-0000-0000-000000000002'::uuid) <> 'confirmed' then
    raise exception 'FAIL: 設定していないゲストの分まで確定した';
  end if;
end $$;

\echo '=== 5. 保留(通報・申し出)は短縮より優先される ==='
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at, held_at)
values ('e2000000-0000-0000-0000-000000000001'::uuid, 'e2000000-0000-0000-0000-000000000009'::uuid,
        60, 1000, 'confirmed', now() - interval '40 hours', now() - interval '40 hours', now());
reset app.ledger_override;
do $$
begin
  perform public.auto_complete_bookings();
  if (select status from public.bookings
      where guest_id = 'e2000000-0000-0000-0000-000000000001'::uuid and held_at is not null) <> 'confirmed' then
    raise exception 'FAIL: 保留中なのに確定した';
  end if;
end $$;

\echo '=== 6. 外すと既定(72時間)に戻る。保存済みの予約にも効く ==='
-- 設定を外してから、終了から40時間の予約が確定しないことを見る
-- (保留中の行は追記専用なので、片付けるときだけ例外を宣言する)
set app.ledger_override = 'on';
delete from public.bookings where held_at is not null and guest_id::text like 'e2000000-%';
reset app.ledger_override;
select public.set_fast_release('e2000000-0000-0000-0000-000000000009'::uuid, null);
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
values ('e2000000-0000-0000-0000-000000000001'::uuid, 'e2000000-0000-0000-0000-000000000009'::uuid,
        60, 1000, 'confirmed', now() - interval '41 hours', now() - interval '41 hours');
reset app.ledger_override;
do $$
begin
  perform public.auto_complete_bookings();
  if (select count(*) from public.bookings
      where guest_id = 'e2000000-0000-0000-0000-000000000001'::uuid
        and status = 'confirmed') <> 1 then
    raise exception 'FAIL: 外したのに確定した(既定72時間に戻っていない)';
  end if;
  if (public.my_fast_release('e2000000-0000-0000-0000-000000000009'::uuid)->>'hours') is not null then
    raise exception 'FAIL: 設定が残っている';
  end if;
end $$;

\echo '=== 7. ピタメイト側からは設定も参照もできない ==='
do $$
declare v text;
begin
  -- ポリシーは自分(ゲスト)の行だけの3本。ホスト向けの口を作っていないこと
  select string_agg(polname, ', ' order by polname) into v
  from pg_policy where polrelid = 'public.fast_release_prefs'::regclass;
  if v is distinct from
     'fast_release_delete_own, fast_release_insert_own, fast_release_select_own' then
    raise exception 'FAIL: 想定外のポリシーがある: %', coalesce(v, '(なし)');
  end if;
  if (select pg_get_expr(polqual, polrelid) from pg_policy
      where polrelid = 'public.fast_release_prefs'::regclass
        and polname = 'fast_release_select_own') !~ 'guest_id = auth\.uid\(\)' then
    raise exception 'FAIL: selectポリシーがゲスト本人に限定されていない';
  end if;
  if not (select relrowsecurity from pg_class
          where oid = 'public.fast_release_prefs'::regclass) then
    raise exception 'FAIL: RLSが無効';
  end if;
end $$;

\echo '=== 8. 未ログインでは何もできない ==='
do $$
begin
  if has_function_privilege('anon', 'public.set_fast_release(uuid, integer)', 'execute') then
    raise exception 'FAIL: anonが設定できる';
  end if;
  if has_function_privilege('anon', 'public.my_fast_release(uuid)', 'execute') then
    raise exception 'FAIL: anonが参照できる';
  end if;
  -- 自動確定は運営(pg_cron)専用のまま
  if has_function_privilege('authenticated', 'public.auto_complete_bookings()', 'execute') then
    raise exception 'FAIL: 利用者が自動確定を叩ける';
  end if;
end $$;

reset test.uid;
set app.ledger_override = 'on';
delete from public.coin_transactions where user_id::text like 'e2000000-%';
delete from public.bookings where guest_id::text like 'e2000000-%' or host_id::text like 'e2000000-%';
reset app.ledger_override;
delete from public.fast_release_prefs where guest_id::text like 'e2000000-%';
delete from public.host_settings where user_id::text like 'e2000000-%';
delete from public.coin_wallets where user_id::text like 'e2000000-%';
delete from public.profiles where id::text like 'e2000000-%';
delete from auth.users where id::text like 'e2000000-%';

\echo '=== 77_fast_release: 全項目OK ==='
