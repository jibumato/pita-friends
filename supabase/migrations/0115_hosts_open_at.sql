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
