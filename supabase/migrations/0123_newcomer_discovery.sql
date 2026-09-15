-- ============================================================
-- 0123: 新しいピタメイトが見つけてもらえるようにする
--
-- 「予約が入らないから評価がつかず、評価がつかないから表示されない」
-- という輪を切るための3点。割引は使わない。
--
-- ------------------------------------------------------------
-- ① さがすの並びが、同点帯の中で**永久に固定**されていた
--
--   `public_host_cards` の並びはこうだった:
--
--     order by repeat_score desc, manner_score desc, review_count desc,
--              user_id                              -- ← ここ
--
--   新しいピタメイトは実績が無いので、
--     repeat_score = 0.2500（`host_repeat_stats` の事前分布そのまま）
--     manner_score = 4.50（既定値）
--     review_count = 0
--   まで全員が同じ値になる。**最後の決め手が UUID。**
--   UUID は変わらないので、一度沈んだ人は何をしても浮きません。
--   表示は24人まで。上位が埋まっていれば1ページ目に一度も出ません。
--
--   直し方は「同点のときだけ、日替わりで順番を回す」。
--   **実績のある順序には一切触れない。** もともと意味のない UUID 順
--   だったところを、意味のない日替わり順に置き換えるだけです。
--   「おすすめ順」と称して特定の人を上げるのとは別物——順位の根拠を
--   偽っていないので、ゲストに対して嘘になりません。
--
--   ⚠️ **並び順は2か所にある。** SQL の `public_host_cards`（未ログイン用）と
--      `src/lib/queries.ts` の `fetchDiscoverableHosts`（ログイン後）で、
--      queries.ts 側に「同じ式・同じ並びにすること」と注記がある。
--      式を両方に書くと必ずずれるので、**並べ替えの鍵をサーバで1回だけ
--      作って、両方がそれを読む**形にしました（`host_discovery_shuffle`）。
--
-- ------------------------------------------------------------
-- ② 「今週はじめた人」を出す場所が無かった
--
--   ①は同点帯の中を回すだけなので、実績のある人が増えるほど新人は
--   下に押し出されます。順位と関係なく見てもらえる場所を別に作ります。
--
--   `host_settings` に「いつピタメイトになったか」が無かったので足します。
--   ⚠️ **一度ついた日付は動かしません。** is_host を切って入れ直すと
--      新人枠に戻れる、という使い回しを塞ぐためです（本人の更新でも
--      書き換えられないよう、トリガで上書きします）。
--
--   枠が1つも無い人は出しません。押しても予約できない相手を
--   推す場所に並べると、ゲストのタップを捨てることになります。
--
-- ------------------------------------------------------------
-- ③ 枠を開けた通知（0054）が、お気に入り登録者にしか飛ばなかった
--
--   新しいピタメイトのお気に入りは0人。**いちばん必要な人に届きません。**
--   「プロフィールを見たけれど予約しなかった人」にも送れるようにします。
--
--   ⚠️ **既定では送りません。** 閲覧はこちらが勝手に記録したものなので、
--      通知設定の「おすすめマッチ」(`notify_recommendations`、既定 off)を
--      本人が on にしたときだけ使います。
--      記録する範囲も絞りました:
--        ・掲載中のピタメイトを見たときだけ（一般のプロフィールは残さない）
--        ・1組につき1行だけ（履歴ではなく「最後に見た日」）
--        ・30日で自動的に消える
--        ・**ホストからは絶対に読めない**（誰が見たかは 0053 の方針どおり渡さない）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 並べ替えの鍵（日替わり・サーバで1回だけ作る）
-- ------------------------------------------------------------
create or replace function public.host_discovery_shuffle(p_host_ids uuid[])
returns table (host_id uuid, shuffle_key text)
language sql stable security definer set search_path = public
as $$
  -- 日付は日本時間で切る。UTC で切ると日本の夜中に並びが変わる
  select h.id,
         md5(h.id::text || (now() at time zone 'Asia/Tokyo')::date::text)
  from unnest(coalesce(p_host_ids, '{}'::uuid[])) as h(id);
$$;

