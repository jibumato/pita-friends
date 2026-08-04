-- ============================================================
-- 24: 退会後の最低申請額と、利用停止時のコインの取扱い(0098)
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答。どちらも
-- **「稼得済みの報酬を没収している」と読まれる形**になっていた箇所。
--
-- 固定するのは5つ:
--   ・退会**前**は最低申請額(5,000)が効くこと
--   ・退会**後**は最低申請額が外れ、少額でも申請できること
--   ・退会後は**分割できない**こと(0100。手数料を何度も取られないため)
--   ・**利用停止**でも最低申請額が外れること(0100)
--   ・手数料(300)以下は、退会後でも申請できないこと
--   ・利用停止で購入コインは消え、**報酬コインは残る**こと
--   ・没収は明示したときだけ起き、理由が無ければ実行できないこと
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('24000000-0000-0000-0000-000000000001'),
  ('24000000-0000-0000-0000-000000000002'),
  ('24000000-0000-0000-0000-0000000000ad');
insert into public.profiles (id, nickname) values
  ('24000000-0000-0000-0000-000000000001','少額のまま辞める人'),
  ('24000000-0000-0000-0000-000000000002','停止される人'),
  ('24000000-0000-0000-0000-0000000000ad','運営')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('24000000-0000-0000-0000-000000000001',
                    '24000000-0000-0000-0000-000000000002');
