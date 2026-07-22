-- ============================================================
-- ギフト(投げ銭): トークの相手にコインを贈る
-- ------------------------------------------------------------
-- 目的: 予約(時間の対価)とは別に、「楽しかった」「応援したい」という
-- 気持ちをコインで相手に贈れるようにする。ホストがより稼げる導線を増やす。
--
-- 会計・不正対策(0016の方針を踏襲):
--   ・ギフトの原資は「有償の購入コイン(balance)」のみ。
--     無償ボーナス(bonus_balance)は換金可能なearned_balanceに化けさせない
--     (無償→換金の抜け道を塞ぐ)。よって paid 残高が不足なら失敗させる。
--   ・受け取った側は earned_balance(換金可能な報酬コイン)として受領する。
--     ホスト報酬(0013/0014)と同じ扱いで、換金フローで精算できる。
--   ・運営マージンは購入額と換金(手数料)の差で従来どおり確保。ギフト自体に
--     追加の手数料は取らない(ホストにやさしい設計・「稼げる」導線を優先)。
--
-- 安全:
--   ・贈れる相手は「トーク(promise)の相手」に限定する。任意ユーザーへは
--     贈れない(実際につながった相手だけ)。これで乱用を構造的に抑える。
--   ・どちらか一方でもブロックしている関係では贈れない。
-- ============================================================

-- coin_transactions.type にギフトを追加
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus',
    'booking_earned', 'payout', 'expire',
    'gift_sent', 'gift_received'
  ));

-- notifications.type にギフト受領を追加
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_requested', 'booking_cancelled', 'gift_received'
  ));

-- ------------------------------------------------------------
-- gifts: 贈答の記録
-- ------------------------------------------------------------
create table public.gifts (
  id uuid primary key default gen_random_uuid(),
  promise_id uuid not null references public.promises (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  receiver_id uuid not null references auth.users (id) on delete cascade,
  coins int not null check (coins > 0),
  message text check (message is null or char_length(message) <= 100),
  created_at timestamptz not null default now(),
  check (sender_id <> receiver_id)
);

comment on table public.gifts is
  'トークの相手に贈るギフト(投げ銭)。原資は贈り主の有償コイン、受領者はearned_balanceで受け取る。';

alter table public.gifts enable row level security;

-- 当事者(贈り主・受領者)だけが閲覧できる。書き込みは send_gift 経由のみ。
create policy "gifts_select_participant"
  on public.gifts for select
  to authenticated
  using (sender_id = auth.uid() or receiver_id = auth.uid());

create index gifts_receiver_idx on public.gifts (receiver_id, created_at desc);
create index gifts_promise_idx on public.gifts (promise_id, created_at);

-- ------------------------------------------------------------
-- send_gift: トーク相手にコインを贈る
--   p_promise_id  贈る相手とのトーク(promise)
--   p_coins       贈るコイン数(10〜50000)
--   p_message     添えるひとこと(任意・100字まで)
-- ------------------------------------------------------------
create function public.send_gift(p_promise_id uuid, p_coins int, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_gift_id uuid;
  v_sender_name text;
  v_msg text;
  v_body text;
begin
  if v_sender is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < 10 or p_coins > 50000 then
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

  if exists (
    select 1 from public.blocks
    where (blocker_id = v_sender and blocked_id = v_receiver)
       or (blocker_id = v_receiver and blocked_id = v_sender)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 有償残高のみを原資にする(ボーナスは使わせない)
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  -- 受領者のウォレットが無ければ作成してから加算(換金可能なearned_balanceへ)
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
  v_body := '🎁 ' || p_coins || 'コインのギフトを贈りました';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 受領者へ通知(ベルのバッジを光らせる)
  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんからギフトが届きました',
    p_coins || 'コインを受け取りました' || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

revoke all on function public.send_gift(uuid, int, text) from public;
grant execute on function public.send_gift(uuid, int, text) to authenticated;
