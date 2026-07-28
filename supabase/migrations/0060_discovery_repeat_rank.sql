-- ============================================================
-- 0060_discovery_repeat_rank.sql
-- 「また呼ばれているか」を掲載順に入れる
-- ------------------------------------------------------------
-- 「さがす」の一覧には**並び順が無かった**(is_host で絞るだけで order 句なし)。
-- 未ログイン向けの掲載カードはマナースコア順で、こちらは「1回来た人」を
-- 何度数えても上がる指標だった。
--
-- 掲載順は予約数に直結するので、実質いちばん大きな報酬でもある。
-- そこを「また呼ばれているか」で決めれば、常連を大事にすることがそのまま
-- 新規の流入につながる。指標としても素直で、レビューを稼ぐより偽装しにくい。
--
-- ■ 小さい母数をどう扱うか(ここが肝)
--   素のリピート率は、1人来て1回また来ただけで100%になる。それを上位に
--   置くと、実績のある人が下がって順位が壊れる。
--   ベイズ平均で丸める:
--     score = (repeat_guests + m * prior) / (guests + m)   … m=5, prior=0.25
--   こうすると、
--     ・まだ誰も来ていない人      → 0.25(不明であって、悪いではない)
--     ・1人来て1回リピート        → 0.375(上がるが独占はしない)
--     ・10人中8人がリピート       → 0.617
--     ・10人来て誰も戻らなかった  → 0.083(新規より下)
--   「実績が無い」を「実績が悪い」と同じ扱いにしないことが大事で、
--   でなければ始めたばかりの人が永久に埋もれる。
--
-- ■ 金額は使わない
--   稼いだ額・投げ銭額は一切入れない(弁護士Q11(d))。使うのは人数だけ。
-- ============================================================

-- ------------------------------------------------------------
-- host_repeat_stats(): まとめて「来た人数・戻った人数・丸めた率」を返す
-- ------------------------------------------------------------
-- 0058 の host_repeat_guest_counts を置き換える(人数だけでは並べられないため)。
drop function if exists public.host_repeat_guest_counts(uuid[]);

create or replace function public.host_repeat_stats(p_host_ids uuid[])
returns table (host_id uuid, guests int, repeat_guests int, repeat_score numeric)
language sql
stable
security definer
set search_path = public
as $$
  with c_const as (select 5.0::numeric as m, 0.25::numeric as prior),
  per_guest as (
    select b.host_id, b.guest_id, count(*) as n
    from public.bookings b
    where b.status = 'completed'
      and b.host_id = any (coalesce(p_host_ids, '{}'::uuid[]))
    group by b.host_id, b.guest_id
  ),
  agg as (
    select pg.host_id,
           count(*)::int as guests,
           count(*) filter (where pg.n >= 2)::int as repeat_guests
    from per_guest pg
    group by pg.host_id
  )
  select h.id,
         coalesce(a.guests, 0),
         coalesce(a.repeat_guests, 0),
         round(
           (coalesce(a.repeat_guests, 0) + k.m * k.prior) / (coalesce(a.guests, 0) + k.m),
           4)
  from unnest(coalesce(p_host_ids, '{}'::uuid[])) as h(id)
  cross join c_const k
  left join agg a on a.host_id = h.id;
$$;

comment on function public.host_repeat_stats(uuid[]) is
  'ピタメイトごとの「来た人数・2回以上来た人数・丸めたリピート率」。誰かは返さない。金額は含まない(弁護士Q11(d))。母数が小さいときはベイズ平均で0.25へ寄せる。';

revoke all on function public.host_repeat_stats(uuid[]) from public;
grant execute on function public.host_repeat_stats(uuid[]) to anon, authenticated;

-- ------------------------------------------------------------
-- 掲載カードもこの順に並べる
-- ------------------------------------------------------------
-- 未ログインとログイン後で並びが違うと、登録した瞬間に一覧が入れ替わって
-- 「さっき見た人がいない」になる。同じ式を使う。
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
  status_updated_at timestamptz,
  repeat_guests int
)
language sql
security definer
set search_path = public
stable
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
    select l.*, r.repeat_guests, r.repeat_score
    from listed l
    join public.host_repeat_stats(array(select user_id from listed)) r on r.host_id = l.user_id
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
           s.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。0056でひとこと、0058でリピーター数、0060で「また呼ばれているか」順に並べる。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;