insert into public.admins (user_id) values ('24000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;

insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
values
  ('24000000-0000-0000-0000-000000000001','テスト銀行','0001','本店','001','普通','1234567','テスト タロウ'),
  ('24000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001','普通','7654321','テスト ジロウ')
  on conflict (user_id) do nothing;

-- 報酬 1,200 コインだけ持っている(最低申請額 5,000 に届かない)
update public.coin_wallets set earned_balance = 1200
  where user_id = '24000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 退会前は最低申請額が効く ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '24000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.request_bank_payout(1200);
    raise exception 'FAIL 退会前なのに 1,200 コインで申請できてしまった';
  exception when others then
    if sqlerrm not like '%MIN_PAYOUT_COINS%' then raise; end if;
    raise notice 'OK 退会前は MIN_PAYOUT_COINS で弾かれる';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 退会すると最低申請額が外れる(A-2) ==='; end $$;
-- ------------------------------------------------------------
-- withdraw_account は成立済み予約が無ければ通る。報酬コインには手を付けない
select public.withdraw_account('テスト');

do $$
begin
  -- 0100: **分割できない。** 分けられると手数料を何度も取られる
  begin
    perform public.request_bank_payout(400);
    raise exception 'FAIL 退会後に分割して申請できてしまった';
  exception when others then
    if sqlerrm not like '%FINAL_PAYOUT_MUST_BE_WHOLE%' then raise; end if;
    raise notice 'OK 一部だけの申請は FINAL_PAYOUT_MUST_BE_WHOLE で弾かれる';
  end;
end $$;

do $$
declare v_id uuid; v_amount int; v_left int;
begin
  v_id := public.request_bank_payout(1200);
  select amount_yen into v_amount from public.payouts where id = v_id;
  if v_amount <> 900 then
    raise exception 'FAIL 手数料の控除がおかしい: %(1200-300=900のはず)', v_amount;
  end if;
  select earned_balance into v_left
    from public.coin_wallets where user_id = '24000000-0000-0000-0000-000000000001';
  if coalesce(v_left, -1) <> 0 then
    raise exception 'FAIL 全額のはずなのに残っている: %', v_left;
  end if;
  raise notice 'OK 退会後は全額(1,200)で申請でき、手数料300を引いて900円。残高は0';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 手数料以下は、退会後でも申請できない ==='; end $$;
-- ------------------------------------------------------------
update public.coin_wallets set earned_balance = 250
  where user_id = '24000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.request_bank_payout(250);
    raise exception 'FAIL 手数料(300)以下なのに申請できてしまった';
  exception when others then
    if sqlerrm not like '%BELOW_PAYOUT_FEE%' then raise; end if;
    raise notice 'OK 手数料以下は BELOW_PAYOUT_FEE で弾かれる(手取りが0以下になるため)';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 利用停止: 購入コインは消え、報酬コインは残る(A-3) ==='; end $$;
-- ------------------------------------------------------------
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('24000000-0000-0000-0000-000000000002','paid', 3000, now() + interval '3 months');
update public.coin_wallets set balance = 3000, earned_balance = 8000
  where user_id = '24000000-0000-0000-0000-000000000002';

set test.uid = '24000000-0000-0000-0000-0000000000ad';
do $$
declare r jsonb; v_paid int; v_earned int; v_deadline timestamptz;
begin
  r := public.admin_suspend_account('24000000-0000-0000-0000-000000000002', '規約違反(テスト)');

  select balance, earned_balance into v_paid, v_earned
    from public.coin_wallets where user_id = '24000000-0000-0000-0000-000000000002';
  if coalesce(v_paid, -1) <> 0 then
    raise exception 'FAIL 購入コインが消えていない: %', v_paid;
  end if;
  if coalesce(v_earned, 0) <> 8000 then
    raise exception 'FAIL 報酬コインまで消してしまった: %', v_earned;
  end if;

  select payout_claim_deadline into v_deadline
    from public.profiles where id = '24000000-0000-0000-0000-000000000002';
  if v_deadline is null then
    raise exception 'FAIL 換金の期限が設定されていない(90日枠を与えるはず)';
  end if;
  raise notice 'OK 購入3000は消え、報酬8000は残り、換金の期限が付いた';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 没収は明示したときだけ。理由が無ければ実行できない ==='; end $$;
-- ------------------------------------------------------------
do $$
begin
  begin
    perform public.admin_suspend_account('24000000-0000-0000-0000-000000000002', '   ');
    raise exception 'FAIL 理由が空でも実行できてしまった';
  exception when others then
    if sqlerrm not like '%REASON_REQUIRED%' then raise; end if;
    raise notice 'OK 理由が空なら REASON_REQUIRED';
  end;
end $$;

do $$
declare v_earned int; v_deadline timestamptz;
begin
  perform public.admin_suspend_account(
    '24000000-0000-0000-0000-000000000002', '不正に取得した報酬のため没収(テスト)', true);
  select earned_balance into v_earned
    from public.coin_wallets where user_id = '24000000-0000-0000-0000-000000000002';
  if coalesce(v_earned, -1) <> 0 then
    raise exception 'FAIL 明示したのに没収されていない: %', v_earned;
  end if;
  select payout_claim_deadline into v_deadline
    from public.profiles where id = '24000000-0000-0000-0000-000000000002';
  if v_deadline is not null then
    raise exception 'FAIL 没収したのに換金の期限が残っている';
  end if;
  raise notice 'OK p_forfeit_earned=true のときだけ没収され、換金の期限も消える';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 利用停止でも最低申請額が外れる(0100) ==='; end $$;
-- ------------------------------------------------------------
-- 5 で没収してしまったので、別のユーザーで見る
insert into auth.users (id) values ('24000000-0000-0000-0000-000000000003');
insert into public.profiles (id, nickname) values
  ('24000000-0000-0000-0000-000000000003','停止される人2')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '24000000-0000-0000-0000-000000000003';
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
values ('24000000-0000-0000-0000-000000000003','テスト銀行','0001','本店','001','普通','1112223','テスト サブロウ')
  on conflict (user_id) do nothing;
update public.coin_wallets set earned_balance = 1600
  where user_id = '24000000-0000-0000-0000-000000000003';

set test.uid = '24000000-0000-0000-0000-0000000000ad';
select public.admin_suspend_account('24000000-0000-0000-0000-000000000003', '規約違反(テスト)');

set test.uid = '24000000-0000-0000-0000-000000000003';
do $$
declare v_id uuid;
begin
  -- **停止された人も、稼いだ分は取り戻せる。**
  -- ここが弾かれると、弁護士の指摘した「稼得済み報酬の没収」が残る
  v_id := public.request_bank_payout(1600);
  if v_id is null then
    raise exception 'FAIL 利用停止で換金できなかった';
  end if;
  raise notice 'OK 利用停止でも 1,600 コイン(<5,000)を申請できる';
end $$;

do $$ begin raise notice '==== 24: すべて通過 ===='; end $$;
