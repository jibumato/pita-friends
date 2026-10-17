-- ============================================================
-- 本番への適用 パート 2/5(0106〜0116)
-- tools/bundle-migrations.py で生成。手で直さないこと。
--
-- 1. このファイルの中身を全部 SQL Editor に貼って Run する
-- 2. docs/check-migrations.sql を流し、「次に適用するファイル」が
--    0116 の次(最後のパートなら「すべて適用済み」)になったことを確かめる
-- 3. エラーが出たら、そこで止めて内容を知らせる
--    (このパートの変更はまるごと取り消されている)
--
-- 先頭の関所は、順番の飛ばしと二重適用を止めるためのもの。
-- ============================================================

do $guard$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'admin_payment_method_mix' and pg_get_functiondef(p.oid) like '%' || 'admin_payment_method_mix' || '%')) then
    raise exception '順番が違います: 0105_business_kpis がまだ当たっていません。前のパートから流してください';
  end if;
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'purchase_evidence') then
    raise exception 'このパートは適用済みです(0106_dispute_evidence が当たっています)。docs/check-migrations.sql で次に流すファイルを確かめてください';
  end if;
end $guard$;

-- >>>>>>>> 0106_dispute_evidence.sql
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


-- >>>>>>>> 0107_earned_survives_window.sql
-- ============================================================
-- 0107: 退会後90日で報酬コインを「消滅させる」のをやめる
--
-- 2026-08-05の弁護士回答（論点A-1）による。**今回の回答で最も重い指摘。**
--
--   「報酬コインは、購入コインと法的性質が根本的に異なります。これは役務提供の
--    対価としてユーザーが既に取得した金銭債権……の計数的表示です。90日の経過に
--    より債権そのものを消滅させる条項は、法定の消滅時効（民法166条1項・5年）を
--    約款で90日に短縮するに等しく、消費者契約法10条により無効と判断される
--    リスクが高い類型です。」
--
-- 直すのは条文だけではない。`expire_withdrawn_earned()` が cron で毎日走り、
-- **実際に earned_balance = 0 にしていた**（0086）。条文を直しても実装が
-- 消していれば、約束と動作が食い違う。
--
-- ■ 新しい建付け（弁護士が示した方向。論点F(b)と同じ整理に揃える）
--
--   債権は消滅しない。閉じるのは**セルフサービスの換金申請の窓口だけ**。
--   期間の経過後は、運営の窓口への個別の申出により換金する。
--
--   | | 従前 | 0107 |
--   |---|---|---|
--   | 90日経過時 | 残高を0にする | **窓口を閉じるだけ。残高は残る** |
--   | 経過後の換金 | 不可能（残高が無い） | 個別の申出 → 運営コンソールから起票 |
--   | 通知の文面 | 「消滅しました」 | 「受付を終了しました。**残高は残っています**」 |
--
-- ■ 期限の判定は増やさない
--   0086 が `payouts` の INSERT トリガー（`_payouts_check_withdrawal`）で
--   止めている。**「条件の置き場所が1か所で済む」というのが 0086 の設計判断**
--   なので、request_bank_payout 側に同じ判定を足さない。
--   運営の起票だけを通すために、0044 の ledger_override と同じ形の
--   セッション変数を1つ用意する。
--
-- ■ 会計への影響
--   J23（退会から90日経過した報酬コインの消滅）は note='withdraw_earned_expired'
--   を拾うが、**この note は今後発生しない**。購入コインの失効（退会時・0092）は
--   別の経路なので J22 はそのまま。預り金（ホスト報酬）が消えずに残るのが
--   正しい姿になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 窓口を閉じた時刻を持つ
--
-- earned_expired_at（消滅した時刻）は**残すが、もう書かない**。
-- 0044 の追記専用台帳と同じ考え方で、過去の記録を壊さないため。
-- ------------------------------------------------------------
alter table public.account_withdrawals
  add column if not exists payout_window_closed_at timestamptz;

comment on column public.account_withdrawals.payout_window_closed_at is
  'セルフサービスの換金申請の受付を終了した時刻(0107)。**報酬コインは消えていない。**個別の申出があれば admin_payout_on_request() で換金する。';

comment on column public.account_withdrawals.earned_expired_at is
  '【廃止】退会後90日で報酬コインを消滅させていた時刻(0086)。0107で消滅をやめたため、今後は書き込まれない。過去の記録のために列は残す。';

-- ------------------------------------------------------------
-- 2. 消す処理を、窓口を閉じる処理に置き換える
-- ------------------------------------------------------------
create or replace function public.close_withdrawn_payout_window()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_count int := 0;
begin
  for v_rec in
    select aw.user_id, coalesce(w.earned_balance, 0) as earned
    from public.account_withdrawals aw
    join public.coin_wallets w on w.user_id = aw.user_id
    where aw.payout_window_closed_at is null
      and aw.payout_deadline < now()
      and coalesce(w.earned_balance, 0) > 0
      and not exists (
        select 1 from public.payouts p
        where p.user_id = aw.user_id and p.status = 'pending')
    for update of aw skip locked
  loop
    -- ⚠️ **残高には触れない。** ここで earned_balance を動かすと、
    -- 0107 が直そうとしたものをそのまま作り直すことになる。
    update public.account_withdrawals
      set payout_window_closed_at = now() where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system', '換金申請の受付期間が終了しました',
      '退会から90日が経過したため、アプリからの換金申請の受付を終了しました。'
      || 'なお報酬コイン' || v_rec.earned || '枚は消えていません。'
      || 'お問い合わせいただければ、個別に換金の手続を行います。');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.close_withdrawn_payout_window() is
  '退会から90日を過ぎたアカウントの、セルフサービスの換金申請の受付を終了する(規約 第6条の2第4項・0107)。**報酬コインは消さない。**個別の申出は admin_payout_on_request() で処理する。';

revoke all on function public.close_withdrawn_payout_window() from public, anon;

-- cron から外してから落とす。順序を逆にするとジョブが毎日失敗し続ける。
select cron.unschedule('expire-withdrawn-earned')
  where exists (select 1 from cron.job where jobname = 'expire-withdrawn-earned');

drop function if exists public.expire_withdrawn_earned();

select cron.schedule('close-withdrawn-payout-window', '31 3 * * *',
  $$select public.close_withdrawn_payout_window()$$);

-- ------------------------------------------------------------
-- 3. 期限のトリガーに、運営の起票だけを通す抜け道を作る
--
-- 0086 の `_payouts_check_withdrawal` は payouts への INSERT を
-- 一律に止める。**残高を残す以上、運営が個別の申出を処理する経路が要る。**
--
-- 0044 の ledger_override と同じ形にした:
--   ・セッション変数（set local）でのみ開く
--   ・開けられるのは SECURITY DEFINER の運営関数の中だけ
--   ・admin_actions に必ず記録が残る（呼び出し側で perform している）
-- ------------------------------------------------------------
create or replace function public._payouts_check_withdrawal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deadline timestamptz;
begin
  -- 0107: 運営が個別の申出を処理するときだけ通す。
  -- **利用者からは開けられない**（set local を挟めるのは運営関数の中だけ）。
  if coalesce(current_setting('app.payout_window_override', true), 'off') = 'on' then
    return new;
  end if;

  -- **期限は account_withdrawals.payout_deadline が唯一の権威。**
  select aw.payout_deadline into v_deadline
  from public.account_withdrawals aw where aw.user_id = new.user_id;

  if v_deadline is not null and now() > v_deadline then
    raise exception 'PAYOUT_WINDOW_CLOSED';
  end if;
  return new;
end;
$$;

comment on function public._payouts_check_withdrawal() is
  '退会後90日(payout_deadline)を過ぎた換金の起票を止める(規約 第6条の2第4項・0086)。0107で、運営の個別処理(app.payout_window_override)だけ通すようにした。';

