-- ============================================================
-- 0101: 制限値を「運営が動かせる場所」へ集約する
-- ------------------------------------------------------------
-- ■ なぜ
--   条文は幅で書いてある(「一定期間」「最長30日」)のに、実装が数値を
--   ハードコードしているせいで、**運営が動かせなくなっていた**箇所がある。
--
--     ・新規ユーザーの購入上限   … platform_pricing にあるが**画面が無い**
--     ・ギフトの上限(6種)       … send_gift の中の `constant` で埋まっている
--
--   前者は SQL Editor を開かないと変えられず、後者は
--   `create or replace function` を書かないと変えられない。どちらも
--   「運営作業は運営コンソールから」という方針から外れている。
--
-- ■ 設計: 条文には上限と手続だけを書き、数値は運営が動かす
--   料率(0091 の admin_schedule_fee_change)がすでにこの形になっている。
--   条文が定めるのは「30%を超えない」「30日前に理由をつけて告知する」だけで、
--   実際の段構成は運営が自由に組める。**上限があるから、上限内では
--   確実に動かせる。**
--
--   同じ形をギフトと新規ユーザー制限にも広げる:
--     ・CHECK 制約が「これ以上は動かせない天井」を持つ
--     ・変更には**理由が必須**で、admin_actions に前後の値ごと残る
--
-- ■ 天井をどこに置いたか(ギフト)
--   ギフトの為替取引該当性を否定している事情のうち、**質的なもの**は
--   ここでは動かせない(相手方の限定・相互送金の禁止・原資は購入コインのみ・
--   チャージ直後の禁止・受領から7日の換金保留)。これらは数値ではないので
--   そもそもこの表に無い。
--
--   動かせるのは「いくらまで」「いつまで」だけで、それにも天井を置く。
--   天井は現在値の2倍前後、期間は90日(3か月)。**付随謝礼として説明できる
--   範囲**を超えないための線で、緩めきっても構成が変わらない幅に収めてある。
--
-- ■ ここに入れなかったもの
--   換金の最低申請額(5,000)と換金事務手数料(300)は入れていない。
--   特商法表記・ウォレット画面・利用規約に**数値そのものが書かれている**ため、
--   変えるなら書面の改定とセットになる。表だけ動かせるようにすると、
--   画面の数字と実際の挙動がずれる事故になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. ギフトの上限を platform_pricing へ移す
--
-- 既定値は 0097 時点の `constant` と同じ。**この migration では挙動を
-- 変えない。** 動かせる場所に移すだけ。
-- ------------------------------------------------------------
alter table public.platform_pricing
  add column if not exists gift_max_per_tx int not null default 50000,
  add column if not exists gift_max_per_day int not null default 50000,
  add column if not exists gift_max_per_month int not null default 200000,
  add column if not exists gift_max_recv_month int not null default 1000000,
  add column if not exists gift_max_pair_month int not null default 100000,
  add column if not exists gift_window_days int not null default 30;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'platform_pricing_gift_limits_check') then
    alter table public.platform_pricing
      add constraint platform_pricing_gift_limits_check
      check (
        -- 天井。ここを超える値は入れられない(規約 第7条の2の建て付けを保つ)
            gift_max_per_tx     between 10 and 100000
        and gift_max_per_day    between 10 and 100000
        and gift_max_per_month  between 10 and 500000
        and gift_max_recv_month between 10 and 2000000
        and gift_max_pair_month between 10 and 200000
        -- 完了確定からギフトできる期間。3か月を超えると、
        -- 「完了した役務への謝礼」という牽連性の説明が苦しくなる
        and gift_window_days    between 1 and 90
        -- 順序。1回 <= 1日 <= 30日、同一相手 <= 受領側 でないと
        -- 内側の上限が意味を失う
        and gift_max_per_day    >= gift_max_per_tx
        and gift_max_per_month  >= gift_max_per_day
        and gift_max_recv_month >= gift_max_pair_month
      );
  end if;
end $$;

comment on column public.platform_pricing.gift_max_per_tx is
  'ギフト1回あたりの上限(コイン)。天井 100,000。';
comment on column public.platform_pricing.gift_max_per_day is
  '送り主の直近24時間の合計上限(コイン)。天井 100,000。';
comment on column public.platform_pricing.gift_max_per_month is
  '送り主の直近30日の合計上限(コイン)。天井 500,000。';
comment on column public.platform_pricing.gift_max_recv_month is
  '受領側の直近30日の合計上限(コイン)。特定の受け手への資金集中を止める。天井 2,000,000。';
comment on column public.platform_pricing.gift_max_pair_month is
  '同一の相手への直近30日の合計上限(コイン)。二者間の反復を止める。天井 200,000。';
comment on column public.platform_pricing.gift_window_days is
  'プレイ完了の確定からギフトできる期間(日)。規約第7条の2は「一定期間」としか書いていないので数値は動かせる。天井 90。';

