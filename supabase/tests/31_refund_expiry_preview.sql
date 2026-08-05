-- ============================================================
-- 31: キャンセル前に、戻るコインの有効期限を知らせる（0109・G18）
-- ------------------------------------------------------------
-- 規約 第9条5の2 後段:
--   「当社は、キャンセルの手続を行う画面において、**返還されるコインの
--    有効期限が近い場合はその旨を事前に表示します。**」
--
-- **条文はあったが実装が無かった**箇所（2026-08-05の横断点検 G18）。
--
-- ここで固定するのは4つ:
--   ・期限が近いコインで予約したら、見積りに soon_coins が出ること
--   ・当初の期限を過ぎていたら、lapsed_coins として「戻らない」と出ること
--   ・**ゲスト都合なら金銭返金は0**、ホスト都合なら消えた分が金銭返金になること
--   ・見積りの数字が、実際にキャンセルした結果と一致すること
--     （**表示と実際がずれるのが一番まずい**ので、突き合わせる）
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('31000000-0000-0000-0000-000000000001'),
  ('31000000-0000-0000-0000-000000000002');
insert into public.profiles (id, nickname) values
  ('31000000-0000-0000-0000-000000000001','ゲスト31'),
  ('31000000-0000-0000-0000-000000000002','ピタメイト31')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('31000000-0000-0000-0000-000000000001',
                    '31000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('31000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- ------------------------------------------------------------
\echo '=== 1. 期限が近いコインで予約したら、見積りに出ること ==='
-- ------------------------------------------------------------
-- 期限まであと3日のロットで払う（既定のしきい値は expiry_notice_days=14日）
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('31000000-0000-0000-0000-000000000001','paid', 4000, now() + interval '3 days');
update public.coin_wallets set balance = 4000
  where user_id = '31000000-0000-0000-0000-000000000001';

set test.uid = '31000000-0000-0000-0000-000000000001';
select public.create_booking('31000000-0000-0000-0000-000000000002', 60) as bk1 \gset

set test.uid = '31000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk1');
set test.uid = '31000000-0000-0000-0000-000000000001';

do $$
declare v jsonb;
begin
  v := public.my_booking_refund_quote(
    (select id from public.bookings
      where guest_id = '31000000-0000-0000-0000-000000000001' order by created_at desc limit 1));

  if (v->>'refund_coins')::int <> 1000 then
    raise exception 'FAIL: 承諾直後は全額戻るはず(%)', v;
  end if;
  if (v->>'soon_coins')::int <> 1000 then
    raise exception
      'FAIL: 期限が近いことを知らせていない(soon_coins=%)。第9条5の2後段の約束',
      v->>'soon_coins';
  end if;
  if (v->>'soonest_expires_at') is null then
    raise exception 'FAIL: 最も早い期限を返していない(%)', v;
  end if;
  if (v->>'lapsed_coins')::int <> 0 then
    raise exception 'FAIL: まだ期限内なのに消える扱いになっている(%)', v;
  end if;
  raise notice 'OK: 1,000コインが%日以内に期限(%)と伝えている',
    v->>'soon_days', v->>'soonest_expires_at';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 当初の期限を過ぎていたら「戻らない」と出ること ==='
-- ------------------------------------------------------------
-- **消費記録の期限を過去にする。** 実際の運用では、期限ぎりぎりのコインで
-- 先の予約を取り、開始前に期限が来た場合に起きる。
-- 時間を進められないので、0044 の追記専用の保護を明示的に外して書き換える
-- （テストのための細工であることが ledger_audit にも残る）。
begin;
set local app.ledger_override = 'on';
update public.coin_lot_consumptions set expires_at = now() - interval '1 day'
 where booking_id = (select id from public.bookings
                      where guest_id = '31000000-0000-0000-0000-000000000001'
                      order by created_at desc limit 1);
commit;

do $$
declare v jsonb;
begin
  v := public.my_booking_refund_quote(
    (select id from public.bookings
      where guest_id = '31000000-0000-0000-0000-000000000001' order by created_at desc limit 1));

  if (v->>'lapsed_coins')::int <> 1000 then
    raise exception
      'FAIL: 期限切れで戻らないことを知らせていない(lapsed=%)', v->>'lapsed_coins';
  end if;
  if (v->>'soon_coins')::int <> 0 then
    raise exception 'FAIL: 戻らない分を「期限が近い」に数えている(%)', v;
  end if;

  -- ★ゲストが押すなら、消えた分の金銭返金は**無い**（第9条5の3はゲスト無帰責のみ）
  if (v->>'cash_refund_coins')::int <> 0 then
    raise exception
      'FAIL: ゲスト都合なのに金銭返金があると伝えている(%)。これは事実と違う',
      v->>'cash_refund_coins';
  end if;
  raise notice 'OK: 1,000コインは戻らない / ゲスト都合なので金銭返金も無い';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. ホスト都合なら、消えた分が金銭返金になると出ること ==='