comment on function public.host_discovery_shuffle(uuid[]) is
  '0123: 同点だったときの並び順を日替わりにする鍵。'
  '実績の順序には関与しない(最後の決め手だった UUID 順を置き換えるだけ)。'
  '画面側(queries.ts)も同じ鍵を読むこと。式を写すと必ずずれる。';

-- 未ログインには開けない。未ログインの一覧は `public_host_cards` の中で
-- 並べ終えて返るので、外から鍵を引く必要が無い(呼ぶのはログイン後の
-- `fetchDiscoverableHosts` だけ)。**要らない口は開けない。**
revoke all on function public.host_discovery_shuffle(uuid[]) from public, anon;
grant execute on function public.host_discovery_shuffle(uuid[]) to authenticated;

-- ------------------------------------------------------------
-- 2. さがすの並びに、その鍵を入れる
--
-- ⚠️ 本体は**適用済みのDBから取り出したもの**をそのまま使い、
--    order by の最後の1行だけ差し替えています。記憶で書き直すと
--    0119/0121/0122 と同じで規則が落ちます。
-- ------------------------------------------------------------
create or replace function public.public_host_cards(p_limit integer default 24)
returns table (
  host_id uuid, nickname text, avatar_initial text, avatar_color text,
  avatar_path text, hourly_rate integer, games text[], bio text,
  manner_score numeric, review_count integer, is_verified boolean,
  status_text text, status_updated_at timestamp with time zone,
  repeat_guests integer)
language sql stable security definer set search_path = public
as $$
  with listed as (
    select h.user_id, h.hourly_rate, h.games, h.bio, h.status_text, h.status_updated_at,
           p.nickname, p.avatar_initial, p.avatar_color, p.avatar_path,
           ts.manner_score, ts.review_count, ts.is_verified
    from public.host_settings h
    join public.profiles p on p.id = h.user_id
    left join public.profile_trust_stats ts on ts.user_id = h.user_id
    left join public.safety_prefs sp on sp.user_id = h.user_id
    where h.is_host = true
      and coalesce(ts.is_verified, false) = true
      and coalesce(sp.discoverable, true) = true
  ),
  scored as (
    select l.*, r.repeat_guests, r.repeat_score, sh.shuffle_key
    from listed l
    join public.host_repeat_stats(array(select user_id from listed)) r on r.host_id = l.user_id
    -- 0123: 同点だったときの並びを日替わりにする
    join public.host_discovery_shuffle(array(select user_id from listed)) sh
      on sh.host_id = l.user_id
  )
  select s.user_id,
         coalesce(nullif(s.nickname, ''), '(名前未設定)'),
         coalesce(nullif(s.avatar_initial, ''), left(coalesce(nullif(s.nickname, ''), '?'), 1)),
         coalesce(nullif(s.avatar_color, ''), '#B3E5F2'),
         s.avatar_path,
         s.hourly_rate,
         s.games,
         s.bio,
         coalesce(s.manner_score, 4.50),
         coalesce(s.review_count, 0),
         coalesce(s.is_verified, false),
         public.fresh_host_status(s.status_text, s.status_updated_at),
         case when public.fresh_host_status(s.status_text, s.status_updated_at) is null
              then null else s.status_updated_at end,
         s.repeat_guests
  from scored s
  order by s.repeat_score desc,
           coalesce(s.manner_score, 4.50) desc,
           coalesce(s.review_count, 0) desc,
           s.shuffle_key            -- 0123: ここが UUID 順だった
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(integer) is
  '未ログインでも見える掲載カード(0052)。0060でリピート実績順。'
  '0123で、同点だったときの最後の決め手を UUID から日替わりの鍵に変えた'
  '(UUID順は一度沈んだ人が永久に浮かべない)。';

revoke all on function public.public_host_cards(integer) from public;
grant execute on function public.public_host_cards(integer) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. 「いつピタメイトになったか」
-- ------------------------------------------------------------
alter table public.host_settings
  add column if not exists host_since timestamptz;

comment on column public.host_settings.host_since is
  '0123: ピタメイトになった日。新人枠の対象を決めるのに使う。'
  '**一度ついたら動かない**(is_host を切って入れ直しても戻らない)。';