-- ------------------------------------------------------------
-- 2. send_gift を表から読むようにする
--
-- 0097 の定義を出発点にして、`constant` の6つを select に置き換えただけ。
-- **それ以外の判定・順序・文言は 0097 のまま。**
-- (関数を作り直すときは最新の定義から始めること)
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
  v_gift_lots jsonb;
  -- 0101: 上限は platform_pricing から読む(運営コンソールで変えられる)
  v_max_per_tx int;
  v_max_per_day int;
  v_max_per_month int;
  v_max_recv_month int;
  v_max_pair_month int;
  v_window_days int;
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_last_purchase timestamptz;
  v_sum_day int;
  v_sum_month int;
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

  select gift_max_per_tx, gift_max_per_day, gift_max_per_month,
         gift_max_recv_month, gift_max_pair_month, gift_window_days
    into v_max_per_tx, v_max_per_day, v_max_per_month,
         v_max_recv_month, v_max_pair_month, v_window_days
    from public.platform_pricing where id = 1;

  if p_coins is null or p_coins < 10 or p_coins > v_max_per_tx then
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
  -- かつ**完了確定から gift_window_days 以内**に限る(0097)。
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
  if v_last_completed < now() - make_interval(days => v_window_days) then
    raise exception 'GIFT_WINDOW_CLOSED';
  end if;

  -- 【相互送金禁止】
  if exists (
    select 1 from public.gifts where sender_id = v_receiver and receiver_id = v_sender
  ) then
    raise exception 'MUTUAL_GIFT_FORBIDDEN';
  end if;

  -- 【チャージ直後禁止】最後のコイン購入から24時間は送金不可。
  -- **これは数値の調整ではなく質的な遮断なので、表に出していない。**
  select max(created_at) into v_last_purchase from public.coin_purchases where user_id = v_sender;
  if v_last_purchase is not null and v_last_purchase > now() - interval '24 hours' then
    raise exception 'RECENT_PURCHASE_COOLDOWN';
  end if;

  -- 【上限】直近24時間・直近30日の送金合計
  select coalesce(sum(coins), 0) into v_sum_day
    from public.gifts where sender_id = v_sender and created_at > now() - interval '1 day';
  select coalesce(sum(coins), 0) into v_sum_month
    from public.gifts where sender_id = v_sender and created_at > now() - interval '30 days';
  if v_sum_day + p_coins > v_max_per_day then
    raise exception 'DAILY_LIMIT';
  end if;
  if v_sum_month + p_coins > v_max_per_month then
    raise exception 'MONTHLY_LIMIT';
  end if;

  -- 【上限・0097】受領側の集中と、二者間の反復を止める。
  -- 特定の受け手への資金集中はギフティングが送金に転用される典型で、
  -- 二者間の反復は**原因関係のない資金移動と最も見分けがつきにくい**。
  select coalesce(sum(coins), 0) into v_recv_month
    from public.gifts where receiver_id = v_receiver and created_at > now() - interval '30 days';
  if v_recv_month + p_coins > v_max_recv_month then
    raise exception 'RECEIVER_MONTHLY_LIMIT';
  end if;
  select coalesce(sum(coins), 0) into v_pair_month
    from public.gifts
    where sender_id = v_sender and receiver_id = v_receiver
      and created_at > now() - interval '30 days';
  if v_pair_month + p_coins > v_max_pair_month then
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

comment on function public.send_gift(uuid, int, text, text) is
  'ギフト。0097で「AがBに贈る」から「コインの消費＋当社の報酬債務としての報酬コイン付与」の構成に合わせ、文言と制限を改めた（規約第7条の2・2026-08-04の弁護士回答 論点B）。0101で上限値を platform_pricing から読むようにした。';

revoke all on function public.send_gift(uuid, int, text, text) from public, anon;
grant execute on function public.send_gift(uuid, int, text, text) to authenticated;

-- ------------------------------------------------------------
-- 3. 運営コンソールから読む
--
-- **天井も一緒に返す。** 画面側に数字を書き写すと、CHECK 制約を緩めた
-- ときに画面だけ古い天井を出し続ける。出典は制約のあるこちら側に置く。
-- ------------------------------------------------------------
create or replace function public.admin_platform_limits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.platform_pricing;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.platform_pricing where id = 1;

  return jsonb_build_object(
    'newUser', jsonb_build_object(
      'days', v_p.new_user_days,
      'purchaseMaxYen', v_p.new_user_purchase_max_yen,
      'periodPurchaseMaxYen', v_p.new_user_period_purchase_max_yen,
      'payoutHoldDays', v_p.new_user_payout_hold_days
    ),
    'gift', jsonb_build_object(
      'maxPerTx', v_p.gift_max_per_tx,
      'maxPerDay', v_p.gift_max_per_day,
      'maxPerMonth', v_p.gift_max_per_month,
      'maxRecvMonth', v_p.gift_max_recv_month,
      'maxPairMonth', v_p.gift_max_pair_month,
      'windowDays', v_p.gift_window_days
    ),
    -- 天井(CHECK 制約と同じ値。片方だけ直すと画面が嘘をつく)
    'caps', jsonb_build_object(
      'newUserPayoutHoldDays', 30,
      'giftMaxPerTx', 100000,
      'giftMaxPerDay', 100000,
      'giftMaxPerMonth', 500000,
      'giftMaxRecvMonth', 2000000,
      'giftMaxPairMonth', 200000,
      'giftWindowDays', 90
    ),
    'updatedAt', v_p.updated_at
  );
