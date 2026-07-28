-- ============================================================
-- 0058_repeat_proof.sql
-- 「また呼ばれている」ことを見せる
-- ------------------------------------------------------------
-- いま公開されている実績は マナースコア・レビュー件数・通算のプレイ回数 で、
-- **どれも「1回来た人」を何度数えても増える**。初めてのゲストから見ると、
-- 100人が1回ずつ来たピタメイトと、10人が10回ずつ来たピタメイトが同じに見える。
--
-- 後者を選びたい人は多いはずで、しかも後者こそがこのサービスが機能している
-- 状態そのものだ。リピーターの数を出せば、常連を大事にすることが
-- そのまま新規の獲得につながる。
--
-- 気をつけたこと:
--   ・**金額は一切出さない。** 弁護士Q11(d)の方針をここでも守る。
--   ・**誰がリピーターかは返さない。** 返すのは人数だけ。誰と誰が繰り返し
--     遊んでいるかが読めると、0053・0055で閉じた穴がここから開く。
--   ・**0人のときは何も出さない**(フロント側の判断)。始めたばかりの人に
--     「リピーター0人」を貼るのは、0056で新規を守った方針と逆になる。
-- ============================================================

-- ------------------------------------------------------------
-- host_repeat_guests(): 2回以上遊んでくれた人の数
-- ------------------------------------------------------------
create or replace function public.host_repeat_guests(p_host_id uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from (
    select b.guest_id
    from public.bookings b
    where b.host_id = p_host_id and b.status = 'completed'
    group by b.guest_id
    having count(*) >= 2
  ) r;
$$;

comment on function public.host_repeat_guests(uuid) is
  'そのピタメイトと2回以上遊んだ人の数。人数だけで、誰かは返さない。金額は含まない(弁護士Q11(d))。';

revoke all on function public.host_repeat_guests(uuid) from public;
grant execute on function public.host_repeat_guests(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- host_repeat_guest_counts(): 一覧向けにまとめて取る
-- ------------------------------------------------------------
-- 「さがす」は数十人を一度に出すので、1人ずつ問い合わせると往復が増える。
create or replace function public.host_repeat_guest_counts(p_host_ids uuid[])
returns table (host_id uuid, repeat_guests int)
language sql
stable
security definer
set search_path = public
as $$
  select h.id, coalesce(r.n, 0)::int
  from unnest(coalesce(p_host_ids, '{}'::uuid[])) as h(id)
  left join (
    select g.host_id, count(*) as n
    from (
      select b.host_id, b.guest_id
      from public.bookings b
      where b.status = 'completed'
        and b.host_id = any (coalesce(p_host_ids, '{}'::uuid[]))
      group by b.host_id, b.guest_id
      having count(*) >= 2
    ) g
    group by g.host_id
  ) r on r.host_id = h.id;
$$;

comment on function public.host_repeat_guest_counts(uuid[]) is
  '複数のピタメイトについて、2回以上遊んだ人の数をまとめて返す。誰かは返さない。';

revoke all on function public.host_repeat_guest_counts(uuid[]) from public;
grant execute on function public.host_repeat_guest_counts(uuid[]) to anon, authenticated;

-- ------------------------------------------------------------
-- 掲載カードにも載せる
-- ------------------------------------------------------------
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
              then null else h.status_updated_at end,
         public.host_repeat_guests(h.user_id)
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
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。0056でひとこと、0058でリピーター数を追加。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;
