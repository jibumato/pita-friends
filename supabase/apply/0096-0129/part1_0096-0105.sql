-- ============================================================
-- 本番への適用 パート 1/5(0096〜0105)
-- tools/bundle-migrations.py で生成。手で直さないこと。
--
-- 1. このファイルの中身を全部 SQL Editor に貼って Run する
-- 2. docs/check-migrations.sql を流し、「次に適用するファイル」が
--    0105 の次(最後のパートなら「すべて適用済み」)になったことを確かめる
-- 3. エラーが出たら、そこで止めて内容を知らせる
--    (このパートの変更はまるごと取り消されている)
--
-- 先頭の関所は、順番の飛ばしと二重適用を止めるためのもの。
-- ============================================================

do $guard$
begin
  if not ((to_regprocedure('public.' || 'credit_coins_for_purchase(uuid, text, int, int, int, text, text)') is not null and not has_function_privilege('anon', to_regprocedure('public.' || 'credit_coins_for_purchase(uuid, text, int, int, int, text, text)'), 'execute'))) then
    raise exception '順番が違います: 0095_close_server_only_functions がまだ当たっていません。前のパートから流してください';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'coin_purchases' and column_name = 'payment_method') then
    raise exception 'このパートは適用済みです(0096_payment_method_on_purchase が当たっています)。docs/check-migrations.sql で次に流すファイルを確かめてください';
  end if;
end $guard$;

-- >>>>>>>> 0096_payment_method_on_purchase.sql
-- ============================================================
-- 0096: コイン購入の決済手段を記録する（PayPay導入に伴う）
-- ------------------------------------------------------------
-- PayPay を決済手段に追加すると、**0080(E-9)のカード共有検知が効かない
-- 購入が生まれる。**
--
-- 0080 でカードのフィンガープリントを最重要の手掛かりに据えたのは、
-- 「端末IDは消せる、IPは変わる、カードは同じ実カードである限り変わらない」
-- という理由だった。PayPay 払いにはカードが無いので、その手掛かりが無い。
--
-- 厄介なのは**検知が弱くなること自体ではなく、弱くなったことが見えないこと**。
-- 換金画面に「カード共有 0件」と出ていると、運営は「調べた結果シロだった」と
-- 読む。実際には「調べようがなかった」かもしれない。この2つは意味が違う。
--
-- そこで購入ごとに決済手段を残し、換金画面で
-- 「この人の購入にはカードで判定できないものが N 件ある」と出せるようにする。
-- 遮断はしない。PayPay で買うこと自体は正当なので、目視の材料にとどめる
-- （0080・0022 と同じ扱い）。
--
-- 会計上も効く。カードと PayPay で決済手数料の料率が違うため、
-- 手数料の内訳を後から説明できる。
-- ============================================================

-- ------------------------------------------------------------
-- 1) coin_purchases.payment_method
-- ------------------------------------------------------------
-- **null を許す。** 0096 より前の購入には決済手段が入らないが、
-- 当時はカードしか有効化していなかったので、null は「カード」と読んでよい。
-- 遡って 'card' で埋めない——「記録が無い」と「カードだった」は別の事実で、
-- 埋めてしまうと後から区別がつかなくなる。
alter table public.coin_purchases
  add column if not exists payment_method text;

comment on column public.coin_purchases.payment_method is
  'Stripe の payment_method_details.type（card / paypay 等）。0096より前の購入は null（当時はカードのみ有効）。stripe-webhook が決済成立後に書き込む。';

-- ------------------------------------------------------------
-- 2) admin_pending_payouts に「カードで判定できない購入の件数」を足す
-- ------------------------------------------------------------
-- 返す列が増えるので create or replace では差し替えられない
drop function if exists public.admin_pending_payouts(int);

create function public.admin_pending_payouts(p_limit int default 100)
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  coins int,
  amount_yen int,
  fee_yen int,
  created_at timestamptz,
  bank_name text,
  bank_code text,
  branch_name text,
  branch_code text,
  account_type text,
  account_number text,
  account_holder_kana text,
  is_verified boolean,
  shared_card_count int,
  flagged_gift_count int,
  non_card_purchase_count int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*) into v_n from public.payouts p where p.status = 'pending';
  perform public._log_admin_action('view_pending_payouts', null, v_n || '件の口座情報を表示');

  return query
  select p.id, p.user_id,
         coalesce(nullif(pf.nickname, ''), '(不明)'),
         p.coins, p.amount_yen, p.fee_yen, p.created_at,
         p.bank_name, p.bank_code, p.branch_name, p.branch_code,
         p.account_type, p.account_number, p.account_holder_kana,
         coalesce(ts.is_verified, false),
         -- このピタメイトとカードを共有している**他の**アカウントの数
         (select count(distinct b.user_id)::int
            from public.user_payment_cards a
            join public.user_payment_cards b
              on b.fingerprint = a.fingerprint and b.user_id <> a.user_id
           where a.user_id = p.user_id),
         -- 受け取ったギフトのうち、IPまたはカードの共有で印が付いたもの
         (select count(*)::int from public.gifts g
           where g.receiver_id = p.user_id
             and (g.ip_flagged or g.card_flagged)),
         -- カードのフィンガープリントで判定できない購入(PayPay等)の件数。
         -- null は 0096 以前＝当時カードのみなので数えない。
         (select count(*)::int from public.coin_purchases cp
           where cp.user_id = p.user_id
             and cp.payment_method is not null
             and cp.payment_method <> 'card')
  from public.payouts p
  left join public.profiles pf on pf.id = p.user_id
  left join public.profile_trust_stats ts on ts.user_id = p.user_id
  where p.status = 'pending'
  order by p.created_at
  limit greatest(1, least(p_limit, 500));
