-- ============================================================
-- 0063_align_payout_terms.sql
-- 換金とギフトの条件を競合と揃える
-- ------------------------------------------------------------
-- GameRoom の公表条件(2022/08/02 時点のヘルプ)を確認したところ、
--   ・チケット手数料 15%
--   ・ギフト手数料 35%
--   ・出金手数料 300円/回
--   ・**最低出金額 5,000円**
--   ・**振込は毎週月曜**
-- だった。こちらは ギフト30% / 最低1,000コイン / 月末締め翌月払い。
--
-- ギフトと最低額を相手に合わせ、振込は週次にして追い越す。
--   ・ギフト 30% → **35%**
--       推しのサービスなのでギフトの比重は大きい。ここを5pt低く保つと
--       収益の主要な柱を自分から削ることになる。相手が35%で成立している
--       以上、揃えて問題ない。
--   ・最低出金 1,000 → **5,000コイン**
--       少額振込の事務コスト(ワンオペ)を抑える。報酬コインは失効しない
--       設計(0018)なので、届くまで待っても目減りしない。
--   ・振込は週次(このファイルでは扱わない。運用手順とUI表記の変更)
--       毎週日曜締め・翌週金曜払い。締め〜支払いの日数は締め曜日に依存しないが、
--       日曜締めにすると不正チェック(手順書①-2)に使える営業日が2日→4日になる。
--
-- ⚠️ **どちらも公開前に決めきること。** 公開後にギフト率を上げるのも
--    最低額を上げるのも、ピタメイトにとっては不利益変更で、規約上の
--    2週間周知が要るうえ、いちばん失いたくない層の心証を損なう。
-- ⚠️ 法務: 手数料率と最低額は特商法表記・規約の記載対象。
-- ============================================================

-- ------------------------------------------------------------
-- ギフト手数料 30% → 35%
-- ------------------------------------------------------------
create or replace function public._apply_gift_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 0063で30%→35%。変更したらUI(ギフト送信シート)と特商法表記も更新すること
  c_gift_rate constant numeric := 0.35;
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;
  v_fee := least(greatest(round(new.coins * c_gift_rate)::int, 0), new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.receiver_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (new.receiver_id, -v_fee, 'platform_fee', 'gift_fee:' || new.id);
  end if;

  insert into public.platform_fees (
    host_id, kind, gift_id, gross_coins, fee_coins, net_coins, applied_rate)
  values (new.receiver_id, 'gift', new.id, new.coins, v_fee, new.coins - v_fee, c_gift_rate);

  return new;
end;
$$;

comment on function public._apply_gift_fee() is
  'ギフト受領時に一律35%を引く(0063で30%から変更)。累進の対象外なのは、金額が任意で青天井になりうるため。';

-- ------------------------------------------------------------
-- 最低換金額 1,000 → 5,000コイン
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 振込手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;
  if v_balance is null or v_balance < p_coins then
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(int) is
  '報酬コインの銀行振込を申請する。最低5,000コイン(0063で1,000から変更)・手数料300コイン/回。締めは毎週日曜・翌週金曜払い。';

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;
