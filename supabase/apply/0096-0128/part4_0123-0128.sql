-- ============================================================
-- 本番への適用 パート 4/4(0123〜0128)
-- tools/bundle-migrations.py で生成。手で直さないこと。
--
-- 1. このファイルの中身を全部 SQL Editor に貼って Run する
-- 2. docs/check-migrations.sql を流し、「次に適用するファイル」が
--    0128 の次(最後のパートなら「すべて適用済み」)になったことを確かめる
-- 3. エラーが出たら、そこで止めて内容を知らせる
--    (このパートの変更はまるごと取り消されている)
--
-- 先頭の関所は、順番の飛ばしと二重適用を止めるためのもの。
-- ============================================================

do $guard$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'host_monthly_ticket_gmv' and pg_get_functiondef(p.oid) like '%' || 'platform_fees' || '%')) then
    raise exception '順番が違います: 0122_fee_on_actual_gmv がまだ当たっていません。前のパートから流してください';
  end if;
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'profile_views') then
    raise exception 'このパートは適用済みです(0123_newcomer_discovery が当たっています)。docs/check-migrations.sql で次に流すファイルを確かめてください';
  end if;
end $guard$;

-- >>>>>>>> 0123_newcomer_discovery.sql
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


-- >>>>>>>> 0124_request_slots_for_new_hosts.sql
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


-- >>>>>>>> 0125_host_pair_partners.sql
-- ============================================================
-- 0125: ペア相手（ピタメイト同士が「一緒に組める」関係を持つ）
--
-- ■ 背景
--   ゲームは人数単位（Apex 3人、Valorant 5人、マリカー4人）で、
--   ゲスト1人＋ピタメイト1人では卓が埋まらない。紹介キャンペーンの
--   検討から出てきた案で、**割引ではなく「予約が入りやすくなる」**方の
--   施策として位置づける。
--
--   紹介した側・された側の2人を、ゲストが**まとめて1回で予約できる**
--   ようにする。土台になるのが、この「ペア相手」関係——
--   ゲストが誰とでも組ませられるわけではなく、**両方のピタメイトが
--   合意した組**だけを対象にする。
--
-- ■ 決めたこと（ユーザーとの確認事項）
--   ・ゲスト1人 × ホスト2人（N対Mではない。まずは2人固定）
--   ・2人目（誘われた側）も承認が必要。片方の合意だけで自動成立させない
--   ・最初のリリースは新規予約のみ。既存の1対1予約(create_booking等)の
--     動作は変えない（このファイルはその土台だけ。実際の予約は0126）
--
-- ■ この関係が要ること
--   ・双方がピタメイトであること（掲載条件はここでは見ない。予約時に見る）
--   ・ブロック関係が無いこと
--   ・**同じ2人の組は1つだけ**。順序に依らず一意にするため、
--     host_lo < host_hi の正規順で持つ
-- ============================================================

create table if not exists public.host_pair_partners (
  id uuid primary key default gen_random_uuid(),
  -- 正規順（小さいUUIDをlo・大きいUUIDをhi）。順序を固定することで
  -- 「AがBを誘う」も「BがAを誘う」も同じ1行に収束させる
  host_lo uuid not null references auth.users (id) on delete cascade,
  host_hi uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'active')),
  requested_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint host_pair_partners_order check (host_lo < host_hi),
  constraint host_pair_partners_requester check (requested_by in (host_lo, host_hi)),
  unique (host_lo, host_hi)
);

comment on table public.host_pair_partners is
  '0125: ピタメイト同士の「一緒に組める」関係。両方の承認で active になる。'
  'ゲストが2人まとめて予約できるのは、ここが active の組だけ(0126)。';

create index if not exists host_pair_partners_hi_idx
  on public.host_pair_partners (host_hi) where status = 'active';

alter table public.host_pair_partners enable row level security;

-- 見えるのは当事者だけ。一覧は関数(my_pair_partners)で配る
create policy "host_pair_partners_select_own"
  on public.host_pair_partners for select
  to authenticated
  using (auth.uid() in (host_lo, host_hi));

-- insert / update のポリシーは置かない。**RPCが唯一の入口**
-- （掲載条件・ブロック・承認の検査を画面の実装に依存させない）

