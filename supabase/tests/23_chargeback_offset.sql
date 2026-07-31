-- ============================================================
-- 23: チャージバック清算の相殺と、新規原資の換金保留(0088・G11後半)
-- ------------------------------------------------------------
-- 規約 第8条の6第3項・第4項・第5項2号。
--
-- **この条項は「広く取れる作り」にした瞬間に許容性を失う。**
-- 弁護士:「この構成で説明できない類型——役務の品質への不満を理由と
-- するもの等——にまで及ぼせば、片面的なリスク転嫁条項となり
-- 許容性は急落する」。だからテストは**引けることより、引けないこと**を
-- 多く固定する。
--
--   ・異議が成立していない購入からは起こせない(4項4号)
--   ・充当された分を超えて引けない(3項)
--   ・**通知なしにいきなり引けない**(4項3号)
--   ・異議期間中は引けない
--   ・未払を超えて引けない＝振込済みは請求しない(4項2号)
--   ・返還済みの予約は対象にならない
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a2000000-0000-0000-0000-000000000001'),
  ('a2000000-0000-0000-0000-000000000002'),
  ('a2000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('a2000000-0000-0000-0000-000000000001','ゲスト'),
  ('a2000000-0000-0000-0000-000000000002','ピタメイト'),
  ('a2000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('a2000000-0000-0000-0000-000000000001',
                    'a2000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a2000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.admins (user_id) values ('a2000000-0000-0000-0000-000000000009');

-- 購入 → 予約 → 完了確定 まで進める
select public.credit_coins_for_purchase(
  'a2000000-0000-0000-0000-000000000001', null, 6000, 0, 6000, 'sess_cb', 'pi_cb');

set test.uid = 'a2000000-0000-0000-0000-000000000001';
select public.create_booking('a2000000-0000-0000-0000-000000000002', 120) as bk \gset
set test.uid = 'a2000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
set test.uid = 'a2000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk');

create temporary table _ctx as
select (select id from public.coin_purchases where stripe_session_id = 'sess_cb') as purchase_id,
       :'bk'::uuid as booking_id;

set test.uid = 'a2000000-0000-0000-0000-000000000009';

-- ------------------------------------------------------------
\echo '=== 1. 対象が「現に充当された取引」として引けること(4項1号) ==='
do $$
declare v_n int; v_ded int; v_funded int; v_earned int;
begin
  select count(*), max(deductible_coins), max(funded_coins), max(host_earned_coins)
    into v_n, v_ded, v_funded, v_earned
  from public.chargeback_offset_preview((select purchase_id from _ctx));

  if v_n <> 1 then raise exception 'FAIL: 対象が%件(期待1件)', v_n; end if;
  if v_funded <> 2000 then
    raise exception 'FAIL: 充当額が合わない(%)。時給1000×2時間=2000のはず', v_funded;
  end if;
  -- **利用料を引いた後の枚数で見る。** 総額で引くと、当社の取り分まで
  -- 相手から取り返すことになる(報酬確定は総額で入り、利用料は別行)
  if v_earned >= v_funded then
    raise exception 'FAIL: 報酬が利用料控除後になっていない(充当% / 報酬%)', v_funded, v_earned;
  end if;
  -- **利用料を引いた後の報酬しか渡っていない。**
  -- 充当額をそのまま引くと、当社の取り分まで相手から取ることになる
  if v_ded <> least(v_funded, v_earned) then
    raise exception 'FAIL: 控除額が「充当額と報酬の小さいほう」でない(% / %)', v_ded, v_earned;
  end if;
  if v_ded > v_earned then
    raise exception 'FAIL: 報酬より多く引こうとしている';
  end if;
  raise notice 'OK: 充当%枚 / 報酬%枚 → 控除%枚', v_funded, v_earned, v_ded;
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 異議が成立していない購入からは起こせないこと(4項4号) ==='
-- **当社が損失を負担していない取引に手を出さない。**
-- 3DSで責任が移った取引はここで自然に外れる
do $$
begin
  perform public.chargeback_offset_notify((select purchase_id from _ctx));
  raise exception 'FAIL: 異議の成立が無いのに控除を予告できてしまった';
exception when others then
  if sqlerrm <> 'PURCHASE_NOT_LOST' then raise; end if;
  raise notice 'OK: PURCHASE_NOT_LOST で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 異議が成立したら、通知だけが起きる(1コインも引かない) ==='
insert into public.payment_disputes
  (user_id, stripe_dispute_id, stripe_charge_id, stripe_payment_intent,
   amount_yen, reason, status)
values ('a2000000-0000-0000-0000-000000000001','dp_cb','ch_cb','pi_cb',
        6000,'fraudulent','lost');

do $$
declare v_n int; v_before int; v_after int; v_notif int;
begin
  select earned_balance into v_before from public.coin_wallets
   where user_id = 'a2000000-0000-0000-0000-000000000002';

  v_n := public.chargeback_offset_notify((select purchase_id from _ctx));
  if v_n <> 1 then raise exception 'FAIL: 予告が%件', v_n; end if;

  select earned_balance into v_after from public.coin_wallets
   where user_id = 'a2000000-0000-0000-0000-000000000002';
  if v_after <> v_before then
    raise exception 'FAIL: **通知の時点で引いてしまった**(% → %)', v_before, v_after;
  end if;

  select count(*) into v_notif from public.notifications
   where user_id = 'a2000000-0000-0000-0000-000000000002'
     and title like '%控除について%';
  if v_notif < 1 then
    raise exception 'FAIL: 控除の予告が本人に届いていない(4項3号)';
  end if;
  raise notice 'OK: 通知のみ。残高は%のまま', v_after;
end $$;

\echo '--- 二重に予告しないこと ---'
do $$
declare v_n int;
begin
  v_n := public.chargeback_offset_notify((select purchase_id from _ctx));
  if v_n <> 0 then raise exception 'FAIL: 同じ取引を二度予告した(%)', v_n; end if;
  raise notice 'OK: 既に予告済みの取引は飛ばす';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 異議期間が終わるまでは実行できないこと(4項3号) ==='
do $$
declare v_id uuid;
begin
  select id into v_id from public.chargeback_offsets limit 1;
  begin
    perform public.chargeback_offset_execute(v_id, null);
    raise exception 'FAIL: 異議期間中に控除できてしまった';
  exception when others then
    if sqlerrm <> 'OBJECTION_PERIOD_OPEN' then raise; end if;
  end;
  raise notice 'OK: OBJECTION_PERIOD_OPEN で止まる';
end $$;

\echo '--- 本人は異議を述べられること ---'
set test.uid = 'a2000000-0000-0000-0000-000000000002';
do $$
declare v_id uuid;
begin
  select id into v_id from public.chargeback_offsets limit 1;
  begin
    perform public.object_to_chargeback_offset(v_id, null);
    raise exception 'FAIL: 理由なしの異議が通った';
  exception when others then
    if sqlerrm <> 'NOTE_REQUIRED' then raise; end if;
  end;
  perform public.object_to_chargeback_offset(v_id, '正規の予約です');
  if not exists (select 1 from public.chargeback_offsets
                  where id = v_id and objected_at is not null) then
    raise exception 'FAIL: 異議が記録されていない';
  end if;
  raise notice 'OK: 異議を記録できる';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 異議が出ているときは、理由なしに押し切れないこと ==='
set test.uid = 'a2000000-0000-0000-0000-000000000009';
update public.chargeback_offsets set objection_deadline = now() - interval '1 day';

do $$
declare v_id uuid;
begin
  select id into v_id from public.chargeback_offsets limit 1;
  begin
    perform public.chargeback_offset_execute(v_id, null);
    raise exception 'FAIL: 異議があるのに理由なしで控除できた';
  exception when others then
    if sqlerrm <> 'NOTE_REQUIRED_AFTER_OBJECTION' then raise; end if;
  end;
  raise notice 'OK: 判断の理由を残さないと実行できない';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 未払の報酬コインからのみ引くこと(3項・4項2号) ==='
-- 振込済みの金銭は請求しない。申請中の分も当てにしない
do $$
declare v_id uuid; v_take int; v_earned int; v_n int;
begin
  select id into v_id from public.chargeback_offsets limit 1;

  -- 未払を控除額より小さくしておく(1000枚しか残っていない状態)
  update public.coin_wallets set earned_balance = 1000
   where user_id = 'a2000000-0000-0000-0000-000000000002';

  v_take := public.chargeback_offset_execute(v_id, '確認のうえ控除');

  select earned_balance into v_earned from public.coin_wallets
   where user_id = 'a2000000-0000-0000-0000-000000000002';
  if v_earned <> 0 then
    raise exception 'FAIL: 未払残高が0にならない(%)', v_earned;
  end if;
  if v_take <> 1000 then
    raise exception 'FAIL: 未払を超えて引いた(%)。4項2号違反', v_take;
  end if;

  -- 記録と通知
  select count(*) into v_n from public.coin_transactions
   where user_id = 'a2000000-0000-0000-0000-000000000002'
     and type = 'chargeback_offset';
  if v_n <> 1 then raise exception 'FAIL: 台帳に記録が無い(%)', v_n; end if;

  if not exists (select 1 from public.admin_actions
                  where kind = 'chargeback_offset_execute' and target_id = v_id) then
    raise exception 'FAIL: 管理操作が記録されていない';
  end if;

  -- 二度目は通らない
  begin
    perform public.chargeback_offset_execute(v_id, 'もう一度');
    raise exception 'FAIL: 同じ相殺を二度実行できた';
  exception when others then
    if sqlerrm <> 'NOT_PENDING' then raise; end if;
  end;
  raise notice 'OK: 未払1000枚まで引いて止まる。二度は実行できない';
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 会計仕訳に相殺が出ること ==='
-- **出ないと預り金が過大に残る**(0079のJ16・0085のJ18と同じ形の穴)
do $$
declare v_yen bigint;
begin
  select 金額円 into v_yen from public.accounting_journal('2000-01-01','2100-01-01')
   where 摘要 like '購入の失効による相殺%';
  if coalesce(v_yen, 0) <> 1000 then
    raise exception 'FAIL: 相殺の仕訳が出ない(%)', v_yen;
  end if;
  raise notice 'OK: J24 %円', v_yen;
end $$;

-- ------------------------------------------------------------
\echo '=== 8. 新規ユーザー原資の換金は保留されること(5項2号) ==='
-- **申請は止めない。止めるのは振込。**
-- 申請を拒むと「換金できない」外形になり、離脱の自由の議論に触れる
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values ('a2000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001',
        '普通','1234567','ピタ タロウ')
on conflict (user_id) do nothing;

update public.coin_wallets set earned_balance = 8000
  where user_id = 'a2000000-0000-0000-0000-000000000002';

set test.uid = 'a2000000-0000-0000-0000-000000000002';
select public.request_bank_payout(6000) as po \gset
create temporary table _po as select :'po'::uuid as id;

do $$
declare v_hold timestamptz;
begin
  select hold_until into v_hold from public.payouts where id = (select id from _po);
  if v_hold is null then
    raise exception 'FAIL: 新規ユーザーの購入が原資なのに保留が付いていない';
  end if;
  if v_hold <= now() then
    raise exception 'FAIL: 保留の期限が過去(%)', v_hold;
  end if;
  raise notice 'OK: 申請は通り、振込だけが%まで保留される', v_hold;
end $$;

\echo '--- 保留中は振込済みにできないこと ---'
do $$
begin
  update public.payouts set status = 'paid' where id = (select id from _po);
  raise exception 'FAIL: 保留中の換金を振込済みにできてしまった';
exception when others then
  if sqlerrm <> 'PAYOUT_ON_RISK_HOLD' then raise; end if;
  raise notice 'OK: PAYOUT_ON_RISK_HOLD で止まる';
end $$;

\echo '--- 期限が過ぎれば振込めること ---'
do $$
begin
  update public.payouts set hold_until = now() - interval '1 minute'
   where id = (select id from _po);
  update public.payouts set status = 'paid' where id = (select id from _po);
  raise notice 'OK: 保留が明ければ通る';
end $$;

\echo '=== 23: 相殺と換金保留 すべて通過 ==='
