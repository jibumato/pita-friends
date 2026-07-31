-- ============================================================
-- 97: コインの消費順序(0082)の検証  ★弁護士 第3回回答 論点4
-- ------------------------------------------------------------
-- 消費順序を「①有効期限の早い順 ②同一期限内では有償が先」に改めた。
--
-- 旧実装(有償を先に使い切る)は、複数回購入したときに
-- **期限順なら失効しなかったはずの無償コインを失効させて**いた。
-- 弁護士の指摘は消費者契約法10条よりむしろ**景品表示法の有利誤認**:
-- 「ボーナス+100」と表示して購入を誘引しながら、仕組みの側で
-- ボーナスが失効しやすいのは説明しづらい。
--
-- ここで固定するのは4つ:
--   ・弁護士が示した設例そのもの(A-有償/A-無償/B-有償)で失効が起きないこと
--   ・同一期限内では有償が先に減ること(逆にすると有償が失効しうる)
--   ・**ギフトの原資は有償のみ**という規約第7条の2の制約を壊していないこと
--   ・延長(extend_booking)にも同じ順序が効くこと
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a1000000-0000-0000-0000-000000000001'),  -- ゲスト
  ('a1000000-0000-0000-0000-000000000002');  -- ピタメイト
insert into public.profiles (id, nickname) values
  ('a1000000-0000-0000-0000-000000000001','ゲスト'),
  ('a1000000-0000-0000-0000-000000000002','ピタメイト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'a1000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a1000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- ------------------------------------------------------------
\echo '=== 1. 弁護士の設例: 期限順なら失効しないこと ==='
-- A-有償 2000(6月末) / A-無償 2000(6月末) / B-有償 2000(12月末)
-- 60分=2000コインの予約を2件。旧実装なら A-有償 → B-有償 と使い、
-- A-無償 2000 が 6月末に未使用のまま失効していた。
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('a1000000-0000-0000-0000-000000000001','paid',  2000, now() + interval '60 days'),
  ('a1000000-0000-0000-0000-000000000001','bonus', 2000, now() + interval '60 days'),
  ('a1000000-0000-0000-0000-000000000001','paid',  2000, now() + interval '200 days');
update public.coin_wallets set balance = 4000, bonus_balance = 2000
  where user_id = 'a1000000-0000-0000-0000-000000000001';

set test.uid = 'a1000000-0000-0000-0000-000000000001';
select public.create_booking('a1000000-0000-0000-0000-000000000002', 60, 'v1',
  now() + interval '2 days') as bk1 \gset
select public.create_booking('a1000000-0000-0000-0000-000000000002', 60, 'v1',
  now() + interval '5 days') as bk2 \gset

do $$
declare v_near_paid int; v_near_bonus int; v_far_paid int;
begin
  select coalesce(sum(remaining), 0) into v_near_paid from public.coin_lots
   where user_id = 'a1000000-0000-0000-0000-000000000001'
     and kind = 'paid' and expires_at < now() + interval '100 days';
  select coalesce(sum(remaining), 0) into v_near_bonus from public.coin_lots
   where user_id = 'a1000000-0000-0000-0000-000000000001'
     and kind = 'bonus' and expires_at < now() + interval '100 days';
  select coalesce(sum(remaining), 0) into v_far_paid from public.coin_lots
   where user_id = 'a1000000-0000-0000-0000-000000000001'
     and kind = 'paid' and expires_at > now() + interval '100 days';

  -- 期限の近い2ロット(有償2000+無償2000)がちょうど使い切られ、
  -- 期限の遠いロットは手つかずで残っているのが正解
  if v_near_paid <> 0 or v_near_bonus <> 0 then
    raise exception 'FAIL: 期限の近いロットが残っている(有償%/無償%)。旧順序のままでは無償が残って失効する',
      v_near_paid, v_near_bonus;
  end if;
  if v_far_paid <> 2000 then
    raise exception 'FAIL: 期限の遠い有償ロットが使われた(残%)。期限順になっていない', v_far_paid;
  end if;
  raise notice 'OK: 期限の近いロットから使い切り、遠いロット%が残った(失効ゼロ)', v_far_paid;
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 同一期限内では有償が先に減ること ==='
-- 逆(無償が先)にすると、使い切れなかったときに**有償分が失効する**
do $$
declare v_paid_used int; v_bonus_used int;
begin
  -- 1件目の予約(2000コイン)は、同一期限の有償2000だけで賄えるはず
  select b.paid_coins, b.bonus_coins into v_paid_used, v_bonus_used
  from public.bookings b
  where b.guest_id = 'a1000000-0000-0000-0000-000000000001'
  order by b.created_at limit 1;

  if v_paid_used <> 2000 or v_bonus_used <> 0 then
    raise exception 'FAIL: 同一期限で有償が先になっていない(有償%/無償%)', v_paid_used, v_bonus_used;
  end if;
  raise notice 'OK: 1件目は有償%のみ。無償は同一期限でも後回し', v_paid_used;
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 内訳が帳簿と一致すること(paid_coins/bonus_coins の合計) ==='
do $$
declare v_sum_paid int; v_sum_bonus int;
begin
  select coalesce(sum(paid_coins), 0), coalesce(sum(bonus_coins), 0)
    into v_sum_paid, v_sum_bonus
  from public.bookings where guest_id = 'a1000000-0000-0000-0000-000000000001';

  -- 2件で4000コイン。期限の近い有償2000と無償2000から出ている
  if v_sum_paid <> 2000 or v_sum_bonus <> 2000 then
    raise exception 'FAIL: 内訳が合わない(有償%/無償% 期待2000/2000)', v_sum_paid, v_sum_bonus;
  end if;
  raise notice 'OK: 有償%+無償%=4000。予約の記録とロットの減りが一致', v_sum_paid, v_sum_bonus;
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 延長にも同じ順序が効くこと ==='
-- 残りは「期限の遠い有償2000」だけ。延長で使われることを確認する
set test.uid = 'a1000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk1');
set test.uid = 'a1000000-0000-0000-0000-000000000001';
select public.extend_booking(:'bk1', 30);

