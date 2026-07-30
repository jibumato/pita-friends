-- ============================================================
-- 90: 会計用の残高・売上サマリー(0070)の検証
-- ------------------------------------------------------------
-- 税理士の指摘に対応した関数が、**記帳に使える数字**を返すことを確かめる。
-- 特に次の3つは、間違えると帳簿が合わなくなる/税額が変わる:
--   ・無償コイン(ボーナス)を前受金に混ぜないこと(現金を受け取っていない)
--   ・手数料の計上が「コイン消費時」ではなく**完了確定時**であること
--   ・換金手数料が売上に出ること(当初の資料で漏れていた項目)
-- あわせて、運営以外から呼べないことも確かめる。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('e0000000-0000-0000-0000-000000000001'),  -- ゲスト
  ('e0000000-0000-0000-0000-000000000002'),  -- ピタメイト
  ('e0000000-0000-0000-0000-000000000009');  -- 運営
insert into public.profiles (id, nickname) values
  ('e0000000-0000-0000-0000-000000000001','ゲスト'),
  ('e0000000-0000-0000-0000-000000000002','ピタメイト'),
  ('e0000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('e0000000-0000-0000-0000-000000000009');
update public.profile_trust_stats set is_verified = true
  where user_id = 'e0000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('e0000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- 有償20000 + 無償5000 を持たせる(購入の記録も残す)
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('e0000000-0000-0000-0000-000000000001','paid',  20000, public.coin_expiry_from(now())),
  ('e0000000-0000-0000-0000-000000000001','bonus',  5000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 20000, bonus_balance = 5000
  where user_id = 'e0000000-0000-0000-0000-000000000001';
insert into public.coin_purchases
  (user_id, pack_id, coins_credited, price_yen, stripe_session_id, safety_fee_yen)
values ('e0000000-0000-0000-0000-000000000001','pack_20000', 25000, 20000, 'sess_acct_1', 1000);

-- ------------------------------------------------------------
\echo '=== 1. 無償コインを前受金に混ぜていないこと ==='
set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_maeuke bigint; v_bonus bigint;
begin
  select 金額円 into v_maeuke from public.accounting_balances() where 勘定科目 = '前受金(コイン)';
  select 金額円 into v_bonus  from public.accounting_balances() where 勘定科目 = '無償コイン残(ボーナス)';
  if v_maeuke <> 20000 then
    raise exception 'FAIL: 前受金が有償分と一致しない(期待20000 / 実際%)', v_maeuke;
  end if;
  if v_bonus <> 5000 then
    raise exception 'FAIL: 無償コインの参考値が合わない(期待5000 / 実際%)', v_bonus;
  end if;
  raise notice 'OK: 前受金=%(有償のみ) / 無償は参考値%として別建て', v_maeuke, v_bonus;
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 予約成立(コイン消費)の時点では、まだ売上にならない ==='
set test.uid = 'e0000000-0000-0000-0000-000000000001';
select public.create_booking('e0000000-0000-0000-0000-000000000002', 60, 'v1') as bk \gset
set test.uid = 'e0000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');

set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_escrow bigint; v_fee bigint;
begin
  select 金額円 into v_escrow from public.accounting_balances()
    where 勘定科目 = '前受金(予約エスクロー)';
  select 金額円 into v_fee from public.accounting_revenue(
    (now() - interval '1 day')::date, (now() + interval '1 day')::date)
    where 科目 = 'PF利用料(予約)';
  if v_escrow <> 2000 then
    raise exception 'FAIL: エスクローに載っていない(期待2000 / 実際%)', v_escrow;
  end if;
  if v_fee <> 0 then
    raise exception 'FAIL: 完了前なのに利用料が売上に立っている(%)', v_fee;
  end if;
  raise notice 'OK: 完了前はエスクロー%のみ。売上は0(権利確定主義)', v_escrow;
end $$;

-- ------------------------------------------------------------
\echo '=== 3. プレイ完了確定で、はじめて売上と預り金に分かれる ==='
set test.uid = 'e0000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk');