end;
$$;

comment on function public.admin_pending_payouts(int) is
  '未振込の換金申請と振込先(運営のみ)。0080でカード共有件数と要確認ギフト件数、0096でカード判定できない購入の件数を追加した(資金が出る瞬間に目に入るようにするため)。閲覧は操作記録に残る。';

revoke all on function public.admin_pending_payouts(int) from public;
grant execute on function public.admin_pending_payouts(int) to authenticated;


-- >>>>>>>> 0097_gift_as_two_obligations.sql
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


-- >>>>>>>> 0098_withdrawal_payout_and_suspension_coins.sql
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


-- >>>>>>>> 0099_offset_time_limit.sql
-- ============================================================
-- 0099: 相殺の時的限界と、不正関与者の扱い（C-2）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答（第1の1(4)）。第8条の6は四重の限定を置いていて
-- 「抑制の効いた設計」と評価されたが、微修正が2点あった。
--
-- ■ 控除の時的限界（実装するのはこちら）
--   「**控除の時的限界が無限定**です。国際ブランドのチャージバック申立期間
--     （概ね120日）を踏まえ、報酬確定から一定期間（例えば180日）を経過した
--     取引は控除の対象としない旨の限定を置くと、**ピタメイト側の予見可能性が
--     高まり、条項の許容性がさらに強固になります**。」
--
--   期限を切らないと、ピタメイトは**いつまで取り返されうるのか分からない**。
--   規約 第8条の6第4項2の2号に条文を置き、ここで候補の抽出から外す。
--
-- ■ 不正関与者への請求（条文のみ・実装なし）
--   「第4項2号（支払済み金銭の返還を請求しない）は、**ピタメイト自身が不正に
--     関与していた場合**……にまで請求権を放棄する趣旨ではないはずですから、
--     ただし書を付すべきです。」
--
--   こちらは**支払済みの金銭を請求する**話で、システムの操作ではない
--   （訴訟・交渉の世界）。規約 第8条の6第4項2号のただし書だけを置いた。
--   実装で自動化するものではない。
-- ============================================================

