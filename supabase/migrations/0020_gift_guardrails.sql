-- ============================================================
-- ギフト(投げ銭)を「役務に付随する謝礼」へ作り替える(弁護士Q11回答対応)
-- ------------------------------------------------------------
-- 弁護士見解(2026-07-22)の要旨:
--   ・現行の「トーク相手なら誰でも・自由に・換金可」は最もリスクが高い。
--     役務対価が不明確な任意の価値移転は、収納代行の説明が苦しく、為替取引
--     (資金移動業)該当リスクも上がる。
--   ・「実際に一緒に遊んだ相手への“ありがとうチップ”」に限定すれば、役務に
--     付随する謝礼として整理しやすく、各規制のリスクを相対的に下げられる。
--   ・換金ロンダリング(クレカ現金化)対策として、保留期間・上限・相互送金禁止・
--     チャージ直後送金禁止・端末/IP監視を推奨。
--
-- 事業判断(2026-07-22):
--   ・送信条件 = 送り主と受け手の間に「完了した予約(status='completed')」が
--     1回以上あること(付随謝礼として最小要件)。
--   ・上限: 1回50,000 / 直近24時間で50,000 / 直近30日で200,000(コイン=円)。
--   ・相互送金禁止(A→Bが存在すればB→Aは不可、逆も同様)。
--   ・チャージ後24時間は送金不可(クレカ現金化の抑止)。
--   ・受領ギフトは7日間は換金不可(request_bank_payout側で保留を差し引く)。
--   ・同一端末/IP/カード等の自動監視は、クライアントの端末情報取得が必要な
--     ため本マイグレーションの範囲外(別途フォロー)。ここではサーバ側で
--     機械的に判定できる制限をすべて実装する。
-- ============================================================

-- ------------------------------------------------------------
-- send_gift: 完了予約のある相手への“ありがとうギフト”に限定し、各種の
-- 不正・マネロン対策を組み込む(0019版を置き換え)。
-- ------------------------------------------------------------
create or replace function public.send_gift(p_promise_id uuid, p_coins int, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_per_tx    constant int := 50000;   -- 1回あたり上限
  c_max_per_day   constant int := 50000;   -- 直近24時間の合計上限
  c_max_per_month constant int := 200000;  -- 直近30日の合計上限
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_last_purchase timestamptz;
  v_sum_day int;
  v_sum_month int;
  v_gift_id uuid;
  v_sender_name text;
  v_msg text;
  v_body text;
begin
  if v_sender is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < 10 or p_coins > c_max_per_tx then
    raise exception 'INVALID_AMOUNT';
  end if;

  select * into v_promise from public.promises where id = p_promise_id;
  if v_promise.id is null then
    raise exception 'THREAD_NOT_FOUND';
  end if;
  if v_sender not in (v_promise.user_a, v_promise.user_b) then
    raise exception 'FORBIDDEN';
  end if;

  v_receiver := case when v_sender = v_promise.user_a then v_promise.user_b else v_promise.user_a end;

  -- ブロック関係では贈れない
  if exists (
    select 1 from public.blocks
    where (blocker_id = v_sender and blocked_id = v_receiver)
       or (blocker_id = v_receiver and blocked_id = v_sender)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 【付随謝礼】実際に一緒に遊んだ相手(=完了した予約が1回以上ある相手)にのみ贈れる
  if not exists (
    select 1 from public.bookings
    where status = 'completed'
      and ((guest_id = v_sender and host_id = v_receiver)
        or (guest_id = v_receiver and host_id = v_sender))
  ) then
    raise exception 'NO_COMPLETED_PLAY';
  end if;

  -- 【相互送金禁止】相手から自分へのギフトが既にあるなら、こちらからは贈れない
  if exists (
    select 1 from public.gifts where sender_id = v_receiver and receiver_id = v_sender
  ) then
    raise exception 'MUTUAL_GIFT_FORBIDDEN';
  end if;

  -- 【チャージ直後禁止】最後のコイン購入から24時間は送金不可(クレカ現金化の抑止)
  select max(created_at) into v_last_purchase from public.coin_purchases where user_id = v_sender;
  if v_last_purchase is not null and v_last_purchase > now() - interval '24 hours' then
    raise exception 'RECENT_PURCHASE_COOLDOWN';
  end if;

  -- 【上限】直近24時間・直近30日の送金合計(自分が贈った額)
  select coalesce(sum(coins), 0) into v_sum_day
    from public.gifts where sender_id = v_sender and created_at > now() - interval '1 day';
  select coalesce(sum(coins), 0) into v_sum_month
    from public.gifts where sender_id = v_sender and created_at > now() - interval '30 days';
  if v_sum_day + p_coins > c_max_per_day then
    raise exception 'DAILY_LIMIT';
  end if;
  if v_sum_month + p_coins > c_max_per_month then
    raise exception 'MONTHLY_LIMIT';
  end if;

  -- 原資は有償の購入コイン(balance)のみ。無償ボーナスは換金ルートに流入させない。
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  -- 受領者のウォレットが無ければ作成してから加算(換金可能なearned_balanceへ)。
  -- ただし受領後7日間は換金保留(request_bank_payoutで直近7日の受領分を差し引く)。
  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg)
    returning id into v_gift_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_sender, -p_coins, 'gift_sent', 'gift:' || v_gift_id);
  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_receiver, p_coins, 'gift_received', 'gift:' || v_gift_id);

  -- トークに履歴として残す(Realtimeで相手にも即時表示)
  v_body := '🎁 ' || p_coins || 'コインのありがとうギフトを贈りました';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 受領者へ通知
  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんからありがとうギフトが届きました',
    p_coins || 'コインを受け取りました(受領から7日間は換金できません)'
      || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

revoke all on function public.send_gift(uuid, int, text) from public;
grant execute on function public.send_gift(uuid, int, text) to authenticated;

-- ------------------------------------------------------------
-- request_bank_payout: 直近7日に受領したギフト分は換金保留として差し引く。
-- (ホスト報酬(予約)は検収済みで即時に換金可能。ギフトのみ7日保留。)
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;
  c_min_coins constant int := 1000;
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

  -- 直近7日に受領したギフトは換金保留(マネロン対策)。換金可能額から差し引く。
  select coalesce(sum(coins), 0) into v_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';
  v_available := coalesce(v_balance, 0) - v_hold;

  if p_coins > v_available then
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

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;
