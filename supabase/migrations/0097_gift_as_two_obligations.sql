-- ============================================================
-- 0097: ギフトを「二本の債権債務関係」として実装し直す（A-1）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答（論点B）。**規約だけ直しても足りない。**
--
--   「行政の実質判断では、**規約の文言と実装・表示の一貫性が重視されます**」
--   「構成を書き換えても、機能の実質が『誰にでも送金でき、受け手が自由に
--     現金化できる』ものであれば、**実質論で為替に引き寄せられます**」
--
-- 規約 第7条の2 は、ゲスト→当社（コインの消費・消滅）と
-- 当社→ピタメイト（自己の報酬債務としての報酬コインの付与）という
-- 二本の独立した債権債務関係に書き換えた。ここではその実装側を揃える。
--
-- ■ 1) 言い方を変える（トーク本文・通知）
--   「贈りました」「受け取りました」は A→B の移転を表す言い方。
--   **画面の言い方が食い違うと、条文の構成が崩れる。**
--   既に流れたメッセージは書き換えない（過去の事実の改変になる）。
--   表示側（`src/lib/giftSticker.ts`）が新旧どちらの本文も読めるようにしてある。
--
-- ■ 2) 通知の金額を実額にする
--   従前は利用料を引く**前**の額を「受け取りました」と通知していた。
--   実際に付与されるのは 35% 控除後なので、**通知のほうが大きい**数字だった。
--   `platform_fees.net_coins` から実額を読む。
--
-- ■ 3) 制限を3つ足す（論点B(b)）
--   いずれも「役務との牽連性」と「送金網化の防止」を強める方向。
--   ・受領側の30日上限（特定の受け手への資金集中は転用の典型）
--   ・同一の相手への30日累計上限（二者間の反復は原因関係のない資金移動と
--     **最も見分けがつきにくい**）
--   ・完了確定から30日を過ぎたらギフトできない（役務との時間的な牽連）
--
--   ⚠️ **数値を緩める方向の変更は、弁護士に相談してから。**
--   制限は「不特定者間の資金移動機能ではない」ことを示す実質そのものであり、
--   緩めると該当性評価の前提が崩れる（恒久的な制約）。
-- ============================================================

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
  v_gift_lots jsonb;
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
  -- 0097: 受領側の上限・同一相手への累計・完了からの経過日数
  c_max_recv_month  constant int := 1000000;  -- 受領側 30日
  c_max_pair_month  constant int := 100000;   -- 同一の相手へ 30日
  c_gift_window_days constant int := 30;      -- 完了確定からギフトできる期間
  v_recv_month int;
  v_pair_month int;
  v_last_completed timestamptz;
  v_net int;
  v_ip_flag boolean;
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

  -- 【同一端末の自己取引を遮断】(端末一致はほぼ同一人物なので拒否)
  if exists (
    select 1
    from public.user_devices d1
    join public.user_devices d2 on d1.device_id = d2.device_id
    where d1.user_id = v_sender and d2.user_id = v_receiver
  ) then
    raise exception 'SAME_DEVICE_FORBIDDEN';
  end if;

  -- 【付随謝礼】実際に一緒に遊んだ相手(=完了した予約がある相手)にのみ、
  -- かつ**完了確定から c_gift_window_days 以内**に限る(0097)。
  -- 期間で画すことで「完了した役務への謝礼」という性格が強まる。
  -- 無期限にすると、役務との牽連性が切れた資金移動と見分けがつかなくなる。
  -- **完了確定の時刻は bookings に無い**(completed_at 相当の列が存在しない)。
  -- 報酬の付与が完了確定そのものなので、その記録の時刻を使う。
  select max(t.created_at) into v_last_completed
    from public.bookings b
    join public.coin_transactions t
      on t.related_booking_id = b.id and t.type = 'booking_earned'
    where b.status = 'completed'
      and ((b.guest_id = v_sender and b.host_id = v_receiver)
        or (b.guest_id = v_receiver and b.host_id = v_sender));
  if v_last_completed is null then
    raise exception 'NO_COMPLETED_PLAY';
  end if;
  if v_last_completed < now() - make_interval(days => c_gift_window_days) then
    raise exception 'GIFT_WINDOW_CLOSED';
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

  -- 【上限・0097】受領側の集中と、二者間の反復を止める。
  -- 特定の受け手への資金集中はギフティングが送金に転用される典型で、
  -- 二者間の反復は**原因関係のない資金移動と最も見分けがつきにくい**。
  select coalesce(sum(coins), 0) into v_recv_month
    from public.gifts where receiver_id = v_receiver and created_at > now() - interval '30 days';
  if v_recv_month + p_coins > c_max_recv_month then
    raise exception 'RECEIVER_MONTHLY_LIMIT';
  end if;
  select coalesce(sum(coins), 0) into v_pair_month
    from public.gifts
    where sender_id = v_sender and receiver_id = v_receiver
      and created_at > now() - interval '30 days';
  if v_pair_month + p_coins > c_max_pair_month then
    raise exception 'PAIR_MONTHLY_LIMIT';
  end if;

  -- 【IP共有の検知】遮断はしない。調査用フラグを立てるだけ。
  select exists (
    select 1
    from public.user_ips a
    join public.user_ips b on a.ip = b.ip
    where a.user_id = v_sender and b.user_id = v_receiver
  ) into v_ip_flag;

  -- 原資は有償の購入コイン(balance)のみ
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  -- 0088: **追跡する側で消費する。** ギフト → ロット → 購入 がたどれないと、
  -- 規約第8条の6第4項1号の「現に充当された…ギフト」を特定できない
  v_gift_lots := public._consume_coin_lots_tracked(v_sender, 'paid', p_coins);

  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message, sender_device_id, ip_flagged)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg, p_device_id, coalesce(v_ip_flag, false))
    returning id into v_gift_id;

  -- ギフトの行ができてから消費記録を書く(gift_id を入れるため)
  perform public._record_gift_lot_consumptions(v_sender, v_gift_id, v_gift_lots);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_sender, -p_coins, 'gift_sent', 'gift:' || v_gift_id);
  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_receiver, p_coins, 'gift_received', 'gift:' || v_gift_id);

  -- 0097: 「贈りました」= A→B の移転を表す言い方をやめる。
  -- 規約(第7条の2)はコインの消費と報酬コインの付与という二本の構成に
  -- 書き換えており、**画面の言い方が食い違うと構成が崩れる。**
  v_body := '🎁 ありがとうギフト ' || p_coins || 'コイン';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 付与された**実額**(利用料控除後)を通知する。
  -- 従前は控除前の額を「受け取りました」と書いており、実際より大きい数字が出ていた。
  select net_coins into v_net from public.platform_fees where gift_id = v_gift_id;

  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんがありがとうギフトをしました',
    '報酬コイン' || coalesce(v_net, p_coins) || 'コインが付与されました(付与から7日間は換金できません)'
      || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

revoke all on function public.send_gift(uuid, int, text, text) from public;

comment on function public.send_gift(uuid, int, text, text) is
  'ギフト。0097で「AがBに贈る」から「コインの消費＋当社の報酬債務としての報酬コイン付与」の構成に合わせ、文言と制限を改めた（規約第7条の2・2026-08-04の弁護士回答 論点B）。';

revoke all on function public.send_gift(uuid, int, text, text) from public, anon;
grant execute on function public.send_gift(uuid, int, text, text) to authenticated;