-- ------------------------------------------------------------
set test.uid = '31000000-0000-0000-0000-000000000002';
do $$
declare v jsonb;
begin
  v := public.my_booking_refund_quote(
    (select id from public.bookings
      where guest_id = '31000000-0000-0000-0000-000000000001' order by created_at desc limit 1));
  if (v->>'cash_refund_coins')::int <> 1000 then
    raise exception
      'FAIL: ホスト都合なのに金銭返金を伝えていない(%)。第9条5の3', v->>'cash_refund_coins';
  end if;
  raise notice 'OK: ホストが押すときは1,000円の金銭返金になると伝える';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 見積りと、実際にキャンセルした結果が一致すること ==='
-- ------------------------------------------------------------
-- **表示と実際がずれるのが一番まずい。** 割当ての規則が2か所にあるので、
-- ここで必ず突き合わせる（0109 のコメントにも書いてある）
do $$
declare
  v_bk uuid;
  v jsonb;
  v_lapsed_q int;
  v_cash_q int;
  v_lapsed_a int;
  v_cash_a int;
begin
  select id into v_bk from public.bookings
   where guest_id = '31000000-0000-0000-0000-000000000001' order by created_at desc limit 1;

  set local test.uid = '31000000-0000-0000-0000-000000000002';
  v := public.my_booking_refund_quote(v_bk);
  v_lapsed_q := (v->>'lapsed_coins')::int;
  v_cash_q := (v->>'cash_refund_coins')::int;

  perform public.cancel_booking(v_bk, 'テスト(ホスト都合)');

  select coalesce(sum(-amount), 0) into v_lapsed_a from public.coin_transactions
   where related_booking_id = v_bk and type = 'expire'
     and note like 'refund_lapsed%';
  select coalesce(sum(coins), 0) into v_cash_a from public.cash_refunds
   where booking_id = v_bk;

  if v_lapsed_q <> v_lapsed_a then
    raise exception
      'FAIL: 見積りの消滅枚数(%)と実際(%)が違う。**表示と実際がずれている**',
      v_lapsed_q, v_lapsed_a;
  end if;
  if v_cash_q <> v_cash_a then
    raise exception
      'FAIL: 見積りの金銭返金(%)と実際(%)が違う', v_cash_q, v_cash_a;
  end if;
  raise notice 'OK: 見積り(消滅% / 返金%)と実際が一致した', v_lapsed_q, v_cash_q;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 期限に余裕があるときは、余計な警告を出さないこと ==='
-- ------------------------------------------------------------
-- **出しすぎも問題。** 毎回警告が出ると、本当に危ないときに読まれなくなる。
--
-- 期限の早いロットから消費される(0082)ので、先に作った3日後のロットを
-- 空にしてからでないと、5か月後のロットは使われない
update public.coin_lots set remaining = 0
 where user_id = '31000000-0000-0000-0000-000000000001' and remaining > 0;

insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('31000000-0000-0000-0000-000000000001','paid', 4000, now() + interval '5 months');
update public.coin_wallets set balance = 4000
  where user_id = '31000000-0000-0000-0000-000000000001';

set test.uid = '31000000-0000-0000-0000-000000000001';
select public.create_booking('31000000-0000-0000-0000-000000000002', 60) as bk2 \gset
set test.uid = '31000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk2');
set test.uid = '31000000-0000-0000-0000-000000000001';

do $$
declare v jsonb;
begin
  v := public.my_booking_refund_quote(
    (select id from public.bookings
      where guest_id = '31000000-0000-0000-0000-000000000001' order by created_at desc limit 1));
  if (v->>'soon_coins')::int <> 0 or (v->>'lapsed_coins')::int <> 0 then
    raise exception 'FAIL: 5か月先の期限で警告が出ている(%)', v;
  end if;
  if (v->>'soonest_expires_at') is null then
    raise exception 'FAIL: 期限そのものは返すべき(%)', v;
  end if;
  raise notice 'OK: 余裕があるときは警告なし(期限は返す)';
end $$;

\echo '=== 31: 返還コインの期限の事前表示(第9条5の2後段) すべて通過 ==='
