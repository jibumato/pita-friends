-- ============================================================
-- 0098: 退会後の換金に最低申請額を適用しない（A-2）と、
--       利用停止・強制退会時のコインの取扱い（A-3）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答。**どちらも「稼得済みの報酬を没収している」
-- と読まれる形**になっていた。
--
-- ■ A-2（第1の1(1)）
--   「報酬コインが5,000未満のまま退会したピタメイトは、**換金の機会を
--     一度も与えられないまま90日で権利を失う**ことになります。……
--     報酬コインは……**既に稼得した報酬債権の残高表示**ですから、その消滅は
--     購入コインの失効とは質的に異なり、**実質は稼得済み報酬の没収**です。
--     民法の任意規定によれば報酬債権は5年の消滅時効に服するにすぎない
--     ところ、これを90日かつ最低額未満は行使不能という形で消滅させる条項は、
--     **消費者契約法10条による無効の主張に対して脆弱**です。」
--
--   第13条4項がサービス終了時には最低申請額を外していることとの均衡からも、
--   揃える必要があった。**手数料300コインの控除自体は実費相当として維持**
--   （弁護士も「維持して構いません」）。
--
-- ■ A-3（第1の3①）
--   「第6条の措置が取られた場合に、購入コイン・報酬コインがどうなるかが
--     **規約全体のどこにも書かれていません**。無定めのまま運用で失効させれば、
--     まさに消費者契約法9条・10条の争点です。」
--
--   規約に第6条の3を新設した。ここではその実装を置く。
--   **違反の内容と、既に提供された役務の対価とは別の事柄。**
--   役務は現に提供されており、その対価まで一律に没収すれば、
--   違反に対する制裁ではなく**利得**になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1) 退会後の換金は最低申請額を適用しない（A-2）
-- ------------------------------------------------------------
-- 退会済みかどうかは profiles.withdrawn_at で判る（0086）。
-- 退会後は**残額の全部を1回で**申請する前提なので、最低額の意味がない。
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 換金事務手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
  v_withdrawn timestamptz;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 0098: **退会後の最終換金には最低申請額を適用しない。**
  -- 5,000未満のまま退会した人が、一度も換金できないまま90日で失うのを防ぐ
  -- (規約 第6条の2第4項)。手数料の控除は退会後も同じ。
  select p.withdrawn_at into v_withdrawn from public.profiles p where p.id = v_uid;

  if p_coins is null or p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;
  if v_withdrawn is null and p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;
  -- 手数料以下では振込が成り立たない(手取りが0以下になる)
  if p_coins <= c_fee then
    raise exception 'BELOW_PAYOUT_FEE';
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

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';

  -- 0077: 係争中のチャージバックに紐づく予約の報酬も保留。
  -- **ホスト全体を止めるのではなく、紐づく額だけを差し引く。**
  v_dispute_hold := public._dispute_payout_hold(v_uid);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、**どちらの保留かを分けて伝える**。
    -- 利用者から見ると原因も待つべき期間も違う(ギフトは7日で明ける／
    -- 係争は決着するまで分からない)ので、同じ文言にしてはいけない。
    if p_coins <= coalesce(v_balance, 0) then
      if v_dispute_hold > 0 and p_coins > coalesce(v_balance, 0) - v_dispute_hold then
        raise exception 'DISPUTE_ON_HOLD';
      end if;
      if v_gift_hold > 0 then
        raise exception 'GIFT_ON_HOLD';
      end if;
    end if;
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
  '換金申請。0098で、退会済み(profiles.withdrawn_at)の場合は最低申請額を適用しないようにした(規約 第6条の2第4項・2026-08-04の弁護士回答)。手数料は退会後も控除する。';

revoke all on function public.request_bank_payout(int) from public, anon;
grant execute on function public.request_bank_payout(int) to authenticated;

-- ------------------------------------------------------------
-- 2) 利用停止・強制退会時のコインの取扱い（A-3・規約 第6条の3）
-- ------------------------------------------------------------
-- 運営が実行する。**cron では走らせない。**
-- 他人の稼得済みの報酬を消す操作なので、必ず人が理由を書いて実行する。
alter table public.profiles
  add column if not exists suspended_at timestamptz,
  add column if not exists payout_claim_deadline timestamptz;

comment on column public.profiles.suspended_at is
  '規約第6条の3。利用停止・強制退会の時刻。';
comment on column public.profiles.payout_claim_deadline is
  '規約第6条の3第2項。この日時まで換金の申請ができる（退会後の90日枠と同じ扱い）。';

create or replace function public.admin_suspend_account(
  p_user_id uuid,
  p_reason text,
  p_forfeit_earned boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;
  -- **理由は必須。** 第6条の3第6項の再審査に応じられない措置は取らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = p_user_id for update;

  -- 第6条の3第5項: 購入コインは消滅する
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots set remaining = 0 where user_id = p_user_id and remaining > 0;
    update public.coin_wallets set balance = 0, bonus_balance = 0 where user_id = p_user_id;
    if v_paid > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_paid, 'expire', 'suspend_paid');
    end if;
    if v_bonus > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_bonus, 'expire', 'suspend_bonus');
    end if;
  end if;

  -- 第6条の3第2項/第3項: **報酬コインは原則として残す。**
  -- 没収するのは、違反行為により取得されたものに限る（運営が個別に判断）。
  if p_forfeit_earned and coalesce(v_earned, 0) > 0 then
    update public.coin_wallets set earned_balance = 0 where user_id = p_user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, -v_earned, 'expire', 'suspend_earned_forfeit');
    v_deadline := null;
  end if;

  update public.profiles
    set suspended_at = now(),
        payout_claim_deadline = v_deadline
    where id = p_user_id;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**
  update public.host_settings set is_host = false where user_id = p_user_id;

  perform public._log_admin_action(
    'suspend_account', p_user_id,
    case when p_forfeit_earned then '報酬コインも没収: ' else '報酬コインは残す: ' end || p_reason);

  return jsonb_build_object(
    'user_id', p_user_id,
    'paid_expired', v_paid,
    'bonus_expired', v_bonus,
    'earned_forfeited', case when p_forfeit_earned then v_earned else 0 end,
    'payout_claim_deadline', v_deadline
  );
end;
$$;

comment on function public.admin_suspend_account(uuid, text, boolean) is
  '規約第6条の3。利用停止・強制退会時のコインの取扱い。購入コインは消滅、報酬コインは原則として残し90日の換金枠を与える。没収は p_forfeit_earned=true を明示したときだけ(違反行為により取得されたものに限る)。理由は必須で、操作記録に残る。';

revoke all on function public.admin_suspend_account(uuid, text, boolean) from public, anon;
grant execute on function public.admin_suspend_account(uuid, text, boolean) to authenticated;
