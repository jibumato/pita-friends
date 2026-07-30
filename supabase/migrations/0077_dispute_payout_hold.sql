-- ============================================================
-- 0077: 係争中のチャージバックに紐づく報酬は換金保留にする
-- ------------------------------------------------------------
-- ■ 税理士の第3回回答(2026-07-30)より
--
--   「チャージバック時に『換金を停止しない』設計ですが、係争中に当該取引の
--     報酬コインが換金されて出ていくと、**回収不能が確定します。**
--     ホスト全体を止めるのは過剰なので、**当該チャージバックに直接紐づく
--     予約の報酬コインだけ決着まで換金保留**にできませんか。
--     技術的に困難なら、Q14-a③の規約条項が必須になります。」
--
--   0075 では「ホストとしての換金は止めない」と書いた。落ち度の無いホストを
--   巻き込まないためだが、**ホスト全体を止めるか / 何も止めないか**の
--   二択で考えていた。**紐づく分だけ止める**という第三の道があった。
--
-- ■ 追えるのか(0075では「実務上不可能」と書いていた)
--   0075 は**どのコインが争われている購入由来か**を追うのは不可能、と書いた。
--   これはコイン単位の話としては今も正しい。しかし**予約単位なら追える。**
--
--     異議申立て
--       → payment_intent
--       → coin_purchases(誰が・いつ買ったか)
--       → その購入**以後**にその人が入れた予約
--       → coin_transactions(type='booking_earned', related_booking_id)
--       → ホストごとの報酬額
--
--   `related_booking_id` は 0009 からある列で、報酬の付与時に必ず入る。
--   **購入日以後の予約に限る**ので、争われている購入より前の予約は巻き込まない。
--
--   ⚠️ これは**過大にも過小にもなりうる近似**である。コインは混ざるので、
--   争われた1万円が実際にどの予約に使われたかは特定できない。
--   購入以後の予約をすべて対象にするのは**保守的な側(過大)**に倒した判断。
--   決着したら解除されるので、過大でも一時的な保留にとどまる。
--
-- ■ 何を止め、何を止めないか
--   止める: **紐づく予約の報酬コインの額だけ**を換金可能額から差し引く
--   止めない: それを超える分の換金。ホストの他の稼ぎは自由に換金できる
--
--   「ホスト全体を止めるのは過剰」というご指摘のとおりの設計にした。
--
-- ■ それでも規約条項は必要
--   この保留で防げるのは「**申立て後に**換金されること」だけである。
--   **申立てより前に換金・振込まで終わっていた分は、取り戻せない。**
--   したがって Q14-a③(ホストの未払報酬からの相殺)の規約条項は依然として必要。
--   弁護士へは「**実装で完全には防げないので規約で担保したい**」と補足する
--   (`docs/legal/lawyer-questions-open.md` Q38)。
-- ============================================================

-- ------------------------------------------------------------
-- _dispute_payout_hold: そのホストの報酬のうち、係争中の購入に紐づく額
-- ------------------------------------------------------------
create or replace function public._dispute_payout_hold(p_host uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(t.amount), 0)::int
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  join public.payment_disputes d on d.user_id = b.guest_id
  join public.coin_purchases cp
    on cp.stripe_payment_intent = d.stripe_payment_intent
  where t.user_id = p_host
    and t.type = 'booking_earned'
    and t.amount > 0
    and d.resolved_at is null
    -- **争われている購入より後に入った予約に限る。**
    -- それより前の予約は、その購入のコインでは払えないので無関係。
    and b.created_at >= cp.created_at;
$$;

comment on function public._dispute_payout_hold(uuid) is
  '係争中のチャージバックに紐づく予約の報酬額(換金保留額)。決着(resolved_at)で自動的に0に戻る。税理士の第3回回答。';

revoke all on function public._dispute_payout_hold(uuid) from public;

-- ------------------------------------------------------------
-- request_bank_payout: ギフト保留(0069)に加えて係争保留を差し引く
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
  v_gift_hold int;
  v_dispute_hold int;
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
  '報酬コインの換金申請。最低5,000コイン・手数料300コイン。直近7日のギフト受領分(0069)と、係争中のチャージバックに紐づく予約の報酬(0077)は換金保留。';

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;

-- ------------------------------------------------------------
-- my_payout_hold: 自分の換金保留額の内訳(ウォレット画面の表示用)
-- ------------------------------------------------------------
-- 保留があるのに理由が分からないのが最も困る。**額と理由を出す。**
-- ただし係争については「お支払いの確認中」以上のことは書かない
-- (0075と同じ理由。凍結の回避方法を探る材料にしない)。
-- ------------------------------------------------------------
create or replace function public.my_payout_hold()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'earnedBalance', coalesce((select earned_balance from public.coin_wallets
                                where user_id = auth.uid()), 0),
    'giftHold', coalesce((select sum(coins) from public.gifts
                           where receiver_id = auth.uid()
                             and created_at > now() - interval '7 days'), 0),
    'disputeHold', public._dispute_payout_hold(auth.uid()),
    'available', greatest(0,
        coalesce((select earned_balance from public.coin_wallets
                   where user_id = auth.uid()), 0)
      - coalesce((select sum(coins) from public.gifts
                   where receiver_id = auth.uid()
                     and created_at > now() - interval '7 days'), 0)
      - public._dispute_payout_hold(auth.uid()))
  )
  where auth.uid() is not null;
$$;

comment on function public.my_payout_hold() is
  '換金できる額と、保留の内訳(ギフト/係争)。ウォレット画面の表示用。';

revoke all on function public.my_payout_hold() from public;
grant execute on function public.my_payout_hold() to authenticated;
