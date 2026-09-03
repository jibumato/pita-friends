-- ============================================================
-- 0120: ゲストのリクエスト（板に出さずに、条件の合う相手にだけ届ける）
--
-- ■ なぜ要るか
--   `0113` で募集板を**ピタメイト専用**に作り直した。判断そのものは正しい
--   （無料で遊べる経路を board に作ると、いちばん使われる導線がその抜け道に
--   なる）が、副作用として**ゲストが「遊びたい」と言える場所が消えた。**
--
--   いまゲストにできるのは「開いている枠を探す」だけ。開いていなければ、
--   何も起きずに離脱する。ピタメイト側からは**その離脱がまったく見えない。**
--   需要と供給が、互いに見えないまますれ違っている。
--
-- ■ 設計の芯：**板には載せない**
--   リクエストは公開の掲示板ではない。条件に合うピタメイトへ**通知として**
--   届き、応じた人の分だけがリクエストした本人に見える。
--
--     ゲスト  「金曜21時ごろ・Apex・60分」でリクエストを出す
--       ↓ 通知（ゲームが一致するピタメイトへ）
--     ピタメイト  「21:00からなら空けられます」と応じる
--       ↓ 通知（リクエストした本人へ）
--     ゲスト  出てきた候補から**通常どおり予約する**（＝有償の入口を必ず通る）
--
--   板に載せてしまうと、そこが「無料で相手を募る場所」になり、0113 が閉じた
--   抜け道が形を変えて戻ってくる。**リクエストは予約の入口であって、
--   遊びの場ではない。**
--
-- ■ ★「応じる」で枠が開く仕組み（ここが実装のいちばんの勘所）
--   素直に作るなら「応じたら host_availability に足す」だが、
--   `host_availability` は**毎週くり返す**設定なので、1回のリクエストに
--   応じただけで「毎週金曜21時が空き枠」になってしまう。本人が頼んでいない
--   永続的な変更で、あとから消す導線も無い。
--
--   そこで**応じた行そのものを「開いている」根拠にする。**
--     `host_is_open_at` に「open のリクエストへの応答が、この時刻を覆っているか」
--     を足す。リクエストが成立/取消/期限切れになれば status が open でなくなり、
--     **開けた枠は自動的に閉じる。** 掃除の cron も、後始末の帳簿も要らない。
--
--   同じ理由で `slot_open_to`（0057 の常連先行）にも足す。ピタメイトが
--   その人に向けて明示的に応じたのに「常連ではない」で弾かれるのは、
--   本人の意思と矛盾する。**判定は 2 つとも既存の1か所に足す**——
--   写して増やすと必ずズレる（0115 で確認した方針）。
--
--   ⚠️ `host_is_open_at` は相手を取らないので、**応じて開いた時間は
--      ほかの人からも予約できる。** これは仕様。「応じる＝その時間を開ける」
--      であって「その人のために取り置く」ではない。画面でもそう書く。
--
-- ■ 開始時刻を「毎正時」に限る理由
--   `booking_fits_availability`(0051) は、予約が触る**時間の枡**を1つずつ見る。
--   21:30 開始・60分の予約は 21時台と22時台の両方を要求する。応じた行の範囲を
--   21:30〜22:30 のまま使うと、21時台が「開いていない」ことになって
--   **応じたのに予約できない**が起きる。毎正時に揃えれば枡と範囲が一致する。
--   （30分刻みの選択は、もともと枠に収まる範囲でしか意味を持たない）
--
-- ■ 通知を送る相手を、空き時間で絞らないこと
--   「範囲に空きがある人だけに送る」は一見親切だが、**それはゲストが探す画面
--   (0115)ですでに見つけられる人**である。リクエストは、その画面に出てこな
--   かったから出されている。絞ると意味が消える。
--   代わりに **登録ゲームの一致**で絞り、1件あたりの宛先に上限を置く。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 通知の種別を足す（既存を欠かさないこと）
-- ------------------------------------------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed', 'booking_requested',
    'booking_approved', 'gift_received', 'booking_extended',
    'board_cancelled', 'integrity_alert', 'booking_no_show',
    'host_slots_opened', 'system',
    -- 0120
    'guest_request_received',   -- ピタメイトへ：条件の合うリクエストが出た
    'guest_request_answered'));  -- ゲストへ：応じた人が出た

