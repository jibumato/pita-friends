-- ============================================================
-- 94: 係争中のチャージバックに紐づく報酬は換金できないこと(0077)
-- ------------------------------------------------------------
-- 税理士の第3回回答:
--   「係争中に当該取引の報酬コインが換金されて出ていくと、**回収不能が
--     確定します。ホスト全体を止めるのは過剰なので、当該チャージバックに
--     直接紐づく予約の報酬コインだけ**決着まで換金保留にできませんか。」
--
-- ⚠️ 両側を固定する。
--    止め足らず → 係争中に資金が出ていき、回収不能が確定する
--    止めすぎ   → 落ち度の無いホストの、無関係な稼ぎまで凍結してしまう
-- ============================================================
insert into auth.users (id) values
  ('f5000000-0000-0000-0000-000000000001'),  -- ゲストA(チャージバックする)
  ('f5000000-0000-0000-0000-000000000002'),  -- ピタメイト
  ('f5000000-0000-0000-0000-000000000003');  -- ゲストB(無関係)
insert into public.profiles (id, nickname) values
  ('f5000000-0000-0000-0000-000000000001','ゲストA'),
  ('f5000000-0000-0000-0000-000000000002','ピタメイト'),
  ('f5000000-0000-0000-0000-000000000003','ゲストB')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('f5000000-0000-0000-0000-000000000001',
                    'f5000000-0000-0000-0000-000000000002',
                    'f5000000-0000-0000-0000-000000000003');
