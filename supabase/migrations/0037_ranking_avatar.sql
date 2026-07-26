-- ============================================================
-- ホストランキングにプロフィール写真を含める
-- ------------------------------------------------------------
-- host_ranking() が avatar_path を返していなかったため、フロントは常に
-- 頭文字+カラーのプレースホルダーしか表示できなかった(実写真があっても
-- 反映されない)。avatar_path を追加で返し、フロント側で公開URLに変換する。
-- 戻り値の列を追加するため、関数を一度dropしてから再作成する。
-- ============================================================

drop function if exists public.host_ranking(text, int);

create function public.host_ranking(p_period text default 'weekly', p_limit int default 30)
returns table (
  rank bigint,
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  completed_count bigint,
  manner_score numeric,
  score numeric,
  is_verified boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with win as (
    select case p_period
             when 'daily'   then date_trunc('day',   (now() at time zone 'Asia/Tokyo'))
             when 'weekly'  then date_trunc('week',  (now() at time zone 'Asia/Tokyo'))
             when 'monthly' then date_trunc('month', (now() at time zone 'Asia/Tokyo'))
             else date_trunc('week', (now() at time zone 'Asia/Tokyo'))
           end as start_jst
  ),
  agg as (
    select b.host_id,
           count(*) filter (where b.status = 'completed') as completed,
           count(*) filter (where b.status in ('cancelled_by_host', 'no_show_host')) as host_cancel
    from public.bookings b, win
    where (b.scheduled_at at time zone 'Asia/Tokyo') >= win.start_jst
    group by b.host_id
    having count(*) filter (where b.status = 'completed') > 0
  ),
  scored as (
    select a.host_id,
           a.completed,
           round(
             a.completed
             * (coalesce(ts.manner_score, 4.50) / 5.0)
             * (a.completed::numeric / nullif(a.completed + a.host_cancel, 0)),
             2
           ) as score,
           coalesce(ts.manner_score, 4.50) as manner_score,
           coalesce(ts.is_verified, false) as is_verified
    from agg a
    left join public.profile_trust_stats ts on ts.user_id = a.host_id
  )
  select row_number() over (order by s.score desc, s.completed desc) as rank,
         s.host_id,
         p.nickname,
         p.avatar_initial,
         p.avatar_color,
         p.avatar_path,
         s.completed as completed_count,
         s.manner_score,
         s.score,
         s.is_verified
  from scored s
  join public.profiles p on p.id = s.host_id
  order by s.score desc, s.completed desc
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

comment on function public.host_ranking(text, int) is
  'ホストのデイリー/ウィークリー/マンスリーランキング。スコア=完了予約数×品質(manner_score)×信頼性。金額(投げ銭・稼ぎ)は一切含めない(弁護士Q11(d))。0037でavatar_pathを追加(ランキングに写真を表示するため)。';

revoke all on function public.host_ranking(text, int) from public;
grant execute on function public.host_ranking(text, int) to authenticated;