-- ------------------------------------------------------------
-- 2. リクエスト本体
-- ------------------------------------------------------------
create table if not exists public.guest_requests (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null references auth.users (id) on delete cascade,
  game text not null,
  -- **範囲は必須。** 板(0114)は「相談で」を許すが、こちらは
  -- 「いつ空ければいいのか」が伝わらないとピタメイトが動けない
  window_start timestamptz not null,
  window_end timestamptz not null,
  duration_minutes int not null default 60,
  note text not null default '',
  status text not null default 'open'
    check (status in ('open', 'matched', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  close_reason text,
  constraint guest_requests_window_ok check (window_end > window_start),
  constraint guest_requests_duration_ok check (public.is_valid_booking_duration(duration_minutes)),
  constraint guest_requests_game_len check (char_length(game) between 1 and 60),
  constraint guest_requests_note_len check (char_length(note) <= 300)
);

comment on table public.guest_requests is
  'ゲストが「この日時・このゲーム・この長さで遊びたい」と出すリクエスト(0120)。'
  '**板には載せない。**条件の合うピタメイトへ通知として届き、応じた人だけが本人に見える。'
  '成立は通常の予約(create_booking)を通る——無料で遊べる経路を作らないため(0113)。';

comment on column public.guest_requests.window_end is
  '受付の終わり。過ぎると expire_guest_requests が expired にし、'
  '応じて開いていた枠もその時点で閉じる(host_is_open_at が open しか見ないため)。';

alter table public.guest_requests enable row level security;

-- **自分の出したものしか見えない。** 一覧は関数(guest_requests_for_host)で配る。
-- 直接 select させると、条件に合わない人にも他人の予定が読めてしまう
create policy "guest_requests_select_own"
  on public.guest_requests for select
  to authenticated
  using (guest_id = auth.uid());

-- insert / update のポリシーは置かない。**RPC が唯一の入口**にする
-- （リードタイム・件数上限・同意の検査を画面の実装に依存させない）

create index if not exists guest_requests_open_idx
  on public.guest_requests (status, window_start) where status = 'open';
create index if not exists guest_requests_guest_idx
  on public.guest_requests (guest_id, created_at desc);

-- みまもりの同意を撤回した人はリクエストを出せない（0074 と揃える）
create or replace function public._guest_requests_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.guest_id, null);
  return new;
end;
$$;

revoke all on function public._guest_requests_require_consent() from public, anon;

drop trigger if exists guest_requests_require_consent on public.guest_requests;
create trigger guest_requests_require_consent
  before insert on public.guest_requests
  for each row execute function public._guest_requests_require_consent();

-- ------------------------------------------------------------
-- 3. 応じた記録
--
--    この行が「その時間が開いている」根拠そのものになる（冒頭参照）。
-- ------------------------------------------------------------
create table if not exists public.guest_request_responses (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.guest_requests (id) on delete cascade,
  host_id uuid not null references auth.users (id) on delete cascade,
  starts_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (request_id, host_id),
  -- 毎正時に揃える（冒頭「開始時刻を毎正時に限る理由」）。
  -- **date_trunc(timestamptz) は stable なので CHECK に書けない。**
  -- 一度 timestamp に落とせば immutable になる。日本時間の時差は
  -- ちょうど9時間なので、UTC で正時なら日本時間でも正時
  constraint guest_request_responses_on_the_hour
    check (starts_at = date_trunc('hour', starts_at at time zone 'UTC') at time zone 'UTC')
);

comment on table public.guest_request_responses is
  'リクエストに応じたピタメイトと、その開始時刻(0120)。'
  '**この行自体が「その時間を開けている」根拠**で、host_is_open_at と slot_open_to が見る。'
  'リクエストが open でなくなれば、開けた枠も同時に閉じる。';

alter table public.guest_request_responses enable row level security;

-- 応じた本人と、リクエストを出した本人だけが見える
create policy "guest_request_responses_select_involved"
  on public.guest_request_responses for select
  to authenticated
  using (
    host_id = auth.uid()
    or exists (
      select 1 from public.guest_requests q
      where q.id = guest_request_responses.request_id and q.guest_id = auth.uid()
    )
  );

create index if not exists guest_request_responses_host_idx
  on public.guest_request_responses (host_id, starts_at);

-- ------------------------------------------------------------
-- 4. 予約との紐づけ（0113 の from_board_post_id と同じ考え方）
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_guest_request_id uuid
    references public.guest_requests (id) on delete set null;

comment on column public.bookings.from_guest_request_id is
  'リクエストから成立した予約は、そのリクエストを指す(0120)。';

create index if not exists bookings_from_guest_request_idx
  on public.bookings (from_guest_request_id) where from_guest_request_id is not null;

-- ------------------------------------------------------------
-- 5. ★判定を既存の1か所に足す
-- ------------------------------------------------------------
/**
 * 応じた行が、その時刻を覆っているか。
 * host_is_open_at と slot_open_to の両方から呼ぶので、条件を1か所に書く。
 * **どちらか片方だけ直すとズレる。**
 */
create or replace function public._request_response_covers(
  p_host_id uuid,
  p_at timestamptz,
  p_guest_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.guest_request_responses r
    join public.guest_requests q on q.id = r.request_id
    where r.host_id = p_host_id
      -- **open だけ。** 成立/取消/期限切れになった時点で枠は閉じる
      and q.status = 'open'
      and (p_guest_id is null or q.guest_id = p_guest_id)
      and p_at >= r.starts_at
      and p_at < r.starts_at + make_interval(mins => q.duration_minutes)
  );
$$;

comment on function public._request_response_covers(uuid, timestamptz, uuid) is
  'リクエストに応じて開けた時間が、その時刻を覆っているか(0120)。'
  'p_guest_id を渡すと、その人が出したリクエストへの応答だけを見る。';

revoke all on function public._request_response_covers(uuid, timestamptz, uuid) from public, anon;

-- 0051 の本体に、応答ぶんを足すだけ。**シグネチャは変えない**
-- （booking_fits_availability・hosts_open_at・host_schedule がそのまま乗る）
create or replace function public.host_is_open_at(p_host_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not public.host_has_availability(p_host_id) then true
    else exists (
      select 1 from public.host_availability a
      where a.user_id = p_host_id
        and a.weekday = extract(dow from (p_at at time zone 'Asia/Tokyo'))::smallint
        and a.hour = extract(hour from (p_at at time zone 'Asia/Tokyo'))::smallint
    )
    -- 0120: リクエストに応じて開けた時間。**相手は問わない**
    -- （「応じる＝その時間を開ける」であって、取り置きではない）
    or public._request_response_covers(p_host_id, p_at)
  end;
$$;

comment on function public.host_is_open_at(uuid, timestamptz) is
  'その時刻が募集枠の中か。枠を設定していないピタメイトは常に受け付ける(true)。'
  '0120で「ゲストのリクエストに応じて開けた時間」も開いている扱いにした。';

revoke all on function public.host_is_open_at(uuid, timestamptz) from public, anon;
grant execute on function public.host_is_open_at(uuid, timestamptz) to authenticated;

-- 0057 の本体に、応答ぶんを足すだけ。こちらは**その人に向けた応答だけ**を見る
create or replace function public.slot_open_to(p_host_id uuid, p_guest_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_guest_id is null then false
    -- 0120: 本人のリクエストに応じているなら、先行予約の期間中でも通す。
    -- **ピタメイトが名指しで応じたのに常連判定で弾くのは、本人の意思と矛盾する**
    when public._request_response_covers(p_host_id, p_at, p_guest_id) then true
    -- 先行予約を使っていなければ従来どおり
    when coalesce((select h.regulars_first_hours from public.host_settings h
                   where h.user_id = p_host_id), 0) = 0 then true
    -- 開始が近づいたら誰でも取れる
    when p_at <= now() + make_interval(
           hours => (select h.regulars_first_hours from public.host_settings h
                     where h.user_id = p_host_id)) then true
    else public._played_together_count(p_host_id, p_guest_id) > 0
  end;
$$;

comment on function public.slot_open_to(uuid, uuid, timestamptz) is
  'その時刻の枠を、この人がいま予約できるか。先行予約の期間中は一緒に遊んだことのある人だけ true。'
  '0120で「本人のリクエストに応じた枠」を例外にした。';

revoke all on function public.slot_open_to(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.slot_open_to(uuid, uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 6. リクエストを出す
-- ------------------------------------------------------------
create or replace function public.create_guest_request(
  p_game text,
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_duration_minutes int default 60,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 同時に開けるリクエストの数。**上限が無いと、1人で全ピタメイトの通知を
  -- 埋められる。** 3件あれば「今夜」「週末」「来週」を並べるには足りる
  c_max_open constant int := 3;
  -- 1件あたりの宛先の上限。掲載人数が増えたときに、1回のリクエストが
  -- 全員へ届くのを避ける
  c_max_notify constant int := 50;
  -- 範囲の広さの上限。広すぎる範囲は「いつでもいい」と同じで、
  -- 応じた枠が長時間開きっぱなしになる
  c_max_span constant interval := interval '7 days';
  v_uid uuid := auth.uid();
  v_id uuid;
  v_game text;
  v_note text;
  v_min_lead int;
  v_max_lead int;
  v_open int;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  v_game := nullif(btrim(coalesce(p_game, '')), '');
  if v_game is null then
    raise exception 'GAME_REQUIRED';
  end if;
  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;
  if p_window_start is null or p_window_end is null then
    raise exception 'WINDOW_REQUIRED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;
  v_min_lead := coalesce(v_min_lead, 30);
  v_max_lead := coalesce(v_max_lead, 35);

  -- 予約が受け付けられない範囲でリクエストを出させない。
  -- **出せてしまうと、応じた側が予約されない枠を開けることになる**
  if p_window_start < now() + make_interval(mins => v_min_lead) then
    raise exception 'WINDOW_TOO_SOON';
  end if;
  if p_window_end > now() + make_interval(days => v_max_lead) then
    raise exception 'WINDOW_TOO_FAR';
  end if;
  if p_window_end - p_window_start < make_interval(mins => p_duration_minutes) then
    raise exception 'WINDOW_TOO_SHORT';
  end if;
  if p_window_end - p_window_start > c_max_span then
    raise exception 'WINDOW_TOO_WIDE';
  end if;

  select count(*) into v_open
  from public.guest_requests q
  where q.guest_id = v_uid and q.status = 'open';
  if v_open >= c_max_open then
    raise exception 'TOO_MANY_OPEN_REQUESTS';
  end if;

  v_note := left(btrim(coalesce(p_note, '')), 300);

  insert into public.guest_requests
    (guest_id, game, window_start, window_end, duration_minutes, note)
  values
    (v_uid, v_game, p_window_start, p_window_end, p_duration_minutes, v_note)
  returning id into v_id;

  select nickname into v_name from public.profiles where id = v_uid;

  -- ------------------------------------------------------------
  -- 宛先。**空き時間では絞らない**（冒頭参照）
  -- ------------------------------------------------------------
  insert into public.notifications (user_id, type, title, body, related_id)
  select
    h.user_id,
    'guest_request_received',
    coalesce(nullif(v_name, ''), 'ゲスト') || 'さんが' || v_game || 'を募集しています',
    to_char(p_window_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI')
      || '〜' || to_char(p_window_end at time zone 'Asia/Tokyo', 'MM/DD HH24:MI')
      || '・' || p_duration_minutes || '分',
    v_id
  from (
    select hs.user_id
    from public.host_settings hs
    join public.profile_trust_stats ts
      on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
    join public.profiles pr on pr.id = hs.user_id
    where hs.is_host
      and hs.hourly_rate is not null
      and hs.user_id <> v_uid
      and pr.withdrawn_at is null
      -- **登録しているゲームが一致すること。** ここを緩めると、
      -- 遊ばないゲームの通知が届き続けて通知そのものが読まれなくなる
      and v_game = any (hs.games)
      and not exists (
        select 1 from public.blocks b
        where (b.blocker_id = v_uid and b.blocked_id = hs.user_id)
           or (b.blocker_id = hs.user_id and b.blocked_id = v_uid)
      )
      -- 自分が非表示にした相手には送らない(0116)。
      -- **相手には何も伝わらない**——非表示であることが漏れない形
      and not exists (
        select 1 from public.hidden_hosts hh
        where hh.user_id = v_uid and hh.hidden_id = hs.user_id
      )
      -- みまもりの同意を撤回している人へは送らない(0074)。
      -- 送っても、応じた先の予約が止まる
      and not public._monitoring_consent_revoked(hs.user_id)
    order by hs.user_id
    limit c_max_notify
  ) h;

  return v_id;
end;
$$;

comment on function public.create_guest_request(text, timestamptz, timestamptz, int, text) is
  'ゲストのリクエストを出す(0120)。**板には載せず**、登録ゲームの一致するピタメイトへ通知だけを送る。'
  '同時に開けるのは3件まで、宛先は1件あたり50人まで。範囲は予約できる期間(min_lead/max_lead)の中に限る。';

revoke all on function public.create_guest_request(text, timestamptz, timestamptz, int, text) from public, anon;
grant execute on function public.create_guest_request(text, timestamptz, timestamptz, int, text) to authenticated;

-- ------------------------------------------------------------
-- 7. 応じる
-- ------------------------------------------------------------
create or replace function public.respond_to_guest_request(
  p_request_id uuid,
  p_starts_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 1件のリクエストに応じられる人数。**上限が無いと、成立するのは1人なのに
  -- 大勢が同じ時間を開けたまま待つことになる**
  c_max_responses constant int := 5;
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_is_host boolean;
  v_rate int;
  v_verified boolean;
  v_min_lead int;
  v_end timestamptz;
  v_count int;
  v_name text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.status <> 'open' then
    raise exception 'REQUEST_NOT_OPEN';
  end if;
  if v_req.guest_id = v_uid then
    raise exception 'CANNOT_ANSWER_OWN_REQUEST';
  end if;

  -- 応じられるのは、実際に予約を受けられる状態の人だけ。
  -- **create_booking が見ているのと同じ条件**（応じたのに予約できない、を作らない）
  select hs.is_host, hs.hourly_rate into v_is_host, v_rate
  from public.host_settings hs where hs.user_id = v_uid;
  if not coalesce(v_is_host, false) or v_rate is null then
    raise exception 'HOST_ONLY';
  end if;
  select ts.is_verified into v_verified
  from public.profile_trust_stats ts where ts.user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  -- みまもりの同意（双方）。撤回されていれば、そもそも予約が成立しない
  perform public._require_monitoring_consent(v_uid, v_req.guest_id);

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_req.guest_id)
       or (b.blocker_id = v_req.guest_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 毎正時に揃える（冒頭「開始時刻を毎正時に限る理由」）
  if p_starts_at is null then
    raise exception 'START_TIME_REQUIRED';
  end if;
  if p_starts_at <> date_trunc('hour', p_starts_at) then
    raise exception 'START_MUST_BE_ON_THE_HOUR';
  end if;

  v_end := p_starts_at + make_interval(mins => v_req.duration_minutes);
  if p_starts_at < v_req.window_start or v_end > v_req.window_end then
    raise exception 'OUTSIDE_REQUEST_WINDOW';
  end if;

  select min_lead_minutes into v_min_lead from public.platform_pricing where id = 1;
  if p_starts_at < now() + make_interval(mins => coalesce(v_min_lead, 30)) then
    raise exception 'START_TOO_SOON';
  end if;

  -- 先約と重なっていないこと。ピタメイト側・ゲスト側の両方を見る
  -- （出したのに申し込めない、を作らない）
  if public._booking_slot_conflict(v_uid, p_starts_at, v_req.duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(v_req.guest_id, p_starts_at, v_req.duration_minutes) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select count(*) into v_count
  from public.guest_request_responses r
  where r.request_id = p_request_id and r.host_id <> v_uid;
  if v_count >= c_max_responses then
    raise exception 'ENOUGH_RESPONSES';
  end if;

  -- 時刻の言い直しは許す（同じ人が2度目に応じたら上書き）
  insert into public.guest_request_responses (request_id, host_id, starts_at)
  values (p_request_id, v_uid, p_starts_at)
  on conflict (request_id, host_id) do update set starts_at = excluded.starts_at
  returning id into v_id;

  select nickname into v_name from public.profiles where id = v_uid;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_req.guest_id,
    'guest_request_answered',
    coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが応じました',
    v_req.game || '・'
      || to_char(p_starts_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI')
      || '〜・' || v_req.duration_minutes || '分',
    p_request_id
  );

  return v_id;
end;
$$;

comment on function public.respond_to_guest_request(uuid, timestamptz) is
  'ゲストのリクエストに応じる(0120)。開始時刻は毎正時で、リクエストの範囲に収まること。'
  '**この行自体がその時間の空き枠になる**(host_is_open_at/slot_open_to が見る)ので、'
  'create_booking と同じ条件(掲載・本人確認・先約・同意)をここでも見る。1件につき5人まで。';

revoke all on function public.respond_to_guest_request(uuid, timestamptz) from public, anon;
grant execute on function public.respond_to_guest_request(uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 8. 応じた人から予約する
--
--    `create_booking` をそのまま呼ぶ。**検証をここで作り直さない**（0113 と同じ）。
-- ------------------------------------------------------------
create or replace function public.create_booking_from_request(
  p_request_id uuid,
  p_host_id uuid,
  p_policy_version text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_res public.guest_request_responses;
  v_booking_id uuid;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.guest_id <> v_uid then
    raise exception 'NOT_MY_REQUEST';
  end if;
  if v_req.status <> 'open' then
    raise exception 'REQUEST_NOT_OPEN';
  end if;

  select * into v_res from public.guest_request_responses
  where request_id = p_request_id and host_id = p_host_id;
  if v_res.id is null then
    raise exception 'RESPONSE_NOT_FOUND';
  end if;

  -- ★**create_booking を先に通す。** ここで status を先に変えると、
  --   host_is_open_at が open のリクエストしか見ないので、
  --   自分で開けた枠を自分で閉じてから予約することになる
  v_booking_id := public.create_booking(
    p_host_id,
    v_req.duration_minutes,
    p_policy_version,
    v_res.starts_at
  );

  update public.bookings
    set from_guest_request_id = p_request_id
    where id = v_booking_id;

  update public.guest_requests
    set status = 'matched', closed_at = now()
    where id = p_request_id;

  -- 応じてくれた他の人に、決まったことを知らせる。
  -- **開けていた枠は同時に閉じている**ので、そのことも書く
  for v_other in
    select r.host_id from public.guest_request_responses r
    where r.request_id = p_request_id and r.host_id <> p_host_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストは他の方で決まりました',
      v_req.game || '・応じていただいた時間の枠は閉じました。ありがとうございました',
      p_request_id
    );
  end loop;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_request(uuid, uuid, text) is
  'リクエストに応じた相手を予約する(0120)。create_booking をそのまま呼ぶ(検証は向こうに集約)。'
  '**予約が通ってからリクエストを matched にする**——先に閉じると、応じて開いた枠が消えて予約できない。';

revoke all on function public.create_booking_from_request(uuid, uuid, text) from public, anon;
grant execute on function public.create_booking_from_request(uuid, uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 9. 取り下げる
-- ------------------------------------------------------------
create or replace function public.cancel_guest_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.guest_id <> v_uid then
    raise exception 'NOT_MY_REQUEST';
  end if;
  if v_req.status <> 'open' then
    return; -- 二重取り下げは何もしない(連打対策)
  end if;

  update public.guest_requests
    set status = 'cancelled', closed_at = now()
    where id = p_request_id;

  -- 応じてくれた人には必ず知らせる。**枠を開けて待っている人がいる**
  for v_other in
    select r.host_id from public.guest_request_responses r where r.request_id = p_request_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストが取り下げられました',
      v_req.game || '・応じていただいた時間の枠は閉じました',
      p_request_id
    );
  end loop;
end;
$$;

comment on function public.cancel_guest_request(uuid) is
  '自分のリクエストを取り下げる(0120)。応じてくれた人に通知する(枠を開けて待っているため)。';

revoke all on function public.cancel_guest_request(uuid) from public, anon;
grant execute on function public.cancel_guest_request(uuid) to authenticated;

-- ------------------------------------------------------------
-- 10. 期限切れ
--
--     **開けた枠が閉じるのはここではなく status の側。**
--     行を消さないので、あとから「何件出て何件応じられたか」を読める
-- ------------------------------------------------------------
create or replace function public.expire_guest_requests()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ⚠️ ループの中で `get diagnostics ... row_count` を使わないこと。
  --    最後に走った文（通知の insert）の件数を拾ってしまい、
  --    「0件処理して2を返す」ような値になる
  v_n int := 0;
  v_row record;
begin
  for v_row in
    select q.id, q.guest_id, q.game,
           (select count(*) from public.guest_request_responses r where r.request_id = q.id) as answers
    from public.guest_requests q
    where q.status = 'open' and q.window_end <= now()
    for update
  loop
    update public.guest_requests
      set status = 'expired', closed_at = now()
      where id = v_row.id;

    -- **誰も応じなかったときだけ知らせる。** 応じた人がいたのに予約しなかった
    -- のは本人の選択なので、そこへ追い打ちの通知は出さない
    if v_row.answers = 0 then
      insert into public.notifications (user_id, type, title, body, related_id)
      values (
        v_row.guest_id,
        'system',
        'リクエストの受付が終わりました',
        v_row.game || '・応じた方はいませんでした。日時やゲームを変えて、もう一度出せます',
        v_row.id
      );
    end if;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

comment on function public.expire_guest_requests() is
  '受付の終わったリクエストを expired にする(0120)。'
  '応じて開いていた枠も同時に閉じる(host_is_open_at が open しか見ないため)。'
  '誰も応じなかった場合だけ、出した本人に知らせる。';

revoke all on function public.expire_guest_requests() from public, anon, authenticated;

select cron.unschedule('expire-guest-requests')
  where exists (select 1 from cron.job where jobname = 'expire-guest-requests');

-- 15分おき。0114 の close-expired-board-posts と揃える
select cron.schedule('expire-guest-requests', '*/15 * * * *',
  $cron$select public.expire_guest_requests();$cron$);

-- ------------------------------------------------------------
-- 11. 読み出し
-- ------------------------------------------------------------
/** 自分が出したリクエスト（応じた人数つき）。 */
create or replace function public.my_guest_requests(p_limit int default 20)
returns table (
  id uuid,
  game text,
  window_start timestamptz,
  window_end timestamptz,
  duration_minutes int,
  note text,
  status text,
  responses int,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    q.id, q.game, q.window_start, q.window_end, q.duration_minutes,
    q.note, q.status,
    (select count(*)::int from public.guest_request_responses r where r.request_id = q.id),
    q.created_at
  from public.guest_requests q
  where q.guest_id = auth.uid()
  order by (q.status = 'open') desc, q.created_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

comment on function public.my_guest_requests(int) is '自分が出したリクエストの一覧(0120)。open を先に並べる。';

revoke all on function public.my_guest_requests(int) from public, anon;
grant execute on function public.my_guest_requests(int) to authenticated;

/**
 * 自分のリクエストに応じた人。
 * **料金は host_settings から都度読む**(0113 と同じ理由——写すと古い額を出す)。
 */
create or replace function public.guest_request_answers(p_request_id uuid)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  starts_at timestamptz,
  answered_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.host_id,
         p.nickname,
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         hs.hourly_rate, r.starts_at, r.created_at
  from public.guest_request_responses r
  join public.guest_requests q on q.id = r.request_id
  left join public.profiles p on p.id = r.host_id
  left join public.host_settings hs on hs.user_id = r.host_id
  where r.request_id = p_request_id
    and q.guest_id = auth.uid()
  order by r.starts_at;
$$;

comment on function public.guest_request_answers(uuid) is
  '自分のリクエストに応じたピタメイトの一覧(0120)。料金は host_settings から都度読む。';

revoke all on function public.guest_request_answers(uuid) from public, anon;
grant execute on function public.guest_request_answers(uuid) to authenticated;

/**
 * 自分（ピタメイト）に届いているリクエスト。
 * **通知と同じ条件で絞る。** 通知は届いたのに一覧に出ない、を作らない。
 */
create or replace function public.guest_requests_for_host(p_limit int default 30)
returns table (
  id uuid,
  guest_id uuid,
  guest_nickname text,
  guest_avatar_initial text,
  guest_avatar_color text,
  game text,
  window_start timestamptz,
  window_end timestamptz,
  duration_minutes int,
  note text,
  answered boolean,
  my_starts_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    q.id, q.guest_id, p.nickname,
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    q.game,
    q.window_start, q.window_end, q.duration_minutes, q.note,
    (r.id is not null), r.starts_at, q.created_at
  from public.guest_requests q
  join public.profiles p on p.id = q.guest_id
  left join public.guest_request_responses r
    on r.request_id = q.id and r.host_id = auth.uid()
  where q.status = 'open'
    and q.window_end > now()
    and q.guest_id <> auth.uid()
    and exists (
      select 1 from public.host_settings hs
      join public.profile_trust_stats ts
        on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
      where hs.user_id = auth.uid()
        and hs.is_host
        and hs.hourly_rate is not null
        and q.game = any (hs.games)
    )
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = q.guest_id)
         or (b.blocker_id = q.guest_id and b.blocked_id = auth.uid())
    )
    and not exists (
      select 1 from public.hidden_hosts hh
      where hh.user_id = q.guest_id and hh.hidden_id = auth.uid()
    )
  order by q.window_start
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

comment on function public.guest_requests_for_host(int) is
  '自分(ピタメイト)に届いているリクエストの一覧(0120)。通知と同じ条件で絞る。'
  '登録ゲームが一致しないと1件も返らない——ピタメイト設定でゲームを登録してもらう前提。';

revoke all on function public.guest_requests_for_host(int) from public, anon;
grant execute on function public.guest_requests_for_host(int) to authenticated;

-- ------------------------------------------------------------
-- 12. 運営コンソールから見る・下ろす
--     （運営作業は SQL Editor ではなくコンソールから行う方針）
-- ------------------------------------------------------------
create or replace function public.admin_guest_requests(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  guest_id uuid,
  guest_nickname text,
  game text,
  window_start timestamptz,
  window_end timestamptz,
  duration_minutes int,
  note text,
  status text,
  responses int,
  bookings int,
  created_at timestamptz,
  closed_at timestamptz,
  close_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    q.id, q.guest_id, p.nickname, q.game,
    q.window_start, q.window_end, q.duration_minutes, q.note, q.status,
    (select count(*)::int from public.guest_request_responses r where r.request_id = q.id),
    (select count(*)::int from public.bookings b where b.from_guest_request_id = q.id),
    q.created_at, q.closed_at, q.close_reason
  from public.guest_requests q
  left join public.profiles p on p.id = q.guest_id
  where public._is_admin()
    and (p_status = 'all' or q.status = p_status)
  order by q.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_guest_requests(text, int) is
  'ゲストのリクエスト一覧(運営・0120)。p_status に ''all'' で全件。';

revoke all on function public.admin_guest_requests(text, int) from public, anon;
grant execute on function public.admin_guest_requests(text, int) to authenticated;

create or replace function public.admin_remove_guest_request(
  p_request_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_reason text;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須**（0112 と同じ。記録の要らない削除は、あとから説明できない）
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.status <> 'open' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.guest_requests
    set status = 'cancelled',
        closed_at = now(),
        close_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_request_id;

  -- 出した本人には**理由つき**（規約 第10条の2 6項）
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_req.guest_id,
    'system',
    'リクエストを取り下げました',
    v_req.game || '（理由：' || v_reason || '）',
    p_request_id
  );

  -- 応じた人には**理由なし**（運営の判断の内容を第三者に配らない）
  for v_other in
    select r.host_id from public.guest_request_responses r where r.request_id = p_request_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストが取り下げられました',
      v_req.game || '・応じていただいた時間の枠は閉じました',
      p_request_id
    );
  end loop;

  perform public._log_admin_action('guest_request_removed', p_request_id, v_reason);
end;
$$;

comment on function public.admin_remove_guest_request(uuid, text) is
  'ゲストのリクエストを運営が取り下げる(0120)。行は消さず cancelled にし、理由を close_reason に残す。'
  '理由は必須。本人には理由つき、応じた人には理由なしで通知し、admin_actions に記録する。';

revoke all on function public.admin_remove_guest_request(uuid, text) from public, anon;
grant execute on function public.admin_remove_guest_request(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 13. プッシュの扱い
--
--     `guest_request_received` は**多数へ一斉に飛ぶ**唯一の種別。
--     静かにする時間を設定している人は、そこで止めてよい種類に入れる。
--     `guest_request_answered` は自分が出したものへの返事なので止めない。
-- ------------------------------------------------------------
create or replace function public._push_is_casual(p_type text)
returns boolean
language sql
immutable
as $$
  select p_type in (
    'host_slots_opened',  -- 0054。もともと24時間に1回に絞ってある
    'gift_received',
    'board_joined',
    'board_cancelled',
    'booking_completed',
    'guest_request_received'  -- 0120。一斉に飛ぶので静かな時間では止める
  );
$$;

revoke all on function public._push_is_casual(text) from public, anon;