-- 既にいる人の埋め戻し。登録日を使う——ピタメイトになった日そのものは
-- 記録が無いので、**さかのぼって作れる中でいちばん妥当な近似**。
-- 既存の人が新人枠に出ないほうに倒れるが、それは正しい側の誤差。
update public.host_settings h
   set host_since = coalesce(p.created_at, now())
  from public.profiles p
 where p.id = h.user_id
   and h.is_host
   and h.host_since is null;

-- ⚠️ 埋め戻しの**あと**にトリガを作ること
create or replace function public._stamp_host_since()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- 引数で渡された値は採用しない。**入口で必ず作り直す**
    new.host_since := case when new.is_host then now() else null end;
  elsif old.host_since is not null then
    -- 一度ついた日付は、本人の更新でも動かさない。
    -- 動かせると「is_host を切って入れ直して新人枠に戻る」ができてしまう
    new.host_since := old.host_since;
  elsif new.is_host then
    new.host_since := now();
  else
    new.host_since := null;
  end if;
  return new;
end;
$$;

drop trigger if exists host_settings_stamp_host_since on public.host_settings;
create trigger host_settings_stamp_host_since
  before insert or update on public.host_settings
  for each row execute function public._stamp_host_since();

revoke all on function public._stamp_host_since() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. 「はじめたばかりの人」の一覧
--
-- 順位と関係なく見てもらえる場所。`public_host_cards` と同じ見え方を
-- 返すので、画面側は同じカードをそのまま使える。
-- ------------------------------------------------------------
create or replace function public.new_host_cards(
  p_limit integer default 12,
  p_days integer default 14
) returns table (
  host_id uuid, nickname text, avatar_initial text, avatar_color text,
  avatar_path text, hourly_rate integer, games text[], bio text,
  manner_score numeric, review_count integer, is_verified boolean,
  status_text text, status_updated_at timestamp with time zone,
  repeat_guests integer, host_since timestamptz)
language sql stable security definer set search_path = public
as $$
  with listed as (
    select h.user_id, h.hourly_rate, h.games, h.bio, h.status_text, h.status_updated_at,
           h.host_since,
           p.nickname, p.avatar_initial, p.avatar_color, p.avatar_path,
           ts.manner_score, ts.review_count, ts.is_verified
    from public.host_settings h
    join public.profiles p on p.id = h.user_id
    left join public.profile_trust_stats ts on ts.user_id = h.user_id
    left join public.safety_prefs sp on sp.user_id = h.user_id
    where h.is_host = true
      -- 掲載の条件は `public_host_cards` と同じ。**ここだけ緩めない**
      and coalesce(ts.is_verified, false) = true
      and coalesce(sp.discoverable, true) = true
      and h.host_since is not null
      and h.host_since > now() - make_interval(days => greatest(1, least(coalesce(p_days, 14), 60)))
      -- 枠が1つも無い人は出さない。押しても予約できない相手を推す場所に
      -- 並べると、ゲストのタップを捨てることになる
      and exists (select 1 from public.host_availability a where a.user_id = h.user_id)
  )
  select l.user_id,
         coalesce(nullif(l.nickname, ''), '(名前未設定)'),
         coalesce(nullif(l.avatar_initial, ''), left(coalesce(nullif(l.nickname, ''), '?'), 1)),
         coalesce(nullif(l.avatar_color, ''), '#B3E5F2'),
         l.avatar_path,
         l.hourly_rate,
         l.games,
         l.bio,
         coalesce(l.manner_score, 4.50),
         coalesce(l.review_count, 0),
         coalesce(l.is_verified, false),
         public.fresh_host_status(l.status_text, l.status_updated_at),
         case when public.fresh_host_status(l.status_text, l.status_updated_at) is null
              then null else l.status_updated_at end,
         0,
         l.host_since
  from listed l
  join public.host_discovery_shuffle(array(select user_id from listed)) sh
    on sh.host_id = l.user_id
  -- **新しい順にしない。** 新しい順だと、その週にたくさん登録した日の人が
  -- ずっと先頭を占める。窓の中はどの人も等しく「はじめたばかり」なので回す
  order by sh.shuffle_key
  limit greatest(1, least(coalesce(p_limit, 12), 30));