create or replace function public.chargeback_offset_preview(p_purchase_id uuid)
returns table (
  host_id uuid,
  nickname text,
  booking_id uuid,
  gift_id uuid,
  funded_coins int,
  host_earned_coins int,
  deductible_coins int,
  already_offset boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  with funded as (
    select c.booking_id, c.gift_id, sum(c.coins)::int as funded
    from public.coin_lot_consumptions c
    join public.coin_lots l on l.id = c.lot_id
    where l.purchase_id = p_purchase_id
      -- **返還済み(restored_at)は充当が巻き戻っているので対象外**
      and c.restored_at is null
    group by c.booking_id, c.gift_id
  ),
  rows as (
    -- 予約: 報酬として確定した分だけが控除の対象(3項)
    select b.host_id,
           f.booking_id,
           null::uuid as gift_id,
           f.funded,
           -- **利用料を引いた後の、実際に渡った枚数。**
           -- 報酬確定は総額で入り(J8)、利用料は別行で控除される(J10)。
           -- 総額で引くと、当社の取り分まで相手から取り返すことになる
           coalesce((
             select sum(t.amount)::int from public.coin_transactions t
             where t.related_booking_id = b.id and t.type = 'booking_earned'
           ), 0)
           - coalesce((
             select sum(pf.fee_coins)::int from public.platform_fees pf
             where pf.booking_id = b.id and pf.kind = 'booking'
           ), 0) as earned,
           -- 報酬が確定した時刻。bookings に完了時刻の列が無いので、
           -- 報酬付与の記録の時刻を使う(0097 の send_gift と同じ考え方)
           (select max(t.created_at) from public.coin_transactions t
             where t.related_booking_id = b.id and t.type = 'booking_earned') as earned_at
    from funded f
    join public.bookings b on b.id = f.booking_id
    where f.booking_id is not null

    union all

    -- ギフト: 受領した枚数がそのまま報酬コインになる
    select g.receiver_id as host_id,
           null::uuid as booking_id,
           f.gift_id,
           f.funded,
           g.coins
           - coalesce((
             select sum(pf.fee_coins)::int from public.platform_fees pf
             where pf.gift_id = g.id and pf.kind = 'gift'
           ), 0) as earned,
           g.created_at as earned_at
    from funded f
    join public.gifts g on g.id = f.gift_id
    where f.gift_id is not null
  )
  select r.host_id,
         p.nickname,
         r.booking_id,
         r.gift_id,
         r.funded,
         r.earned,
         -- **充当された分と、実際に報酬になった分の小さいほう。**
         -- 利用料を引いた後の報酬しか渡っていないので、
         -- 充当額をそのまま引くと当社の取り分まで相手から取ることになる
         least(r.funded, r.earned) as deductible,
         exists (
           select 1 from public.chargeback_offsets o
           where o.purchase_id = p_purchase_id
             and o.booking_id is not distinct from r.booking_id
             and o.gift_id is not distinct from r.gift_id
             and o.status <> 'cancelled'
         ) as already
  from rows r
  left join public.profiles p on p.id = r.host_id
  where least(r.funded, r.earned) > 0
    -- 0099(規約 第8条の6第4項2の2号): **報酬確定から180日を過ぎた取引は対象外。**
    -- 国際ブランドの申立期間(概ね120日)を踏まえた時的限界。
    -- 期限を切らないと、ピタメイトは**いつまで取り返されうるのか分からない**。
    -- 弁護士:「ピタメイト側の予見可能性が高まり、条項の許容性がさらに強固になります」
    and r.earned_at is not null
    and r.earned_at > now() - interval '180 days'
  order by r.host_id;
end;
$$;

comment on function public.chargeback_offset_preview(uuid) is
  '相殺の対象候補。0099で「報酬確定から180日超は対象外」の時的限界を入れた(規約 第8条の6第4項2の2号)。';

revoke all on function public.chargeback_offset_preview(uuid) from public, anon;
grant execute on function public.chargeback_offset_preview(uuid) to authenticated;


-- >>>>>>>> 0100_final_payout_must_be_whole.sql
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


-- >>>>>>>> 0101_operator_adjustable_limits.sql
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


-- >>>>>>>> 0102_played_then_cancelled.sql
-- ============================================================
-- 0102: 遊んだあとのキャンセルは、完了と同じ扱いにする
-- ------------------------------------------------------------
-- ■ 見つかった穴
--   プレイ中(開始後)の画面には「✓ プレイ完了」と「キャンセルする」が
--   **両方出ている**。開始後は返還0%なので、**ゲストの支払額はどちらでも
--   同じ**。違うのは次の2点だけだった。
--
--     ✓ プレイ完了 … ピタメイトの手取り 予約額−20%(利用料) / 記録なし
--     キャンセル   … ピタメイトの手取り **予約額まるごと** / ゲストに
--                    **ドタキャン記録**
--
--   つまり「完了じゃなくてキャンセル押しといて」と言うだけで手取りが
--   20%増える。ゲストは支払額が同じなので断る理由がなく、
--   **運営だけが損をして、しかも記録上は「キャンセルされた予約」なので
--   気づけない。** ゲストには事実と違うドタキャン記録が残る。
--
-- ■ いちばんまずいのは、利用料の取りこぼしではない
--   キャンセル分に利用料を課さないのは、規約 第8条の2第7項が
--   「**役務の対価ではなく機会損失の補償**」と整理しているからだった。
--   2時間遊んだあとの「キャンセル」で満額を渡すなら、それは補償ではなく
--   **完全に役務の対価**。この取引が積み上がると、
--     ・消費者契約法9条の「平均的な損害」の主張
--     ・補償金を不課税として扱う整理
--   のどちらも、後から説明できなくなる。**条文が事実と食い違う。**
--
-- ■ 直し方
--   「実際に遊んだか」は既に記録がある。チェックイン(0050)は
--   ボタンだけでなく**メッセージを1通送るだけでも自動で立つ**ので、
--   本当に遊んだ組はほぼ確実に両方立っている。
--
--     両方チェックイン済み → 完了と同じ: 利用料を控除し、ドタキャン記録なし
--     片方だけ / 未チェックイン → 従来どおり(補償として満額・記録あり)
--
--   **片方だけでは足りない。** ゲストが開始時刻に一言つぶやいた一方で
--   ピタメイトが現れなかった場合まで「遊んだ」ことにすると、
--   無断欠席の側の救済(0050)と食い違う。
--
--   キャンセルのボタン自体は残す。プレイ中に気まずくなって途中で
--   切りたい場面の出口を塞がないため。
--
-- ■ 当月累計(GMV)には足さない
--   `host_monthly_ticket_gmv` は `status = 'completed'` だけを数えている。
--   ここは変えない。数えないと累計が小さいまま = **率が下がりにくい**ので、
--   ピタメイトに有利にはならず、抜け道にならない。
--   (逆に「キャンセルを積んで率を下げる」ことはできない)
-- ============================================================

-- ------------------------------------------------------------
-- 1. 手数料の計算を、トリガーの外から呼べる形にする
--
-- 0091 の `_apply_booking_fee()` の中身をそのまま関数にしただけ。
-- 違いは基準額を引数で受けること(キャンセルでは予約額ではなく
-- **実際にピタメイトへ渡る額**が基準になる)。
-- ------------------------------------------------------------
create or replace function public._booking_fee_coins(
  p_host_id uuid,
  p_guest_id uuid,
  p_booking_id uuid,
  p_gross_coins int,
  p_scheduled_at timestamptz,
  -- 0091: **予約が「成立」した時点。**確定した時点ではない(規約第8条の2第5項)
  p_agreed_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_repeat_discount constant numeric := 0.03;
  c_rate_floor constant numeric := 0.10;
  v_gmv_before int;
  v_gmv_after int;
  v_base_fee numeric;
  v_rate numeric;
  v_discount numeric := 0;
  v_is_repeat boolean := false;
  v_fee int;
begin
  if p_gross_coins is null or p_gross_coins <= 0 then
    return jsonb_build_object('fee', 0, 'repeat', false);
  end if;

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(p_host_id, p_scheduled_at, p_booking_id);
  v_gmv_after := v_gmv_before + p_gross_coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after, p_agreed_at)
              - public.host_progressive_fee(v_gmv_before, p_agreed_at);
  v_rate := v_base_fee / p_gross_coins;

  -- 指名リピート: 同じゲストと過去に完了した予約があるか
  select exists (
    select 1 from public.bookings b
    where b.host_id = p_host_id
      and b.guest_id = p_guest_id
      and b.status = 'completed'
      and b.id <> p_booking_id
      and b.scheduled_at < p_scheduled_at
  ) into v_is_repeat;

  if v_is_repeat then
    v_discount := least(c_repeat_discount, greatest(0, v_rate - c_rate_floor)) * p_gross_coins;
  end if;

  v_fee := least(greatest(0, round(v_base_fee - v_discount))::int, p_gross_coins);

  return jsonb_build_object('fee', v_fee, 'repeat', v_is_repeat);
end;
$$;

comment on function public._booking_fee_coins(uuid, uuid, uuid, int, timestamptz, timestamptz) is
  '予約の利用料(コイン)を計算する。基準額を引数で受けるので、完了(予約額)にも'
  '遊んだあとのキャンセル(実際に渡る額)にも同じ式を使える(0102)。';

revoke all on function public._booking_fee_coins(uuid, uuid, uuid, int, timestamptz, timestamptz)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. 完了時のトリガーは、計算だけを上の関数に委ねる
--    **挙動は 0091 と同じ。** `tests/40_host_fees` がそれを見ている
-- ------------------------------------------------------------
create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r jsonb;
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  v_r := public._booking_fee_coins(
    new.host_id, new.guest_id, new.id, new.coins, new.scheduled_at,
    coalesce(new.confirmed_at, new.created_at, now()));
  v_fee := (v_r ->> 'fee')::int;

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (new.host_id, -v_fee, 'platform_fee', new.id, 'booking_fee');
  end if;

  insert into public.platform_fees (
    host_id, kind, booking_id, gross_coins, fee_coins, net_coins, applied_rate, repeat_discounted)
  values (
    new.host_id, 'booking', new.id, new.coins, v_fee, new.coins - v_fee,
    round(v_fee::numeric / new.coins, 4), (v_r ->> 'repeat')::boolean);

  return new;
end;
$$;

revoke all on function public._apply_booking_fee() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. cancel_booking
--
-- 0085 の定義を出発点にして、足したのは
--   ・v_played(両方チェックイン済みか)の判定
--   ・遊んでいたらドタキャン記録をつけない
--   ・遊んでいたら渡す額から利用料を引く
-- の3点だけ。**他は 0085 のまま。**
-- (関数を作り直すときは最新の定義から始めること)
-- ------------------------------------------------------------
create or replace function public.cancel_booking(p_booking_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_new_status text;
  v_other uuid;
  v_name text;
  v_pct int;
  v_refund_total int;
  v_refund_paid int;
  v_refund_bonus int;
  v_to_host int;
  -- 0085: 誰の責めによる返還か。ゲスト無帰責なら期限切れ分を金銭で返す
  v_cause text;
  -- 0102: **実際に遊んだか。** 両方がチェックイン済みなら「遊んだ」と見る
  v_played boolean;
  v_fee_r jsonb;
  v_fee int := 0;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  -- **取り消したのがどちらかで決まる。** ピタメイト側の取消し・辞退は
  -- 承諾の前後を問わずゲストに落ち度が無い
  v_cause := case when v_uid = v_booking.host_id then 'host_fault' else 'guest_fault' end;

  -- 承諾前の取り消しは、どちらからでも全額返還(従来どおり)
  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id, null, null, v_cause);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');
    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額戻りました', p_booking_id);
    return;
  end if;

  if v_booking.status <> 'confirmed' then raise exception 'BOOKING_NOT_CANCELLABLE'; end if;

  -- 0102: チェックインはメッセージ1通でも自動で立つ(0050)ので、
  -- 本当に遊んだ組はほぼ確実に両方立っている
  v_played := v_booking.guest_checked_in_at is not null
          and v_booking.host_checked_in_at is not null;

  if v_uid = v_booking.host_id then
    -- ピタメイト都合はいつでも全額
    v_pct := 100;
    v_new_status := 'cancelled_by_host';
    update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_pct := public.booking_refund_percent(
      v_booking.status, v_booking.confirmed_at, v_booking.scheduled_at, now());
    -- 全額戻らなかった場合だけドタキャンとして記録する。
    -- 0102: **ただし実際に遊んだあとなら、それはドタキャンではない。**
    -- 「早く終わろう」の合意でキャンセルを押した人に、事実と違う記録を残さない
    if v_pct < 100 and not v_played then
      update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  -- 返す枚数。没収の上限(0048)を効かせてから、購入コインを先に返す
  v_refund_total := public.booking_refund_coins(
    v_booking.coins, v_booking.duration_minutes, v_pct, v_booking.scheduled_at, now());
  v_refund_paid := least(v_booking.paid_coins, v_refund_total);
  v_refund_bonus := v_refund_total - v_refund_paid;
  v_to_host := v_booking.coins - v_refund_total;

  update public.bookings set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund_total > 0 then
    update public.coin_wallets
      set balance = balance + v_refund_paid, bonus_balance = bonus_balance + v_refund_bonus
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(
      p_booking_id, v_refund_paid, v_refund_bonus, v_cause);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_refund_total, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 一部も戻らない場合でも、消費記録は閉じておく(期限管理のため)
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0, v_cause);
  end if;

  if v_to_host > 0 then
    update public.coin_wallets set earned_balance = earned_balance + v_to_host
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_to_host, 'booking_earned', p_booking_id, 'cancel_booking_late');

    -- 0102: **遊んだあとなら、これは機会損失の補償ではなく役務の対価。**
    -- 完了と同じように利用料を引く(規約 第8条の2第7項が適用されるのは
    -- 「遊んでいないのに渡る分」だけ)。
    -- 基準は予約額ではなく**実際に渡る額**。長い予約では没収の上限(0048)が
    -- 効いて、予約額より少ないことがある
    if v_played then
      v_fee_r := public._booking_fee_coins(
        v_booking.host_id, v_booking.guest_id, v_booking.id, v_to_host,
        v_booking.scheduled_at,
        coalesce(v_booking.confirmed_at, v_booking.created_at, now()));
      v_fee := (v_fee_r ->> 'fee')::int;

      if v_fee > 0 then
        update public.coin_wallets
          set earned_balance = greatest(0, earned_balance - v_fee)
          where user_id = v_booking.host_id;
        insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
          values (v_booking.host_id, -v_fee, 'platform_fee', p_booking_id, 'cancel_played_fee');
      end if;

      insert into public.platform_fees (
        host_id, kind, booking_id, gross_coins, fee_coins, net_coins,
        applied_rate, repeat_discounted)
      values (
        v_booking.host_id, 'booking', p_booking_id, v_to_host, v_fee, v_to_host - v_fee,
        round(v_fee::numeric / v_to_host, 4), (v_fee_r ->> 'repeat')::boolean);
    end if;
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約を'
      || case when v_played then '終了しました' else 'キャンセルしました' end,
    case when v_refund_total >= v_booking.coins then 'コインは全額戻りました'
         when v_refund_total = 0 then 'コインは報酬として確定しました'
         else v_refund_total || 'コインが戻り、' || v_to_host || 'コインが報酬として確定しました' end,
    p_booking_id);
