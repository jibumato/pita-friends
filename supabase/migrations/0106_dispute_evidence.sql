-- ============================================================
-- 0106: 異議申立てに出す証跡を、集めて・束ねて・取り出せるようにする
-- ------------------------------------------------------------
-- ■ 何が足りなかったか
--   争うのに要る材料を1つずつ確認したところ、5つは既にあった。
--
--     購入時刻          coin_purchases.created_at            ✓
--     本人確認の結果    identity_verifications               ✓
--     チャット          messages                             ✓
--     予約・ギフト      bookings / gifts / coin_transactions ✓
--     提供完了の記録    guest/host_checked_in_at + completed ✓
--
--   足りないのは4つ。
--
--     ① **購入時点の**IP・端末      user_ips / user_devices は「最初と最後に
--                                    見た時刻」しか持たない。**どの購入のときに
--                                    どのIPだったか**が分からない。Stripe の
--                                    異議申立てフォームが最初に聞くのがこれ
--     ② User-Agent                   まったく記録していない
--     ③ **返金ポリシーへの同意**     弁護士が「①予約確定前の画面でキャンセル
--                                    ポリシーを明示し**同意の痕跡(ログ)を残す**」
--                                    と挙げていた項目。実装済み一覧でも⬜だった
--     ④ ログイン(アプリ起動)の記録   「本人が使っていた」ことの土台
--
--   そして**いちばん大きい穴は、束ねて取り出す口が無いこと。**
--   材料が全部あっても、Stripeの反論期限(7〜21日)の中で1枚にまとめられ
--   なければ使えない。SQL Editor で5テーブルを手で引くのは、期限のある
--   作業としては成立しない。
--
-- ■ 記録の範囲について
--   プライバシーポリシーは弁護士(Q26)の指摘で「**参照そのものの全件記録は
--   行っていません**」と狭めてある。ここで足すのは**購入・同意・ログインの
--   3つだけ**で、閲覧の記録ではない。同じ注記の「重要な操作の記録を保存する」
--   の範囲に収まる。
--
-- ■ メッセージの本文は束に入れない(意図的)
--   本文にはピタメイト(第三者)の発言が混ざる。カード会社へ渡すのは
--   第三者提供の判断が要るので、**束には「いつ・何通・どちらから」までを
--   入れ、本文は別の操作で出す。** みまもりを「原則は自動処理、担当者が
--   読むのは通報時だけ」としているのと同じ線。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 購入時点の環境(①②)
--
-- **決済ページを作った時点**で記録する。決済が完了しなくても残す
-- (「試したが完了していない」ことも、それはそれで証跡になる)。
-- 鍵は stripe_session_id。webhook が付与に使うのと同じ鍵なので、
-- 購入と1対1でつながる。
-- ------------------------------------------------------------
create table if not exists public.purchase_evidence (
  stripe_session_id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- Edge Function が X-Forwarded-For から読む実IP。クライアント申告は使わない
  ip text,
  -- localStorage の端末ID(0021と同じもの)
  device_id text,
  -- 生の User-Agent。長さだけ制限して中身は加工しない
  user_agent text check (user_agent is null or char_length(user_agent) <= 512),
  -- 請求額の内訳。**あとから coin_packs を変えても、当時の額が残る**
  price_yen int,
  safety_fee_yen int,
  created_at timestamptz not null default now()
);

comment on table public.purchase_evidence is
  '決済ページを作った時点の環境(IP・端末・UA)。異議申立てのときに「誰がどこから買ったか」を示す(0106)。決済が完了しなかったセッションの行も残す。';

create index if not exists purchase_evidence_user_idx
  on public.purchase_evidence (user_id, created_at desc);

alter table public.purchase_evidence enable row level security;
-- **本人にも見せない。** 調査のための記録で、本人が確認する用途が無い。
-- 運営は SECURITY DEFINER の関数経由でだけ読む
create policy "purchase_evidence_select_admin"
  on public.purchase_evidence for select
  to authenticated
  using (public._is_admin());