revoke all on function public._payouts_check_withdrawal() from public, anon;

-- ------------------------------------------------------------
-- 4. 運営コンソール: 窓口が閉じた後の個別の申出を処理する
-- ------------------------------------------------------------
create or replace function public.admin_closed_window_balances(p_limit int default 200)
returns table (
  user_id uuid,
  nickname text,
  withdrawn_at timestamptz,
  payout_deadline timestamptz,
  window_closed_at timestamptz,
  earned_balance int,
  has_bank_account boolean,
  is_verified boolean
)
language sql
security definer
set search_path = public
as $$
  select aw.user_id,
         p.nickname,
         p.withdrawn_at,
         aw.payout_deadline,
         aw.payout_window_closed_at,
         coalesce(w.earned_balance, 0)::int,
         (b.user_id is not null),
         coalesce(t.is_verified, false)
  from public.account_withdrawals aw
  join public.coin_wallets w on w.user_id = aw.user_id
  left join public.profiles p on p.id = aw.user_id
  left join public.host_bank_accounts b on b.user_id = aw.user_id
  left join public.profile_trust_stats t on t.user_id = aw.user_id
  where public._is_admin()
    and aw.payout_deadline < now()
    and coalesce(w.earned_balance, 0) > 0
  order by coalesce(w.earned_balance, 0) desc
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$$;

comment on function public.admin_closed_window_balances(int) is
  '換金申請の受付が終了した後も残っている報酬コインの一覧(0107)。**残高は消していない**ので、個別の申出があればここから admin_payout_on_request() で起票する。';

revoke all on function public.admin_closed_window_balances(int) from public, anon;
grant execute on function public.admin_closed_window_balances(int) to authenticated;

create or replace function public.admin_payout_on_request(
  p_user_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = p_user_id;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets
    where user_id = p_user_id for update;

  -- 保留は運営の起票でも外さない。**保留の理由は窓口の開閉と無関係**で、
  -- ギフトの様子見(7日)も係争中の凍結も、そのまま効いている必要がある。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = p_user_id and created_at > now() - interval '7 days';
  v_dispute_hold := public._dispute_payout_hold(p_user_id);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if v_available <= c_fee then
    -- 手取りが0以下。**勝手に手数料を引いて振り込まない**
    -- (サービス終了の手順書と同じ考え方。本人に確認してから決める)。
    raise exception 'BELOW_PAYOUT_FEE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - v_available
    where user_id = p_user_id;

  -- 期限を過ぎているので、0086 のトリガーをここだけ開ける
  set local app.payout_window_override = 'on';

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    p_user_id, v_available, v_available - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, -v_available, 'payout', 'admin_payout_on_request:' || v_payout_id);

  perform public._log_admin_action('payout_on_request', v_payout_id,
    v_available || 'コイン / ' || p_reason);

  insert into public.notifications (user_id, type, title, body)
  values (p_user_id, 'system', '換金の手続を行いました',
    'お申し出により、報酬コイン' || v_available || '枚の換金を受け付けました。'
    || '振込手数料を含む事務手数料' || c_fee || '円を差し引いた'
    || (v_available - c_fee) || '円をお振込みします。');

  return v_payout_id;
end;
$$;

comment on function public.admin_payout_on_request(uuid, text) is
  '換金申請の受付が終了した後の個別の申出を、運営が起票する(規約 第6条の2第4項・0107)。**換金可能な全額**を1回で出す(最終換金と同じ扱い)。ギフト・係争の保留はそのまま効く。';

revoke all on function public.admin_payout_on_request(uuid, text) from public, anon;
grant execute on function public.admin_payout_on_request(uuid, text) to authenticated;


-- >>>>>>>> 0108_suspension_paid_coins_limited.sql
-- ============================================================
-- 0108: 利用停止のときに、購入コインを一律で消さないようにする
--
-- 2026-08-05の弁護士回答（論点A-2）による。
--
--   「利用停止等の**原因・程度を問わず**購入コインを一律に消滅させる定めは、
--    違約金・損害賠償額の予定の性質を帯び、消費者契約法9条1号（平均的な損害を
--    超える部分の無効）・10条の攻撃対象になります。軽微な違反（例: マナー違反の
--    累積）でも数万円分の残高が没収される帰結は、**平均的損害との均衡を欠く**と
--    評価されやすい。」
--
-- 報酬コインは 0098 の時点で既に「原則残す・没収は個別判断」になっていた
-- （p_forfeit_earned）。**購入コインだけが無条件に消えていた。**
--
-- ■ 新しい建付け（規約 第6条の3第5項）
--
--   不正な取得・利用が認められる場合に限り消滅させる。
--   それ以外は**消さない**。停止が解除されれば使えるし、解除されなければ
--   第7条5項の有効期限（6か月）で通常どおり失効する。
--
--   **有効期限に委ねるのが要点。** 失効の根拠が「制裁」ではなく
--   「もともとの期限」になるので、平均的損害の議論から外れる。
--
-- ■ 既定値を「消さない」にする
--   p_forfeit_paid の既定は false。**うっかり消えるより、うっかり残るほうが安全。**
--   消すときは運営が明示的に選ぶ（理由は admin_actions に残る）。
-- ============================================================

create or replace function public.admin_suspend_account(
  p_user_id uuid,
  p_reason text,
  p_forfeit_earned boolean default false,
  p_forfeit_paid boolean default false
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

  -- 第6条の3第5項（0108で改訂）:
  -- **不正な取得・利用が認められる場合に限り**購入コインを消滅させる。
  -- それ以外は触らない。停止が解除されれば使えるし、解除されなければ
  -- 第7条5項の有効期限で通常どおり失効する。
  if p_forfeit_paid and (coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0) then
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
    case when p_forfeit_paid then '購入コイン没収 / ' else '購入コインは残す / ' end
    || case when p_forfeit_earned then '報酬コインも没収: ' else '報酬コインは残す: ' end
    || p_reason);

  return jsonb_build_object(
    'user_id', p_user_id,
    'paid_expired', case when p_forfeit_paid then v_paid else 0 end,
    'bonus_expired', case when p_forfeit_paid then v_bonus else 0 end,
    'paid_kept', case when p_forfeit_paid then 0 else v_paid end,
    'earned_forfeited', case when p_forfeit_earned then v_earned else 0 end,
    'payout_claim_deadline', v_deadline
  );
end;
$$;

comment on function public.admin_suspend_account(uuid, text, boolean, boolean) is
  '利用停止(規約 第6条の3)。**購入コインも報酬コインも、既定では消さない。**消すのは違反行為による不正な取得・利用が認められる場合だけで、運営が明示的に選ぶ(0108・2026-08-05の弁護士回答 論点A-2)。消さなかった購入コインは第7条5項の有効期限で通常どおり失効する。';

