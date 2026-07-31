-- ============================================================
-- 13: ゲスト無帰責の返還で消滅した分の金銭返金(0085・G8)
-- ------------------------------------------------------------
-- 規約 第9条5の3。弁護士が「消費者契約法10条無効の典型的な標的」と
-- 名指しした条項なので、**動くことより、動かないときに気づけることが重要**。
--
-- ここで固定するのは5つ:
--   ・ピタメイト都合の返還で期限切れが出たら、返金債務が立つこと
--   ・**ゲスト都合では立たないこと**(誰にでも返金するのは条文と違う)
--   ・期限内に戻せた場合は債務が立たないこと(二重取りを作らない)
--   ・1コイン=1円の前提が崩れていないこと
--   ・運営以外が台帳を触れないこと
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d1000000-0000-0000-0000-000000000001'),
  ('d1000000-0000-0000-0000-000000000002'),
  ('d1000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('d1000000-0000-0000-0000-000000000001','ゲスト'),
  ('d1000000-0000-0000-0000-000000000002','ピタメイト'),
  ('d1000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'd1000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('d1000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.admins (user_id) values ('d1000000-0000-0000-0000-000000000009');

-- ------------------------------------------------------------
\echo '=== 1. 1コイン=1円の前提(これが崩れると返金額の計算が狂う) ==='
-- 0085 は「消滅した有償コインの数 = 円」で債務を立てる。
-- 割引パックを作った瞬間にこの前提は崩れるので、ここで止める
do $$
declare v_n int;
begin
  select count(*) into v_n from public.coin_packs
   where active and price_yen <> coins;
  if v_n > 0 then
    raise exception
      'FAIL: coins <> price_yen のパックが%件ある。0085の返金額(1コイン=1円)を見直すこと', v_n;
  end if;
  raise notice 'OK: 有効なパックはすべて coins = price_yen';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. ピタメイト都合のキャンセルで、消滅分の返金債務が立つこと ==='
insert into public.coin_lots (user_id, kind, remaining, expires_at, created_at)
values ('d1000000-0000-0000-0000-000000000001','paid', 2000,
        now() + interval '2 hours', now() - interval '5 months');
update public.coin_wallets set balance = 2000
  where user_id = 'd1000000-0000-0000-0000-000000000001';

set test.uid = 'd1000000-0000-0000-0000-000000000001';
select public.create_booking('d1000000-0000-0000-0000-000000000002', 60) as bk \gset

-- 返還までの間に期限が過ぎた状況を作る(0044の台帳を明示的に解除)
set app.ledger_override = 'on';
update public.coin_lot_consumptions set expires_at = now() - interval '1 hour'
  where booking_id = :'bk';
reset app.ledger_override;

set test.uid = 'd1000000-0000-0000-0000-000000000002';
select public.decline_booking(:'bk');

do $$
declare v_coins int; v_yen int; v_cause text; v_status text; v_n int;
begin
  select count(*) into v_n from public.cash_refunds
   where user_id = 'd1000000-0000-0000-0000-000000000001';
  if v_n <> 1 then
    raise exception 'FAIL: 返金債務が%件(期待1件)。第9条5の3が働いていない', v_n;
  end if;

  select coins, amount_yen, cause, status into v_coins, v_yen, v_cause, v_status
  from public.cash_refunds where user_id = 'd1000000-0000-0000-0000-000000000001';

  if v_coins <> 1000 then raise exception 'FAIL: 消滅数が合わない(%)', v_coins; end if;
  if v_yen <> 1000 then raise exception 'FAIL: 返金額が合わない(%)', v_yen; end if;
  if v_cause <> 'host_fault' then raise exception 'FAIL: 事由が違う(%)', v_cause; end if;
  if v_status <> 'pending' then
    raise exception 'FAIL: いきなり支払済みになっている(%)。金銭の払い出しは人が実行すること', v_status;
  end if;
  raise notice 'OK: %コイン → %円 の返金債務が pending で立つ', v_coins, v_yen;
end $$;

\echo '--- 利用者に通知が届いているか(黙って債務だけ立てない) ---'
do $$
declare v_n int;
begin
  select count(*) into v_n from public.notifications
   where user_id = 'd1000000-0000-0000-0000-000000000001'
     and body like '%返金します%';
  if v_n < 1 then raise exception 'FAIL: 返金の通知が無い'; end if;
  raise notice 'OK: 返金する旨を通知している';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. ゲスト都合のキャンセルでは債務が立たないこと ==='
-- **ここが緩むと、期限切れコインを持つ人が自分でキャンセルして
--   現金を引き出せることになる。**
insert into public.coin_lots (user_id, kind, remaining, expires_at, created_at)
values ('d1000000-0000-0000-0000-000000000001','paid', 2000,
        now() + interval '2 hours', now() - interval '5 months');
update public.coin_wallets set balance = balance + 2000
  where user_id = 'd1000000-0000-0000-0000-000000000001';

set test.uid = 'd1000000-0000-0000-0000-000000000001';
select public.create_booking('d1000000-0000-0000-0000-000000000002', 60) as bk2 \gset
set app.ledger_override = 'on';
update public.coin_lot_consumptions set expires_at = now() - interval '1 hour'
  where booking_id = :'bk2';
reset app.ledger_override;

-- ゲスト自身が承諾前に取り消す
select public.cancel_booking(:'bk2', 'やめました');

do $$
declare v_n int;
begin
  select count(*) into v_n from public.cash_refunds
   where booking_id = (select id from public.bookings
                        where status = 'cancelled_by_guest'
                          and guest_id = 'd1000000-0000-0000-0000-000000000001'
                        order by cancelled_at desc limit 1);
  if v_n > 0 then
    raise exception 'FAIL: ゲスト都合なのに返金債務が立った(%件)', v_n;
  end if;
  raise notice 'OK: ゲスト都合では金銭返金しない';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 期限内に戻せた場合は債務が立たないこと ==='
-- コインが戻っているのに現金も出すと二重取りになる
insert into public.coin_lots (user_id, kind, remaining, expires_at, created_at)
values ('d1000000-0000-0000-0000-000000000001','paid', 2000,
        now() + interval '30 days', now());
update public.coin_wallets set balance = balance + 2000
  where user_id = 'd1000000-0000-0000-0000-000000000001';

set test.uid = 'd1000000-0000-0000-0000-000000000001';
select public.create_booking('d1000000-0000-0000-0000-000000000002', 60) as bk3 \gset
set test.uid = 'd1000000-0000-0000-0000-000000000002';
select public.decline_booking(:'bk3');

do $$
declare v_n int;
begin
  select count(*) into v_n from public.cash_refunds where booking_id = (
    select id from public.bookings where guest_id = 'd1000000-0000-0000-0000-000000000001'
     order by created_at desc limit 1);
  if v_n > 0 then
    raise exception 'FAIL: コインが戻っているのに返金債務まで立った(二重取り)';
  end if;
  raise notice 'OK: 期限内に戻せたときは債務を立てない';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 運営だけが解決でき、理由なしには断れないこと ==='
set test.uid = 'd1000000-0000-0000-0000-000000000009';
do $$
declare v_id uuid; v_n int;
begin
  select id into v_id from public.cash_refunds where status = 'pending' limit 1;

  -- 理由なしの却下は通さない
  begin
    perform public.admin_resolve_cash_refund(v_id, 'rejected', null);
    raise exception 'FAIL: 理由なしで却下できてしまった';
  exception when others then
    if sqlerrm <> 'NOTE_REQUIRED' then raise; end if;
  end;

  -- 支払済みにする
  perform public.admin_resolve_cash_refund(v_id, 'paid', '2026-08-05 振込');
  select count(*) into v_n from public.cash_refunds
   where id = v_id and status = 'paid' and resolved_at is not null;
  if v_n <> 1 then raise exception 'FAIL: 支払済みにできない'; end if;

  -- 二度目は通らない(二重払いの防止)
  begin
    perform public.admin_resolve_cash_refund(v_id, 'paid', 'もう一度');
    raise exception 'FAIL: 同じ返金を二度支払済みにできてしまった';
  exception when others then
    if sqlerrm <> 'NOT_PENDING' then raise; end if;
  end;

  -- 操作が記録されているか(0068)
  select count(*) into v_n from public.admin_actions
   where kind = 'resolve_cash_refund' and target_id = v_id;
  if v_n < 1 then raise exception 'FAIL: 管理操作が記録されていない'; end if;
  raise notice 'OK: 運営のみ / 理由必須 / 二重払い不可 / 記録あり';
end $$;

\echo '--- 一般ユーザーは解決できないこと ---'
set test.uid = 'd1000000-0000-0000-0000-000000000001';
do $$
declare v_id uuid;
begin
  select id into v_id from public.cash_refunds limit 1;
  begin
    perform public.admin_resolve_cash_refund(v_id, 'paid', 'なりすまし');
    raise exception 'FAIL: 一般ユーザーが返金を支払済みにできてしまった';
  exception when others then
    if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  end;
  raise notice 'OK: NOT_ADMIN で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 台帳が本人と運営にしか見えないこと ==='
do $$
declare v_n int;
begin
  if not (select relrowsecurity from pg_class where oid = 'public.cash_refunds'::regclass) then
    raise exception 'FAIL: cash_refunds のRLSが無効';
  end if;
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'cash_refunds' and cmd = 'SELECT';
  if v_n < 2 then raise exception 'FAIL: 参照ポリシーが足りない(%)', v_n; end if;
  -- 書き込みポリシーは**作らない**。台帳を触れるのは関数だけ
  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'cash_refunds' and cmd <> 'SELECT';
  if v_n > 0 then
    raise exception 'FAIL: 書き込みポリシーがある(%件)。台帳は関数経由だけにすること', v_n;
  end if;
  raise notice 'OK: RLS有効 / 参照のみ / 書き込みは関数経由';
end $$;

\echo '=== 13: 金銭返金(第9条5の3) すべて通過 ==='
