-- 取引台帳の追記専用化(0044)の検証。
--
-- 守りたいのは「うっかり」です。管理画面から行を選んで消す、where を
-- 付け忘れた UPDATE を流す、退会処理のつもりで auth.users を消す。
-- これらが全部止まること、そして明示的に宣言したときだけ通り、
-- そのとき必ず旧値が残ることを確かめます。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('c0000000-0000-0000-0000-0000000000f1'::uuid),
  ('c0000000-0000-0000-0000-0000000000f2'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('c0000000-0000-0000-0000-0000000000f1'::uuid, '不変メイト'),
  ('c0000000-0000-0000-0000-0000000000f2'::uuid, '不変ゲスト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'c0000000-0000-0000-0000-0000000000f1'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('c0000000-0000-0000-0000-0000000000f1'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000, trial_discount_percent = 0;

select public.credit_coins_for_purchase(
  'c0000000-0000-0000-0000-0000000000f2'::uuid, 'pack_5000',
  5000, 500, 5000, 'sess_immutable_1', 'pi_immutable_1');

set test.uid = 'c0000000-0000-0000-0000-0000000000f2';
select public.create_booking('c0000000-0000-0000-0000-0000000000f1'::uuid, 60, 'v2', null);

\echo '=== 1. 取引履歴は書き換えられない ==='
do $$
begin
  update public.coin_transactions set amount = 999999
    where user_id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  raise exception 'FAIL 履歴を書き換えられてしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 履歴のUPDATEは拒否された';
end $$;

\echo '=== 2. 取引履歴は削除できない(whereを忘れた全消しを想定) ==='
do $$
begin
  delete from public.coin_transactions;
  raise exception 'FAIL 履歴を全消しできてしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 履歴のDELETEは拒否された';
end $$;

\echo '=== 3. 入金記録も同じく守られる ==='
do $$
begin
  delete from public.coin_purchases where stripe_session_id = 'sess_immutable_1';
  raise exception 'FAIL 入金記録を消せてしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 入金記録のDELETEは拒否された';
end $$;

\echo '=== 4. コインロットは削除できない(残高そのものなので) ==='
do $$
begin
  delete from public.coin_lots where user_id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  raise exception 'FAIL ロットを消せてしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK ロットのDELETEは拒否された';
end $$;

\echo '=== 5. ロットの remaining 更新は通常運用なので通る ==='
do $$
declare v_before int; v_after int;
begin
  select sum(remaining) into v_before from public.coin_lots
    where user_id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  -- 予約はロットから消費するので、この更新経路を塞いではいけない
  -- 0049の重複検査があるので、冒頭の「今すぐ」とは別の時刻にする
  perform public.create_booking('c0000000-0000-0000-0000-0000000000f1'::uuid, 60, 'v2',
    date_trunc('hour', now()) + interval '1 day');
  select sum(remaining) into v_after from public.coin_lots
    where user_id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  if v_after <> v_before - 2000 then
    raise exception 'FAIL 消費でロットが減っていない(% → %)', v_before, v_after;
  end if;
  raise notice 'OK 消費によるremainingの更新は塞がれていない(残 % → %)', v_before, v_after;
end $$;

\echo '=== 6. 預かり中の予約は削除できない ==='
do $$
begin
  delete from public.bookings
    where guest_id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  raise exception 'FAIL 予約を消せてしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 予約のDELETEは拒否された';
end $$;

\echo '=== 7. 換金の金額・宛先は変更できないが、ステータス更新は通る ==='
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
  values ('c0000000-0000-0000-0000-0000000000f1'::uuid,
          'テスト銀行', '0001', 'テスト支店', '001', '普通', '1234567', 'フヘンメイト')
  on conflict (user_id) do nothing;
update public.coin_wallets set earned_balance = 5000
  where user_id = 'c0000000-0000-0000-0000-0000000000f1'::uuid;
insert into public.coin_transactions (user_id, amount, type, note)
  values ('c0000000-0000-0000-0000-0000000000f1'::uuid, 5000, 'booking_earned', 'test:seed');
set test.uid = 'c0000000-0000-0000-0000-0000000000f1';
select public.request_bank_payout(5000);  -- 0063で最低額5,000

do $$
begin
  update public.payouts set coins = 99999
    where user_id = 'c0000000-0000-0000-0000-0000000000f1'::uuid;
  raise exception 'FAIL 換金額を書き換えられてしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 換金額のUPDATEは拒否された';
end $$;

do $$
begin
  update public.payouts set status = 'paid'
    where user_id = 'c0000000-0000-0000-0000-0000000000f1'::uuid;
  raise notice 'OK ステータス更新(振込完了の記録)は通る';
end $$;

\echo '=== 8. 明示的に宣言すれば通り、旧値が ledger_audit に残る ==='
do $$
declare v_n int; v_old jsonb;
begin
  set local app.ledger_override = 'on';
  delete from public.coin_transactions where note = 'test:seed';
  reset app.ledger_override;

  select count(*) into v_n from public.ledger_audit
    where table_name = 'coin_transactions' and op = 'DELETE';
  select old_row into v_old from public.ledger_audit
    where table_name = 'coin_transactions' and op = 'DELETE'
    order by at desc limit 1;
  if v_n < 1 then raise exception 'FAIL 解除した操作が記録されていない'; end if;
  if (v_old->>'note') <> 'test:seed' then raise exception 'FAIL 旧値が残っていない: %', v_old; end if;
  raise notice 'OK 宣言すれば実行でき、旧値(%コイン)が監査記録に残る', v_old->>'amount';
end $$;

\echo '=== 9. 宣言はトランザクションを抜ければ切れる ==='
do $$
begin
  delete from public.coin_transactions
    where user_id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  raise exception 'FAIL 宣言が漏れて次の操作まで通ってしまった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 宣言は持ち越されず、次の操作は再び拒否される';
end $$;

\echo '=== 10. ユーザーの物理削除は台帳の保護で止まる(0045の匿名化を使うべき) ==='
do $$
begin
  delete from auth.users where id = 'c0000000-0000-0000-0000-0000000000f2'::uuid;
  raise exception 'FAIL ユーザーを消せてしまい、取引記録も道連れになった';
exception when others then
  if sqlerrm not like 'LEDGER_IMMUTABLE%' then raise; end if;
  raise notice 'OK 物理削除は台帳の保護で止まる(黙って消えない)';
end $$;

\echo '=== 11. 監査記録は管理者しか読めない ==='
do $$
declare v_pol int;
begin
  select count(*) into v_pol from pg_policies
    where tablename = 'ledger_audit' and cmd = 'SELECT';
  if v_pol <> 1 then raise exception 'FAIL SELECTポリシーが想定と違う: %', v_pol; end if;
  if exists (select 1 from pg_policies where tablename = 'ledger_audit' and cmd <> 'SELECT') then
    raise exception 'FAIL 書き込みポリシーが存在する';
  end if;
  raise notice 'OK ledger_audit は管理者のSELECTのみ(書き込みポリシー無し)';
end $$;

\echo '=== 完了 ==='