revoke all on function public.admin_suspend_account(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.admin_suspend_account(uuid, text, boolean, boolean) to authenticated;

-- 3引数の旧シグネチャは残さない。**既定値が変わったのに古い版が残っていると、
-- どちらが呼ばれたかで結果が変わる。**
drop function if exists public.admin_suspend_account(uuid, text, boolean);


-- >>>>>>>> 0109_refund_expiry_preview.sql
-- ============================================================
-- 0109: キャンセルの前に、戻るコインの有効期限を知らせる
--
-- 規約 第9条5の2 後段（2026-07-31 新設）:
--
--   「当社は、キャンセルの手続を行う画面において、**返還されるコインの
--    有効期限が近い場合はその旨を事前に表示します。**」
--
-- **書いたが、実装していなかった。** 2026-08-05 の横断点検（G18）で判明。
-- `my_booking_refund_quote()` は枚数と率しか返しておらず、期限を返していない。
--
-- ■ なぜ「守れない約束」の中でも重いのか
--
--   コインの返還は、**消費したときの期限をそのまま引き継ぐ**（同項前段）。
--   したがって、
--     ・当初の期限を**既に過ぎている分は、戻らずに消える**
--     ・戻っても**残りわずかで、使い切れずに失効する**
--   という事態が現に起こる。
--
--   ゲスト都合のキャンセルでは、消えた分の金銭返金もない
--   （第9条5の3の対象は**ゲスト無帰責**の場合だけ）。
--   **押す前に知らせないと「知らされずに消えた」という話になる。**
--
-- ■ 何を返すか
--
--   `_refund_coin_lots_for_booking()` の割当てを**書き込まずに**なぞる。
--   実際に戻す処理と同じ順序（期限の早い順）・同じ有償/無償の配分で数え、
--     ・lapsed_coins … 既に期限切れで**戻らない**枚数（うち有償分も）
--     ・soon_coins   … 戻るが**期限が近い**枚数（既定14日以内）
--     ・soonest_expires_at … 戻る分のうち最も早い期限
--     ・cash_refund_coins  … 消えた分のうち**金銭で返す**枚数
--   を返す。
--
--   ⚠️ **画面で計算し直さないこと。** 割当ての規則が2か所になると、
--   表示と実際がずれる（0048 で率から実額が出せなくなったのと同じ轍）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 割当てのなぞり（書き込みなし）
--
-- _refund_coin_lots_for_booking と**同じループ**にしてある。
-- どちらかを直すときは、必ず両方を直すこと。
-- ------------------------------------------------------------
create or replace function public._refund_lot_forecast(
  p_booking_id uuid,
  p_paid int,
  p_bonus int,
  p_soon_days int default 14
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_booking public.bookings;
  v_rec record;
  v_found boolean := false;
  v_left_paid int;
  v_left_bonus int;
  v_take int;
  v_lapsed_paid int := 0;
  v_lapsed_bonus int := 0;
  v_soon int := 0;
  v_soonest timestamptz;
  v_expiry timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null then
    return jsonb_build_object('lapsed_coins', 0, 'lapsed_paid_coins', 0,
                              'soon_coins', 0, 'soonest_expires_at', null);
  end if;

  v_left_paid := coalesce(p_paid, v_booking.paid_coins);
  v_left_bonus := coalesce(p_bonus, v_booking.bonus_coins);

  for v_rec in
    select kind, expires_at, coins
    from public.coin_lot_consumptions
    where booking_id = p_booking_id and restored_at is null
    order by expires_at
  loop
    v_found := true;
    if v_rec.kind = 'paid' then
      v_take := least(v_left_paid, v_rec.coins);
      v_left_paid := v_left_paid - v_take;
    else
      v_take := least(v_left_bonus, v_rec.coins);
      v_left_bonus := v_left_bonus - v_take;
    end if;

    if v_take > 0 then
      if v_rec.expires_at > now() then
        if v_soonest is null or v_rec.expires_at < v_soonest then
          v_soonest := v_rec.expires_at;
        end if;
        if v_rec.expires_at < now() + make_interval(days => p_soon_days) then
          v_soon := v_soon + v_take;
        end if;
      elsif v_rec.kind = 'paid' then
        v_lapsed_paid := v_lapsed_paid + v_take;
      else
        v_lapsed_bonus := v_lapsed_bonus + v_take;
      end if;
    end if;
  end loop;

  -- 0030 より前の予約(消費記録なし)。本体と同じく作成時刻から引き直す。
  if not v_found then
    v_expiry := public.coin_expiry_from(v_booking.created_at);
    if v_expiry > now() then
      v_soonest := v_expiry;
      if v_expiry < now() + make_interval(days => p_soon_days) then
        v_soon := v_left_paid + v_left_bonus;
      end if;
    else
      v_lapsed_paid := v_left_paid;
      v_lapsed_bonus := v_left_bonus;
    end if;
  end if;

  return jsonb_build_object(
    'lapsed_coins', v_lapsed_paid + v_lapsed_bonus,
    'lapsed_paid_coins', v_lapsed_paid,
    'soon_coins', v_soon,
    'soonest_expires_at', v_soonest
  );
end;
$$;

comment on function public._refund_lot_forecast(uuid, int, int, int) is
  'キャンセルで戻るコインの期限を、書き込まずに見積もる(規約 第9条5の2後段・0109)。_refund_coin_lots_for_booking と同じ順序・同じ配分でなぞる。**片方だけ直さないこと。**';

revoke all on function public._refund_lot_forecast(uuid, int, int, int) from public, anon;

-- ------------------------------------------------------------
-- 2. 見積りに期限を足す
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
  v_refund_paid int;
  v_refund_bonus int;
  v_fc jsonb;
  v_soon_days int;
  v_guest_fault boolean;
  v_cash int;
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

  -- cancel_booking と同じ配分(有償から先に戻す)
  v_refund_paid := least(v_b.paid_coins, v_refund);
  v_refund_bonus := v_refund - v_refund_paid;

  -- 「期限が近い」の目安は、失効の事前通知(0089)と同じ日数を使う。
  -- **2か所に別の数字があると、通知が来ない期間に警告だけ出る**ような
  -- ちぐはぐが起きる
  select coalesce(expiry_notice_days, 14) into v_soon_days
    from public.platform_pricing where id = 1;

  v_fc := public._refund_lot_forecast(
    p_booking_id, v_refund_paid, v_refund_bonus, coalesce(v_soon_days, 14));

  -- いま押そうとしているのがゲストなら guest_fault。
  -- **ゲスト都合だと、消えた分の金銭返金は無い**(第9条5の3はゲスト無帰責のみ)。
  -- ここを取り違えると、消える話を「返金されます」と伝えてしまう
  v_guest_fault := auth.uid() = v_b.guest_id;
  v_cash := case when v_guest_fault then 0
                 else (v_fc ->> 'lapsed_paid_coins')::int end;

  return jsonb_build_object(
    'coins', v_b.coins,
    'refund_coins', v_refund,
    'forfeit_coins', v_b.coins - v_refund,
    'base_percent', v_pct,
    'capped', v_refund > round(v_b.coins * v_pct / 100.0),
    'played', v_b.guest_checked_in_at is not null and v_b.host_checked_in_at is not null,
    -- 0109(規約 第9条5の2後段)
    'lapsed_coins', (v_fc ->> 'lapsed_coins')::int,
    'soon_coins', (v_fc ->> 'soon_coins')::int,
    'soonest_expires_at', v_fc ->> 'soonest_expires_at',
    'soon_days', coalesce(v_soon_days, 14),
    'cash_refund_coins', v_cash
  );
end;
$$;

comment on function public.my_booking_refund_quote(uuid) is
  'いまキャンセルしたら何コイン戻るか。0109で、戻るコインの有効期限(既に切れて戻らない分・期限が近い分・最も早い期限)と、消えた分の金銭返金の有無を足した(規約 第9条5の2後段・5の3)。';

revoke all on function public.my_booking_refund_quote(uuid) from public, anon;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;


-- >>>>>>>> 0110_gift_share_metric.sql
-- ============================================================
-- 0110: ギフトが「従たる地位」に留まっていることを、月次で残す
--
-- 2026-08-05 の弁護士回答（論点B(b)2）:
--
--   「**月次モニタリング指標の設定** — ギフト流通総額／予約対価総額の比率を
--    継続的に記録し、**ギフトが従たる地位に留まることを事後的に立証できる**
--    ようにする（分析メモの実証パート）。」
--
-- ■ なぜ数字が要るのか
--
--   ギフトを「為替取引に当たらない」と整理する根拠のひとつは、
--   **ギフトが主たる収益源ではなく、役務提供に付随する任意の追加対価に
--   すぎない**ことにある。これは条文で宣言するだけでは足りず、
--   **実績で示せなければ、財務局への照会でも紛争でも通らない。**
--
--   逆に、この比率が上がり続けているのに放置していると、
--   「実態としては送金の仕組みだった」という評価を自ら裏づけることになる。
--
-- ■ どこに出すか
--   運営コンソールの「経営」タブ（`admin_business_kpis`）に1行足す。
--   混合実効率・上位集中・チャージバック率と同じ場所で毎月見る。
--   **別画面にすると見なくなる。**
--
-- ■ 母数が0のときは null
--   0105 と同じ扱い。**「0%」と「まだ取引が無い」を区別する。**
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_gross bigint := 0;
  v_fee bigint := 0;
  v_booking_gross bigint := 0;
  v_booking_fee bigint := 0;
  v_gift_gross bigint := 0;
  v_gift_fee bigint := 0;
  v_hosts int := 0;
  v_top5 bigint := 0;
  v_top1 bigint := 0;
  v_purchase_yen bigint := 0;
  v_safety_yen bigint := 0;
  v_cb_count int := 0;
  v_cb_yen bigint := 0;
  v_cb_open int := 0;
  v_cb_lost int := 0;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  v_from := coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - 30)::timestamptz;
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date) + 1)::timestamptz;

  -- ① 利用料の実効率
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ② 上位集中(予約の対価で見る)
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where kind = 'booking' and created_at >= v_from and created_at < v_to
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ③ チャージバック
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
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end,
      -- 0110: **ギフトが従たる地位に留まっているか。**
      -- 為替取引に当たらないという整理の実証パート
      -- (2026-08-05の弁護士回答 論点B(b)2)。
      -- 分母は予約の対価。**上がり続けているのに放置しない。**
      'giftToBookingPercent', case when v_booking_gross > 0
        then round(v_gift_gross::numeric * 100 / v_booking_gross, 1) else null end
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
      'safetyFeeYen', v_safety_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    )
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営の要点(運営)。利用料の混合実効率・上位集中・チャージバック率。0110で「ギフト流通総額／予約対価総額」を追加(ギフトが従たる地位に留まることを事後的に立証するため。2026-08-05の弁護士回答 論点B(b)2)。母数0は null で返し、0%と区別する。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;