insert into public.host_settings (user_id,is_host,hourly_rate) values
  ('f5000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host=true, hourly_rate=2000;
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values ('f5000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001',
        '普通','1234567','ピタメイト')
on conflict (user_id) do nothing;

-- ゲストAの購入(争われる決済)。**7日前**にしておく
insert into public.coin_purchases
  (user_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent, created_at)
values ('f5000000-0000-0000-0000-000000000001', 100000, 100000,
        'cs_A', 'pi_A', now() - interval '7 days');
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('f5000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='f5000000-0000-0000-0000-000000000001';
-- ゲストB(無関係)
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('f5000000-0000-0000-0000-000000000003','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='f5000000-0000-0000-0000-000000000003';

-- ゲストAの予約(購入より後)を完了させて、ピタメイトに報酬を付ける
set test.uid = 'f5000000-0000-0000-0000-000000000001';
select public.create_booking('f5000000-0000-0000-0000-000000000002'::uuid, 360,
         'v1', date_trunc('hour', now()) + interval '2 hours') as ba \gset
-- ゲストBの予約(無関係)
set test.uid = 'f5000000-0000-0000-0000-000000000003';
select public.create_booking('f5000000-0000-0000-0000-000000000002'::uuid, 360,
         'v1', date_trunc('hour', now()) + interval '26 hours') as bb \gset

-- 両方を過去にして完了させる
update public.bookings set scheduled_at = now() - interval '3 hours', status = 'confirmed'
  where id in (:'ba', :'bb');
set test.uid = 'f5000000-0000-0000-0000-000000000001';
select public.complete_booking(:'ba');
set test.uid = 'f5000000-0000-0000-0000-000000000003';
select public.complete_booking(:'bb');

\echo '=== 1. 前提: ピタメイトに2件分の報酬が付いている ==='
do $$
declare v_bal int; v_hold int;
begin
  select earned_balance into v_bal from public.coin_wallets
   where user_id = 'f5000000-0000-0000-0000-000000000002';
  if coalesce(v_bal,0) < 10000 then
    raise exception 'FAIL: 前提が崩れている(報酬=%)', v_bal;
  end if;
  v_hold := public._dispute_payout_hold('f5000000-0000-0000-0000-000000000002');
  if v_hold <> 0 then
    raise exception 'FAIL: 申立てが無いのに保留が立っている(%)', v_hold;
  end if;
  raise notice 'OK: 報酬=% / 保留=0', v_bal;
end $$;

\echo '=== 2. 申立てを受けると、紐づく予約の報酬**だけ**が保留になる ==='
select public.record_payment_dispute('dp_A','ch_A','pi_A', 100000, 'fraudulent', 'open');
do $$
declare v_bal int; v_hold int; v_a int;
begin
  select earned_balance into v_bal from public.coin_wallets
   where user_id = 'f5000000-0000-0000-0000-000000000002';
  v_hold := public._dispute_payout_hold('f5000000-0000-0000-0000-000000000002');

  -- ゲストAの予約から生じた報酬額
  select coalesce(sum(t.amount),0) into v_a from public.coin_transactions t
   join public.bookings b on b.id = t.related_booking_id
   where t.user_id = 'f5000000-0000-0000-0000-000000000002'
     and t.type = 'booking_earned'
     and b.guest_id = 'f5000000-0000-0000-0000-000000000001';

  if v_hold <> v_a then
    raise exception 'FAIL: 保留額%がゲストAの報酬%と一致しない', v_hold, v_a;
  end if;
  -- **止めすぎていないこと。** 無関係なゲストBの分は保留に入らない
  if v_hold >= v_bal then
    raise exception 'FAIL: 無関係な稼ぎまで保留になっている(保留% / 残高%)', v_hold, v_bal;
  end if;
  raise notice 'OK: 残高% のうち保留% (ゲストA分のみ)', v_bal, v_hold;
end $$;

\echo '=== 3. 保留を超える申請は DISPUTE_ON_HOLD で弾かれる ==='
set test.uid = 'f5000000-0000-0000-0000-000000000002';
do $$
declare v_bal int;
begin
  select earned_balance into v_bal from public.coin_wallets
   where user_id = 'f5000000-0000-0000-0000-000000000002';
  begin
    perform public.request_bank_payout(v_bal);   -- 全額の申請
    raise exception 'FAIL: 係争中なのに全額を換金できてしまった';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%DISPUTE_ON_HOLD%' then
      raise exception 'FAIL: 係争保留ではない理由で落ちた: %', sqlerrm;
    end if;
  end;
end $$;
\echo 'OK'

\echo '=== 4. 保留を除いた額なら換金できる(止めすぎていない) ==='
-- 「ホスト全体を止めるのは過剰」という指摘に応えているかの確認。
do $$
declare v_bal int; v_hold int; v_ok int; v_id uuid;
begin
  select earned_balance into v_bal from public.coin_wallets
   where user_id = 'f5000000-0000-0000-0000-000000000002';
  v_hold := public._dispute_payout_hold('f5000000-0000-0000-0000-000000000002');
  v_ok := v_bal - v_hold;
  if v_ok < 5000 then
    raise exception 'FAIL: 前提が崩れている(換金可能額%が最低額未満)', v_ok;
  end if;
  v_id := public.request_bank_payout(v_ok);
  if v_id is null then
    raise exception 'FAIL: 保留を除いた額なのに換金できない';
  end if;
  raise notice 'OK: 残高%・保留% → %を換金できた', v_bal, v_hold, v_ok;
end $$;

\echo '=== 5. 決着(won)すると保留が自動的に外れる ==='
select public.record_payment_dispute('dp_A','ch_A','pi_A', 100000, 'fraudulent', 'won');
do $$
declare v_hold int;
begin
  v_hold := public._dispute_payout_hold('f5000000-0000-0000-0000-000000000002');
  if v_hold <> 0 then
    raise exception 'FAIL: 決着したのに保留が残っている(%)', v_hold;
  end if;
end $$;
\echo 'OK'

\echo '=== 6. 争われた購入より【前】の予約は巻き込まない ==='
-- コインが混ざる以上、購入以後の予約に限るのが精一杯の絞り込み。
-- 購入より前の予約は、その購入のコインでは払えないので無関係。
insert into auth.users (id) values ('f5000000-0000-0000-0000-000000000004');
insert into public.profiles (id, nickname) values
  ('f5000000-0000-0000-0000-000000000004','ゲストC') on conflict (id) do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f5000000-0000-0000-0000-000000000004';
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('f5000000-0000-0000-0000-000000000004','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='f5000000-0000-0000-0000-000000000004';
set test.uid = 'f5000000-0000-0000-0000-000000000004';
select public.create_booking('f5000000-0000-0000-0000-000000000002'::uuid, 360,
         'v1', date_trunc('hour', now()) + interval '50 hours') as bc \gset
-- この予約を「購入より前」に作られたことにする
update public.bookings set created_at = now() - interval '30 days',
       scheduled_at = now() - interval '3 hours', status = 'confirmed'
  where id = :'bc';
select public.complete_booking(:'bc');
-- ゲストCの購入(予約より後)に対する申立て
insert into public.coin_purchases
  (user_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent, created_at)
values ('f5000000-0000-0000-0000-000000000004', 100000, 100000,
        'cs_C', 'pi_C', now() - interval '1 day');
select public.record_payment_dispute('dp_C','ch_C','pi_C', 100000, 'fraudulent', 'open');
do $$
declare v_hold int;
begin
  v_hold := public._dispute_payout_hold('f5000000-0000-0000-0000-000000000002');
  if v_hold <> 0 then
    raise exception 'FAIL: 購入より前の予約まで保留に入っている(%)', v_hold;
  end if;
end $$;
\echo 'OK'

\echo '=== 7. my_payout_hold が内訳を返す ==='
set test.uid = 'f5000000-0000-0000-0000-000000000002';
do $$
declare v jsonb;
begin
  v := public.my_payout_hold();
  if v is null then
    raise exception 'FAIL: my_payout_hold が null';
  end if;
  if (v->>'disputeHold') is null or (v->>'giftHold') is null
     or (v->>'available') is null or (v->>'earnedBalance') is null then
    raise exception 'FAIL: 内訳が欠けている: %', v;
  end if;
  if (v->>'available')::int
     <> greatest(0, (v->>'earnedBalance')::int
                    - (v->>'giftHold')::int - (v->>'disputeHold')::int) then
    raise exception 'FAIL: available が内訳と整合しない: %', v;
  end if;
end $$;
\echo 'OK'

\echo '=== 8. ギフト保留(0069)が壊れていないこと ==='
-- 0077 は 0069 の request_bank_payout を作り直している。回帰の確認。
do $$
begin
  if position('GIFT_ON_HOLD' in
       (select pg_get_functiondef(oid) from pg_proc
         where proname = 'request_bank_payout')) = 0 then
    raise exception 'FAIL: ギフト保留(GIFT_ON_HOLD)が消えている';
  end if;
  if position('interval ''7 days''' in
       (select pg_get_functiondef(oid) from pg_proc
         where proname = 'request_bank_payout')) = 0 then
    raise exception 'FAIL: 7日の保留期間が消えている';
  end if;
end $$;
\echo 'OK'

\echo '=== 94 PASS ==='
