-- ============================================================
-- ギフトの端末監視: 同一端末での自己取引(換金ロンダリング)を検知・遮断する
-- ------------------------------------------------------------
-- 弁護士Q11(c)の推奨「同一IP・端末・カード・Wi-Fiを監視し、換金停止・調査の
-- 対象とする」への対応の一部。
--
-- 本マイグレーションで実装する範囲(サーバ側で機械的に判定できるもの):
--   ・クライアントが localStorage に永続化する端末ID(device_id)を、ログイン中の
--     ユーザーごとに user_devices へ記録する(record_device)。
--   ・ギフト送信時に、送り主と受け手が「同一端末を共有した履歴」があれば、
--     ほぼ同一人物による自己取引とみなして送信を遮断する(SAME_DEVICE_FORBIDDEN)。
--   ・監視・調査用に、送り主の端末IDをギフトに記録する。
--
-- 本マイグレーションの範囲外(継続課題・別途フォロー):
--   ・IPアドレス監視: PostgRESTのRPCからクライアントIPを確実に取得できないため、
--     Edge Function 経由(ヘッダのX-Forwarded-Forを読む)にするか、別途ログ基盤が必要。
--   ・カード(決済手段)フィンガープリント監視: 購入フロー(Stripe webhook)側で
--     payment_method のフィンガープリントを保存する改修が必要。
--   端末IDはクリアされうる(完全ではない)が、通常の自己取引の主要導線は捕捉できる。
-- ============================================================

-- ------------------------------------------------------------
-- user_devices: ユーザーが使った端末(ブラウザ)の記録
-- ------------------------------------------------------------
create table public.user_devices (
  user_id uuid not null references auth.users (id) on delete cascade,
  device_id text not null check (char_length(device_id) between 8 and 128),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  uses int not null default 1,
  primary key (user_id, device_id)
);

comment on table public.user_devices is
  'ユーザーが利用した端末ID(クライアントのlocalStorageに永続化したランダムID)の記録。ギフトの自己取引検知に用いる。';

alter table public.user_devices enable row level security;

create policy "user_devices_select_own"
  on public.user_devices for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは record_device / send_gift(SECURITY DEFINER)経由のみ。

create index user_devices_device_idx on public.user_devices (device_id);

-- ------------------------------------------------------------
-- gifts に監視用の端末IDを追加
-- ------------------------------------------------------------
alter table public.gifts add column sender_device_id text;

-- ------------------------------------------------------------
-- record_device: ログイン中ユーザーの端末IDを記録(アプリ起動時に呼ぶ)
-- ------------------------------------------------------------
create function public.record_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return;
  end if;
  if p_device_id is null or char_length(p_device_id) < 8 or char_length(p_device_id) > 128 then
    return;
  end if;
  insert into public.user_devices (user_id, device_id)
    values (v_uid, p_device_id)
  on conflict (user_id, device_id) do update
    set last_seen_at = now(), uses = public.user_devices.uses + 1;
end;
$$;

revoke all on function public.record_device(text) from public;
grant execute on function public.record_device(text) to authenticated;

-- ------------------------------------------------------------
-- send_gift: 端末IDを受け取り、同一端末の自己取引を遮断する(0020版を置き換え)
-- ------------------------------------------------------------
create or replace function public.send_gift(
  p_promise_id uuid,
  p_coins int,
  p_message text default null,
  p_device_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_per_tx    constant int := 50000;
  c_max_per_day   constant int := 50000;
  c_max_per_month constant int := 200000;
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

  -- 送り主の端末を記録(以降の共有判定に使う)
  if p_device_id is not null and char_length(p_device_id) between 8 and 128 then
    insert into public.user_devices (user_id, device_id)
      values (v_sender, p_device_id)
    on conflict (user_id, device_id) do update
      set last_seen_at = now(), uses = public.user_devices.uses + 1;
  end if;

  -- ブロック関係では贈れない
  if exists (
    select 1 from public.blocks
    where (blocker_id = v_sender and blocked_id = v_receiver)
       or (blocker_id = v_receiver and blocked_id = v_sender)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 【同一端末の自己取引を遮断】送り主と受け手が同じ端末を共有した履歴があれば拒否
  if exists (
    select 1
    from public.user_devices d1
    join public.user_devices d2 on d1.device_id = d2.device_id
    where d1.user_id = v_sender and d2.user_id = v_receiver
  ) then
    raise exception 'SAME_DEVICE_FORBIDDEN';
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

  -- 【相互送金禁止】
  if exists (
    select 1 from public.gifts where sender_id = v_receiver and receiver_id = v_sender
  ) then
    raise exception 'MUTUAL_GIFT_FORBIDDEN';
  end if;

  -- 【チャージ直後禁止】最後のコイン購入から24時間は送金不可
  select max(created_at) into v_last_purchase from public.coin_purchases where user_id = v_sender;
  if v_last_purchase is not null and v_last_purchase > now() - interval '24 hours' then
    raise exception 'RECENT_PURCHASE_COOLDOWN';
  end if;

  -- 【上限】直近24時間・直近30日の送金合計
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

  -- 原資は有償の購入コイン(balance)のみ
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message, sender_device_id)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg, p_device_id)
    returning id into v_gift_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_sender, -p_coins, 'gift_sent', 'gift:' || v_gift_id);
  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_receiver, p_coins, 'gift_received', 'gift:' || v_gift_id);

  v_body := '🎁 ' || p_coins || 'コインのありがとうギフトを贈りました';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

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

revoke all on function public.send_gift(uuid, int, text, text) from public;
grant execute on function public.send_gift(uuid, int, text, text) to authenticated;

-- 旧シグネチャ(4引数でない版)は不要になるが、明示的に削除はしない
-- (PostgRESTは引数名で解決するため、フロントは常に4引数版を呼ぶ)。