-- >>>>>>>> 0111_kpi_window_timezone_fix.sql
-- ============================================================
-- 0111: 経営指標の集計期間が JST になっていなかったのを直す
--
-- ■ 何が起きていたか
--   `0110` が `admin_business_kpis` を書き直したとき（ギフト比率の追加）、
--   集計期間の作り方が `0105` から変わっていた。
--
--     0105（正）: v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
--     0110（誤）: v_from := coalesce(p_from, ...)::timestamptz;
--
--   `date::timestamptz` は**セッションのタイムゾーン**で解釈される。
--   Supabase のセッションは UTC なので、日本時間の日付を渡しても
--   UTC の 00:00 として扱われ、**集計の窓が9時間ずれる**。
--
--   結果として、日本時間の 00:00〜09:00 に発生した手数料が、
--   その日の集計から落ちて前日に入る。日次で見れば毎日ずれ、
--   月次でも月初・月末の境界がずれる。
--
-- ■ なぜ気づきにくかったか
--   母数が0になると各指標は `null` を返す設計になっている。
--   `29_business_kpis.sql` の判定は `(... ->> 'blendedPercent')::numeric <> 17.73`
--   の形で、値が null だと比較結果も null になり、`if null then` は
--   発火しない。**窓がずれて空になっても、テストは黙って通っていた。**
--   落ちたのは activeHosts だけで、これは count(*) が 0 を返すため
--   null にならず、比較が成立したから。
--
--   → 検知できるように、テスト側も「値が入っていること」を先に確かめる形へ
--     直した（`supabase/tests/29_business_kpis.sql`）。
--
-- ■ なぜ直す価値があるか
--   この関数の `giftToBookingPercent` は、**ギフトが従たる地位に留まることを
--   事後的に示すために置いた指標**（`0110`／2026-08-05 の弁護士回答 論点B(b)2）。
--   財務局への説明に使う数字がずれたままなのは、いちばん困る。
--
-- ■ 引数の既定値（null）は 0110 のまま残す
--   運営コンソールが期間を指定せずに呼ぶ経路があるため。
--   ただし既定値の算出も JST の日付から作り、変換も JST で行う。
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date default null,
  p_to date default null
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
  v_from_d date;
  v_to_d date;
  v_gross bigint := 0;
  v_fee bigint := 0;
  v_booking_gross bigint := 0;
  v_booking_fee bigint := 0;
  v_gift_gross bigint := 0;
  v_gift_fee bigint := 0;
  v_hosts int := 0;
  v_top5 bigint := 0;
  v_top1 bigint := 0;
  v_purchase_yen bigint := 0;
  v_safety_yen bigint := 0;
  v_cb_count int := 0;
  v_cb_yen bigint := 0;
  v_cb_open int := 0;
  v_cb_lost int := 0;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  -- 既定は「JSTの今日から遡って30日」。
  -- **日付は JST で決め、timestamptz への変換も JST で行う。**
  -- `date::timestamptz` はセッションのタイムゾーン(UTC)で解釈されるため使わない。
  v_from_d := coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - 30);
  v_to_d := coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date);
  if v_to_d < v_from_d then
    raise exception 'INVALID_RANGE';
  end if;

  -- JSTの [v_from_d 00:00, v_to_d+1日 00:00)。会計タブ(0086)と同じ切り方
  v_from := (v_from_d::timestamp at time zone 'Asia/Tokyo');
  v_to := ((v_to_d + 1)::timestamp at time zone 'Asia/Tokyo');

  -- ① 利用料の実効率
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ② 上位集中(予約の対価で見る)
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where kind = 'booking' and created_at >= v_from and created_at < v_to
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ③ チャージバック
  select
    coalesce(sum(price_yen), 0),
    coalesce(sum(safety_fee_yen), 0)
  into v_purchase_yen, v_safety_yen
  from public.coin_purchases
  where created_at >= v_from and created_at < v_to;

  select
    count(*),
    coalesce(sum(amount_yen), 0),
    count(*) filter (where status = 'open'),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', v_from_d,
    'to', v_to_d,
    'fees', jsonb_build_object(
      'grossCoins', v_gross,
      'feeCoins', v_fee,
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end,
      -- 0110: ギフトが従たる地位に留まることを事後的に示すための比率
      'giftToBookingPercent', case when v_booking_gross > 0
        then round(v_gift_gross::numeric * 100 / v_booking_gross, 1) else null end
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
      'safetyFeeYen', v_safety_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    )
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営の要点(運営)。利用料の混合実効率・上位集中・チャージバック率・ギフト比率。0111で集計期間をJSTに直した(0110がセッションのタイムゾーンで日付を変換しており、窓が9時間ずれていた)。母数0は null で返し、0%と区別する。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;


-- >>>>>>>> 0112_admin_board_moderation.sql
-- ============================================================
-- 0112: 募集投稿を運営コンソールから取り下げられるようにする  ★突合表 G21
--
-- ■ 何が無かったか
--   募集掲示板（`board_posts`）に不適切な投稿が出たとき、
--   **運営に消す手段が無かった。**
--     ・`cancel_board_post` は `creator_id <> auth.uid()` で弾くので投稿者専用
--     ・通報（`reports`）は**人**に対するもので、投稿を指せない
--     ・運営コンソールに募集を見るタブが無い
--   つまり「見つけても消せない」状態だった。
--   規約 第13条は当社が投稿を削除できると定めているのに、実装が無い。
--
-- ■ なぜ運営の裁量に寄せるか
--   「今後は運営作業は運営コンソールから操作できるようにして下さい」という
--   方針に従う。SQL Editor で `update board_posts set status='cancelled'` を
--   打つ運用にすると、**誰がいつ何を消したかが残らない。**
--
-- ■ 消さずに取り下げる
--   行は削除せず `status = 'cancelled'` にする。投稿者専用の取り消しと
--   同じ状態にそろえる。**証跡を消さない**ためで、通報の裏取りにも要る。
--   区別は `cancel_reason` の頭に「運営による取り下げ：」を付けて残す。
--
-- ■ 投稿者にも必ず知らせる
--   投稿者専用の `cancel_board_post` は、参加表明した人にだけ通知する
--   （投稿者は自分で消しているので知らせる必要が無い）。
--   運営が取り下げる場合は逆で、**投稿者が知らないと何が起きたか分からない。**
--   両方に通知する。
-- ============================================================