set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_escrow bigint; v_fee bigint; v_azukari bigint;
begin
  select 金額円 into v_escrow from public.accounting_balances()
    where 勘定科目 = '前受金(予約エスクロー)';
  select 金額円 into v_fee from public.accounting_revenue(
    (now() - interval '1 day')::date, (now() + interval '1 day')::date)
    where 科目 = 'PF利用料(予約)';
  select 金額円 into v_azukari from public.accounting_balances()
    where 勘定科目 = '預り金(ホスト報酬)';
  if v_escrow <> 0 then
    raise exception 'FAIL: 確定後もエスクローに残っている(%)', v_escrow;
  end if;
  if v_fee <= 0 then
    raise exception 'FAIL: 確定したのに利用料が売上に立っていない';
  end if;
  if v_azukari <= 0 then
    raise exception 'FAIL: ホスト報酬が預り金に立っていない';
  end if;
  -- 2000コインが 利用料 + 報酬 に分かれること(取りこぼしが無いこと)
  if v_fee + v_azukari <> 2000 then
    raise exception 'FAIL: 利用料%+預り金%が元の2000と合わない', v_fee, v_azukari;
  end if;
  raise notice 'OK: 2000 = 利用料% + 預り金%(差額なし)', v_fee, v_azukari;
end $$;

-- ------------------------------------------------------------
\echo '=== 4. あんしんサポート料が購入時の売上に出ること ==='
set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_fee bigint; v_sales bigint;
begin
  select 金額円 into v_fee from public.accounting_revenue(
    (now() - interval '1 day')::date, (now() + interval '1 day')::date)
    where 科目 = 'あんしんサポート料(購入時)';
  select 金額円 into v_sales from public.accounting_revenue(
    (now() - interval '1 day')::date, (now() + interval '1 day')::date)
    where 科目 = 'コイン販売額(前受金の増加)';
  if v_fee <> 1000 then
    raise exception 'FAIL: サポート料が売上に出ない(期待1000 / 実際%)', v_fee;
  end if;
  if v_sales <> 20000 then
    raise exception 'FAIL: コイン販売額が参考表示されない(%)', v_sales;
  end if;
  raise notice 'OK: サポート料%は売上 / コイン販売%は前受金(参考表示)', v_fee, v_sales;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 換金手数料が売上に出ること(当初の資料で漏れていた項目) ==='
set test.uid = 'e0000000-0000-0000-0000-000000000002';
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values ('e0000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001',
        '普通','1234567','ピタメイト')
on conflict (user_id) do nothing;
-- 換金できる額まで報酬を積む(ギフト由来ではないので保留は掛からない)
update public.coin_wallets set earned_balance = 10000
  where user_id = 'e0000000-0000-0000-0000-000000000002';
select public.request_bank_payout(6000) as po \gset

set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_miharai bigint;
begin
  select 金額円 into v_miharai from public.accounting_balances()
    where 勘定科目 = '未払金(換金申請中)';
  -- 申請直後は未振込なので未払金に立つ(6000 - 手数料300 = 5700)
  if v_miharai <> 5700 then
    raise exception 'FAIL: 未払金が振込予定額と合わない(期待5700 / 実際%)', v_miharai;
  end if;
  raise notice 'OK: 未払金=%(手数料控除後の振込予定額)', v_miharai;
end $$;

