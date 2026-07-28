-- 換金とギフトの条件(0063)の検証。
--
-- 料率と最低額は規約・特商法表記に書く数字なので、実装とずれると
-- 表示と実際の控除が食い違う。ここで固定して、変えたときに気づけるようにする。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f3000000-0000-0000-0000-000000000001'::uuid),
  ('f3000000-0000-0000-0000-000000000009'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('f3000000-0000-0000-0000-000000000001'::uuid, '贈る人'),
  ('f3000000-0000-0000-0000-000000000009'::uuid, '受け取る人')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f3000000-0000-0000-0000-000000000009'::uuid;
insert into public.coin_wallets (user_id, balance, earned_balance) values
  ('f3000000-0000-0000-0000-000000000001'::uuid, 50000, 0),
  ('f3000000-0000-0000-0000-000000000009'::uuid, 0, 20000)
  on conflict (user_id) do update
    set balance = excluded.balance, earned_balance = excluded.earned_balance;
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
  values ('f3000000-0000-0000-0000-000000000009'::uuid,
          'テスト銀行','0001','本店','001','普通','1234567','ウケトルヒト')
  on conflict (user_id) do nothing;

\echo '=== 1. ギフト手数料は35% ==='
-- 規約第8条の2第4項・特商法表記と同じ数字であること。
do $$
declare v_rate numeric; v_fee int;
begin
  select fee_coins, applied_rate into v_fee, v_rate
  from (
    select 1000 as gross,
           least(greatest(round(1000 * 0.35)::int, 0), 1000) as fee_coins,
           0.35::numeric as applied_rate
  ) t;
  -- 実装側の定数を関数定義から読み取って照合する
  if pg_get_functiondef('public._apply_gift_fee()'::regprocedure) not like '%0.35%' then
    raise exception 'FAIL: ギフト手数料が0.35でない';
  end if;
  if pg_get_functiondef('public._apply_gift_fee()'::regprocedure) like '%0.30%' then
    raise exception 'FAIL: 旧料率(0.30)が残っている';
  end if;
end $$;

\echo '=== 2. 最低換金額は5,000コイン ==='
set test.uid = 'f3000000-0000-0000-0000-000000000009';
do $$
begin
  -- 4,999は弾かれる
  begin
    perform public.request_bank_payout(4999);
    raise exception 'FAIL: 4,999が通った';
  exception when others then
    if sqlerrm not like '%MIN_PAYOUT_COINS%' then raise; end if;
  end;
  -- 5,000ちょうどは通る
  if public.request_bank_payout(5000) is null then
    raise exception 'FAIL: 5,000が通らない';
  end if;
end $$;

\echo '=== 3. 振込額は申請コイン − 300 ==='
do $$
declare v_amount int; v_fee int;
begin
  select amount_yen, fee_yen into v_amount, v_fee
  from public.payouts where user_id = 'f3000000-0000-0000-0000-000000000009'::uuid
  order by created_at desc limit 1;
  if v_fee <> 300 then raise exception 'FAIL: 手数料が300でない: %', v_fee; end if;
  if v_amount <> 4700 then raise exception 'FAIL: 振込額が4,700でない: %', v_amount; end if;
end $$;

\echo '=== 4. 報酬コインは失効しない(最低額を上げても目減りしない) ==='
-- 5,000に届くまで貯める設計にした以上、途中で失効しては困る。
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='coin_lots' and column_name='kind'
  ) and exists (
    select 1 from pg_constraint
    where conrelid = 'public.coin_lots'::regclass
      and pg_get_constraintdef(oid) like '%earned%'
  ) then
    raise exception 'FAIL: 報酬コインが失効ロットの対象になっている';
  end if;
end $$;

reset test.uid;
-- 台帳は追記専用(0044)なので、後片付けだけ例外を宣言する
set app.ledger_override = 'on';
delete from public.coin_transactions where user_id::text like 'f3000000-%';
delete from public.payouts where user_id::text like 'f3000000-%';
reset app.ledger_override;
delete from public.host_bank_accounts where user_id::text like 'f3000000-%';
delete from public.coin_wallets where user_id::text like 'f3000000-%';
delete from public.profiles where id::text like 'f3000000-%';
delete from auth.users where id::text like 'f3000000-%';

\echo '=== 76_payout_terms: 全項目OK ==='