-- ------------------------------------------------------------
-- 一覧（運営コンソールの「募集」タブ）
--
-- 掲示板の公開クエリと違い、**取り下げ済みも見える**ようにする。
-- 「消したはずのものが本当に消えているか」を確かめる場所でもあるため。
-- ------------------------------------------------------------
create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  capacity int,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  participants int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.capacity,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.board_participants bp where bp.post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0112。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;

-- ------------------------------------------------------------
-- 取り下げ
-- ------------------------------------------------------------
create or replace function public.admin_remove_board_post(
  p_post_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_reason text;
  v_participant record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須。** 記録の要らない削除は、あとから説明できない。
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_post_id;

  -- 投稿者に知らせる。**理由も渡す。**
  -- 何が引っかかったのか分からないと、同じ投稿をもう一度出してくる
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_cancelled',
    '募集を取り下げました',
    v_post.game || '・' || v_post.when_text || '（理由：' || v_reason || '）',
    p_post_id
  );

  -- 参加表明していた人にも知らせる。
  -- 待っている側からすると、理由より「無くなった」ことのほうが要る情報なので、
  -- 理由は載せない（運営の判断の内容を第三者に配らない）
  for v_participant in
    select user_id from public.board_participants where post_id = p_post_id
  loop
    if v_participant.user_id <> v_post.creator_id then
      insert into public.notifications (user_id, type, title, body, related_id)
      values (
        v_participant.user_id,
        'board_cancelled',
        '参加予定だった募集が取り下げられました',
        v_post.game || '・' || v_post.when_text,
        p_post_id
      );
    end if;
  end loop;

  perform public._log_admin_action('board_post_removed', p_post_id, v_reason);
end;
$$;

comment on function public.admin_remove_board_post(uuid, text) is
  '募集投稿を運営が取り下げる(0112・突合表G21)。行は消さず status=cancelled にし、cancel_reason に「運営による取り下げ：」を付けて残す。理由は必須。投稿者と参加者の双方に通知し、admin_actions に記録する。';

revoke all on function public.admin_remove_board_post(uuid, text) from public, anon;
grant execute on function public.admin_remove_board_post(uuid, text) to authenticated;


-- >>>>>>>> 0113_board_is_for_hosts.sql
-- ============================================================
-- 0113: 募集板を「ピタメイトがゲストを呼ぶ場」に作り直す
--
-- ■ これまで
--   `0011` の募集板は**誰でも投稿でき、誰でも無料で参加表明できる**掲示板だった。
--   「今夜Apexを一緒に」を出して、定員まで人が集まったら締め切る、という形。
--   コインは一切動かない。
--
-- ■ これから
--   **掲載中のピタメイトだけが投稿でき、ゲストは予約の申込みに進む。**
--   募集は「この条件で空いています」という告知で、入口は予約に繋がる。
--
-- ■ ★なぜ「参加表明」を残さないか（ここがいちばん大事）
--   投稿をピタメイトに限ったうえで無料の参加表明を残すと、
--   **板の上に「ピタメイトと無料で遊べる経路」ができる。**
--   ピタフレの役務は予約＝有償で成り立っており、
--     ・税務（対価を得て提供する役務）
--     ・規約 第8条（役務提供契約はゲストとピタメイトの間に成立し、対価が発生する）
--     ・プラットフォーム利用料の徴収
--   のすべてがその前提に乗っている。無料の抜け道を board に作ると、
--   **いちばん使われる導線がその抜け道になる。**
--   なので `join_board_post` は廃止し、`board_participants` ごと落とす。
--
-- ■ capacity を落とす理由
--   予約は1対1（`create_booking(p_host_id, ...)`）。定員3の募集に3人来たら
--   「同時に3人と遊ぶ」のか「3人ぶんの別々の枠」なのか、誰にも分からない。
--   **1募集＝1つの空き枠**にそろえる。
--
-- ■ 料金を投稿に持たせない
--   `host_settings.hourly_rate` から出す。投稿に写すと、料金を変えたときに
--   板だけ古い額を出し続ける。申込前の価格表示なので、ずれると景表法の問題になる。
--
-- ■ 日時は自由記述のまま
--   `when_text`（「今夜 22:00〜」等）は目安として残す。実際の日時は
--   予約画面で選び、`create_booking` の側でリードタイム・枠・重複が検証される。
--   **検証の責任を1か所に集めておく**ため、板では持たない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 参加表明を落とす
-- ------------------------------------------------------------
drop function if exists public.join_board_post(uuid);
-- テーブルを落とせば、それに付いていたトリガーも一緒に落ちる
--   ・`0012` の board_participants_notify_joined（参加の通知）
--   ・`0074` の board_participants_require_consent（みまもり撤回で参加を止める）
drop table if exists public.board_participants;
-- トリガーが消えても関数は残るので、使われなくなったものを片付ける
drop function if exists public._board_participants_require_consent();
drop function if exists public.notify_board_joined();

-- ⚠️ **募集の投稿を止める側（`0074` の board_posts_require_consent）は残す。**
-- みまもりの同意を撤回した人が募集を出せてしまうと、撤回の意味が無くなる。

-- ------------------------------------------------------------
-- 2. 列の入れ替え
-- ------------------------------------------------------------
alter table public.board_posts drop column if exists capacity;

alter table public.board_posts
  add column if not exists duration_minutes int not null default 60;

-- 予約できる長さと同じ集合に縛る。板で選べる長さが予約で通らない、を防ぐ
alter table public.board_posts
  drop constraint if exists board_posts_duration_ok;
alter table public.board_posts
  add constraint board_posts_duration_ok
  check (public.is_valid_booking_duration(duration_minutes));

comment on column public.board_posts.duration_minutes is
  '募集している1枠の長さ(分)。予約画面の初期値になる。0113。';
comment on table public.board_posts is
  'ピタメイトが空き枠を告知する板(0113)。**投稿できるのは掲載中のピタメイトだけ。**ゲストは予約の申込みに進む。無料で参加する経路は持たない。';

-- ------------------------------------------------------------
-- 3. 投稿できるのは掲載中のピタメイトだけ
--
--    RLS の with check ではなくトリガーにする。理由は 0081（居住地）と同じで、
--    **条件を画面の実装に依存させない**ため。エラー名で理由も返せる。
-- ------------------------------------------------------------
create or replace function public._board_posts_require_host()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_host boolean;
  v_rate int;
begin
  select hs.is_host, hs.hourly_rate into v_is_host, v_rate
  from public.host_settings hs where hs.user_id = new.creator_id;

  if not coalesce(v_is_host, false) then
    raise exception 'HOST_ONLY';
  end if;
  -- 料金が無いと、見た人が予約に進んだ先で詰まる
  if coalesce(v_rate, 0) <= 0 then
    raise exception 'HOURLY_RATE_REQUIRED';
  end if;
  return new;
end;
$$;

revoke all on function public._board_posts_require_host() from public, anon;

drop trigger if exists board_posts_require_host on public.board_posts;
create trigger board_posts_require_host
  before insert on public.board_posts
  for each row execute function public._board_posts_require_host();

-- ------------------------------------------------------------
-- 4. 取り消しの通知先を変える
--
--    参加者がいなくなったので、代わりに**この募集から予約を申し込んだゲスト**へ知らせる。
--    予約は板を経由しなくても作れるので、板から来たものだけを結びつける列を持つ。
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_board_post_id uuid references public.board_posts (id) on delete set null;

