-- ============================================================
-- 0124: リクエストの応答枠を、はじめたばかりの人に少し残す
--
-- ■ 何が起きていたか
--   0120 のリクエストは、**始めたばかりの人にも平等に届く唯一の経路**
--   （さがすの一覧は実績順なので下に沈む）。ところが応じられるのは
--   1件につき5人まで（`c_max_responses`）で、**先に押した人から埋まる**。
--
--   通知は全員に同時に飛ぶので、気づく速さの勝負になる。実績のある人は
--   すでに予約が入っていて通知をよく見ているぶん有利で、
--   **新人は「唯一平等な経路」でも席が取れない。**
--
-- ■ 直し方：5枠のうち2つを、30分だけ取っておく
--
--   | | 直す前 | 直したあと |
--   |---|---|---|
--   | 実績のある人 | 5枠まで先着 | 最初の30分は3枠まで |
--   | 実績ゼロの人 | 5枠まで先着 | いつでも5枠まで |
--   | 30分経過後 | — | 誰でも5枠まで（取り置きは消える） |
--
--   **通知も応答も遅らせない。** 実績のある人もすぐ応じられる（3枠まで）。
--   ゲストが待たされるのは「最初の30分に実績のある人が4人以上応じたい
--   ケース」だけで、そのときも30分後には5枠まで埋まる。
--
--   ⚠️ 「実績ゼロ」の判定は `platform_fees`(kind='booking') が
--      1件も無いこと——**0122 と同じ基準**。役務の対価を一度も
--      受け取っていない人だけが対象で、返金や没収では資格を失わない。
--
--   ⚠️ 上限の規則は `_request_response_block` に**1か所だけ**置く。
--      応じる側（respond_to_guest_request）と一覧（guest_requests_for_host）の
--      両方が同じ関数を呼ぶ。数え方を2か所に書くと必ずずれて、
--      「押せるのに断られる」が起きる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 上限と取り置きの判定（**唯一の置き場所**）
-- ------------------------------------------------------------
create or replace function public._request_response_block(
  p_request_id uuid,
  p_host_id uuid
) returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  -- 1件のリクエストに応じられる人数。**上限が無いと、成立するのは1人なのに
  -- 大勢が同じ時間を開けたまま待つことになる**（0120）
  c_max constant int := 5;
  -- そのうち、まだ実績のない人のために取っておく数
  c_reserved constant int := 2;
  -- 取り置きが効いている時間。過ぎたら誰でも埋められる
  c_window constant interval := interval '30 minutes';
  v_created timestamptz;
  v_count int;
  v_is_new boolean;
begin
  select created_at into v_created
  from public.guest_requests where id = p_request_id;
  -- 無いリクエストのことは、ここでは判断しない（呼ぶ側が先に見ている）
  if v_created is null then
    return null;
  end if;

  -- すでに応じている人は、いつでも時刻を言い直せる。
  -- **上限で弾かない**——席はもう取っているので、数え直す話ではない。
  -- これが無いと、実績のある人が応じたあと他に3人集まった時点で
  -- **自分の時刻を直せなくなる**（画面には「時刻を変える」が出ているのに）
  if exists (
    select 1 from public.guest_request_responses
    where request_id = p_request_id and host_id = p_host_id
  ) then
    return null;
  end if;

  -- **自分の分は数えない。** 時刻の言い直し（2度目に応じる）を
  -- 上限で弾いてしまわないため（0120 の on conflict do update）
  select count(*) into v_count
  from public.guest_request_responses r
  where r.request_id = p_request_id and r.host_id <> p_host_id;

  if v_count >= c_max then
    return 'enough';
  end if;

  -- 実績ゼロ＝役務の対価を一度も受け取っていない（0122 と同じ基準）。
  -- 全額返金や無断欠席の没収では明細が作られないので、資格を失わない
  v_is_new := not exists (
    select 1 from public.platform_fees pf
    where pf.host_id = p_host_id and pf.kind = 'booking'
  );

  if not v_is_new
     and v_created > now() - c_window
     and v_count >= c_max - c_reserved
  then
    return 'reserved_for_new';
  end if;

  return null;
end;
$$;

comment on function public._request_response_block(uuid, uuid) is
  '0124: そのピタメイトが今このリクエストに応じられるか。'
  'null=応じられる / enough=5人埋まった / reserved_for_new=残りは新人用に取り置き中。'
  '**上限の規則はここだけに置く。**応じる側と一覧の両方がこれを呼ぶ。';

revoke all on function public._request_response_block(uuid, uuid) from public, anon;
grant execute on function public._request_response_block(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. 応じる側
--
-- ⚠️ 本体は 0120 のものをそのまま使い、上限を見ている部分だけ差し替え。
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
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_is_host boolean;
  v_rate int;
  v_verified boolean;
  v_min_lead int;
  v_end timestamptz;
  -- 0124: 上限と取り置きの判定は _request_response_block が持つ
  v_block text;
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

  -- 0124: 上限と「新人のための取り置き」。**ここで数え直さない**——
  -- 規則が2か所に分かれると必ずずれて、「一覧では押せるのに断られる」が起きる
  v_block := public._request_response_block(p_request_id, v_uid);
  if v_block = 'enough' then
    raise exception 'ENOUGH_RESPONSES';
  elsif v_block = 'reserved_for_new' then
    raise exception 'RESERVED_FOR_NEW_HOSTS';
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
  'create_booking と同じ条件(掲載・本人確認・先約・同意)をここでも見る。'
  '1件につき5人まで。0124で、最初の30分は2枠を実績ゼロの人のために取り置く。';

revoke all on function public.respond_to_guest_request(uuid, timestamptz) from public, anon;
grant execute on function public.respond_to_guest_request(uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 3. 届いているリクエストの一覧に「応じられるか」を足す
--
-- ⚠️ これが無いと、取り置きに当たった人は**押してから断られる**。
--    返す列が増えるので drop してから作り直す（create or replace では
--    RETURNS TABLE を変えられない）。
-- ------------------------------------------------------------
drop function if exists public.guest_requests_for_host(int);

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
  created_at timestamptz,
  -- 0124: 今この人が応じられるか。null=応じられる /
  -- 'enough'=5人埋まった / 'reserved_for_new'=残りは新人用に取り置き中。
  -- **画面で数え直さないために返す。** これが無いと、押してから断られる
  cannot_respond text
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
    (r.id is not null), r.starts_at, q.created_at,
    public._request_response_block(q.id, auth.uid())
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
  '登録ゲームが一致しないと1件も返らない——ピタメイト設定でゲームを登録してもらう前提。'
  '0124で cannot_respond を追加(押してから断られるのを防ぐ)。';

revoke all on function public.guest_requests_for_host(int) from public, anon;
grant execute on function public.guest_requests_for_host(int) to authenticated;
