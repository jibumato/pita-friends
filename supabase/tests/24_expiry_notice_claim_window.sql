-- ============================================================
-- 24: 失効の事前通知・期限の表示(G7)と、申出の期間制限(G9)
-- ------------------------------------------------------------
-- 規約 第7条5の3 / 第9条4項。どちらも「利用者に不利な仕組みを、
-- 気づける形にする」ための条項なので、**通知が出ないこと**と
-- **期限を過ぎても受けてしまうこと**の両方を落とす。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('b3000000-0000-0000-0000-000000000001'),
  ('b3000000-0000-0000-0000-000000000002'),
  ('b3000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('b3000000-0000-0000-0000-000000000001','ゲスト'),
  ('b3000000-0000-0000-0000-000000000002','ピタメイト'),
  ('b3000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('b3000000-0000-0000-0000-000000000001',
                    'b3000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('b3000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.admins (user_id) values ('b3000000-0000-0000-0000-000000000009');

-- ------------------------------------------------------------
\echo '=== 1. 残高と有効期限を、期限ごとに出せること(第7条5の3 後段) ==='
-- **合計だけでは足りない。**「いつ何枚消えるか」が分からないと
-- 使い切る判断ができない
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('b3000000-0000-0000-0000-000000000001','paid', 1000, now() + interval '5 days'),
  ('b3000000-0000-0000-0000-000000000001','paid',  500, now() + interval '5 days'),
  ('b3000000-0000-0000-0000-000000000001','paid', 3000, now() + interval '100 days');
update public.coin_wallets set balance = 4500
  where user_id = 'b3000000-0000-0000-0000-000000000001';

set test.uid = 'b3000000-0000-0000-0000-000000000001';
do $$
declare v_n int; v_first int;
begin
  select count(*) into v_n from public.my_coin_expiry();
  if v_n <> 2 then
    raise exception 'FAIL: 期限ごとにまとまっていない(%行)', v_n;
  end if;
  select coins into v_first from public.my_coin_expiry() order by expires_at limit 1;
  if v_first <> 1500 then
    raise exception 'FAIL: 同じ期限のロットが合算されていない(%)', v_first;
  end if;
  raise notice 'OK: 期限ごとに2行。直近は%枚', v_first;
end $$;

\echo '--- 他人の残高は見えないこと ---'
set test.uid = 'b3000000-0000-0000-0000-000000000002';
do $$
declare v_n int;
begin
  select count(*) into v_n from public.my_coin_expiry();
  if v_n <> 0 then raise exception 'FAIL: 他人のコインが見えている(%行)', v_n; end if;
  raise notice 'OK: 自分の分だけ';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 期限が近いコインを事前に通知すること(第7条5の3 前段) ==='
do $$
declare v_n int; v_notif int;
begin
  v_n := public.notify_expiring_coins();
  if v_n <> 1 then
    raise exception 'FAIL: 通知が%件(期待1件。同じ期限はまとめて1通)', v_n;
  end if;

  select count(*) into v_notif from public.notifications
   where user_id = 'b3000000-0000-0000-0000-000000000001'
     and title like '%有効期限が近づいて%';
  if v_notif <> 1 then raise exception 'FAIL: 通知が届いていない(%)', v_notif; end if;

  -- **残高は1枚も動かさない。** 失効そのものは expire_coins() の仕事
  if (select balance from public.coin_wallets
       where user_id = 'b3000000-0000-0000-0000-000000000001') <> 4500 then
    raise exception 'FAIL: 通知の処理が残高を動かした';
  end if;
  raise notice 'OK: 1通だけ送り、残高は動かさない';
end $$;

\echo '--- 同じロットを二度通知しないこと ---'
do $$
declare v_n int;
begin
  v_n := public.notify_expiring_coins();
  if v_n <> 0 then raise exception 'FAIL: 同じロットを二度通知した(%)', v_n; end if;
  raise notice 'OK: 通知済みは飛ばす';
end $$;

\echo '--- まだ先のコインは通知しないこと ---'
do $$
declare v_n int;
begin
  select count(*) into v_n from public.coin_lots
   where user_id = 'b3000000-0000-0000-0000-000000000001'
     and expires_at > now() + interval '90 days'
     and expiry_notified_at is not null;
  if v_n > 0 then
    raise exception 'FAIL: 100日先のコインまで通知した(早すぎる通知は無視される)';
  end if;
  raise notice 'OK: 期限が近いものだけ';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 申出は完了確定から14日以内に限ること(第9条4項・G9) ==='
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('b3000000-0000-0000-0000-000000000001','paid', 5000, now() + interval '100 days');
update public.coin_wallets set balance = balance + 5000
  where user_id = 'b3000000-0000-0000-0000-000000000001';

set test.uid = 'b3000000-0000-0000-0000-000000000001';
select public.create_booking('b3000000-0000-0000-0000-000000000002', 60) as bk \gset
set test.uid = 'b3000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
create temporary table _bk as select :'bk'::uuid as id;

set test.uid = 'b3000000-0000-0000-0000-000000000009';

\echo '--- 確定前はいつでも受けられること ---'
do $$
declare v jsonb;
begin
  v := public.claim_window_status((select id from _bk));
  if (v->>'can_accept')::boolean is not true then
    raise exception 'FAIL: 確定前なのに受けられない(%)', v;
  end if;
  if v->>'confirmed_at' is not null then
    raise exception 'FAIL: まだ確定していないのに確定日がある(%)', v;
  end if;
  raise notice 'OK: 確定前は期限が始まっていない';
end $$;

-- 完了を確定させる
set test.uid = 'b3000000-0000-0000-0000-000000000001';
select public.complete_booking((select id from _bk));
set test.uid = 'b3000000-0000-0000-0000-000000000009';

\echo '--- 確定直後は受けられること ---'
do $$
declare v jsonb;
begin
  v := public.claim_window_status((select id from _bk));
  if (v->>'can_accept')::boolean is not true then
    raise exception 'FAIL: 確定直後なのに受けられない(%)', v;
  end if;
  if (v->>'window_days')::int <> 14 then
    raise exception 'FAIL: 期間が14日でない(%)', v;
  end if;
  if v->>'deadline' is null then
    raise exception 'FAIL: 期限を返していない(押す前に分からない)';
  end if;
  raise notice 'OK: 期限は%まで', v->>'deadline';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 14日を過ぎたら受けられないこと ==='
-- **期限が無いと、振込まで済んだ後から申出が来る。**
-- 控除できるのは未払の報酬だけなので、救済のしようがない場面ができる
do $$
begin
  -- 確定を15日前にずらす(台帳は追記専用なので明示的に解除)
  set local app.ledger_override = 'on';
  update public.coin_transactions
    set created_at = now() - interval '15 days'
    where related_booking_id = (select id from _bk) and type = 'booking_earned';
end $$;

do $$
declare v jsonb;
begin
  v := public.claim_window_status((select id from _bk));
  if (v->>'can_accept')::boolean is not false then
    raise exception 'FAIL: 15日経っているのに受けられることになっている(%)', v;
  end if;

  begin
    perform public.hold_booking((select id from _bk), 'claim');
    raise exception 'FAIL: 期限を過ぎた申出で保留できてしまった';
  exception when others then
    if sqlerrm <> 'CLAIM_WINDOW_CLOSED' then raise; end if;
  end;
  raise notice 'OK: CLAIM_WINDOW_CLOSED で止まり、押す前にも分かる';
end $$;

\echo '--- 運営の職権(manual)は期間の制限を受けないこと ---'
-- 利用者からの申出とは別物。**不正の調査まで14日で切れると困る**
do $$
begin
  perform public.hold_booking((select id from _bk), 'manual');
  raise notice 'OK: manual は通る';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 一般ユーザーは申出の可否を調べられないこと ==='
do $$
begin
  if has_function_privilege('anon', 'public.claim_window_status(uuid)', 'execute') then
    raise exception 'FAIL: 未ログインが claim_window_status を呼べる';
  end if;
  if not has_function_privilege('authenticated', 'public.my_coin_expiry()', 'execute') then
    raise exception 'FAIL: 本人が残高と期限を見られない';
  end if;
  if has_function_privilege('anon', 'public.notify_expiring_coins()', 'execute') then
    raise exception 'FAIL: 未ログインが通知処理を叩ける';
  end if;
  raise notice 'OK: 権限は閉じている';
end $$;

set test.uid = 'b3000000-0000-0000-0000-000000000001';
do $$
begin
  perform public.claim_window_status((select id from _bk));
  raise exception 'FAIL: 一般ユーザーが運営用の判定を呼べた';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK: NOT_ADMIN で止まる';
end $$;

\echo '=== 24: 失効の事前通知と申出の期間制限 すべて通過 ==='