comment on column public.bookings.from_board_post_id is
  '募集板から申し込まれた予約は、その募集を指す(0113)。募集が取り消されたときに、申込者へ知らせるために使う。';

create index if not exists bookings_from_board_post_idx
  on public.bookings (from_board_post_id) where from_board_post_id is not null;

create or replace function public.cancel_board_post(
  p_post_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_name text;
  v_reason text;
  v_guest record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.creator_id <> v_uid then
    raise exception 'ONLY_CREATOR_CAN_CANCEL';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り消しは何もしない(連打対策)
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left(v_reason, 200)
    where id = p_post_id;

  select nickname into v_name from public.profiles where id = v_uid;

  -- この募集から予約を申し込んでいて、まだ終わっていないゲストに知らせる。
  -- **予約そのものは取り消さない。** 予約のキャンセルは返金の規定
  -- （規約 第9条・`cancel_booking`）に乗るので、板の都合で勝手に消さない。
  for v_guest in
    select distinct b.guest_id
    from public.bookings b
    where b.from_board_post_id = p_post_id
      and b.status in ('requested', 'approved')
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_guest.guest_id,
      'board_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが募集を取り下げました',
      v_post.game || '・' || v_post.when_text
        || case when v_reason is null then '' else '（' || v_reason || '）' end
        || ' ※お申し込み済みの予約はそのままです',
      p_post_id
    );
  end loop;
end;
$$;

comment on function public.cancel_board_post(uuid, text) is
  '自分の募集を取り下げる。0113で通知先を「参加表明した人」から「この募集から予約を申し込んだゲスト」に変えた。予約自体は取り消さない(キャンセルは第9条の規定に乗せる)。';