-- ------------------------------------------------------------
-- 2. ポリシーへの同意(③)
--
-- 弁護士の条件:
--   「①予約確定前の画面でキャンセルポリシーを明示し**同意の痕跡(ログ)を
--     残す**(特商法の表示義務の観点からも必要)」
--
-- **何に同意したかを、そのとき表示していた文面ごと残す。**
-- 版番号だけだと、後から文面を差し替えたときに何を見せたのか
-- 証明できない。文面を丸ごと持つのがいちばん強い。
-- ------------------------------------------------------------
create table if not exists public.policy_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 'cancellation' … 予約確定前のキャンセル・返金ポリシー
  -- 'purchase'     … 購入手続前の「返品不可」の確認
  -- 'terms'        … 利用規約(登録時)
  kind text not null check (kind in ('cancellation', 'purchase', 'terms')),
  -- 表示していた文面そのもの。**要約ではなく、画面に出したまま**
  shown_text text not null check (char_length(shown_text) between 1 and 4000),
  -- 紐づく対象(予約ID・Checkoutセッション等)。無い場合もある
  related_id text,
  ip text,
  device_id text,
  created_at timestamptz not null default now()
);

comment on table public.policy_consents is
  'キャンセル・返金ポリシー等への同意の記録。**そのとき表示していた文面ごと**残す(2026-07-30の弁護士回答Q14の条件①)。0106。';

create index if not exists policy_consents_user_idx
  on public.policy_consents (user_id, kind, created_at desc);
create index if not exists policy_consents_related_idx
  on public.policy_consents (related_id) where related_id is not null;

alter table public.policy_consents enable row level security;
-- **本人は自分の同意記録を見られる。** 「いつ何に同意したか」は
-- 本人に開示されて当然の情報で、隠す理由が無い
create policy "policy_consents_select_own"
  on public.policy_consents for select
  to authenticated
  using (user_id = auth.uid() or public._is_admin());

/**
 * 同意を記録する。**表示した文面を呼び出し側が渡す。**
 * サーバで文面を組み立てないのは、画面に実際に出たものと
 * records が食い違うのを避けるため(食い違えば証跡にならない)。
 */
