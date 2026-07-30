-- ============================================================
-- 0069: ギフトの7日換金保留を復活させる(0063で消えていた)
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   0020 で `request_bank_payout` に「**受領から7日以内のギフトは換金保留**」を
--   入れた(マネー・ローンダリング / クレジットカード現金化の対策)。
--   ところが 0063(最低換金額を1,000→5,000に変えた移行)が、**0020ではなく
--   0014 の本文をベースに `create or replace` してしまい、保留のロジックが
--   まるごと消えた。** 関数は正常に動くので気づけず、テストも無かった。
--
-- ■ なぜ重大か
--   この保留は、単なる機能ではなく**対外的に説明している統制**である。
--     ・利用規約 第7条の2第5号「受領日から7日間は換金できない保留期間を設けます」
--     ・弁護士への説明(Q11-c)で、換金ロンダリング対策の一つとして挙げている
--   つまり「規約に書いてあるのに実装されていない」状態だった。
--   条文と実装の食い違いは、それ自体が説明責任の問題になる。
--
-- ■ ここで直すこと
--   0063 の内容(手数料300・最低5,000コイン)は維持したうえで、
--   0020 の保留ロジックを戻す。**両方が入った状態が正しい。**
--
--   ・換金可能額 = 報酬コイン残高 − 直近7日に受領したギフトの合計
--   ・保留のせいで足りない場合は `GIFT_ON_HOLD` を返す
--     (残高不足 `INSUFFICIENT_EARNED_BALANCE` と区別する。利用者に
--      「あと何日待てばよいか」を案内できるようにするため)
--
-- ■ 再発防止
--   `supabase/tests/89_gift_legal_invariants.sql` を追加した。
--   保留の境界を両側から確かめる(保留分を含む額は弾かれ、
--   換金可能額ちょうどは通る)ので、次に誰かが同じ消し方をすれば落ちる。
-- ============================================================

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
  v_hold int;
  v_available int;
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

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';
  v_available := coalesce(v_balance, 0) - v_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、そう伝える
    if v_hold > 0 and p_coins <= coalesce(v_balance, 0) then
      raise exception 'GIFT_ON_HOLD';
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
  '報酬コインの換金申請。最低5,000コイン・手数料300コイン。直近7日に受領したギフトは換金保留(0069で0063から復活)。';

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;