$$;

comment on function public.new_host_cards(integer, integer) is
  '0123: はじめたばかりのピタメイト。実績順とは別枠で見てもらうための一覧。'
  '掲載条件は public_host_cards と同じ。枠が無い人は出さない。';

revoke all on function public.new_host_cards(integer, integer) from public;
grant execute on function public.new_host_cards(integer, integer) to anon, authenticated;

-- ------------------------------------------------------------
-- 5. 「見たけれど予約しなかった」の記録
--
-- ⚠️ 残す情報を最小限にしてある。履歴ではなく「最後に見た日」1行だけ。
-- ------------------------------------------------------------
create table if not exists public.profile_views (
  viewer_id uuid not null references auth.users(id) on delete cascade,
  host_id   uuid not null references auth.users(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (viewer_id, host_id)
);

comment on table public.profile_views is
  '0123: 掲載中のピタメイトのプロフィールを最後に見た日。'
  '枠が開いたときの通知(0054)を、お気に入り以外にも届けるためだけに使う。'
  '**ホストからは読めない**(誰が見ているかは 0053 の方針どおり渡さない)。'
  '1組1行・30日で自動的に消える。';

create index if not exists profile_views_host_idx
  on public.profile_views (host_id, viewed_at desc);

alter table public.profile_views enable row level security;

-- 読めるのも消せるのも**本人の分だけ**。ホスト向けのポリシーは作らない
drop policy if exists profile_views_own_select on public.profile_views;
create policy profile_views_own_select on public.profile_views
  for select to authenticated using (viewer_id = auth.uid());

drop policy if exists profile_views_own_delete on public.profile_views;
create policy profile_views_own_delete on public.profile_views
  for delete to authenticated using (viewer_id = auth.uid());

-- 書き込みは RPC からだけ(insert/update のポリシーを作らない)
revoke all on table public.profile_views from public, anon, authenticated;
grant select, delete on table public.profile_views to authenticated;

create or replace function public.record_profile_view(p_host_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  -- 未ログイン・自分自身は記録しない。**黙って何もしない**——
  -- ここで例外を投げると、プロフィールが開けないという形で出てしまう
  if v_uid is null or p_host_id is null or p_host_id = v_uid then
    return;
  end if;

  -- 掲載中のピタメイトを見たときだけ。一般のプロフィールまで残す必要が無く、
  -- 残すほど、漏れたときに困る情報が増える
  if not exists (
    select 1 from public.host_settings h where h.user_id = p_host_id and h.is_host
  ) then
    return;
  end if;

  insert into public.profile_views (viewer_id, host_id, viewed_at)
  values (v_uid, p_host_id, now())
  on conflict (viewer_id, host_id) do update set viewed_at = excluded.viewed_at;

  -- 古い分は自分の行だけ掃除する。cron を待たずに上限が効く
  delete from public.profile_views
   where viewer_id = v_uid and viewed_at < now() - interval '30 days';
end;
$$;

comment on function public.record_profile_view(uuid) is
  '0123: 掲載中のピタメイトを見たことを記録する(1組1行・30日)。'
  '失敗しても画面を止めないよう、対象外なら黙って何もしない。';

revoke all on function public.record_profile_view(uuid) from public, anon;
grant execute on function public.record_profile_view(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. 枠を開けた通知を、見ていた人にも届ける
--
-- ⚠️ 本体は 0054 のものをそのまま使い、宛先の select だけ差し替えています。
-- ------------------------------------------------------------
create or replace function public.set_host_availability(p_slots jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cooldown constant interval := interval '24 hours';
  -- 0123: 「前に見た」をどこまで遡って通知に使うか
  c_view_window constant interval := interval '14 days';
  v_uid uuid := auth.uid();
  v_count int;
  v_added int;
  v_sample text;
  v_name text;
  v_last timestamptz;
  v_is_host boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if jsonb_typeof(coalesce(p_slots, '[]'::jsonb)) <> 'array' then
    raise exception 'INVALID_SLOTS';
  end if;

  -- 新しく指定された枠を一時表に取る(重複と範囲外はここで落とす)
  create temporary table if not exists _new_slots (weekday smallint, hour smallint) on commit drop;
  delete from _new_slots;
  insert into _new_slots (weekday, hour)
  select distinct (s->>'weekday')::smallint, (s->>'hour')::smallint
  from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) s
  where (s->>'weekday')::int between 0 and 6
    and (s->>'hour')::int between 0 and 23;

  -- **入れ替える前に**「増えた枠」を数える。減った枠は対象にしない。
  select count(*),
         string_agg(
           case n.weekday when 0 then '日' when 1 then '月' when 2 then '火' when 3 then '水'
                          when 4 then '木' when 5 then '金' else '土' end
           || n.hour || '時', '・' order by n.weekday, n.hour)
    into v_added, v_sample
  from _new_slots n
  where not exists (
    select 1 from public.host_availability a
    where a.user_id = v_uid and a.weekday = n.weekday and a.hour = n.hour
  );

  delete from public.host_availability where user_id = v_uid;

  insert into public.host_availability (user_id, weekday, hour)
  select v_uid, weekday, hour from _new_slots;

  get diagnostics v_count = row_count;

  -- ここから通知。掲載中のピタメイトが枠を増やしたときだけ。
  select coalesce(h.is_host, false), h.slots_notified_at
    into v_is_host, v_last
  from public.host_settings h where h.user_id = v_uid;

  if coalesce(v_added, 0) > 0
     and coalesce(v_is_host, false)
     and (v_last is null or v_last < now() - c_cooldown)
  then
    select nickname into v_name from public.profiles where id = v_uid;

    insert into public.notifications (user_id, type, title, body, related_id)
    select r.user_id,
           'host_slots_opened',
           -- 0123: 見ていただけの人には、なぜ届いたのかが分かる書き方にする。
           -- 同じ文面だと「登録した覚えがないのに通知が来た」になる
           case when r.view_only then '前に見ていた' else '' end
             || coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが枠を開けました',
           -- 長くなりすぎないよう、先頭のいくつかだけ見せる
           case when v_added > 3
                then split_part(v_sample, '・', 1) || '・' || split_part(v_sample, '・', 2)
                     || ' ほか' || (v_added - 2) || '枠'
                else v_sample end,
           v_uid
    from (
      select u.user_id, bool_and(u.view_only) as view_only
      from (
        -- お気に入りに入れている人(0054)。**本人が明示的に選んだ相手**なので既定で届く
        select f.user_id, false as view_only
        from public.favorites f
        where f.host_id = v_uid
        union all
        -- 0123: 見たけれど予約しなかった人。
        -- **「おすすめマッチ」を自分で on にした人にだけ**送る(既定は off)。
        -- 閲覧はこちらが勝手に記録したものなので、同意なしには使わない
        select pv.viewer_id, true
        from public.profile_views pv
        join public.notification_prefs np on np.user_id = pv.viewer_id
        where pv.host_id = v_uid
          and pv.viewed_at > now() - c_view_window
          and np.notify_recommendations
      ) u
      group by u.user_id
    ) r
    where r.user_id <> v_uid
      -- ブロック関係があれば送らない
      and not exists (
        select 1 from public.blocks b
        where (b.blocker_id = r.user_id and b.blocked_id = v_uid)
           or (b.blocker_id = v_uid and b.blocked_id = r.user_id)
      );

    update public.host_settings set slots_notified_at = now() where user_id = v_uid;
  end if;

  -- **件数は返さない。** 誰がお気に入りにしているかに繋がる情報を渡さない(0053の方針)。
  return v_count;
end;
$$;

comment on function public.set_host_availability(jsonb) is
  '週間の募集枠を丸ごと入れ替える。0054で、枠が増えたときにお気に入りに入れている'
  'ファンへ通知する(24時間に1回まで・増えた分のみ)。'
  '0123で、宛先に「14日以内にプロフィールを見た人」を足した'
  '(おすすめマッチを on にしている人だけ)。';

revoke all on function public.set_host_availability(jsonb) from public;
grant execute on function public.set_host_availability(jsonb) to authenticated;