end;
$$;

comment on function public.cancel_booking(uuid, text) is
  'キャンセル。0102で、両方がチェックイン済み(=実際に遊んだ)あとのキャンセルは'
  '完了と同じ扱いにした(利用料を控除し、ドタキャン記録をつけない)。'
  '規約 第8条の2第7項の「機会損失の補償」が当てはまるのは、遊んでいないのに渡る分だけ。';

revoke all on function public.cancel_booking(uuid, text) from public, anon;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 4. 画面の見積りに「遊んだあとか」を足す
--
-- 確認ダイアログは「ドタキャンとして記録されます」と書いていたが、
-- 0102 で遊んだあとは記録されなくなった。**判定を画面で作り直さない。**
-- サーバが1か所で持っている答えをそのまま渡す。
--
-- 0048 の定義に played を足しただけで、金額の計算には触っていない。
-- ------------------------------------------------------------
create or replace function public.my_booking_refund_quote(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
  v_pct int;
  v_refund int;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;

  v_pct := public.booking_refund_percent(v_b.status, v_b.confirmed_at, v_b.scheduled_at, now());
  v_refund := public.booking_refund_coins(
    v_b.coins, v_b.duration_minutes, v_pct, v_b.scheduled_at, now());

  return jsonb_build_object(
    'coins', v_b.coins,
    'refund_coins', v_refund,
    'forfeit_coins', v_b.coins - v_refund,
    'base_percent', v_pct,
    -- 上限が効いたか(効いていれば、率から期待される額より多く戻る)
    'capped', v_refund > round(v_b.coins * v_pct / 100.0),
    -- 0102: 両方チェックイン済み = 実際に遊んだ。
    -- このときキャンセルは完了と同じ扱いになる(ドタキャン記録がつかない)
    'played', v_b.guest_checked_in_at is not null and v_b.host_checked_in_at is not null
  );
end;
$$;

revoke all on function public.my_booking_refund_quote(uuid) from public, anon;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;


-- >>>>>>>> 0103_fee_on_actual_earnings.sql
-- ============================================================
-- 0103: 利用料は「実際に受け取った額」から引く(保留解除の過大控除を直す)
-- ------------------------------------------------------------
-- ■ 見つかった穴(0102 の逆向き)
--   完了時の利用料トリガー(0033/0091)は **new.coins = 予約の全額** を
--   基準に控除する。ところが、申し出の保留を一部返還で解除する
--   `release_hold_and_refund`(0042/0085)も status を 'completed' に
--   するので同じトリガーが走り、**ホストが受け取っていない分にまで
--   利用料がかかっていた。**
--
--   実測(2,000コインの予約・20%ティア):
--     50%返還  → ホストの受取 1,000。控除 400(2,000×20%)。**実効40%**
--     100%返還 → ホストの受取 **0**。それでも 340 が控除され、
--                **別の予約で稼いだ残高 5,000 が 4,660 に減った**
--
--   0102 が「運営の取り漏れ」だったのに対し、こちらは**運営の取りすぎ**。
--   規約 第8条の2第2項は「ピタメイトが受け取った対価から控除する」と
--   定めているので、受け取っていない額からの控除は**規約違反そのもの**。
--   個人のピタメイト相手なので、優越的地位の濫用の評価でも最も分が悪い。
--   platform_fees の明細も net 1,600 と記録され、実際の受取 600 と
--   食い違っていた(会計の突合も狂う)。
--
-- ■ 直し方: 基準額を「予約の全額」ではなく「この予約でホストに
--   実際に付与された額」にする
--
--   付与は必ず coin_transactions に type='booking_earned' で記録される
--   (complete_booking / auto_complete_bookings / release_hold_and_*)。
--   トリガーは deferrable initially deferred なので、**同じ
--   トランザクションで挿入された付与の行が必ず見える**。
--
--     通常の完了・自動確定・保留解除(全額) → 付与 = 予約額。挙動は従来どおり
--     保留解除(一部返還)                   → 付与 = ホストへ渡る分だけ
--     保留解除(全額返還)                   → 付与 = 0。**控除も明細も作らない**
--
--   関数を1本ずつ直すのではなくトリガー側で吸収するのは、
--   付与する関数が今後増えても取りこぼさないため(0033 が手数料を
--   トリガーにした理由と同じ)。
--
-- ■ 直さないことにしたもの(意図的)
--   `host_monthly_ticket_gmv`(料率ティアの当月累計)は、一部返還があっても
--   予約の全額を数える。累計が実受取より少し大きく出て、**以後の限界料率が
--   下がりやすくなる = ピタメイト有利**の側にしか働かないので、複雑にして
--   まで直さない。ティアは「その月に取り扱った規模」への割引であり、
--   予約の全額が一度は流通しているという説明も立つ。
-- ============================================================

create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r jsonb;
  v_fee int;
  v_base int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  -- 0103: この予約でホストに実際に付与された額。
  -- 一部返還つきの保留解除では予約額より小さく、全額返還では0になる
  select coalesce(sum(t.amount), 0) into v_base
    from public.coin_transactions t
    where t.related_booking_id = new.id
      and t.user_id = new.host_id
      and t.type = 'booking_earned';

  -- 受け取っていないものからは引かない(規約 第8条の2第2項)。
  -- 明細も作らない(gross 0 の行は applied_rate が計算できない)
  if v_base <= 0 then
    return new;
  end if;

  v_r := public._booking_fee_coins(
    new.host_id, new.guest_id, new.id, v_base, new.scheduled_at,
    coalesce(new.confirmed_at, new.created_at, now()));
  v_fee := (v_r ->> 'fee')::int;

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (new.host_id, -v_fee, 'platform_fee', new.id, 'booking_fee');
  end if;

  insert into public.platform_fees (
    host_id, kind, booking_id, gross_coins, fee_coins, net_coins, applied_rate, repeat_discounted)
  values (
    new.host_id, 'booking', new.id, v_base, v_fee, v_base - v_fee,
    round(v_fee::numeric / v_base, 4), (v_r ->> 'repeat')::boolean);

  return new;
end;
$$;

comment on function public._apply_booking_fee() is
  '予約が completed になったときに利用料を引く。0103で基準額を「予約の全額」から'
  '「この予約でホストに実際に付与された額(booking_earned の合計)」に改めた。'
  '一部返還つきの保留解除で、受け取っていない分にまで課金していたため(規約 第8条の2第2項)。';

revoke all on function public._apply_booking_fee() from public, anon, authenticated;


-- >>>>>>>> 0104_webhook_purchase_records.sql
-- ============================================================
-- 0104: webhook の購入記録(サポート料・決済手段)が0044に弾かれていた
-- ------------------------------------------------------------
-- ■ 見つかった穴(決済まわりのセキュリティ点検で発見)
--   stripe-webhook はコイン付与のあと、coin_purchases に対して
--     ・safety_fee_yen(あんしんサポート料)      … 素の UPDATE
--     ・payment_method(card / paypay。0096)     … 素の UPDATE
--   を書き込む。ところが 0044 が coin_purchases を**追記専用**にした
--   (UPDATE は app.ledger_override 無しでは常に例外)ため、この2つは
--   **本番で毎回失敗していた。**
--
--   実測: credit_coins_for_purchase → UPDATE safety_fee_yen で
--   `LEDGER_IMMUTABLE: coin_purchases は追記専用です` が出る。
--
-- ■ なぜ誰も気づかなかったか
--   ①webhook は記録の失敗をログに書くだけで 200 を返す(仕様として正しい:
--     ここで 5xx を返すと付与済みなのに Stripe が再送し続ける)。
--     コイン付与は成功するので、画面上は何も欠けて見えない。
--   ②テスト(90)は INSERT 時に safety_fee_yen を直接入れており、
--     webhook と同じ「あとから UPDATE」の経路を通っていなかった。
--
-- ■ 実害
--   ・サポート料の売上が記録されない(会計・税務の集計から欠ける。
--     2026-08-03 のテスト購入 ¥5,250 の ¥250 も記録されていない)
--   ・payment_method が永遠に null → 0096 の「カードの共有では判定
--     できません」警告が一度も出ない。運営コンソールの「非カード購入 0件」が
--     **「調べた結果シロ」ではなく「記録が無かった」**を意味してしまう
--
-- ■ 直し方: coin_purchases 専用の不変トリガーに差し替える
--   payouts が既に同じ形をとっている(0044 の _payout_amount_immutable:
--   「status/振込結果の更新は通常運用なので通す」)。同じ考え方で、
--   coin_purchases も**この2列だけ・書き込みは1回だけ**を通す:
--
--     safety_fee_yen  … 既定値 0 からの変更のみ(上書き不可)
--     payment_method  … null からの変更のみ(上書き不可)
--     それ以外の列    … 従来どおり変更禁止(金額・ユーザー・セッションID)
--     DELETE          … 従来どおり禁止
--     同値の再書き込み … 通す(Stripe の再送で同じ値がもう一度来る)
--
--   関数側(webhook)は**1文字も変えない**。デプロイ済みのコードが
--   このマイグレーションだけで意図どおり動き始める。マイグレーションと
--   関数デプロイの順序事故を避ける(0096 の safety_fee と同じ理由)。
--
-- ■ 適用後の運用メモ
--   既存の本番データ(テスト購入)の safety_fee_yen=0 は、公開前の
--   リセット(docs/reset-before-launch.sql)で消える予定なのでそのまま。
--   残す場合は override を宣言して1回だけ訂正する(ledger_audit に残る)。
-- ============================================================

create or replace function public._purchase_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rest_old jsonb;
  v_rest_new jsonb;
begin
  -- 明示的な解除は従来どおり通す(記録つき)
  if public._ledger_override_on() then
    perform public._ledger_record_bypass(
      TG_TABLE_NAME, TG_OP,
      to_jsonb(OLD),
      case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);
    if TG_OP = 'DELETE' then return OLD; end if;
    return NEW;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases の行は削除できません。訂正が必要な場合は打ち消しの行を追加してください。';
  end if;

  -- webhook が決済成立後に書く2列だけを、書き込み1回に限って通す。
  -- 「同値の再書き込み」を許すのは、Stripe が同じイベントを再送するため
  -- (冪等な再実行を例外にしない)。
  v_rest_old := to_jsonb(OLD) - 'safety_fee_yen' - 'payment_method';
  v_rest_new := to_jsonb(NEW) - 'safety_fee_yen' - 'payment_method';
  if v_rest_old <> v_rest_new then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases は追記専用です(変更できるのは safety_fee_yen と payment_method の初回書き込みだけ)。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。';
  end if;
  if NEW.safety_fee_yen is distinct from OLD.safety_fee_yen
     and OLD.safety_fee_yen <> 0 then
    raise exception 'LEDGER_IMMUTABLE: safety_fee_yen は一度しか書き込めません(現在値 %)', OLD.safety_fee_yen;
  end if;
  if NEW.payment_method is distinct from OLD.payment_method
     and OLD.payment_method is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_method は一度しか書き込めません(現在値 %)', OLD.payment_method;
  end if;

  return NEW;
end;
$$;

comment on function public._purchase_immutable() is
  'coin_purchases の不変トリガー。0044 の全面禁止から、webhook が決済成立後に書く safety_fee_yen / payment_method の初回書き込みだけを通す形に緩めた(0104)。金額・ユーザー・セッションIDは従来どおり変更できない。';

revoke all on function public._purchase_immutable() from public, anon, authenticated;

drop trigger if exists coin_purchases_immutable on public.coin_purchases;
create trigger coin_purchases_immutable
  before update or delete on public.coin_purchases
  for each row execute function public._purchase_immutable();


-- >>>>>>>> 0105_business_kpis.sql
-- ============================================================
-- 0105: 収益構造を見張る3つの指標(運営コンソール「経営」タブ)
-- ------------------------------------------------------------
-- 事業計画書(docs/business-plan-2026-08.md)の収益構造は、平常時は堅い。
-- 崩れるとしたら**構造の欠陥ではなく、前提が実績とずれたとき**なので、
-- ずれを早く見つけるための数字だけをここに集める。
--
-- ■ ① 混合実効率 … 計画は「実効利用料率18%」を置いている
--   利用料は超過累進なので、**稼ぐピタメイトほど率が下がる。**
--   マーケットプレイスのGMVは上位に集中する(べき分布になる)のが通例なので、
--   全体をならした実効率は計画の18%より**下振れしうる**。
--   16%を切ったら段の見直しを検討する(変更の予約は0091で実装済み・30日前告知)。
--
-- ■ ② 上位集中 … 上位5人のGMVシェア
--   実効率が下がる原因であり、同時に**チャーンリスク**でもある。
--   1人が抜けると売上の何割が消えるのかを、数字で見えるようにしておく。
--
-- ■ ③ チャージバック … 件数・金額・GMV比
--   平常時の収支は堅いが、**一撃で月次を壊せる唯一の項目**。
--   税理士の第3回回答が「支払手数料(チャージバック)」を独立科目にして
--   早期警戒指標に使うよう設計した、その画面側。
--
-- ■ おまけ: 決済手段の内訳
--   PayPay はカードより手数料が低いので、比率が上がるほど貢献利益率
--   (計画では19.4%)が改善する。0096で payment_method を記録しているので
--   ここで一緒に出す。**0096より前の購入は null**(当時はカードのみ)。
--
-- ■ この関数は数えるだけで、何も書き換えない
--   運営が読む用。stable + 管理者チェックのみ。
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_gross bigint;
  v_fee bigint;
  v_booking_gross bigint;
  v_booking_fee bigint;
  v_gift_gross bigint;
  v_gift_fee bigint;
  v_hosts int;
  v_top5 bigint;
  v_top1 bigint;
  v_purchase_yen bigint;
  v_safety_yen bigint;
  v_cb_count int;
  v_cb_yen bigint;
  v_cb_open int;
  v_cb_lost int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;

  -- JSTの[p_from 00:00, p_to+1日 00:00)。会計タブ(0086)と同じ切り方にする
  v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
  v_to := ((p_to + 1)::timestamp at time zone 'Asia/Tokyo');

  -- ------------------------------------------------------------
  -- ① 混合実効率
  --
  -- **platform_fees が唯一の出典。** 予約とギフトで率がまったく違う
  -- (予約20〜12% / ギフト35%)ので、合算した「混合」と、内訳の両方を出す。
  -- 合算だけ見ていると、ギフトが増えただけで実効率が上がったように見える。
  -- ------------------------------------------------------------
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins)   filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins)   filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ------------------------------------------------------------
  -- ② 上位集中(予約のGMVで見る。ギフトは母数が別物なので混ぜない)
  -- ------------------------------------------------------------
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where created_at >= v_from and created_at < v_to and kind = 'booking'
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ------------------------------------------------------------
  -- ③ チャージバック
  --
  -- **GMVではなく購入額(円)に対する比で見る。** 申立ては購入に対して
  -- 起きるので、分母は売った額でなければ意味が合わない。
  -- ------------------------------------------------------------
  select
    coalesce(sum(price_yen), 0),
    coalesce(sum(safety_fee_yen), 0)
  into v_purchase_yen, v_safety_yen
  from public.coin_purchases
  where created_at >= v_from and created_at < v_to;

  select
    count(*),
    coalesce(sum(amount_yen), 0),
    count(*) filter (where resolved_at is null),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'fees', jsonb_build_object(
      'grossCoins', v_gross,
      'feeCoins', v_fee,
      -- 混合実効率(%)。母数0なら null を返す。**0%と区別する**
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end
    ),
    'concentration', jsonb_build_object(
      'activeHosts', v_hosts,
      'top5Coins', v_top5,
      'top5Percent', case when v_booking_gross > 0
        then round(v_top5::numeric * 100 / v_booking_gross, 1) else null end,
      'top1Percent', case when v_booking_gross > 0
        then round(v_top1::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'chargebacks', jsonb_build_object(
      'count', v_cb_count,
      'amountYen', v_cb_yen,
      'openCount', v_cb_open,
      'lostCount', v_cb_lost,
      'purchaseYen', v_purchase_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    ),
    'safetyFeeYen', v_safety_yen
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営指標(運営)。混合実効率・上位集中・チャージバック比率を返す。'
  '事業計画書の前提(実効18%・貢献利益率19.4%)が実績とずれていないかを見張るためのもの。0105。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;

-- ------------------------------------------------------------
-- 決済手段の内訳(0096)
--
-- **別の関数にしてある。** 上のKPIは「構造がずれていないか」で、
-- こちらは「原価が下がる余地があるか」。混ぜると読む目的がぼやける。
-- ------------------------------------------------------------
create or replace function public.admin_payment_method_mix(
  p_from date,
  p_to date
)
returns table (
  method text,
  purchases int,
  amount_yen bigint,
  share_percent numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;

  v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
  v_to := ((p_to + 1)::timestamp at time zone 'Asia/Tokyo');

  return query
  with p as (
    select
      -- 0096より前の購入は null。**'card' に丸めない。**
      -- 「カードだった」と「記録が無い」は別のことで、
      -- 丸めると 0104 で直した記録漏れが見えなくなる
      coalesce(cp.payment_method, '(記録なし)') as m,
      cp.price_yen + cp.safety_fee_yen as yen
    from public.coin_purchases cp
    where cp.created_at >= v_from and cp.created_at < v_to
  ),
  total as (select coalesce(sum(yen), 0) as t from p)
  select
    p.m,
    count(*)::int,
    coalesce(sum(p.yen), 0)::bigint,
    case when (select t from total) > 0
      then round(sum(p.yen)::numeric * 100 / (select t from total), 1)
      else null end
  from p
  group by p.m
  order by 3 desc;
end;
$$;

comment on function public.admin_payment_method_mix(date, date) is
  '決済手段の内訳(運営)。PayPayはカードより手数料が低いので、比率が上がるほど貢献利益率が改善する。0096で記録した payment_method を集計する。0105。';

revoke all on function public.admin_payment_method_mix(date, date) from public, anon;
grant execute on function public.admin_payment_method_mix(date, date) to authenticated;