revoke all on function public.cancel_board_post(uuid, text) from public, anon;
grant execute on function public.cancel_board_post(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 5. 募集から予約する
--
--    `create_booking` をそのまま呼ぶ。**検証をここで作り直さない。**
--    リードタイム・枠・重複・残高・本人確認は、すべて向こうが見ている。
--    ここがやるのは「板の条件を満たしているか」と「紐づけ」だけ。
-- ------------------------------------------------------------
create or replace function public.create_booking_from_board(
  p_post_id uuid,
  p_policy_version text,
  p_scheduled_at timestamptz default null,
  p_duration_minutes int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_verified boolean;
  v_my_gender text;
  v_creator_gender text;
  v_booking_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_uid then
    raise exception 'CANNOT_BOOK_OWN_POST';
  end if;

  -- 板の側の条件（0011 から引き継ぐ）
  if v_post.verified_only then
    select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
    if not coalesce(v_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_my_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  -- ブロック関係は create_booking 側でも見るが、
  -- ここで止めたほうが「なぜ押せないか」を板の文脈で返せる
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  v_booking_id := public.create_booking(
    v_post.creator_id,
    coalesce(p_duration_minutes, v_post.duration_minutes),
    p_policy_version,
    p_scheduled_at
  );

  update public.bookings set from_board_post_id = p_post_id where id = v_booking_id;

  -- **1募集＝1枠。** 申込みが入った時点で板から下ろす。
  -- 断られた場合に開き直さないのは、開け直しの判断を投稿者に委ねるため
  -- （辞退した相手の申込みで枠が消えたままになるより、自分で出し直せるほうが分かりやすい）
  update public.board_posts set status = 'closed' where id = p_post_id;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_board(uuid, text, timestamptz, int) is
  '募集板から予約を申し込む(0113)。板の条件(本人確認・対象・ブロック)を見たうえで create_booking をそのまま呼ぶ。検証は create_booking 側に集約する。申込みが入ったら募集は closed にする(1募集=1枠)。';

revoke all on function public.create_booking_from_board(uuid, text, timestamptz, int) from public, anon;
grant execute on function public.create_booking_from_board(uuid, text, timestamptz, int) to authenticated;

-- ------------------------------------------------------------
-- 5-2. 運営の取り下げも通知先を変える（0112 の作り直し）
--
--      0112 は参加表明した人に通知していた。参加表明が無くなったので、
--      **この募集から予約を申し込んだゲスト**に切り替える。
-- ------------------------------------------------------------
create or replace function public.admin_remove_board_post(
  p_post_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_reason text;
  v_guest record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須。** 記録の要らない削除は、あとから説明できない。
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_post_id;

  -- 投稿者に知らせる。**理由も渡す。**
  -- 規約 第10条の2 6項が「削除の理由をユーザーに通知します」と定めている。
  -- 何が引っかかったのか分からないと、同じ投稿をもう一度出してくる
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_cancelled',
    '募集を取り下げました',
    v_post.game || '・' || v_post.when_text || '（理由：' || v_reason || '）',
    p_post_id
  );

  -- この募集から申し込んでいたゲストにも知らせる。
  -- **理由は載せない**（運営の判断の内容を第三者に配らない）。
  -- **予約は取り消さない**（キャンセルは規約 第9条の規定に乗せる）。
  for v_guest in
    select distinct b.guest_id
    from public.bookings b
    where b.from_board_post_id = p_post_id
      and b.status in ('requested', 'approved')
      and b.guest_id <> v_post.creator_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_guest.guest_id,
      'board_cancelled',
      '申し込んだ募集が取り下げられました',
      v_post.game || '・' || v_post.when_text || ' ※お申し込み済みの予約はそのままです',
      p_post_id
    );
  end loop;

  perform public._log_admin_action('board_post_removed', p_post_id, v_reason);
end;
$$;

comment on function public.admin_remove_board_post(uuid, text) is
  '募集投稿を運営が取り下げる(0112・突合表G21。0113で通知先を予約の申込者に変更)。行は消さず status=cancelled にし、cancel_reason に「運営による取り下げ：」を付けて残す。理由は必須。投稿者には理由つき、申込者には理由なしで通知し、admin_actions に記録する。予約は取り消さない。';

revoke all on function public.admin_remove_board_post(uuid, text) from public, anon;
grant execute on function public.admin_remove_board_post(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 6. 運営の一覧から capacity / participants を外す（0112 の作り直し）
-- ------------------------------------------------------------
drop function if exists public.admin_board_posts(text, int);

create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  duration_minutes int,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  bookings int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.duration_minutes,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.bookings bk where bk.from_board_post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0113で参加人数を「この募集から入った予約の件数」に置き換えた。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;


-- >>>>>>>> 0114_board_time_window.sql
-- ============================================================
-- 0114: 募集に「受付の範囲」を持たせる
--
-- ■ 直前の状態
--   `0113` で募集板をピタメイト専用にしたが、日時は `when_text` の自由記述
--   （画面では3択 `WHENS = ['今夜 22:00〜', '明日 21:00〜', '日時を指定']`）
--   のままだった。
--
--   ここには2つ問題があった。
--     ① **「日時を指定」を選んでも、日時を入れる欄が無い。** 投稿にそのまま
--        「日時を指定」という文字列が入る
--     ② **書いた内容と予約画面が無関係。** 「今夜22時〜」と書いてあっても、
--        ゲストは翌日の昼を選べてしまう
--
-- ■ 1点の日時ではなく「範囲」にする理由
--   1点固定だと硬すぎる。22:00ちょうどしか取れないと、少しズレただけで
--   成立せず、1件の募集で1人しか拾えない。
--   範囲なら、**広く取れば「相談で」・狭く取れば「この時間だけ」**になり、
--   柔軟さの度合いをピタメイト自身が決められる。
--
--     window_start / window_end がどちらも null … 日時は相談で
--     8/12 20:00 〜 8/12 24:00               … その日の夜のあいだで
--     8/15 00:00 〜 8/17 24:00               … その週末のどこかで
--
-- ■ 遊べる時間帯の枠（`set_host_availability`）とは別物
--   枠は「毎週この曜日のこの時間」。募集の範囲は「今回この日程で募集します」。
--   **予約は両方を満たす必要がある**（枠は `create_booking` が見ている）。
--   枠の外に範囲を書くと予約画面で全部弾かれるので、画面側で警告を出す。
--   ただし**ここでは弾かない**——枠を後から足す運用があるため。
--
-- ■ 期限切れを自動で下ろす
--   いまは「今夜」と書いた募集が1週間残る。`window_end` があれば過ぎたものを
--   閉じられる。**板が死んだ投稿で埋まるのは、公開直後にいちばん効く問題。**
-- ============================================================

alter table public.board_posts
  add column if not exists window_start timestamptz,
  add column if not exists window_end timestamptz;

-- 片方だけ入っている状態を作らない。範囲として意味を成さない
alter table public.board_posts
  drop constraint if exists board_posts_window_pair;
alter table public.board_posts
  add constraint board_posts_window_pair
  check (
    (window_start is null and window_end is null)
    or (window_start is not null and window_end is not null and window_end > window_start)
  );

comment on column public.board_posts.window_start is
  '受付を開始する日時。null なら「相談で」(0114)。';
comment on column public.board_posts.window_end is
  '受付を締め切る日時。null なら「相談で」(0114)。過ぎた募集は close_expired_board_posts が閉じる。';

create index if not exists board_posts_window_end_idx
  on public.board_posts (window_end) where status = 'open' and window_end is not null;

-- ------------------------------------------------------------
-- 範囲の中でしか申し込めないようにする
-- ------------------------------------------------------------
create or replace function public.create_booking_from_board(
  p_post_id uuid,
  p_policy_version text,
  p_scheduled_at timestamptz default null,
  p_duration_minutes int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_verified boolean;
  v_my_gender text;
  v_creator_gender text;
  v_booking_id uuid;
  v_minutes int;
  v_end timestamptz;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_uid then
    raise exception 'CANNOT_BOOK_OWN_POST';
  end if;

  -- 板の側の条件（0011 から引き継ぐ）
  if v_post.verified_only then
    select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
    if not coalesce(v_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_my_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  v_minutes := coalesce(p_duration_minutes, v_post.duration_minutes);

  -- 0114: 範囲が指定されている募集は、その中に**収まる**こと。
  -- 開始だけ範囲内で終わりがはみ出す申込みは、告知した時間を超えるので通さない
  if v_post.window_start is not null then
    if p_scheduled_at is null then
      raise exception 'START_TIME_REQUIRED';
    end if;
    v_end := p_scheduled_at + make_interval(mins => v_minutes);
    if p_scheduled_at < v_post.window_start or v_end > v_post.window_end then
      raise exception 'OUTSIDE_BOARD_WINDOW';
    end if;
    -- 締め切りを過ぎた募集は、cron が閉じる前でも受け付けない
    if now() >= v_post.window_end then
      raise exception 'BOARD_WINDOW_PASSED';
    end if;
  end if;

  v_booking_id := public.create_booking(
    v_post.creator_id,
    v_minutes,
    p_policy_version,
    p_scheduled_at
  );

  update public.bookings set from_board_post_id = p_post_id where id = v_booking_id;
  update public.board_posts set status = 'closed' where id = p_post_id;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_board(uuid, text, timestamptz, int) is
  '募集板から予約を申し込む(0113、0114で受付の範囲を追加)。範囲が指定されている募集は、開始から終了まで範囲に収まる申込みだけを通す。板の条件を見たうえで create_booking をそのまま呼ぶ(リードタイム・枠・重複・残高の検証は向こうに集約)。申込みが入ったら募集は closed。';

revoke all on function public.create_booking_from_board(uuid, text, timestamptz, int) from public, anon;
grant execute on function public.create_booking_from_board(uuid, text, timestamptz, int) to authenticated;

-- ------------------------------------------------------------
-- 締め切りを過ぎた募集を閉じる
--
-- **取り消し(cancelled)ではなく closed。** 投稿者が下ろしたわけではないので、
-- 取り消しと同じ状態にすると、あとから「なぜ消えたか」が読めなくなる。
-- 申込みが入って締まったのと同じ扱いにする。
-- ------------------------------------------------------------
create or replace function public.close_expired_board_posts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update public.board_posts
    set status = 'closed'
    where status = 'open'
      and window_end is not null
      and window_end <= now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.close_expired_board_posts() is
  '受付の締め切りを過ぎた募集を閉じる(0114)。cancelled ではなく closed にする(投稿者が下ろしたわけではないため)。';

revoke all on function public.close_expired_board_posts() from public, anon, authenticated;

select cron.unschedule('close-expired-board-posts')
  where exists (select 1 from cron.job where jobname = 'close-expired-board-posts');

-- 15分おき。締め切りちょうどに消える必要は無いが、
-- 1時間も残ると「もう終わった募集」を押させてしまう
select cron.schedule('close-expired-board-posts', '*/15 * * * *',
  $cron$select public.close_expired_board_posts();$cron$);

-- ------------------------------------------------------------
-- 運営の一覧にも範囲を出す
-- ------------------------------------------------------------
drop function if exists public.admin_board_posts(text, int);

create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  duration_minutes int,
  window_start timestamptz,
  window_end timestamptz,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  bookings int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.duration_minutes,
    b.window_start,
    b.window_end,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.bookings bk where bk.from_board_post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0114で受付の範囲を追加。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;


-- >>>>>>>> 0115_hosts_open_at.sql
-- ============================================================
-- 0115: 「その時間に遊べるピタメイト」を一度に引く
--
-- ■ なぜ要るか
--   ゲストが金を払って買っているのは「今夜21時に、確実に、気楽に遊べる状態」
--   であって、人そのものではない。ところが探す画面は**時間を検索条件として
--   持っていなかった**。
--
--     ・`fetchDiscoverableHosts` は host_availability を見ていない
--     ・空き枠が見えるのはプロフィールを開いてから(0051 の host_schedule)
--     ・並びは「また呼ばれているか」順。今夜遊びたい人には無関係
--
--   結果、良さそうな人を一人ずつ開いて、空きを見て、閉じる、の繰り返しになる。
--   一番強い動機が、一番手間のかかる作業に変換されていた。
--
-- ■ 既存の host_schedule との違い
--   あちらは**1人ぶん**を1時間ごとに返す(プロフィールのタイル用)。
--   こちらは**範囲を渡して、その中で予約できる人を全員**返す。
--   人ごとに host_schedule を呼ぶと、一覧の人数だけ往復が増える。
--
-- ■ create_booking と判定を必ず揃えること
--   ここに出したのに申し込むと弾かれる、が最悪の体験になる。
--   `create_booking`(0082) が見ているものと同じものを、同じ順で見る:
--     ・is_host / hourly_rate があること・本人確認済みであること
--     ・min_lead_minutes / max_lead_days(platform_pricing)
--     ・booking_fits_availability 相当(プレイ時間の全体が枠に収まる)
--     ・slot_open_to(0057 の常連への先行予約)
--     ・ピタメイト側とゲスト側、どちらの予約とも重ならないこと
--   **判定を足したり緩めたりしない。** 片方だけ直すとズレる。
--
-- ■ 出さないもの
--   在席(オンライン)は返さない。ここは「予約できる時間」を返す関数で、
--   「いま誰が居るか」を配る関数ではない(0052 が未ログインに在席を出さない
--   と決めたのと同じ理由)。
--
-- ■ 走査量
--   ピタメイト数 × 時間数。範囲は 14 日で頭打ちにする。
--   1時間刻みで見るのは、探す画面の表示が「今夜 21:00〜空き」で足りるから。
--   30分刻みの選択は予約画面(startTimeOptionsInRange)の担当。
-- ============================================================

create or replace function public.hosts_open_at(
  p_from timestamptz,
  p_to timestamptz,
  p_minutes int default 60
)
returns table (host_id uuid, next_open_at timestamptz, open_starts int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_minutes int;
  v_span int;
  v_from timestamptz;
  v_to timestamptz;
  v_min_lead int;
  v_max_lead int;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  v_minutes := greatest(30, least(coalesce(p_minutes, 60), 720));
  -- 1時間刻みの開始なので、必要な「開いている時間」の数は切り上げでよい
  -- (21:00 から90分なら 21時と22時の2つ)
  v_span := ceil(v_minutes / 60.0)::int;

  select p.min_lead_minutes, p.max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing p where p.id = 1;
  v_min_lead := coalesce(v_min_lead, 30);
  v_max_lead := coalesce(v_max_lead, 35);

  -- 受け付けられない時刻は最初から候補にしない。
  -- **切り上げる。** 切り下げると START_TOO_SOON で弾かれる枠を出してしまう
  v_from := greatest(
    date_trunc('hour', coalesce(p_from, now())),
    date_trunc('hour', now() + make_interval(mins => v_min_lead)) + interval '1 hour'
  );
  v_to := least(
    coalesce(p_to, v_from + interval '1 day'),
    now() + make_interval(days => v_max_lead),
    v_from + interval '14 days'
  );

  if v_to <= v_from then
    return;
  end if;

  return query
  with hosts as (
    select hs.user_id
    from public.host_settings hs
    join public.profile_trust_stats ts
      on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
    where hs.is_host
      and hs.hourly_rate is not null
      and hs.user_id <> v_uid
  ),
  slots as (
    select generate_series(v_from, v_to - make_interval(mins => v_minutes), interval '1 hour') as slot_at
  ),
  grid as (
    select
      h.user_id as gh_host_id,
      s.slot_at,
      case
        -- 予約が入っている時間(申請中も含む。booking_slots の定義どおり)
        when exists (
          select 1 from public.booking_slots b
          where (b.host_id = h.user_id or b.guest_id = h.user_id)
            and b.starts_at < s.slot_at + interval '1 hour'
            and s.slot_at < b.ends_at
        ) then 0
        -- 遊べる時間帯の外。枠を1つも設定していない人は常に開いている扱い(0051)
        when not public.host_is_open_at(h.user_id, s.slot_at) then 0
        else 1
      end as ok
    from hosts h cross join slots s
  ),
  runs as (
    select
      g.gh_host_id,
      g.slot_at,
      sum(g.ok) over w as span_ok,
      count(*) over w as span_rows
    from grid g
    window w as (
      partition by g.gh_host_id order by g.slot_at
      rows between current row and v_span - 1 following
    )
  ),
  bookable as (
    select r.gh_host_id, r.slot_at
    from runs r
    where r.span_rows = v_span      -- 範囲の末尾で足りなくなった分は候補にしない
      and r.span_ok = v_span        -- 触るすべての時間が開いていること
      -- 常連への先行予約(0057)。判定はあちらに任せる(写すとズレる)
      and public.slot_open_to(r.gh_host_id, v_uid, r.slot_at)
      -- ゲスト自身の予約と重ならないこと(_booking_slot_conflict と同じ範囲の見方)
      and not exists (
        select 1 from public.booking_slots b
        where (b.host_id = v_uid or b.guest_id = v_uid)
          and b.starts_at < r.slot_at + make_interval(mins => v_minutes)
          and r.slot_at < b.ends_at
      )
  )
  select b.gh_host_id, min(b.slot_at), count(*)::int
  from bookable b
  group by b.gh_host_id;
end;
$$;

comment on function public.hosts_open_at(timestamptz, timestamptz, int) is
  '指定した範囲で、その長さの予約を受けられるピタメイトと、その最初の開始時刻・候補数を返す(0115)。'
  '判定は create_booking(0082) と同じものを同じ順で見る——出したのに申し込めない、を作らないため。'
  '在席(オンライン)は返さない。1時間刻み(30分刻みの選択は予約画面の担当)。';

revoke all on function public.hosts_open_at(timestamptz, timestamptz, int) from public, anon;
grant execute on function public.hosts_open_at(timestamptz, timestamptz, int) to authenticated;


-- >>>>>>>> 0116_hidden_hosts.sql
-- ============================================================
-- 0116: 「この人は検索に出さない」(ブロックより軽い出口)
--
-- ■ なぜ要るか
--   いまある出口は通報とブロックの2つで、どちらも**相手に非がある**ことを
--   前提にした重い操作。「悪くはないが、自分には合わない」に当たる出口が無い。
--
--   出口が重すぎると2つのことが起きる。
--     ① 使われない。合わない相手が一覧に出続け、探すのが面倒になって離れる
--     ② 誤用される。相性の問題を通報やブロックで処理する人が出て、
--        通報の中身が薄まり、本当に危ない通報が埋もれる
--
--   **通報の精度を保つためにも、軽い出口が要る。**
--
-- ■ ブロックとの違い(混ぜないこと)
--                     ブロック(0008)        非表示(ここ)
--     相手への影響     予約もトークも不可     何も変わらない
--     自分の見え方     相手が見えない         検索に出ないだけ
--     相手に伝わるか   実質伝わる             伝わらない
--     運営の扱い       トラブルの記録         **何もしない**
--
--   非表示は**運営の判断材料にしない。** 好みの問題を安全の指標に混ぜると、
--   「この人は非表示にされやすい」といった評価が生まれてしまう。
--   だから件数の集計も、運営コンソールへの表示も作らない。
--
-- ■ 相手からは見えない
--   誰に非表示にされているかが分かると、それ自体が攻撃の材料になる。
--   RLS は自分の行だけ。集計する関数も置かない。
-- ============================================================

create table if not exists public.hidden_hosts (
  user_id uuid not null references auth.users (id) on delete cascade,
  hidden_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, hidden_id),
  constraint hidden_hosts_not_self check (user_id <> hidden_id)
);

comment on table public.hidden_hosts is
  '自分の検索結果に出したくない相手(0116)。ブロックと違い相手には何の影響も無く、'
  '相手からも見えない。運営の判断材料にしない(好みの問題を安全の指標に混ぜないため)。';

alter table public.hidden_hosts enable row level security;

-- 自分の行だけ。**相手からは一切見えない**
create policy "hidden_hosts_own"
  on public.hidden_hosts for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists hidden_hosts_user_idx on public.hidden_hosts (user_id);

-- ------------------------------------------------------------
-- 付け外し
-- ------------------------------------------------------------
create or replace function public.set_host_hidden(p_host_id uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if v_uid = p_host_id then
    raise exception 'CANNOT_HIDE_SELF';
  end if;

  if p_on then
    insert into public.hidden_hosts (user_id, hidden_id)
    values (v_uid, p_host_id)
    on conflict do nothing;
  else
    delete from public.hidden_hosts
    where user_id = v_uid and hidden_id = p_host_id;
  end if;
end;
$$;

comment on function public.set_host_hidden(uuid, boolean) is
  '検索結果に出さない相手の付け外し(0116)。相手には何も起きず、通知も行かない。';

revoke all on function public.set_host_hidden(uuid, boolean) from public, anon;
grant execute on function public.set_host_hidden(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 自分が非表示にしている相手の一覧(解除できるように名前も返す)
--
-- 解除する画面が無いと「間違えて押した」を取り戻せない。
-- 軽い操作ほど誤タップされるので、取り消せることのほうが大事。
-- ------------------------------------------------------------
create or replace function public.my_hidden_hosts()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    h.hidden_id,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    p.avatar_path,
    h.created_at
  from public.hidden_hosts h
  left join public.profiles p on p.id = h.hidden_id
  where h.user_id = auth.uid()
  order by h.created_at desc;
$$;

comment on function public.my_hidden_hosts() is
  '自分が検索に出さないようにしている相手(0116)。解除の画面で使う。';

revoke all on function public.my_hidden_hosts() from public, anon;
grant execute on function public.my_hidden_hosts() to authenticated;
