-- 退会の匿名化(0046)の検証。
--
-- いちばん大事なのは「退会させたあとも入金・換金の記録が残っているか」です。
-- これまでは auth.users を1行消すだけで、その人の取引記録が全部道連れに
-- なっていました(0044でその物理削除自体は止まるようになっています)。

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('b0000000-0000-0000-0000-0000000000a1'::uuid, 'mate@example.test'),
  ('b0000000-0000-0000-0000-0000000000a2'::uuid, 'guest@example.test'),
  ('b0000000-0000-0000-0000-0000000000a9'::uuid, 'admin@example.test')
on conflict do nothing;
insert into public.profiles (id, nickname, bio) values
  ('b0000000-0000-0000-0000-0000000000a1'::uuid, '退会メイト', 'よろしくお願いします'),
  ('b0000000-0000-0000-0000-0000000000a2'::uuid, '退会ゲスト', 'FPSやってます'),
  ('b0000000-0000-0000-0000-0000000000a9'::uuid, '運営', '')
on conflict (id) do update set nickname = excluded.nickname, bio = excluded.bio;
insert into public.admins (user_id) values ('b0000000-0000-0000-0000-0000000000a9'::uuid)
  on conflict do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id in ('b0000000-0000-0000-0000-0000000000a1'::uuid,
                    'b0000000-0000-0000-0000-0000000000a2'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate, bio) values
  ('b0000000-0000-0000-0000-0000000000a1'::uuid, true, 2000, 'ランク上げ手伝います')
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000, trial_discount_percent = 0;
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
  values ('b0000000-0000-0000-0000-0000000000a1'::uuid,
          'テスト銀行', '0001', 'テスト支店', '001', '普通', '1234567', 'タイカイメイト')
  on conflict (user_id) do nothing;
insert into public.user_devices (user_id, device_id) values
  ('b0000000-0000-0000-0000-0000000000a2'::uuid, 'device-taikai-0001')
  on conflict do nothing;

-- 入金 → 予約 → 完了 まで走らせて、記録を作る
select public.credit_coins_for_purchase(
  'b0000000-0000-0000-0000-0000000000a2'::uuid, 'pack_5000',
  5000, 500, 5000, 'sess_anon_1', 'pi_anon_1');
set test.uid = 'b0000000-0000-0000-0000-0000000000a2';
select public.create_booking('b0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2', null) as bk \gset
set test.uid = 'b0000000-0000-0000-0000-0000000000a1';
select public.approve_booking(:'bk');

\echo '=== 1. 未処理の予約が残っているうちは退会させない ==='
set test.uid = 'b0000000-0000-0000-0000-0000000000a9';
do $$
begin
  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a2'::uuid);
  raise exception 'FAIL 進行中の予約があるのに匿名化できてしまった';
exception when others then
  if sqlerrm <> 'OPEN_BOOKINGS_REMAIN' then raise; end if;
  raise notice 'OK 進行中の予約があるうちは OPEN_BOOKINGS_REMAIN';
end $$;

set test.uid = 'b0000000-0000-0000-0000-0000000000a2';
select public.complete_booking(:'bk');

\echo '=== 2. 報酬残高が残っているうちは退会させない ==='
set test.uid = 'b0000000-0000-0000-0000-0000000000a9';
do $$
declare v_earned int;
begin
  select earned_balance into v_earned from public.coin_wallets
    where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid;
  if v_earned <= 0 then raise exception 'FAIL 報酬が入っていない前提が崩れた: %', v_earned; end if;
  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a1'::uuid);
  raise exception 'FAIL 未払いの報酬があるのに匿名化できてしまった';
exception when others then
  if sqlerrm <> 'EARNED_BALANCE_REMAINS' then raise; end if;
  raise notice 'OK 未払いの報酬があるうちは EARNED_BALANCE_REMAINS(勝手に消さない)';
end $$;

\echo '=== 3. 換金申請が処理待ちのうちは退会させない ==='
set test.uid = 'b0000000-0000-0000-0000-0000000000a1';
select public.request_bank_payout(1000);
set test.uid = 'b0000000-0000-0000-0000-0000000000a9';
do $$
begin
  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a1'::uuid);
  raise exception 'FAIL 処理待ちの換金があるのに匿名化できてしまった';
exception when others then
  if sqlerrm <> 'PENDING_PAYOUT_REMAINS' then raise; end if;
  raise notice 'OK 処理待ちの換金があるうちは PENDING_PAYOUT_REMAINS';
end $$;

\echo '=== 4. 退会請求の一覧に「実行できない理由」が出る ==='
insert into public.account_requests (user_id, type) values
  ('b0000000-0000-0000-0000-0000000000a2'::uuid, 'account_deletion');
do $$
declare v_row public.pending_account_deletions;
begin
  select * into v_row from public.pending_account_deletions
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  if v_row.user_id is null then raise exception 'FAIL 退会請求が一覧に出ていない'; end if;
  if v_row.prepaid_balance <= 0 then raise exception 'FAIL 前払い残高が出ていない'; end if;
  raise notice 'OK 一覧に出る(未処理予約=% / 処理待ち換金=% / 報酬=% / 前払い=%)',
    v_row.open_bookings, v_row.pending_payouts, v_row.earned_balance, v_row.prepaid_balance;
end $$;