create or replace function public.record_policy_consent(
  p_kind text,
  p_shown_text text,
  p_related_id text default null,
  p_device_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_kind not in ('cancellation', 'purchase', 'terms') then
    raise exception 'INVALID_KIND';
  end if;
  if coalesce(btrim(p_shown_text), '') = '' then
    raise exception 'TEXT_REQUIRED';
  end if;

  insert into public.policy_consents (user_id, kind, shown_text, related_id, device_id)
  values (v_uid, p_kind, left(p_shown_text, 4000), p_related_id,
          nullif(btrim(coalesce(p_device_id, '')), ''))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.record_policy_consent(text, text, text, text) is
  'ポリシーへの同意を、表示した文面ごと記録する。IPはEdge Function側でしか取れないのでここでは入れない(0106)。';

revoke all on function public.record_policy_consent(text, text, text, text) from public, anon;
grant execute on function public.record_policy_consent(text, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 3. ログイン(アプリ起動)の記録(④)
--
-- ⚠️ **閲覧の記録ではない。** プライバシーポリシーは
-- 「参照そのものの全件記録は行っていません」と書いてあり、これは守る。
-- ここで残すのは**セッションの開始**だけで、どの画面を見たかは残さない。
--
-- record-ip(アプリ起動時に1回呼ばれる)から書く。同じIP・端末の連続で
-- 行が増え続けないよう、**直近30分以内の同じ組み合わせはまとめる。**
-- ------------------------------------------------------------
create table if not exists public.access_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ip text,
  device_id text,
  user_agent text check (user_agent is null or char_length(user_agent) <= 512),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  hits int not null default 1
);

comment on table public.access_events is
  'ログイン(アプリ起動)の記録。**閲覧の記録ではない**(プライバシーポリシーの「参照そのものの全件記録は行っていません」を守る)。異議申立てで「本人が継続的に使っていた」ことを示すのに使う。0106。';

create index if not exists access_events_user_idx
  on public.access_events (user_id, last_at desc);

alter table public.access_events enable row level security;
create policy "access_events_select_own"
  on public.access_events for select
  to authenticated
  using (user_id = auth.uid() or public._is_admin());

/**
 * アプリ起動の記録。record-ip から service_role で呼ぶ。
 * **30分以内の同じ(IP, 端末)はまとめる。** 起動のたびに行を作ると、
 * 証跡としてはノイズが増えるだけで読めなくなる。
 */
create or replace function public.record_access_event(
  p_user_id uuid,
  p_ip text,
  p_device_id text default null,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_user_id is null then
    return;
  end if;

  select id into v_id from public.access_events
  where user_id = p_user_id
    and ip is not distinct from nullif(btrim(coalesce(p_ip, '')), '')
    and device_id is not distinct from nullif(btrim(coalesce(p_device_id, '')), '')
    and last_at > now() - interval '30 minutes'
  order by last_at desc limit 1;

  if v_id is not null then
    update public.access_events
      set last_at = now(), hits = hits + 1
      where id = v_id;
    return;
  end if;

  insert into public.access_events (user_id, ip, device_id, user_agent)
  values (p_user_id,
          nullif(btrim(coalesce(p_ip, '')), ''),
          nullif(btrim(coalesce(p_device_id, '')), ''),
          left(nullif(btrim(coalesce(p_user_agent, '')), ''), 512));
end;
$$;

comment on function public.record_access_event(uuid, text, text, text) is
  'アプリ起動の記録(service_role専用)。30分以内の同じIP・端末はまとめる。0106。';

revoke all on function public.record_access_event(uuid, text, text, text) from public, anon, authenticated;

/** 購入時点の環境を記録する。create-checkout-session から service_role で呼ぶ。 */
create or replace function public.record_purchase_evidence(
  p_session_id text,
  p_user_id uuid,
  p_ip text,
  p_device_id text,
  p_user_agent text,
  p_price_yen int,
  p_safety_fee_yen int
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.purchase_evidence
    (stripe_session_id, user_id, ip, device_id, user_agent, price_yen, safety_fee_yen)
  values (
    p_session_id, p_user_id,
    nullif(btrim(coalesce(p_ip, '')), ''),
    nullif(btrim(coalesce(p_device_id, '')), ''),
    left(nullif(btrim(coalesce(p_user_agent, '')), ''), 512),
    p_price_yen, p_safety_fee_yen)
  on conflict (stripe_session_id) do nothing;
$$;

comment on function public.record_purchase_evidence(text, uuid, text, text, text, int, int) is
  '決済ページ作成時の環境を記録する(service_role専用)。0106。';

revoke all on function public.record_purchase_evidence(text, uuid, text, text, text, int, int)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. ★ 証跡を1つに束ねる
--
-- **これがこの migration の本体。** 材料が全部あっても、期限の中で
-- 1枚にまとめられなければ争えない。
--
-- 出力は Stripe の異議申立てフォームの欄立てに合わせてある:
--   customer / purchase_ip / receipt / service_documentation /
--   service_date / activity / refund_policy
-- そのまま写せる形にしておかないと、結局その場で組み直すことになる。
-- ------------------------------------------------------------
create or replace function public.admin_purchase_evidence(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.coin_purchases;
  v_prof public.profiles;
  v_email text;
  v_ev public.purchase_evidence;
  v_verified boolean;
  v_verified_at timestamptz;
  v_access jsonb;
  v_consents jsonb;
  v_bookings jsonb;
  v_gifts jsonb;
  v_msgs jsonb;
  v_card jsonb;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.coin_purchases where id = p_purchase_id;
  if v_p.id is null then
    raise exception 'PURCHASE_NOT_FOUND';
  end if;

  select * into v_prof from public.profiles where id = v_p.user_id;
  select email into v_email from auth.users where id = v_p.user_id;
  select * into v_ev from public.purchase_evidence
    where stripe_session_id = v_p.stripe_session_id;

  select ts.is_verified, iv.verified_at into v_verified, v_verified_at
    from public.profile_trust_stats ts
    left join lateral (
      select verified_at from public.identity_verifications
      where user_id = v_p.user_id and status = 'verified'
      order by verified_at desc nulls last limit 1
    ) iv on true
    where ts.user_id = v_p.user_id;

  -- ログイン記録(購入の前後30日)。**購入の前にも後にも使っている**ことが、
  -- 「乗っ取られた」「身に覚えがない」への最も素直な反証になる
  select coalesce(jsonb_agg(jsonb_build_object(
           'firstAt', a.first_at, 'lastAt', a.last_at,
           'ip', a.ip, 'deviceId', a.device_id, 'hits', a.hits
         ) order by a.last_at desc), '[]'::jsonb)
    into v_access
    from (
      select * from public.access_events
      where user_id = v_p.user_id
        and last_at between v_p.created_at - interval '30 days'
                        and v_p.created_at + interval '30 days'
      order by last_at desc limit 50
    ) a;

  -- 同意の記録
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', c.kind, 'at', c.created_at,
           'relatedId', c.related_id, 'shownText', c.shown_text
         ) order by c.created_at), '[]'::jsonb)
    into v_consents
    from public.policy_consents c
    where c.user_id = v_p.user_id;

  -- **役務が提供されたことの中心的な証拠。**
  -- 購入の後に成立し完了した予約と、その双方のチェックイン時刻
  select coalesce(jsonb_agg(jsonb_build_object(
           'bookingId', b.id, 'hostNickname', hp.nickname,
           'scheduledAt', b.scheduled_at, 'durationMinutes', b.duration_minutes,
           'coins', b.coins, 'status', b.status,
           'guestCheckedInAt', b.guest_checked_in_at,
           'hostCheckedInAt', b.host_checked_in_at,
           'completedAt', (select max(t.created_at) from public.coin_transactions t
                           where t.related_booking_id = b.id and t.type = 'booking_earned')
         ) order by b.scheduled_at), '[]'::jsonb)
    into v_bookings
    from public.bookings b
    left join public.profiles hp on hp.id = b.host_id
    where b.guest_id = v_p.user_id and b.created_at >= v_p.created_at;

  select coalesce(jsonb_agg(jsonb_build_object(
           'giftId', g.id, 'to', rp.nickname, 'coins', g.coins, 'at', g.created_at
         ) order by g.created_at), '[]'::jsonb)
    into v_gifts
    from public.gifts g
    left join public.profiles rp on rp.id = g.receiver_id
    where g.sender_id = v_p.user_id and g.created_at >= v_p.created_at;

  -- **本文は入れない。** 第三者(ピタメイト)の発言が混ざるので、
  -- カード会社へ渡すかは別の判断。ここでは「やりとりがあった事実」まで
  select coalesce(jsonb_agg(jsonb_build_object(
           'promiseId', m.promise_id, 'messages', m.n,
           'firstAt', m.first_at, 'lastAt', m.last_at,
           'fromGuest', m.from_guest, 'fromOther', m.n - m.from_guest
         ) order by m.last_at desc), '[]'::jsonb)
    into v_msgs
    from (
      select msg.promise_id, count(*) as n,
             min(msg.created_at) as first_at, max(msg.created_at) as last_at,
             count(*) filter (where msg.sender_id = v_p.user_id) as from_guest
      from public.messages msg
      join public.promises pr on pr.id = msg.promise_id
      where (pr.user_a = v_p.user_id or pr.user_b = v_p.user_id)
        and msg.created_at >= v_p.created_at
      group by msg.promise_id
    ) m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'brand', pc.brand, 'last4', pc.last4, 'firstSeenAt', pc.first_seen_at
         )), '[]'::jsonb)
    into v_card
    from public.user_payment_cards pc
    where pc.user_id = v_p.user_id;

  return jsonb_build_object(
    -- Stripe「Customer details」欄
    'customer', jsonb_build_object(
      'userId', v_p.user_id,
      'nickname', v_prof.nickname,
      'email', v_email,
      'registeredAt', v_prof.created_at,
      'identityVerified', coalesce(v_verified, false),
      'identityVerifiedAt', v_verified_at,
      'paymentCards', v_card
    ),
    -- Stripe「Customer IP address」欄
    'purchaseEnvironment', jsonb_build_object(
      'ip', v_ev.ip,
      'deviceId', v_ev.device_id,
      'userAgent', v_ev.user_agent,
      'recordedAt', v_ev.created_at,
      -- **記録が無いことを黙って隠さない。** 0106より前の購入は環境が無い
      'available', v_ev.stripe_session_id is not null
    ),
    -- Stripe「Receipt」欄
    'purchase', jsonb_build_object(
      'purchaseId', v_p.id,
      'at', v_p.created_at,
      'packId', v_p.pack_id,
      'coinsCredited', v_p.coins_credited,
      'priceYen', v_p.price_yen,
      'safetyFeeYen', v_p.safety_fee_yen,
      'totalYen', v_p.price_yen + v_p.safety_fee_yen,
      'paymentMethod', v_p.payment_method,
      'stripeSessionId', v_p.stripe_session_id,
      'stripePaymentIntent', v_p.stripe_payment_intent
    ),
    -- Stripe「Refund policy」欄
    'consents', v_consents,
    -- Stripe「Service documentation / Service date」欄
    'service', jsonb_build_object(
      'bookings', v_bookings,
      'gifts', v_gifts,
      'messageThreads', v_msgs
    ),
    -- Stripe「Activity log」欄
    'accessLog', v_access,
    'generatedAt', now(),
    'note', 'メッセージの本文は含めていません（第三者の発言が混ざるため、'
         || '提出は個人情報の第三者提供として別に判断してください）。'
  );