-- 振込済みにすると、手数料が売上に出る
select public.mark_payout_paid(:'po');
set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_fee bigint; v_miharai bigint;
begin
  select 金額円 into v_fee from public.accounting_revenue(
    (now() - interval '1 day')::date, (now() + interval '1 day')::date)
    where 科目 = '換金手数料';
  select 金額円 into v_miharai from public.accounting_balances()
    where 勘定科目 = '未払金(換金申請中)';
  if v_fee <> 300 then
    raise exception 'FAIL: 換金手数料が売上に出ない(期待300 / 実際%)', v_fee;
  end if;
  if v_miharai <> 0 then
    raise exception 'FAIL: 振込済みなのに未払金が残っている(%)', v_miharai;
  end if;
  raise notice 'OK: 換金手数料%が売上に出た / 未払金は0', v_fee;
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 失効処理待ちが検知されること(雑収入の計上漏れ防止) ==='
set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_pending bigint; v_zatsu bigint;
begin
  -- 期限切れにするが失効処理は走らせない
  update public.coin_lots set expires_at = now() - interval '1 day'
    where user_id = 'e0000000-0000-0000-0000-000000000001';
  select 金額円 into v_pending from public.accounting_balances()
    where 勘定科目 = '期限切れ・失効処理待ち';
  if v_pending <= 0 then
    raise exception 'FAIL: 失効処理待ちを検知できていない';
  end if;
  raise notice 'OK: 失効処理待ち%を検知(0でなければ expire_coins 未実行)', v_pending;

  -- 失効させると雑収入に出る
  perform public.expire_coins();
  select 金額円 into v_zatsu from public.accounting_revenue(
    (now() - interval '1 day')::date, (now() + interval '1 day')::date)
    where 科目 = 'コイン失効益';
  if v_zatsu <= 0 then
    raise exception 'FAIL: 失効させたのに雑収入に出ない';
  end if;
  raise notice 'OK: 失効益%が雑収入に出た(不課税)', v_zatsu;
end $$;

-- ------------------------------------------------------------
\echo '=== 7. ホストごとの年間支払額が出ること ==='
set test.uid = 'e0000000-0000-0000-0000-000000000009';
do $$
declare v_n int; v_amt bigint;
begin
  select count(*)::int, coalesce(sum(支払額円), 0) into v_n, v_amt
  from public.accounting_host_payments(extract(year from now())::int);
  if v_n <> 1 or v_amt <> 5700 then
    raise exception 'FAIL: 年間支払額が合わない(件数% / 額%)', v_n, v_amt;
  end if;
  raise notice 'OK: ホスト%人 / 年間支払額%円を出力できる', v_n, v_amt;
end $$;

-- ------------------------------------------------------------
\echo '=== 8. 運営以外は呼べないこと ==='
set test.uid = 'e0000000-0000-0000-0000-000000000001';
do $$
begin
  perform public.accounting_balances();
  raise exception 'FAIL: 運営でない利用者が残高を引けてしまった';
exception
  when others then
    if sqlerrm like '%FAIL:%' then raise; end if;
    if sqlerrm not like '%NOT_ADMIN%' then
      raise exception 'FAIL: 想定と違う理由で失敗(%)', sqlerrm;
    end if;
    raise notice 'OK: NOT_ADMIN で弾かれた';
end $$;
do $$
begin
  perform public.accounting_host_payments(2026);
  raise exception 'FAIL: 運営でない利用者が支払額を引けてしまった';
exception
  when others then
    if sqlerrm like '%FAIL:%' then raise; end if;
    if sqlerrm not like '%NOT_ADMIN%' then
      raise exception 'FAIL: 想定と違う理由で失敗(%)', sqlerrm;
    end if;
    raise notice 'OK: 支払額もNOT_ADMINで弾かれた';
end $$;

-- ------------------------------------------------------------
\echo '=== 9. anonからは呼べないこと ==='
set role anon;
do $$
begin
  perform public.accounting_balances();
  raise exception 'FAIL: anonが残高を引けた';
exception
  when insufficient_privilege then
    raise notice 'OK: anonには実行権限が無い';
  when others then
    if sqlerrm like '%FAIL:%' then raise; end if;
    raise notice 'OK: anonは弾かれた(%)', sqlerrm;
end $$;
reset role;

\echo '=== 90 すべて通過 ==='