\echo '=== 5. ゲストを匿名化する(前払いコインは失効・記録は残す) ==='
do $$
declare v_paid_before int; v_tx_before int;
begin
  select balance + bonus_balance into v_paid_before from public.coin_wallets
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  select count(*) into v_tx_before from public.coin_transactions
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;

  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a2'::uuid);

  if (select balance + bonus_balance from public.coin_wallets
      where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid) <> 0 then
    raise exception 'FAIL 前払いコインが失効していない';
  end if;
  if (select count(*) from public.coin_transactions
      where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid) <= v_tx_before then
    raise exception 'FAIL 失効の履歴が残っていない';
  end if;
  raise notice 'OK 前払い%コインを失効させ、履歴に1行残した', v_paid_before;
end $$;

\echo '=== 6. ★取引の記録は消えていない(これが本丸) ==='
do $$
declare v_purchases int; v_tx int; v_bookings int;
begin
  select count(*) into v_purchases from public.coin_purchases
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  select count(*) into v_tx from public.coin_transactions
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  select count(*) into v_bookings from public.bookings
    where guest_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  if v_purchases < 1 then raise exception 'FAIL 入金記録が消えた'; end if;
  if v_tx < 1 then raise exception 'FAIL 取引履歴が消えた'; end if;
  if v_bookings < 1 then raise exception 'FAIL 予約記録が消えた'; end if;
  raise notice 'OK 退会後も 入金%件 / 履歴%件 / 予約%件 が残っている', v_purchases, v_tx, v_bookings;
end $$;

\echo '=== 7. 個人を識別する情報は消えている ==='
do $$
declare v_p public.profiles; v_email text; v_devices int; v_prefs int;
begin
  select * into v_p from public.profiles where id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  if v_p.nickname <> '退会したユーザー' then raise exception 'FAIL ニックネームが残っている: %', v_p.nickname; end if;
  if v_p.bio <> '' then raise exception 'FAIL 自己紹介が残っている: %', v_p.bio; end if;
  if v_p.anonymized_at is null then raise exception 'FAIL 匿名化の印が付いていない'; end if;

  select email into v_email from auth.users where id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  if v_email = 'guest@example.test' then raise exception 'FAIL メールアドレスが残っている'; end if;

  select count(*) into v_devices from public.user_devices
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  select count(*) into v_prefs from public.safety_prefs
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid;
  if v_devices <> 0 then raise exception 'FAIL 端末IDが残っている'; end if;
  if v_prefs <> 0 then raise exception 'FAIL 安心設定が残っている'; end if;

  raise notice 'OK 表示名・自己紹介・メール・端末ID・設定はすべて消えている';
end $$;

\echo '=== 8. 匿名化しても整合性チェックは通る ==='
do $$
declare v_err int; v_bad text;
begin
  v_err := public.run_integrity_checks();
  if v_err <> 0 then
    select string_agg(check_name, ', ') into v_bad
      from public.integrity_latest where severity = 'error';
    raise exception 'FAIL 匿名化で帳尻が崩れた: %', v_bad;
  end if;
  raise notice 'OK 匿名化後も残高と履歴は一致している';
end $$;

\echo '=== 9. 退会請求は完了になり、二重実行は弾かれる ==='
do $$
declare v_status text;
begin
  select status into v_status from public.account_requests
    where user_id = 'b0000000-0000-0000-0000-0000000000a2'::uuid and type = 'account_deletion';
  if v_status <> 'completed' then raise exception 'FAIL 退会請求が完了になっていない: %', v_status; end if;

  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a2'::uuid);
  raise exception 'FAIL 二重に匿名化できてしまった';
exception when others then
  if sqlerrm <> 'ALREADY_ANONYMIZED' then raise; end if;
  raise notice 'OK 退会請求は完了になり、二重実行は ALREADY_ANONYMIZED';
end $$;

\echo '=== 10. 換金を済ませればピタメイト側も退会できる(口座は消える) ==='
-- 振込を実行済みにし、残った報酬は本人が放棄したものとして落とす
-- (運用上は換金しきってから退会させる。ここでは履歴も同時に積んで帳尻を保つ)
do $$
declare v_earned int;
begin
  update public.payouts set status = 'paid'
    where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid and status = 'pending';

  select earned_balance into v_earned from public.coin_wallets
    where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid;
  if v_earned > 0 then
    update public.coin_wallets set earned_balance = 0
      where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid;
    insert into public.coin_transactions (user_id, amount, type, note)
      values ('b0000000-0000-0000-0000-0000000000a1'::uuid, -v_earned, 'withdrawal', 'test:forfeit');
  end if;
end $$;

do $$
declare v_bank int; v_is_host boolean; v_payouts int;
begin
  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a1'::uuid, 'inactive');
  select count(*) into v_bank from public.host_bank_accounts
    where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid;
  select is_host into v_is_host from public.host_settings
    where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid;
  select count(*) into v_payouts from public.payouts
    where user_id = 'b0000000-0000-0000-0000-0000000000a1'::uuid;
  if v_bank <> 0 then raise exception 'FAIL 振込先口座が残っている'; end if;
  if v_is_host then raise exception 'FAIL 掲載が止まっていない'; end if;
  if v_payouts < 1 then raise exception 'FAIL 換金の記録まで消えた'; end if;
  raise notice 'OK 口座は消え掲載も止まったが、換金の記録%件は残っている', v_payouts;
end $$;

\echo '=== 11. 管理者以外は実行できない ==='
set test.uid = 'b0000000-0000-0000-0000-0000000000a2';
do $$
begin
  perform public.anonymize_user('b0000000-0000-0000-0000-0000000000a1'::uuid);
  raise exception 'FAIL 一般ユーザーが実行できてしまった';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK 一般ユーザーの実行は NOT_ADMIN';
end $$;

\echo '=== 完了 ==='