do $$
declare v_paid int; v_bonus int; v_far int;
begin
  select b.paid_coins, b.bonus_coins into v_paid, v_bonus
  from public.bookings b where b.id = (
    select id from public.bookings
     where guest_id = 'a1000000-0000-0000-0000-000000000001'
     order by created_at limit 1);
  select coalesce(sum(remaining), 0) into v_far from public.coin_lots
   where user_id = 'a1000000-0000-0000-0000-000000000001'
     and expires_at > now() + interval '100 days';

  -- 30分=1000コインが、残っていた遠い有償ロットから出る
  if v_paid <> 3000 or v_bonus <> 0 then
    raise exception 'FAIL: 延長分の内訳が合わない(有償%/無償%)', v_paid, v_bonus;
  end if;
  if v_far <> 1000 then
    raise exception 'FAIL: 遠いロットの残が合わない(期待1000 / 実際%)', v_far;
  end if;
  raise notice 'OK: 延長も期限順で充当(有償計% / 遠いロットの残%)', v_paid, v_far;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. ギフトの原資は有償のみ、という制約を壊していないこと ==='
-- 規約 第7条の2。0082 は充当の内訳を変えただけで、
-- send_gift は従来どおり有償ロットしか消費しない
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc
  where proname = 'send_gift'
    and prosrc like '%_consume_coin_lots(%''paid''%';
  if v_n = 0 then
    raise exception 'FAIL: send_gift が有償限定でコインを消費していない(規約第7条の2に違反)';
  end if;
  select count(*) into v_n from pg_proc
  where proname = 'send_gift' and prosrc like '%''bonus''%';
  if v_n > 0 then
    raise exception 'FAIL: send_gift が無償コインに触れている';
  end if;
  raise notice 'OK: ギフトの原資は有償のみのまま';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. ロットの記録が無い利用者でも落ちないこと ==='
-- 0030 より前に付与された残高など。残高の判定は呼び出し側で済んでいるので、
-- ここで例外にすると「残高はあるのに予約できない」状態になる
do $$
declare v_paid int; v_bonus int;
begin
  select s.paid, s.bonus into v_paid, v_bonus
  from public._split_coins_by_expiry('a1000000-0000-0000-0000-000000000002', 500) s;
  if v_paid <> 500 or v_bonus <> 0 then
    raise exception 'FAIL: ロットが無いとき有償に寄せていない(有償%/無償%)', v_paid, v_bonus;
  end if;
  raise notice 'OK: ロットの記録が無くても例外にせず、有償%に寄せる', v_paid;
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 期限切れのロットを充当に数えないこと ==='
do $$
declare v_paid int; v_bonus int;
begin
  insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('a1000000-0000-0000-0000-000000000002','paid', 9999, now() - interval '1 day');

  select s.paid, s.bonus into v_paid, v_bonus
  from public._split_coins_by_expiry('a1000000-0000-0000-0000-000000000002', 500) s;
  -- 期限切れロットは無視され、6と同じく有償に寄る
  if v_paid <> 500 or v_bonus <> 0 then
    raise exception 'FAIL: 期限切れロットを充当に数えた(有償%/無償%)', v_paid, v_bonus;
  end if;
  raise notice 'OK: 期限切れロットは充当に数えない';
end $$;

-- ------------------------------------------------------------
\echo '=== 8. 計算だけで、消費はしないこと ==='
do $$
declare v_before bigint; v_after bigint;
begin
  select coalesce(sum(remaining), 0) into v_before from public.coin_lots;
  perform * from public._split_coins_by_expiry('a1000000-0000-0000-0000-000000000001', 100);
  select coalesce(sum(remaining), 0) into v_after from public.coin_lots;
  if v_before <> v_after then
    raise exception 'FAIL: _split_coins_by_expiry がロットを減らした(%→%)', v_before, v_after;
  end if;
  raise notice 'OK: 呼んでもロットは動かない(残 %)', v_after;
end $$;

\echo '=== 97: コインの消費順序 すべて通過 ==='