end;
$$;

comment on function public.admin_platform_limits() is
  '運営コンソールの「制限値」タブ。現在値と、CHECK 制約が定める天井を返す。';

revoke all on function public.admin_platform_limits() from public, anon;
grant execute on function public.admin_platform_limits() to authenticated;

-- ------------------------------------------------------------
-- 4. 運営コンソールから変える
--
-- ■ 理由を必須にしているのは、運営を縛るためではなく守るため
--   料率変更(第8条の2第4項)と同じ。後から「理由なく上限を下げて
--   換金させなかった」と言われたときに、反証できる記録がこれしかない。
--
-- ■ 部分更新
--   p_values に入っているキーだけを更新する。画面が1項目ずつ直せる。
--   入っていないキーは現在値のまま(coalesce)。
--
-- ■ 通知は出さない
--   料率と違い、これらは**不正防止の措置**で、規約第8条の6第5項が
--   「具体的な数値は変更することがあります」と定めている。個別通知の
--   義務が無い代わりに、admin_actions への記録を必ず残す。
-- ------------------------------------------------------------
create or replace function public.admin_update_platform_limits(
  p_reason text,
  p_values jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_diff text := '';
  v_key text;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object'
     or p_values = '{}'::jsonb then
    raise exception 'NO_CHANGES';
  end if;

  -- 知らないキーは黙って捨てない。**綴り間違いで「変えたつもり」に
  -- なるのが一番まずい**ので、その場で落とす
  for v_key in select jsonb_object_keys(p_values)
  loop
    if v_key not in (
      'newUserDays', 'newUserPurchaseMaxYen', 'newUserPeriodPurchaseMaxYen',
      'newUserPayoutHoldDays', 'giftMaxPerTx', 'giftMaxPerDay',
      'giftMaxPerMonth', 'giftMaxRecvMonth', 'giftMaxPairMonth',
      'giftWindowDays'
    ) then
      raise exception 'UNKNOWN_KEY:%', v_key;
    end if;
  end loop;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days
  ) into v_before
  from public.platform_pricing where id = 1;

  -- 天井を超えた値は CHECK 制約が落とす。**ここで先回りして
  -- 個別のエラー名にしない** — 制約が唯一の出典であるほうが、
  -- 制約を直したときに漏れない
  update public.platform_pricing set
    new_user_days = coalesce((p_values ->> 'newUserDays')::int, new_user_days),
    new_user_purchase_max_yen =
      coalesce((p_values ->> 'newUserPurchaseMaxYen')::int, new_user_purchase_max_yen),
    new_user_period_purchase_max_yen =
      coalesce((p_values ->> 'newUserPeriodPurchaseMaxYen')::int, new_user_period_purchase_max_yen),
    new_user_payout_hold_days =
      coalesce((p_values ->> 'newUserPayoutHoldDays')::int, new_user_payout_hold_days),
    gift_max_per_tx = coalesce((p_values ->> 'giftMaxPerTx')::int, gift_max_per_tx),
    gift_max_per_day = coalesce((p_values ->> 'giftMaxPerDay')::int, gift_max_per_day),
    gift_max_per_month = coalesce((p_values ->> 'giftMaxPerMonth')::int, gift_max_per_month),
    gift_max_recv_month = coalesce((p_values ->> 'giftMaxRecvMonth')::int, gift_max_recv_month),
    gift_max_pair_month = coalesce((p_values ->> 'giftMaxPairMonth')::int, gift_max_pair_month),
    gift_window_days = coalesce((p_values ->> 'giftWindowDays')::int, gift_window_days),
    updated_at = now()
  where id = 1;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days
  ) into v_after
  from public.platform_pricing where id = 1;

  -- 「何を いくつから いくつへ」を記録に残す。
  -- 前後の値が無いと、記録があっても後から説明できない
  for v_key in select jsonb_object_keys(v_after)
  loop
    if (v_before ->> v_key) is distinct from (v_after ->> v_key) then
      v_diff := v_diff || case when v_diff = '' then '' else ' / ' end
        || v_key || ': ' || (v_before ->> v_key) || '→' || (v_after ->> v_key);
    end if;
  end loop;

  if v_diff = '' then
    raise exception 'NO_CHANGES';
  end if;

  perform public._log_admin_action('update_platform_limits', null,
    v_diff || ' 理由: ' || p_reason);

  return jsonb_build_object('changed', v_diff, 'values', v_after);
end;
$$;

comment on function public.admin_update_platform_limits(text, jsonb) is
  '制限値の変更。天井は platform_pricing の CHECK 制約が持つ。理由は必須で、前後の値とともに admin_actions に残る(0101)。';

revoke all on function public.admin_update_platform_limits(text, jsonb) from public, anon;
grant execute on function public.admin_update_platform_limits(text, jsonb) to authenticated;
