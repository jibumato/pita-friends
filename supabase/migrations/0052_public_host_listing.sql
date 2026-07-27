-- ============================================================
-- 0052_public_host_listing.sql
-- 未ログインの訪問者に「掲載中のピタメイト」だけを見せる
-- ------------------------------------------------------------
-- これまで profiles / host_settings のRLSは to authenticated で、
-- ログインしていない訪問者にはピタメイトが1件も返らなかった。
-- そのためトップに人を出せず、「見つける→興味が湧く→登録」という
-- 導線が成立しなかった(ピタメイトがSNSにURLを貼っても中身が出ない)。
--
-- **RLSは緩めない。** テーブルを直接読めるようにすると、掲載していない
-- 利用者の情報まで芋づるで出る。代わりに、掲載カードに必要な項目だけを
-- 返す関数を用意し、そこにだけ anon の実行権を渡す。
--
-- 出さないもの(意図的):
--   ・性別、last_seen_at、presence_status(いま誰がオンラインかは、
--     未ログインの相手に教える必要が無い。付きまといの材料になる)
--   ・ボイスあいさつ(ストレージを公開せずに済ませる)
--   ・掲載していない利用者、本人確認前の利用者、掲載を望まない利用者
-- ============================================================

-- ------------------------------------------------------------
-- public_host_cards(): 掲載中のピタメイトのカード情報
-- ------------------------------------------------------------
drop function if exists public.public_host_cards(int);

create or replace function public.public_host_cards(p_limit int default 24)
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
  is_verified boolean
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
         coalesce(ts.is_verified, false)
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  left join public.profile_trust_stats ts on ts.user_id = h.user_id
  left join public.safety_prefs sp on sp.user_id = h.user_id
  where h.is_host = true
    -- 掲載条件は本人確認済み(0003のトリガーと同じ条件)。
    -- 未確認の人が公開の場に出ることが無いよう、ここでも確かめる。
    and coalesce(ts.is_verified, false) = true
    -- 本人が「さがすに出さない」を選んでいれば、公開の場にも出さない。
    -- 設定が未作成なら既定(true)として扱う。
    and coalesce(sp.discoverable, true) = true
  order by coalesce(ts.manner_score, 4.50) desc, coalesce(ts.review_count, 0) desc, h.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;

-- ------------------------------------------------------------
-- ランキングも未ログインで見せる
-- ------------------------------------------------------------
-- host_ranking は元から security definer で、返すのは順位・名前・アバター・
-- 完了数・マナースコアのみ(金額は含まない)。掲載カードと同じ性質なので、
-- 実行権を anon にも渡す。
grant execute on function public.host_ranking(text, int) to anon;

comment on function public.host_ranking(text, int) is
  'ホストのデイリー/ウィークリー/マンスリーランキング。スコア=完了予約数×品質(manner_score)×信頼性。金額(投げ銭・稼ぎ)は一切含めない(弁護士Q11(d))。0037でavatar_pathを追加。0052で未ログインにも公開。';
