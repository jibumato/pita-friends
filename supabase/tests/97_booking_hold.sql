-- 自動確定の保留(0042 / E-12)の検証。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-00000000cc01'::uuid),
  ('a0000000-0000-0000-0000-00000000cc11'::uuid),
  ('a0000000-0000-0000-0000-00000000cc99'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('a0000000-0000-0000-0000-00000000cc01'::uuid, '保留メイト'),
  ('a0000000-0000-0000-0000-00000000cc11'::uuid, '保留ゲスト'),
  ('a0000000-0000-0000-0000-00000000cc99'::uuid, '運営')
on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('a0000000-0000-0000-0000-00000000cc99'::uuid)
  on conflict do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id = 'a0000000-0000-0000-0000-00000000cc01'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a0000000-0000-0000-0000-00000000cc01'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000, trial_discount_percent = 0;
-- 0044でコインロットは削除保護がかかっているため、明示的に解除して掃除する
set app.ledger_override = 'on';
delete from public.coin_lots where user_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid;
reset app.ledger_override;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('a0000000-0000-0000-0000-00000000cc11'::uuid, 'paid', 50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid;

-- 72時間経過した予約を作るヘルパ的な流れ
\echo '=== 1. 保留していなければ72時間で自動確定する(従来どおり) ==='
set test.uid = 'a0000000-0000-0000-0000-00000000cc11';
select public.create_booking('a0000000-0000-0000-0000-00000000cc01'::uuid, 60, 'v2', null) as h1 \gset
set test.uid = 'a0000000-0000-0000-0000-00000000cc01';
select public.approve_booking(:'h1');
update public.bookings set scheduled_at = now() - interval '80 hours' where id = :'h1';

do $$
declare v_n int; v_st text;
begin
  v_n := public.auto_complete_bookings();
  select status into v_st from public.bookings where id = (select id from public.bookings
    where guest_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid order by created_at desc limit 1);
  if v_st <> 'completed' then raise exception 'FAIL 自動確定されていない: %', v_st; end if;
  raise notice 'OK 保留なしなら自動確定する(% 件)', v_n;
end $$;

\echo '=== 2. 保留していれば自動確定されない ==='
set test.uid = 'a0000000-0000-0000-0000-00000000cc11';
select public.create_booking('a0000000-0000-0000-0000-00000000cc01'::uuid, 60, 'v2', null) as h2 \gset
set test.uid = 'a0000000-0000-0000-0000-00000000cc01';
select public.approve_booking(:'h2');
update public.bookings set scheduled_at = now() - interval '80 hours' where id = :'h2';
set test.uid = 'a0000000-0000-0000-0000-00000000cc99';
select public.hold_booking(:'h2', 'claim');

do $$
declare v_st text; v_earned_before int; v_earned_after int;
begin
  select earned_balance into v_earned_before from public.coin_wallets
    where user_id = 'a0000000-0000-0000-0000-00000000cc01'::uuid;
  perform public.auto_complete_bookings();
  select status into v_st from public.bookings where id = (select id from public.bookings
    where guest_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid order by created_at desc limit 1);
  select earned_balance into v_earned_after from public.coin_wallets
    where user_id = 'a0000000-0000-0000-0000-00000000cc01'::uuid;
  if v_st <> 'confirmed' then raise exception 'FAIL 保留中なのに確定した: %', v_st; end if;
  if v_earned_after <> v_earned_before then
    raise exception 'FAIL 保留中なのに報酬が動いた(% -> %)', v_earned_before, v_earned_after;
  end if;
  raise notice 'OK 保留中は確定されず、報酬も動かない';
end $$;

\echo '=== 3. ピタメイトに保留の通知が届いている(黙って凍結しない) ==='
do $$
declare v_n int;
begin
  select count(*) into v_n from public.notifications
    where user_id = 'a0000000-0000-0000-0000-00000000cc01'::uuid
      and title like '%保留%';
  if v_n = 0 then raise exception 'FAIL 保留の通知が届いていない'; end if;
  raise notice 'OK 保留をピタメイトに通知している';
end $$;

\echo '=== 4. 管理者以外は保留・解除できない ==='
set test.uid = 'a0000000-0000-0000-0000-00000000cc11';
do $$
begin
  begin
    perform public.hold_booking('00000000-0000-0000-0000-000000000000'::uuid, 'claim');
    raise exception 'FAIL 一般ユーザーが保留できてしまった';
  exception when others then
    if sqlerrm <> 'NOT_ADMIN' then raise; end if;
    raise notice 'OK 一般ユーザーの保留は NOT_ADMIN';
  end;
end $$;

\echo '=== 5. 申し出を認めて一部返還する(50%) ==='
set test.uid = 'a0000000-0000-0000-0000-00000000cc99';
do $$
declare v_id uuid; v_bal_b int; v_bal_a int; v_earn_b int; v_earn_a int;
begin
  select id into v_id from public.bookings
    where guest_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid and held_at is not null limit 1;
  select balance into v_bal_b from public.coin_wallets where user_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid;
  select earned_balance into v_earn_b from public.coin_wallets where user_id = 'a0000000-0000-0000-0000-00000000cc01'::uuid;

  perform public.release_hold_and_refund(v_id, 50, '合流の形跡が無いため半額返還');

  select balance into v_bal_a from public.coin_wallets where user_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid;
  select earned_balance into v_earn_a from public.coin_wallets where user_id = 'a0000000-0000-0000-0000-00000000cc01'::uuid;

  -- 2000コインの予約 → 1000返還・1000がピタメイトへ
  if v_bal_a - v_bal_b <> 1000 then raise exception 'FAIL 返還が1000でない: %', v_bal_a - v_bal_b; end if;
  if v_earn_a - v_earn_b <> 1000 then raise exception 'FAIL ピタメイト取り分が1000でない: %', v_earn_a - v_earn_b; end if;
  raise notice 'OK 2000のうち1000を返還し、1000をピタメイトへ確定した';
end $$;

\echo '=== 6. 解除後は保留が外れ、再度の解除はできない ==='
do $$
declare v_id uuid; v_held timestamptz;
begin
  select id, held_at into v_id, v_held from public.bookings
    where guest_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid
      and status = 'completed' order by created_at desc limit 1;
  if v_held is not null then raise exception 'FAIL 解除後も保留が残っている'; end if;
  begin
    perform public.release_hold_and_complete(v_id);
    raise exception 'FAIL 保留していないものを解除できてしまった';
  exception when others then
    if sqlerrm <> 'NOT_HELD' then raise; end if;
    raise notice 'OK 解除後は NOT_HELD';
  end;
end $$;

\echo '=== 7. 通報も保留の引き金になる(申し出をしないゲストを救う) ==='
set test.uid = 'a0000000-0000-0000-0000-00000000cc11';
select public.create_booking('a0000000-0000-0000-0000-00000000cc01'::uuid, 60, 'v2', null) as h3 \gset
set test.uid = 'a0000000-0000-0000-0000-00000000cc01';
select public.approve_booking(:'h3');
set test.uid = 'a0000000-0000-0000-0000-00000000cc11';

insert into public.reports (reporter_id, reported_id, category, severity)
values ('a0000000-0000-0000-0000-00000000cc11'::uuid, 'a0000000-0000-0000-0000-00000000cc01'::uuid,
        'no_show', 'high');

do $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = (select id from public.bookings
    where guest_id = 'a0000000-0000-0000-0000-00000000cc11'::uuid order by created_at desc limit 1);
  if b.held_at is null then raise exception 'FAIL 通報しても保留されていない'; end if;
  if b.hold_reason <> 'report' then raise exception 'FAIL 保留理由が report でない: %', b.hold_reason; end if;
  raise notice 'OK 通報で自動的に保留された(理由=report)';
end $$;

\echo '=== 8. 保留の期限切れが一覧で分かる ==='
update public.bookings set held_at = now() - interval '20 days' where held_at is not null;
set test.uid = 'a0000000-0000-0000-0000-00000000cc99';
do $$
declare v_n int;
begin
  select count(*) into v_n from public.held_bookings_overview where is_overdue;
  if v_n = 0 then raise exception 'FAIL 期限切れの保留が一覧に出ない'; end if;
  raise notice 'OK 保留したまま期限(14日)を過ぎたものが督促対象として出る(% 件)', v_n;
end $$;
