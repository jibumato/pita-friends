-- ============================================================
-- 0056_host_status.sql
-- ピタメイトの「ひとこと」(近況)
-- ------------------------------------------------------------
-- 推しがいる人がホームに来る目的は「その人の様子を見ること」なのに、
-- 今のホームには**更新されるものが何も無い**。名前も料金もプロフィール文も
-- 昨日と同じで、開く理由が続かない。
--
-- 既にある bio(200字)は自己紹介で、書き換える性質のものではない。
-- 別に、短くて頻繁に書き換わる欄をひとつ持たせる。
--
-- 設計で気をつけたこと:
--   ・**60字まで。** 長くすると自己紹介と同じになり、書き換えられなくなる。
--   ・**古いひとことは出さない。** 「今日は21時から!」が2か月前のものだと、
--     何も無いより悪い。14日を過ぎたものは返さない(消しはしない。本人には
--     見えていて、書き直せばまた出る)。
--   ・**通知は出さない。** 0054で枠の通知を24時間に1回まで絞ったのに、
--     ひとことで毎回鳴らしたら同じことになる。ホームで見えれば足りる。
--   ・掲載条件(掲載中・本人確認済み・さがすに出す)を満たす人のものだけを
--     公開の場に返す。カードに出る他の項目と同じ扱いにする。
-- ============================================================

alter table public.host_settings
  add column if not exists status_text text,
  add column if not exists status_updated_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'host_settings_status_text_len'
  ) then
    alter table public.host_settings
      add constraint host_settings_status_text_len
      check (status_text is null or char_length(status_text) <= 60);
  end if;
end $$;

comment on column public.host_settings.status_text is
  'ピタメイトの「ひとこと」(近況)。60字まで。14日を過ぎたものは公開の場には出さない。';
comment on column public.host_settings.status_updated_at is
  'ひとことを最後に書き換えた時刻。「3時間前」の表示と、古いものを隠す判定に使う。';

-- ------------------------------------------------------------
-- set_host_status(): 自分のひとことを書き換える
-- ------------------------------------------------------------
create or replace function public.set_host_status(p_text text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_clean text;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 前後の空白と改行を落とす。改行を許すと1行の表示欄が崩れる
  v_clean := nullif(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), '');
  if v_clean is not null and char_length(v_clean) > 60 then
    raise exception 'STATUS_TOO_LONG';
  end if;

  -- ひとことは掲載設定の一部。まだ host_settings が無い人にも書けるようにする
  insert into public.host_settings (user_id, status_text, status_updated_at)
  values (v_uid, v_clean, case when v_clean is null then null else v_now end)
  on conflict (user_id) do update
    set status_text = excluded.status_text,
        -- 消したときは時刻も消す(「0分前に空を投稿」を出さないため)
        status_updated_at = case when excluded.status_text is null then null else v_now end;

  return case when v_clean is null then null else v_now end;
end;
$$;

comment on function public.set_host_status(text) is
  '自分の「ひとこと」を書き換える。空文字を渡すと消える。60字まで。';

revoke all on function public.set_host_status(text) from public;
grant execute on function public.set_host_status(text) to authenticated;

-- ------------------------------------------------------------
-- 公開の場に出すときの共通判定
-- ------------------------------------------------------------
-- 同じ「14日」をカードと一覧とプロフィールに三度書くと、いずれ食い違う。
create or replace function public.fresh_host_status(p_text text, p_at timestamptz)
returns text
language sql
-- now() を見るので immutable にはできない(定数として畳まれ、古いひとことが
-- いつまでも出続ける)。
stable
set search_path = public
as $$
  select case
    when p_text is null or p_at is null then null
    when p_at < now() - interval '14 days' then null
    else p_text
  end;
$$;

comment on function public.fresh_host_status(text, timestamptz) is
  'ひとことを公開の場に出してよいか判定する。14日を過ぎたものは null を返す。';

grant execute on function public.fresh_host_status(text, timestamptz) to anon, authenticated;

-- ------------------------------------------------------------
-- 掲載カード・推し一覧にひとことを載せる
-- ------------------------------------------------------------
-- 戻り値の型が変わるので、作り直す(create or replace では変えられない)。
drop function if exists public.public_host_cards(int);

create function public.public_host_cards(p_limit int default 24)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  bio text,
  manner_score numeric,
  review_count int,
  is_verified boolean,
  status_text text,
  status_updated_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select h.user_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         h.hourly_rate,
         h.games,
         h.bio,
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         public.fresh_host_status(h.status_text, h.status_updated_at),
         case when public.fresh_host_status(h.status_text, h.status_updated_at) is null
              then null else h.status_updated_at end
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  left join public.profile_trust_stats ts on ts.user_id = h.user_id
  left join public.safety_prefs sp on sp.user_id = h.user_id
  where h.is_host = true
    and coalesce(ts.is_verified, false) = true
    and coalesce(sp.discoverable, true) = true
  order by coalesce(ts.manner_score, 4.50) desc, coalesce(ts.review_count, 0) desc, h.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。0056でひとことを追加。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;

drop function if exists public.my_favorites();

create function public.my_favorites()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  manner_score numeric,
  review_count int,
  is_verified boolean,
  is_active boolean,
  favorited_at timestamptz,
  status_text text,
  status_updated_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select f.host_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         coalesce(h.hourly_rate, 0),
         coalesce(h.games, '{}'),
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         coalesce(h.is_host, false)
           and coalesce(ts.is_verified, false)
           and coalesce(sp.discoverable, true),
         f.created_at,
         public.fresh_host_status(h.status_text, h.status_updated_at),
         case when public.fresh_host_status(h.status_text, h.status_updated_at) is null
              then null else h.status_updated_at end
  from public.favorites f
  join public.profiles p on p.id = f.host_id
  left join public.host_settings h on h.user_id = f.host_id
  left join public.profile_trust_stats ts on ts.user_id = f.host_id
  left join public.safety_prefs sp on sp.user_id = f.host_id
  where f.user_id = auth.uid()
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = f.host_id)
         or (b.blocker_id = f.host_id and b.blocked_id = auth.uid())
    )
  order by f.created_at desc;
$$;

comment on function public.my_favorites() is
  '自分が推しているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からない)。0056でひとことを追加。';

revoke all on function public.my_favorites() from public;
grant execute on function public.my_favorites() to authenticated;