end;
$$;

comment on function public.admin_purchase_evidence(uuid) is
  '異議申立てに出す証跡を1つに束ねる(運営)。Stripeの申立てフォームの欄立てに合わせてある。メッセージ本文は含めない(0106)。';

revoke all on function public.admin_purchase_evidence(uuid) from public, anon;
grant execute on function public.admin_purchase_evidence(uuid) to authenticated;

/**
 * 異議申立てのIDから証跡を出す。**運営が実際に使う入口はこちら。**
 * 申立てから購入をたどる手間を画面に持たせない。
 */
create or replace function public.admin_dispute_evidence(p_dispute_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_d public.payment_disputes;
  v_purchase_id uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_d from public.payment_disputes where id = p_dispute_id;
  if v_d.id is null then
    raise exception 'DISPUTE_NOT_FOUND';
  end if;

  -- payment_intent で購入を引く。0075のコメントどおり、購入と紐づかない
  -- 申立てもあり得るので**無いことを明示して返す**(例外にしない)
  select id into v_purchase_id from public.coin_purchases
    where stripe_payment_intent = v_d.stripe_payment_intent
    order by created_at limit 1;

  if v_purchase_id is null then
    return jsonb_build_object(
      'dispute', to_jsonb(v_d),
      'purchaseFound', false,
      'note', 'この申立てに対応する購入が見つかりません（当社の購入と紐づかない申立て）。'
    );
  end if;

  return jsonb_build_object(
    'dispute', jsonb_build_object(
      'id', v_d.id,
      'stripeDisputeId', v_d.stripe_dispute_id,
      'amountYen', v_d.amount_yen,
      'reason', v_d.reason,
      'status', v_d.status,
      'createdAt', v_d.created_at
    ),
    'purchaseFound', true,
    'evidence', public.admin_purchase_evidence(v_purchase_id)
  );
end;
$$;

comment on function public.admin_dispute_evidence(uuid) is
  '異議申立てから証跡一式を出す(運営)。購入と紐づかない申立ては purchaseFound=false で返す(0106)。';

revoke all on function public.admin_dispute_evidence(uuid) from public, anon;
grant execute on function public.admin_dispute_evidence(uuid) to authenticated;
