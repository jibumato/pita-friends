-- ============================================================
-- 0100: 退会・利用停止後の換金は「換金可能な全額を一括」に限る
-- ------------------------------------------------------------
-- 0098(A-2)で最低申請額の適用を外したところ、**条文が書いていることを
-- 実装していない**箇所が2つ残っていた。
--
-- ■ 1) 分割して何回でも申請できた
--   規約 第6条の2第4項は「保有する報酬コインの**全額を一括して**申請する
--   ことができます」と書いてあるのに、実装は回数も額も見ていなかった。
--
--   実測: 1,600コインを 400 × 3回 に分けて申請できた。
--   結果は **振込3件で合計300円、手数料は900円**。
--
--   **これは利用者が得をする穴ではなく、利用者が損をする落とし穴。**
--   1回で申請していれば手取り1,300円だったものが300円になる。
--   運営から見ても、¥100の振込を3件、目視と消し込みで扱うことになる。
--
-- ■ 2) 利用停止された人には最低額の免除が効いていなかった
--   規約 第6条の3第2項は「第6条の2第4項に**準じて**換金の申請を行うことが
--   できます」と定めたのに、実装は `withdrawn_at` しか見ていなかった。
--
--   実測: 1,600コインを持ったまま利用停止された人は `MIN_PAYOUT_COINS` で
--   弾かれ、90日後に消える。**弁護士が指摘した「稼得済み報酬の没収」が、
--   停止の側にそのまま残っていた。**
--
-- ■ なぜ「全額を一括」で足りるのか
--   額を全額に縛ると、1回目で残高が0になるので**2回目は自然に起きない**。
--   回数を数える必要がない。
--
--   ただし保留(ギフトの7日・係争中)がある場合は全額を出せないので、
--   縛るのは「**その時点で換金可能な全額**」。保留が明けたら改めて申請できる。
--   これは分割ではなく、保留の仕組みが働いた結果なので妨げない。
-- ============================================================

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
  v_final boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 0098/0100: **退会または利用停止の後は「最終換金」として扱う。**
  -- 最低申請額を外す代わりに、換金可能な全額を1回で出してもらう
  -- (規約 第6条の2第4項・第6条の3第2項)。
  select (p.withdrawn_at is not null or p.suspended_at is not null)
    into v_final from public.profiles p where p.id = v_uid;
  v_final := coalesce(v_final, false);

  if p_coins is null or p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;
  if not v_final and p_coins < c_min_coins then
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

  -- 0100: **最終換金は分割できない。** 額を全額に縛ると、1回目で残高が0に
  -- なるので2回目は自然に起きない。回数を数える必要がない。
  -- 保留がある場合に「換金可能な全額」で足りるのは、保留が明けてからの
  -- 申請は分割ではなく保留の仕組みが働いた結果だから。
  if v_final and p_coins <> v_available then
    raise exception 'FINAL_PAYOUT_MUST_BE_WHOLE';
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
  '換金申請。退会(withdrawn_at)または利用停止(suspended_at)の後は最終換金として扱い、最低申請額を外す代わりに**換金可能な全額を一括**でのみ申請できる(規約 第6条の2第4項・第6条の3第2項。0098・0100)。手数料は最終換金でも控除する。';

revoke all on function public.request_bank_payout(int) from public, anon;
grant execute on function public.request_bank_payout(int) to authenticated;