-- ------------------------------------------------------------
-- 1. 申請する
-- ------------------------------------------------------------
create or replace function public.propose_pair_partner(p_partner_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lo uuid;
  v_hi uuid;
  v_is_host boolean;
  v_partner_is_host boolean;
  v_existing public.host_pair_partners;
  v_id uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_partner_id is null or p_partner_id = v_uid then
    raise exception 'INVALID_PARTNER';
  end if;

  select coalesce(is_host, false) into v_is_host
  from public.host_settings where user_id = v_uid;
  if not v_is_host then
    raise exception 'HOST_ONLY';
  end if;
  select coalesce(is_host, false) into v_partner_is_host
  from public.host_settings where user_id = p_partner_id;
  if not v_partner_is_host then
    raise exception 'PARTNER_NOT_HOST';
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = p_partner_id)
       or (b.blocker_id = p_partner_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  if v_uid < p_partner_id then
    v_lo := v_uid; v_hi := p_partner_id;
  else
    v_lo := p_partner_id; v_hi := v_uid;
  end if;

  select * into v_existing from public.host_pair_partners
    where host_lo = v_lo and host_hi = v_hi for update;

  if v_existing.id is not null then
    if v_existing.status = 'active' then
      raise exception 'ALREADY_PARTNERS';
    end if;
    -- 既に相手からの申請が来ている場合は、新規に作らず**その場で成立させる**。
    -- 両方が「申請」を押した=両方の意思が揃っている
    if v_existing.requested_by <> v_uid then
      update public.host_pair_partners
        set status = 'active', responded_at = now()
        where id = v_existing.id;
      select nickname into v_name from public.profiles where id = v_uid;
      insert into public.notifications (user_id, type, title, body, related_id)
      values (v_existing.requested_by, 'system',
        coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんとペア相手になりました',
        '2人まとめて予約を受けられるようになりました', v_existing.id);
      return v_existing.id;
    end if;
    -- 自分がすでに出した申請の再送。**同じ行を返すだけ**(重複は作らない)
    return v_existing.id;
  end if;

  insert into public.host_pair_partners (host_lo, host_hi, requested_by)
  values (v_lo, v_hi, v_uid)
  returning id into v_id;

  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (p_partner_id, 'system',
    coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんからペア相手の申請が届きました',
    '承認すると、2人まとめての予約を受けられるようになります', v_id);

  return v_id;
end;
$$;

comment on function public.propose_pair_partner(uuid) is
  '0125: ペア相手を申請する。相手からの申請が既にあれば、その場で成立させる'
  '(両方が押した時点で両方の意思が揃っているため、二重に待たせない)。';

revoke all on function public.propose_pair_partner(uuid) from public, anon;
grant execute on function public.propose_pair_partner(uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. 応じる（申請された側だけ）
-- ------------------------------------------------------------
create or replace function public.respond_pair_partner(p_partner_row_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.host_pair_partners;
  v_other uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_row from public.host_pair_partners where id = p_partner_row_id for update;
  if v_row.id is null then
    raise exception 'PARTNER_REQUEST_NOT_FOUND';
  end if;
  if v_uid not in (v_row.host_lo, v_row.host_hi) then
    raise exception 'FORBIDDEN';
  end if;
  -- **申請した本人は応じられない。** 自分の申請を自分で承認する経路を作らない
  if v_row.requested_by = v_uid then
    raise exception 'CANNOT_RESPOND_OWN_REQUEST';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'PARTNER_REQUEST_NOT_PENDING';
  end if;

  v_other := case when v_row.host_lo = v_uid then v_row.host_hi else v_row.host_lo end;

  if not p_accept then
    delete from public.host_pair_partners where id = p_partner_row_id;
    return;
  end if;

  update public.host_pair_partners
    set status = 'active', responded_at = now()
    where id = p_partner_row_id;

  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'system',
    coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんがペア相手の申請を承認しました',
    '2人まとめて予約を受けられるようになりました', p_partner_row_id);
end;
$$;

comment on function public.respond_pair_partner(uuid, boolean) is
  '0125: ペア相手の申請に応じる。断ったときは行ごと消す(履歴を持つ理由が無い)。';

revoke all on function public.respond_pair_partner(uuid, boolean) from public, anon;
grant execute on function public.respond_pair_partner(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 3. 解消する（成立後に、どちらからでも）
-- ------------------------------------------------------------
create or replace function public.end_pair_partner(p_partner_row_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.host_pair_partners;
  v_other uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  select * into v_row from public.host_pair_partners where id = p_partner_row_id for update;
  if v_row.id is null then
    raise exception 'PARTNER_REQUEST_NOT_FOUND';
  end if;
  if v_uid not in (v_row.host_lo, v_row.host_hi) then
    raise exception 'FORBIDDEN';
  end if;

  v_other := case when v_row.host_lo = v_uid then v_row.host_hi else v_row.host_lo end;
  delete from public.host_pair_partners where id = p_partner_row_id;

  -- 成立済みを解消したときだけ知らせる。申請の取り下げは静かに消える
  if v_row.status = 'active' then
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'system',
      coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんとのペア相手を解消しました',
      '今後、2人まとめての予約は届きません', null);
  end if;
end;
$$;

comment on function public.end_pair_partner(uuid) is
  '0125: ペア相手を解消する(申請中の取り下げにも使う)。どちらからでもできる。';

revoke all on function public.end_pair_partner(uuid) from public, anon;
grant execute on function public.end_pair_partner(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4. 一覧（自分の分だけ）
-- ------------------------------------------------------------
create or replace function public.my_pair_partners()
returns table (
  id uuid,
  partner_id uuid,
  partner_nickname text,
  partner_avatar_initial text,
  partner_avatar_color text,
  status text,
  -- true なら自分が申請した側(取り下げはできるが承認はできない)
  requested_by_me boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.id,
    case when r.host_lo = auth.uid() then r.host_hi else r.host_lo end,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    r.status,
    (r.requested_by = auth.uid()),
    r.created_at
  from public.host_pair_partners r
  join public.profiles p
    on p.id = case when r.host_lo = auth.uid() then r.host_hi else r.host_lo end
  where auth.uid() in (r.host_lo, r.host_hi)
  order by r.status = 'pending' desc, r.created_at desc;
$$;

comment on function public.my_pair_partners() is
  '0125: 自分のペア相手(申請中・成立済み)の一覧。';

revoke all on function public.my_pair_partners() from public, anon;
grant execute on function public.my_pair_partners() to authenticated;

-- ------------------------------------------------------------
-- 5. その2人が active なペア相手か（0126がゲストの予約時に使う）
-- ------------------------------------------------------------
create or replace function public.are_pair_partners(p_host_a uuid, p_host_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.host_pair_partners
    where status = 'active'
      and host_lo = least(p_host_a, p_host_b)
      and host_hi = greatest(p_host_a, p_host_b)
  );
$$;

comment on function public.are_pair_partners(uuid, uuid) is
  '0126で使う。ゲストが2人まとめて予約できるのは、ここが true の組だけ。';

revoke all on function public.are_pair_partners(uuid, uuid) from public, anon;
grant execute on function public.are_pair_partners(uuid, uuid) to authenticated;


-- >>>>>>>> 0126_paired_bookings.sql
-- ============================================================
-- 0126: ペア予約（ゲスト1人がペア相手の2人をまとめて予約する）
--
-- ■ 決めたこと（0125の続き）
--   ・ゲスト1人 × ホスト2人。2人とも active なペア相手であること(0125)
--   ・2人目も承認が必要。**片方だけの承諾では成立しない**
--   ・最初のリリースは新規予約のみ。ペア予約でも、成立後の1件1件は
--     **ふつうの予約と完全に同じ**。承諾・チェックイン・完了・キャンセル・
--     手数料・GMV・リピート判定は、0001〜0124 のロジックを一切変えずに
--     ホストごとに独立して流れる
--
-- ■ 何を新しく作るか
--   ・`booking_pairs`: 2件の bookings を束ねる薄い表(状態は持たない。
--     status は下の bookings 2件から導出する——2箇所に同じ状態を
--     持つと必ずずれる)
--   ・`bookings.from_pair_id`: どのペアに属す予約か(0120の
--     from_guest_request_id と同じ形)
--   ・`create_booking` の5引数版: p_pair_id を追加。**中身は4引数版と
--     ほぼ同一**で、変えたのはゲスト側の重複予約チェックが
--     「ペアの相方」を衝突と見なさない1点だけ。既存の4引数版は
--     この5引数版へ委譲するだけにする(2〜3引数版がすでに4引数版へ
--     委譲している、既存の書き方と揃える)。**既存の呼び出し元の挙動は
--     1文字も変わらない**(p_pair_id=null で今までと同じ経路を通る)。
--
-- ■ 「片方が断ったら、もう片方はどうなるか」
--   ゲストは「2人揃って遊ぶ」つもりで申し込んでいる。片方だけ確定した
--   ソロ予約に化けさせない。**もう片方が申請中(requested)のうちに
--   一方が断った/取り消したら、残りも同じ理由で全額返還して閉じる。**
--   （すでに両方 confirmed になったあとの片方キャンセルは、
--     このリリースでは自動連鎖させない——ゲストがもう片方だけで
--     続けたい場合もあるため。個別に判断してもらう。）
--
-- ■ 自作自演・0122との関係
--   ペアの2人は別々のホストなので、月間GMV・リピート判定・手数料は
--   **今までどおりホストごとに独立**して計算される(0122のロジックは
--   一切触っていない)。ペアという理由で優遇・軽減はしない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. bookings にペアの紐付け列を足す
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_pair_id uuid;

comment on column public.bookings.from_pair_id is
  '0126: ペア予約(booking_pairs)の一部なら、その行のid。'
  '単独の予約なら null。create_booking の5引数版だけがここを書く。';

create index if not exists bookings_from_pair_id_idx
  on public.bookings (from_pair_id) where from_pair_id is not null;

-- ------------------------------------------------------------
-- 2. booking_pairs（2件の bookings を束ねるだけの表）
--
-- **状態を持たない。** 「承認待ち／両方確定／片方だけ確定」などは
-- 2件の bookings.status から毎回導くもので、ここに複製すると
-- どちらかの更新を忘れたときに食い違う。
-- ------------------------------------------------------------
create table if not exists public.booking_pairs (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null references auth.users (id) on delete cascade,
  booking_a uuid references public.bookings (id) on delete cascade,
  booking_b uuid references public.bookings (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint booking_pairs_distinct check (booking_a is null or booking_a <> booking_b)
);

comment on table public.booking_pairs is
  '0126: 2件のbookingsを束ねるだけの表。状態は持たない'
  '(bookings.status から導出する。get_paired_booking / my_paired_bookings を参照)。';

alter table public.booking_pairs enable row level security;

create policy "booking_pairs_select_participant"
  on public.booking_pairs for select
  to authenticated
  using (
    guest_id = auth.uid()
    or exists (
      select 1 from public.bookings b
      where b.id in (booking_a, booking_b) and b.host_id = auth.uid()
    )
  );

-- insert / update のポリシーは置かない。**RPCが唯一の入口**

alter table public.bookings
  add constraint bookings_from_pair_id_fkey
  foreign key (from_pair_id) references public.booking_pairs (id) on delete set null;

-- ------------------------------------------------------------
-- 3. create_booking の5引数版（p_pair_id を追加）
--
-- ⚠️ 本体は適用済みのDBから取り出したもの。差分は2箇所だけ:
--    ・ゲスト側の重複予約チェックが「ペアの相方」を除外する
--    ・insert 文に from_pair_id を足す
-- ------------------------------------------------------------
create or replace function public.create_booking(p_host_id uuid, p_duration_minutes integer, p_policy_version text, p_scheduled_at timestamp with time zone, p_pair_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_verified boolean;
  v_coins int;
  v_list_coins int;
  v_discount int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_lead int;
  v_start timestamptz;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  -- 0121: ブロック関係があれば予約させない。
  -- **0116 が「ブロック＝予約もトークも不可」と書いているのに、
  --   ここには検査が無かった。** create_booking_from_board(0113)だけが
  --   独自に見ていたので、板を経由しない経路は全部素通りだった。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_guest_id and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_guest_id)
  ) then
    raise exception 'BLOCKED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_lead) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hs.hourly_rate, hs.is_host into v_hourly_rate, v_is_host
  from public.host_settings hs where hs.user_id = p_host_id for share;
  if not coalesce(v_is_host, false) or v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  select pts.is_verified into v_verified
  from public.profile_trust_stats pts where pts.user_id = p_host_id;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  v_start := coalesce(p_scheduled_at, now());

  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 常連への先行予約(0057)。開始まで遠い枠は、一緒に遊んだことのある人だけ。
  if not public.slot_open_to(p_host_id, v_guest_id, v_start) then
    raise exception 'REGULARS_FIRST';
  end if;

  perform public._lock_booking_slots(v_guest_id, p_host_id);

  if public._booking_slot_conflict(p_host_id, v_start, p_duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペア予約(同じゲスト・同じ時間で2人のホストに同時に申し込む)は、
  -- ここが無いと**自分自身の、もう片方への申し込み**を「重複」として
  -- 弾いてしまう。p_pair_id が同じ予約(=ペアの相方)だけ、この検査から除く
  -- (他のゲストの予約や、別のペアとは今までどおり衝突させる)。
  -- **_booking_slot_conflict は1件しか返さない**ので、ここは書き直さず
  -- 素の exists で「相方以外との重なり」だけを見る。
  if exists (
    select 1 from public.bookings b
    where b.status = any (array['requested', 'confirmed'])
      and (b.guest_id = v_guest_id or b.host_id = v_guest_id)
      and (p_pair_id is null or b.from_pair_id is distinct from p_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes),
            '[)')
          && tstzrange(v_start, v_start + make_interval(mins => p_duration_minutes), '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;
  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 有償を先に使い切るのではなく、**有効期限の早いロットから**充当する。
  -- 同一期限内では有償が先。詳細は 0082 の冒頭を参照。
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_guest_id, v_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, policy_version, policy_agreed_at,
    list_coins, discount_percent, requested_start_at, from_pair_id
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at, p_pair_id
  )
  returning id into v_booking_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$$;

comment on function public.create_booking(uuid, integer, text, timestamptz, uuid) is
  '予約の確定+コイン消費(0003)。0126でp_pair_idを追加——'
  'ペアの相方への同時申し込みを、ゲスト側の重複予約チェックから除外する。'
  '**単独では呼ばない。** create_paired_booking からだけ使う内部経路。';

revoke all on function public.create_booking(uuid, integer, text, timestamptz, uuid) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz, uuid) to authenticated;

-- 4引数版は、この5引数版へ委譲するだけにする(2〜3引数版が4引数版へ
-- 委譲しているのと同じ書き方)。**p_pair_id=null なので、経路も挙動も
-- 今までと1バイトも変わらない**——上で足した分岐は p_pair_id is null の
-- ときはすべて素通りする。
create or replace function public.create_booking(
  p_host_id uuid, p_duration_minutes integer, p_policy_version text,
  p_scheduled_at timestamp with time zone
)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.create_booking(p_host_id, p_duration_minutes, p_policy_version, p_scheduled_at, null::uuid);
$$;

revoke all on function public.create_booking(uuid, integer, text, timestamptz) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 4. 「片方が申請中のうちにもう片方が終わったら、連鎖して閉じる」
--
-- ゲストは「2人揃って遊ぶ」つもりで申し込んでいる。片方が断られた/
-- 取り消されたのに、もう片方だけ残って**ソロ予約に化ける**のを防ぐ。
--
-- ⚠️ **承認(confirmed)後の片方キャンセルは連鎖させない。** 両方確定した
--    あとにどちらかが個別の理由でキャンセルするのは、通常のキャンセルと
--    同じ扱いでよく、ゲストがもう片方だけで続けたい場合もあるため。
--    連鎖は「まだ両方とも返事待ちの段階」に限る。
-- ------------------------------------------------------------
alter table public.bookings drop constraint bookings_status_check;
alter table public.bookings add constraint bookings_status_check
  check (status = any (array[
    'requested', 'confirmed', 'completed',
    'cancelled_by_guest', 'cancelled_by_host', 'declined_by_host',
    'no_show_host', 'no_show_guest',
    -- 0126: ペアの相方が申請段階で終わったことによる、システム側の自動取消し。
    -- 本人が押したのではないので、既存の理由と混ぜない
    'cancelled_by_platform'
  ]));

create or replace function public._cascade_pair_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sibling public.bookings;
  v_host_name text;
begin
  -- ペアに属さない予約、または「申請中」以外からの遷移は無関係
  if new.from_pair_id is null or old.status <> 'requested' then
    return new;
  end if;
  -- 連鎖の対象は「本人の意思で終わった」遷移だけ。
  -- **cancelled_by_platform はここに含めない**——含めると、いま自分が
  -- 起こしている連鎖が、相手側の行を経由して往復してしまう
  if new.status not in ('declined_by_host', 'cancelled_by_guest', 'cancelled_by_host') then
    return new;
  end if;

  select * into v_sibling from public.bookings
    where from_pair_id = new.from_pair_id and id <> new.id
    for update;
  -- 相方が無い、またはすでに動いている(承認済み・すでに連鎖済みなど)なら何もしない
  if v_sibling.id is null or v_sibling.status <> 'requested' then
    return new;
  end if;

  update public.bookings
    set status = 'cancelled_by_platform', cancelled_at = now(),
        cancel_reason = 'pair_partner_declined'
    where id = v_sibling.id;

  update public.coin_wallets
    set balance = balance + v_sibling.paid_coins, bonus_balance = bonus_balance + v_sibling.bonus_coins
    where user_id = v_sibling.guest_id;
  perform public._refund_coin_lots_for_booking(v_sibling.id, null, null, 'host_fault');
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_sibling.guest_id, v_sibling.coins, 'refund', v_sibling.id, 'pair_partner_declined');

  select nickname into v_host_name from public.profiles where id = v_sibling.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_sibling.guest_id, 'booking_cancelled',
    'ペアの片方が成立しなかったため、もう一方も取り消しました',
    coalesce(nullif(v_host_name, ''), '相手') || 'さんへの申し込みはコイン全額を返却しました',
    v_sibling.id);

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_sibling.host_id, 'booking_cancelled',
    'ペア予約の申し込みが取り消されました',
    'もう一方が成立しなかったため、この申し込みも自動的に取り消されました',
    v_sibling.id);

  return new;
end;
$$;

comment on function public._cascade_pair_cancel() is
  '0126: ペアの片方が「申請中」のまま終わったら、もう片方も同時に閉じて全額返還する。'
  '両方confirmed後の片方キャンセルは連鎖させない(設計どおり)。';

revoke all on function public._cascade_pair_cancel() from public, anon, authenticated;

drop trigger if exists bookings_cascade_pair_cancel on public.bookings;
create trigger bookings_cascade_pair_cancel
  after update on public.bookings
  for each row execute function public._cascade_pair_cancel();

-- ------------------------------------------------------------
-- 5. ゲストが2人まとめて申し込む
-- ------------------------------------------------------------
create or replace function public.create_paired_booking(
  p_host_a_id uuid,
  p_host_b_id uuid,
  p_duration_minutes integer,
  p_policy_version text,
  p_scheduled_at timestamptz
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_pair_id uuid;
  v_booking_a uuid;
  v_booking_b uuid;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_host_a_id is null or p_host_b_id is null or p_host_a_id = p_host_b_id then
    raise exception 'INVALID_PAIR';
  end if;

  -- ゲストが誰とでも組ませられるわけではない。**両方が合意した組だけ**(0125)
  if not public.are_pair_partners(p_host_a_id, p_host_b_id) then
    raise exception 'NOT_PAIR_PARTNERS';
  end if;
  -- 成立後にブロックが起きている可能性がある。are_pair_partners は
  -- 申請の状態しか見ないので、ここで別途確認する
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = p_host_a_id and b.blocked_id = p_host_b_id)
       or (b.blocker_id = p_host_b_id and b.blocked_id = p_host_a_id)
  ) then
    raise exception 'PARTNER_BLOCKED';
  end if;

  insert into public.booking_pairs (guest_id) values (v_guest_id)
  returning id into v_pair_id;

  -- **create_booking をそのまま呼ぶ。** 検査(掲載・本人確認・先約・同意・
  -- ブロック・残高)を作り直さない(0113/0120と同じ方針)。片方が失敗すれば
  -- 例外が伝播し、この関数全体がロールバックする(booking_pairs の行も含めて
  -- 何も残らない)——**中途半端な「片方だけ成立」を作らない**。
  v_booking_a := public.create_booking(
    p_host_a_id, p_duration_minutes, p_policy_version, p_scheduled_at, v_pair_id);
  v_booking_b := public.create_booking(
    p_host_b_id, p_duration_minutes, p_policy_version, p_scheduled_at, v_pair_id);

  update public.booking_pairs
    set booking_a = v_booking_a, booking_b = v_booking_b
    where id = v_pair_id;

  return v_pair_id;
end;
$$;

comment on function public.create_paired_booking(uuid, uuid, integer, text, timestamptz) is
  '0126: ペア相手の2人をまとめて予約する。承認・チェックイン・完了・キャンセル・'
  '手数料・GMV・リピート判定は、成立後は通常の1対1予約と完全に同じ経路を通る'
  '(ホストごとに独立)。片方が申請段階で終わったら、もう片方も自動的に閉じる。';

revoke all on function public.create_paired_booking(uuid, uuid, integer, text, timestamptz) from public, anon;
grant execute on function public.create_paired_booking(uuid, uuid, integer, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 6. ペアの情報を引く（両側から使う）
-- ------------------------------------------------------------
create or replace function public.fetch_booking_pair(p_booking_id uuid)
returns table (
  pair_id uuid,
  sibling_booking_id uuid,
  sibling_user_id uuid,
  sibling_nickname text,
  sibling_status text,
  sibling_starts_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    bp.id,
    sib.id,
    -- 呼び出し元がゲストなら相方の「ホスト」を、ホストなら相方の「ゲスト」…
    -- ではなく、常に「もう一方の予約のホスト」を返す。ゲストは同一人物なので
    -- 見せる意味が無い
    sib.host_id,
    p.nickname,
    sib.status,
    coalesce(sib.requested_start_at, sib.scheduled_at)
  from public.bookings me
  join public.booking_pairs bp on bp.id = me.from_pair_id
  join public.bookings sib on sib.from_pair_id = bp.id and sib.id <> me.id
  join public.profiles p on p.id = sib.host_id
  where me.id = p_booking_id
    and (me.guest_id = auth.uid() or me.host_id = auth.uid());
$$;

comment on function public.fetch_booking_pair(uuid) is
  '0126: この予約がペアの一部なら、相方の状態を返す(無ければ0行)。'
  '承認画面・トーク画面で「ペア予約です」と出すのに使う。';

revoke all on function public.fetch_booking_pair(uuid) from public, anon;
grant execute on function public.fetch_booking_pair(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. 自分のペア予約の一覧（ゲスト向け）
-- ------------------------------------------------------------
create or replace function public.my_paired_bookings(p_limit int default 20)
returns table (
  pair_id uuid,
  booking_a uuid,
  host_a_id uuid,
  host_a_nickname text,
  status_a text,
  booking_b uuid,
  host_b_id uuid,
  host_b_nickname text,
  status_b text,
  starts_at timestamptz,
  duration_minutes int,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    bp.id, a.id, a.host_id, pa.nickname, a.status,
    b.id, b.host_id, pb.nickname, b.status,
    coalesce(a.requested_start_at, a.scheduled_at), a.duration_minutes,
    bp.created_at
  from public.booking_pairs bp
  join public.bookings a on a.id = bp.booking_a
  join public.bookings b on b.id = bp.booking_b
  join public.profiles pa on pa.id = a.host_id
  join public.profiles pb on pb.id = b.host_id
  where bp.guest_id = auth.uid()
  order by bp.created_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;

comment on function public.my_paired_bookings(int) is
  '0126: 自分(ゲスト)が申し込んだペア予約の一覧。';

revoke all on function public.my_paired_bookings(int) from public, anon;
grant execute on function public.my_paired_bookings(int) to authenticated;

-- ------------------------------------------------------------
-- 8. approve_booking / extend_booking も同じ理由で1点だけ直す
--
-- ⚠️ **設計時点では気づけなかった追加の変更。** 「create_booking以外の
--    予約ライフサイクル(承認・チェックイン・完了・キャンセル)には
--    一切手を入れない」つもりだったが、実装してテストを流したところ
--    approve_booking と extend_booking にも**ゲスト側の「成立済みと
--    重複していないか」の再チェック**があり、これがペアの相方を
--    「衝突」として検出してしまうことが分かった:
--
--      ・ペアの片方を承諾した瞬間、もう片方の承諾がGUEST_SLOT_TAKENで
--        弾かれる(テスト46の★4で実際に踏んだ)
--      ・ペア予約は延長が一度もできない(相方が同じ時刻で確定して
--        いる以上、延長前から必ず重なって見えるため)
--
--    どちらも「本人の別予約と重複していないか」という**既存の検査の
--    意図を変えていない**。除外するのは「ペアの相方」1種類だけで、
--    通常の1対1予約の挙動(from_pair_idがnull)は一切変わらない。
--    本体は適用済みのDBから取り出したもので、変更点はコメントで示した
--    exists節1つずつだけ。
-- ------------------------------------------------------------
create or replace function public.approve_booking(p_booking_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
  v_start timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 指定があればその時刻、無ければ従来どおり承諾時点が開始時刻。
  -- 承諾時刻は別に持つ(キャンセル猶予の起点になるため。0040以前は
  -- scheduled_at が承諾時刻を兼ねていた)。
  v_start := coalesce(v_booking.requested_start_at, now());

  -- ここで見るのは**成立済み(confirmed)だけ**。
  -- 申請中の予約まで見ると、同じ枠に2件のリクエストが並んだときに
  -- ピタメイトが**どちらも承諾できなくなります**。申請は「希望」であって
  -- 確約ではないので、承諾の可否を縛るべきではありません。
  -- (先に1件を承諾すれば、もう1件はここで弾かれて全額返還されます。)
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_start, v_booking.duration_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペアの相方(同じfrom_pair_id)は「重複」として数えない。
  -- ペア予約は両方が同じ時刻で確定するのが前提なので、ここが無いと
  -- 1件目を承諾した瞬間、2件目の承諾がここで弾かれてしまう
  -- (_booking_slot_conflict は素の関数なので、除外条件はここに直接書く)。
  if exists (
    select 1 from public.bookings b
    where b.status = 'confirmed'
      and b.guest_id = v_booking.guest_id
      and b.id <> p_booking_id
      and (v_booking.from_pair_id is null
           or b.from_pair_id is distinct from v_booking.from_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes), '[)')
          && tstzrange(v_start, v_start + make_interval(mins => v_booking.duration_minutes), '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  update public.bookings
    set status = 'confirmed', scheduled_at = v_start, confirmed_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ピタメイト') || 'さんが予約を承諾しました',
    case when v_booking.requested_start_at is null
         then 'トークが始まりました。プレイの準備をしましょう'
         else to_char(v_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜 で成立しました' end,
    v_promise_id
  );

  return v_promise_id;
end;
$$;

comment on function public.approve_booking(uuid) is
  '予約の承諾(0003)。0126で、ペアの相方(from_pair_id)は成立済みどうしの'
  '重複チェックから除く(両方が同じ時刻で確定するのがペア予約の前提のため)。';

revoke all on function public.approve_booking(uuid) from public, anon;
grant execute on function public.approve_booking(uuid) to authenticated;

create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes integer)
 returns integer
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_max int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
  end if;

  -- 延長は終了時刻を後ろにずらすので、次の予約に食い込まないか確かめる。
  -- ここも成立済みだけを見る。まだ承諾されていない後続のリクエストのために
  -- 進行中のプレイの延長を止めるのは、優先順位が逆。
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペアの相方(同じfrom_pair_id)は「重複」として数えない。
  -- 相方は同じ開始時刻で確定しているので、延長前の時点で必ず重なって見える。
  -- ここが無いと、ペア予約の延長が一度もできない。
  if exists (
    select 1 from public.bookings b
    where b.status = 'confirmed'
      and b.guest_id = v_booking.guest_id
      and b.id <> p_booking_id
      and (v_booking.from_pair_id is null
           or b.from_pair_id is distinct from v_booking.from_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes), '[)')
          && tstzrange(
               v_booking.scheduled_at,
               v_booking.scheduled_at + make_interval(mins => v_booking.duration_minutes + p_additional_minutes),
               '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 期限の早いロットから充当する(同一期限内は有償が先)
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_uid, v_add_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
  values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

comment on function public.extend_booking(uuid, integer) is
  'プレイ時間の延長(0055)。0126で、ペアの相方(from_pair_id)は'
  '重複チェックから除く(相方は同じ開始時刻の別予約として必ず重なるため。'
  '除かないとペア予約は一度も延長できない)。片方だけ延長すると2人の'
  '終了時刻がずれる——連動させるかは今回のリリース範囲外。';

revoke all on function public.extend_booking(uuid, integer) from public, anon;
grant execute on function public.extend_booking(uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- 9. このホストの、active なペア相手を誰でも見られるようにする
--
-- `host_pair_partners` はRLSで当事者にしか見えない。しかし
-- 「このピタメイトはペアで予約できます」はゲストへの案内なので、
-- **公開情報として見せる必要がある**(掲載中のゲーム・時給と同じ扱い)。
-- 見せるのは active な相手の最小限の表示情報だけで、申請中の行や
-- 誰が申請した側かは渡さない。
-- ------------------------------------------------------------
create or replace function public.host_pair_partners_of(p_host_id uuid)
returns table (
  partner_id uuid,
  partner_nickname text,
  partner_avatar_initial text,
  partner_avatar_color text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    case when r.host_lo = p_host_id then r.host_hi else r.host_lo end,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2')
  from public.host_pair_partners r
  join public.profiles p
    on p.id = case when r.host_lo = p_host_id then r.host_hi else r.host_lo end
  where r.status = 'active' and p_host_id in (r.host_lo, r.host_hi);
$$;

comment on function public.host_pair_partners_of(uuid) is
  '0126: 指定したホストの、active なペア相手の一覧(誰でも見られる)。'
  'プロフィール画面の「ペアで予約できます」の案内に使う。';

revoke all on function public.host_pair_partners_of(uuid) from public, anon;
grant execute on function public.host_pair_partners_of(uuid) to authenticated;


-- >>>>>>>> 0127_dormant_accounts.sql
-- ============================================================
-- 0127: 長期間ご利用のないアカウント（規約 第6条の4）
--
-- ■ 何が抜けていたか
--   規約 第6条の4 は「最終ログインから2年以上→30日前通知→利用停止/削除。
--   購入コインは消滅するが、**報酬コインの金銭債権は消滅させない**」と
--   約束している。ところが実装は1行も存在しなかった——`0086`(退会後90日)
--   と同じ形で、**条文だけが先に走っていた。**
--
-- ■ 「最終ログイン」はどこから取るか
--   `profiles.last_seen_at` は使えない。0026 の設計で、オンライン表示を
--   オフにした瞬間に **null に戻る**（プライバシー設定であって、ログイン
--   記録ではない）。本番の Supabase Auth が実際に持つ
--   `auth.users.last_sign_in_at`（GoTrue がログインのたびに更新する）を使う。
--   一度もログイン記録が無い場合は `profiles.created_at` に落とす。
--
-- ■ 設計：既存の「最終換金」の仕組みにそのまま乗せる
--   第6条の4第4項は「換金については、第6条の2第4項を準用する」と定めている。
--   実装でも同じ道を通す。`request_bank_payout` の最低申請額の除外判定は
--   既に `withdrawn_at is not null or suspended_at is not null` の1行に
--   集約されている(0100)。ここに `dormant_closed_at is not null` を足すだけで、
--   **最終換金(全額一括・最低額なし)の仕組みをまるごと再利用できる。**
--
--   `withdrawn_at`(退会・本人の意思)や `suspended_at`(第6条・違反による停止)
--   と**同じ列を使い回さない**。理由の異なる3つの停止を1つの列に混ぜると、
--   運営コンソールで「違反により停止」の一覧に、何もしていない休眠者が
--   混ざってしまう。
--
-- ■ 通知→30日待つ→再確認、の流れ
--   `dormant_account_notices` に1人1行。
--     1. 検知した日に通知を送り、実行日(30日後)を記録する
--     2. 実行日になったら**もう一度**最終ログインを見る。通知後にログインが
--        あれば(第6条の4第2項)、行を削除して終わり——措置は取らない
--     3. まだ休眠のままなら、そのときだけ実行する
--   こうすれば「30日以内にログインがあれば措置をしない」を、判定のやり直し
--   だけで満たせる。ログイン済みかどうかのフラグを別に持つ必要がない。
-- ============================================================

alter table public.profiles
  add column if not exists dormant_closed_at timestamptz;

comment on column public.profiles.dormant_closed_at is
  '0127: 規約第6条の4により、長期間未ログインを理由に利用停止/削除した時刻。'
  '**報酬コインの金銭債権は消滅させない**(第6条の4第4項)。'
  'withdrawn_at(退会)・suspended_at(違反による停止)とは別の列にしてある——'
  '理由が異なる停止を1つの列に混ぜると、運営コンソールの一覧が混同する。';

create index if not exists profiles_dormant_closed_at_idx
  on public.profiles (dormant_closed_at) where dormant_closed_at is not null;

-- ------------------------------------------------------------
-- 1. 最終ログインを引く
-- ------------------------------------------------------------
create or replace function public._effective_last_login(p_user_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select u.last_sign_in_at from auth.users u where u.id = p_user_id),
    (select p.created_at from public.profiles p where p.id = p_user_id)
  );
$$;

comment on function public._effective_last_login(uuid) is
  '0127: 最終ログイン時刻。auth.users.last_sign_in_at を使う'
  '(profiles.last_seen_at はオンライン表示のプライバシー設定でnullに戻るため不可)。'
  '記録が無ければ登録日に落とす。';

revoke all on function public._effective_last_login(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. 通知の記録
-- ------------------------------------------------------------
create table if not exists public.dormant_account_notices (
  user_id uuid primary key references auth.users (id) on delete cascade,
  notified_at timestamptz not null default now(),
  execute_at timestamptz not null,
  executed_at timestamptz
);

comment on table public.dormant_account_notices is
  '0127: 長期未ログイン(規約第6条の4)の通知記録。1人1行。'
  'execute_at より前にログインがあれば行ごと削除する(措置を取らない)。'
  'executed_at が付いた行は履歴として残す。';

alter table public.dormant_account_notices enable row level security;

-- 見えるのは本人だけ。運営は _is_admin() 経由の関数で扱う
create policy "dormant_account_notices_select_own"
  on public.dormant_account_notices for select
  to authenticated
  using (user_id = auth.uid());

-- insert/update/delete のポリシーは置かない。**cronの内部関数だけが操作する**

-- ------------------------------------------------------------
-- 3. 検知して通知する(日次cron)
-- ------------------------------------------------------------
create or replace function public.flag_dormant_accounts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_threshold constant interval := interval '2 years';
  c_notice_days constant int := 30;
  v_rec record;
  v_count int := 0;
begin
  for v_rec in
    select p.id
    from public.profiles p
    where p.withdrawn_at is null
      and p.suspended_at is null
      and p.dormant_closed_at is null
      and public._effective_last_login(p.id) < now() - c_threshold
      and not exists (
        select 1 from public.dormant_account_notices n
        where n.user_id = p.id and n.executed_at is null
      )
  loop
    insert into public.dormant_account_notices (user_id, notified_at, execute_at)
    values (v_rec.id, now(), now() + make_interval(days => c_notice_days))
    on conflict (user_id) do nothing;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.id, 'system',
      '長期間ご利用が無いため、まもなく利用を停止します',
      '最終のご利用から2年以上が経過しました。このまま' || c_notice_days
        || '日間ログインが無い場合、規約第6条の4に基づき、利用を停止いたします。'
        || 'ログインいただければ、この措置は取りません。'
        || '報酬コインをお持ちの場合、停止後も換金の権利は消滅しません。');

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.flag_dormant_accounts() is
  '0127: 最終ログインから2年以上のアカウントに、30日前通知を送る(規約第6条の4第1・2項)。'
  '日次cron(flag-dormant-accounts)から呼ぶ。運営が手動で呼ぶ経路は用意しない'
  '(対象の選定に個別判断が要らないため、自動処理で十分)。';

revoke all on function public.flag_dormant_accounts() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. 実行する(日次cron。通知の30日後)
-- ------------------------------------------------------------
create or replace function public.execute_dormant_accounts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_final_deadline constant interval := interval '90 days';
  v_rec record;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_blocking int;
  v_count int := 0;
begin
  for v_rec in
    select n.user_id, n.notified_at
    from public.dormant_account_notices n
    where n.executed_at is null
      and n.execute_at <= now()
    for update of n skip locked
  loop
    -- 第6条の4第2項: **通知後にログインがあれば、措置を取らない。**
    -- 判定をやり直すだけで満たせる(別にフラグを持たない)
    if public._effective_last_login(v_rec.user_id) > v_rec.notified_at then
      delete from public.dormant_account_notices where user_id = v_rec.user_id;
      continue;
    end if;

    -- 成立済みの予約を残したまま止めない。相手のあることなので、
    -- 片方が消えると相手が救済されない(0086と同じ考え方)。
    -- **実行を見送るだけ**——次の日次実行で再判定する
    select count(*) into v_blocking
    from public.bookings b
    where (b.guest_id = v_rec.user_id or b.host_id = v_rec.user_id)
      and b.status in ('requested', 'confirmed');
    if coalesce(v_blocking, 0) > 0 then
      continue;
    end if;

    select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
      into v_paid, v_bonus, v_earned
    from public.coin_wallets where user_id = v_rec.user_id for update;

    -- 第6条の4第3項: 購入コインは消滅する。
    -- ⚠️ **通常はここより先に第7条5項の6か月失効で既に0になっている。**
    -- 2年ログインが無い間、期限切れの日次cron(expire-coins)は動き続けるため。
    -- ここでの没収は、その取りこぼしに対する保険。
    if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
      update public.coin_lots set remaining = 0
        where user_id = v_rec.user_id and remaining > 0;
      update public.coin_wallets set balance = 0, bonus_balance = 0
        where user_id = v_rec.user_id;
      if v_paid > 0 then
        insert into public.coin_transactions (user_id, amount, type, note)
          values (v_rec.user_id, -v_paid, 'expire', 'dormant_paid');
      end if;
      if v_bonus > 0 then
        insert into public.coin_transactions (user_id, amount, type, note)
          values (v_rec.user_id, -v_bonus, 'expire', 'dormant_bonus');
      end if;
    end if;

    -- 第6条の4第4項: **報酬コインの金銭債権は消滅させない。**
    -- 換金は第6条の2第4項を準用する(最低額なし・全額一括)。
    -- payout_claim_deadline は表示用(request_bank_payoutの実行そのものは
    -- 期限で縛らない。0098のsuspended_atと同じ扱い)。
    update public.profiles
      set dormant_closed_at = now(),
          payout_claim_deadline = case when v_earned > 0 then now() + c_final_deadline else null end
      where id = v_rec.user_id;

    -- 掲載を止める。検索・ランキング・「いま遊べる」は is_host を見ている
    update public.host_settings set is_host = false where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system',
      '長期間ご利用が無いため、利用を停止しました',
      case when v_earned > 0
        then '規約第6条の4に基づく措置です。報酬コイン' || v_earned || '枚は消滅せず、'
               || '最低申請額の制限なく全額を一括で申請できます。'
        else '規約第6条の4に基づく措置です。' end);

    update public.dormant_account_notices
      set executed_at = now()
      where user_id = v_rec.user_id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.execute_dormant_accounts() is
  '0127: 通知から30日後、まだ休眠のままなら利用を停止する(規約第6条の4)。'
  '成立済みの予約がある間は見送る(次回に再判定)。'
  '購入コインは消滅させるが、報酬コインの金銭債権は消滅させない。';

revoke all on function public.execute_dormant_accounts() from public, anon, authenticated;

select cron.schedule('flag-dormant-accounts', '0 4 * * *',
  $$select public.flag_dormant_accounts()$$);
select cron.schedule('execute-dormant-accounts', '20 4 * * *',
  $$select public.execute_dormant_accounts()$$);

-- ------------------------------------------------------------
-- 5. request_bank_payout: 長期未ログインによる停止も最終換金として扱う
--
-- ⚠️ 本体は適用済みのDBから取り出したもの。差分は最終換金の判定に
--    dormant_closed_at を足した1行だけ。
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins integer)
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
  -- 0127: 長期未ログインによる停止(第6条の4)も最終換金として扱う。
  -- 準用元(第6条の2第4項)と同じく、最低申請額を外し全額一括にする。
  select (p.withdrawn_at is not null or p.suspended_at is not null
          or p.dormant_closed_at is not null)
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

comment on function public.request_bank_payout(integer) is
  '換金申請。退会(withdrawn_at)・利用停止(suspended_at)・長期未ログインによる停止'
  '(dormant_closed_at・0127)の後は最終換金として扱い、最低申請額を外す代わりに'
  '**換金可能な全額を一括**でのみ申請できる(規約 第6条の2第4項・第6条の3第2項・'
  '第6条の4第4項)。手数料は最終換金でも控除する。';

revoke all on function public.request_bank_payout(integer) from public, anon;
grant execute on function public.request_bank_payout(integer) to authenticated;

-- ------------------------------------------------------------
-- 6. withdraw_account: 期限後は「消滅する」と読める通知文を訂正
--
-- 0107(2026-08-05)で退会後90日の消滅そのものは撤去したが、退会**直後**に
-- 送るこの通知の文面は直し忘れていた。「期限を過ぎると消滅します」は
-- 現在の実装(消滅しない)と食い違ったまま残っていた——0086→0107と同じ
-- 種類の見落とし。本体は適用済みのDBから取り出したもので、差分は
-- 通知本文の1行だけ。
-- ------------------------------------------------------------
create or replace function public.withdraw_account(p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  if exists (select 1 from public.profiles p
              where p.id = v_uid and p.withdrawn_at is not null) then
    raise exception 'ALREADY_WITHDRAWN';
  end if;

  -- 第6条の2第2項。**成立済みの予約を残したまま辞めさせない。**
  -- 相手のあることなので、片方が黙って消えると相手が救済されない
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');
  if coalesce(v_blocking, 0) > 0 then
    raise exception 'HAS_ACTIVE_BOOKINGS';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = v_uid for update;

  -- ----------------------------------------------------------
  -- コインを消滅させる(第7条3項・第6条の2第3項)
  --
  -- **報酬コイン(earned_balance)には手を付けない。** 換金の対象であり、
  -- ここで消すと弁護士の指摘した「人質」そのものになる
  -- ----------------------------------------------------------
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots
      set remaining = 0
      where user_id = v_uid and remaining > 0;
    update public.coin_wallets
      set balance = 0, bonus_balance = 0
      where user_id = v_uid;
    if coalesce(v_paid, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_paid, 'expire', 'withdraw_paid');
    end if;
    if coalesce(v_bonus, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_bonus, 'expire', 'withdraw_bonus');
    end if;
  end if;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**ので、
  -- ここを落とすことで退会者が誰の目にも触れなくなる
  update public.host_settings set is_host = false where user_id = v_uid;

  -- 0092: 規約 第10条の2第4項。**投稿等の利用許諾は退会で将来に向かって終わる。**
  -- 条文でそう約束した以上、表示に使う投稿物への参照はここで落とす。
  -- 落とさないものは第10条の2第4項1号・2号の例外(レビューと、
  -- マナースコアの算定根拠、法令に基づく記録)だけ。
  --
  -- ⚠️ ストレージ上の実体(音声・アバターのファイル)はここでは消せない。
  --    参照を切ったうえで、運営が avatar-delete / voice-delete を回す。
  --    **参照だけ切って安心しないこと。**
  update public.profiles
    set withdrawn_at = now(),
        presence_status = 'busy',
        bio = '',
        voice_path = null,
        voice_seconds = null,
        avatar_path = null,
        favorite_games = '{}'
    where id = v_uid;

  insert into public.account_withdrawals
    (user_id, expired_paid_coins, expired_bonus_coins, earned_balance, payout_deadline, reason)
  values (v_uid, coalesce(v_paid, 0), coalesce(v_bonus, 0), coalesce(v_earned, 0),
          v_deadline, p_reason);

  -- 期限を本人に残す。画面を閉じても分かるように通知にも書く
  insert into public.notifications (user_id, type, title, body)
  values (v_uid, 'system', '退会の手続が完了しました',
    case when coalesce(v_earned, 0) > 0
      then '報酬コイン' || v_earned || '枚の換金は、'
             || to_char(v_deadline, 'YYYY年MM月DD日') || 'まで申請できます。'
             -- 0127: 「期限を過ぎると消滅します」は0107(2026-08-05)で誤りになった
             -- ままの文言だった。報酬コインの金銭債権はこの期限を過ぎても消えない
             -- (第6条の2第4項)。アプリからの申請受付が終わるだけで、それ以降は
             -- 個別の申出で換金できる、と正確に書く。**「まで申請できます」の
             -- 文言はテスト(21_account_withdrawal.sql)が固定して見ているので、
             -- そのまま残し、訂正は後ろに続ける形にする**
             || '期限を過ぎるとアプリからの申請受付は終了しますが、コインは消滅しません。'
             || 'お問い合わせいただければ個別に換金いたします。'
      else 'ご利用ありがとうございました。' end);

  return jsonb_build_object(
    'withdrawn_at', now(),
    'expired_paid', coalesce(v_paid, 0),
    'expired_bonus', coalesce(v_bonus, 0),
    'earned_balance', coalesce(v_earned, 0),
    'payout_deadline', v_deadline
  );
end;
$$;

comment on function public.withdraw_account(text) is
  '退会(規約 第6条の2)。報酬コインは消滅させない。90日間はアプリから換金申請できる'
  '(最低申請額なし・全額一括)。期限後の文言は0127で訂正——'
  '「消滅します」は0107で事実と食い違ったまま残っていた誤り。';

revoke all on function public.withdraw_account(text) from public, anon;
grant execute on function public.withdraw_account(text) to authenticated;


-- >>>>>>>> 0128_guest_verification_required.sql
-- ============================================================
-- 0128: 予約時にゲスト側の本人確認も検査する
--
-- 規約 第3条1項は「本サービスの利用には……本人確認……の完了が必要」と
-- 定めており、**ホストとゲストを区別していない。**
--
-- ところが `create_booking` はホストの `is_verified` しか見ていなかった。
-- アプリの通常導線(signUp→consent→verify→setup)を経由すれば未確認のまま
-- 予約画面には到達しないが、**RPCを直接叩けば未確認のゲストでも予約できる**
-- 状態だった。「規約に書いてあるのに実装が無い」ものを全体的に洗い出す中で
-- 見つけた（`docs/legal/terms-implementation-matrix.md` 第3条1項の注記）。
--
-- ホスト側と同じ検査を1つ足すだけ。**予約を作る経路はここに集約されている**
-- (`create_booking_from_board`・`create_booking_from_request`・
-- `create_paired_booking` はいずれもこの関数を呼ぶだけで、検査を作り直して
-- いない)ので、直すのはここ1か所で足りる。
--
-- ⚠️ 本体は適用済みのDBから取り出したもの。差分はゲスト側の検査1つだけ。
-- ============================================================

create or replace function public.create_booking(p_host_id uuid, p_duration_minutes integer, p_policy_version text, p_scheduled_at timestamp with time zone, p_pair_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_verified boolean;
  v_guest_verified boolean;
  v_coins int;
  v_list_coins int;
  v_discount int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_lead int;
  v_start timestamptz;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  -- 0121: ブロック関係があれば予約させない。
  -- **0116 が「ブロック＝予約もトークも不可」と書いているのに、
  --   ここには検査が無かった。** create_booking_from_board(0113)だけが
  --   独自に見ていたので、板を経由しない経路は全部素通りだった。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_guest_id and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_guest_id)
  ) then
    raise exception 'BLOCKED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_lead) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hs.hourly_rate, hs.is_host into v_hourly_rate, v_is_host
  from public.host_settings hs where hs.user_id = p_host_id for share;
  if not coalesce(v_is_host, false) or v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  select pts.is_verified into v_verified
  from public.profile_trust_stats pts where pts.user_id = p_host_id;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  -- 0128: 規約第3条1項は「利用には本人確認の完了が必要」と定めており、
  -- ホスト・ゲストを区別していない。ところがここではホストの本人確認しか
  -- 見ておらず、**アプリの通常導線(signUp→consent→verify→setup)を経由すれば
  -- 未確認では予約画面に到達しないが、RPCを直接叩けば未確認のゲストでも
  -- 予約できていた。** ホスト側と同じ検査をゲスト側にも足すだけ。
  select pts.is_verified into v_guest_verified
  from public.profile_trust_stats pts where pts.user_id = v_guest_id;
  if not coalesce(v_guest_verified, false) then
    raise exception 'GUEST_NOT_VERIFIED';
  end if;

  v_start := coalesce(p_scheduled_at, now());

  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 常連への先行予約(0057)。開始まで遠い枠は、一緒に遊んだことのある人だけ。
  if not public.slot_open_to(p_host_id, v_guest_id, v_start) then
    raise exception 'REGULARS_FIRST';
  end if;

  perform public._lock_booking_slots(v_guest_id, p_host_id);

  if public._booking_slot_conflict(p_host_id, v_start, p_duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペア予約(同じゲスト・同じ時間で2人のホストに同時に申し込む)は、
  -- ここが無いと**自分自身の、もう片方への申し込み**を「重複」として
  -- 弾いてしまう。p_pair_id が同じ予約(=ペアの相方)だけ、この検査から除く
  -- (他のゲストの予約や、別のペアとは今までどおり衝突させる)。
  -- **_booking_slot_conflict は1件しか返さない**ので、ここは書き直さず
  -- 素の exists で「相方以外との重なり」だけを見る。
  if exists (
    select 1 from public.bookings b
    where b.status = any (array['requested', 'confirmed'])
      and (b.guest_id = v_guest_id or b.host_id = v_guest_id)
      and (p_pair_id is null or b.from_pair_id is distinct from p_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes),
            '[)')
          && tstzrange(v_start, v_start + make_interval(mins => p_duration_minutes), '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;
  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 有償を先に使い切るのではなく、**有効期限の早いロットから**充当する。
  -- 同一期限内では有償が先。詳細は 0082 の冒頭を参照。
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_guest_id, v_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, policy_version, policy_agreed_at,
    list_coins, discount_percent, requested_start_at, from_pair_id
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at, p_pair_id
  )
  returning id into v_booking_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$$;

comment on function public.create_booking(uuid, integer, text, timestamptz, uuid) is
  '予約の確定+コイン消費(0003)。0126でp_pair_idを追加、0128でゲスト側の本人確認検査を追加'
  '(規約第3条1項はホスト・ゲストを区別していない。ホスト側の検査しか無かった)。'
  '**単独では呼ばない。** create_paired_booking / create_booking_from_board / '
  'create_booking_from_request からだけ使う内部経路。';

revoke all on function public.create_booking(uuid, integer, text, timestamptz, uuid) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz, uuid) to authenticated;
