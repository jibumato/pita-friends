-- ============================================================
-- ホスト向けダッシュボードの集計
-- ------------------------------------------------------------
-- 「頑張れる目標が見つかる」ことを目的にした集計。既存データから導出でき、
-- 実在する数字だけを返す。集計はすべて JST の暦月を基準にする。
--
-- ⚠️ ここに金額ベースの「ランキング(他人との順位)」は含めない。
--    弁護士見解(Q11-d)で「投げ銭ランキング・人気ランキングは
--    『人気女性への金銭提供サービス』と見られ危険」と明確に指摘されており、
--    既存の host_ranking も金額を一切スコアに入れていない。
--    ここで返すのは**自分自身の実績**だけ。
-- ============================================================

create function public.host_dashboard(p_at timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_ticket int;
  v_gift int;
  v_fee int;
  v_next_bound int;
  v_cur_rate numeric;
  v_next_rate numeric;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- JSTの当月[start, end)
  v_start := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) at time zone 'Asia/Tokyo');
  v_end   := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) + interval '1 month')
             at time zone 'Asia/Tokyo';

  v_ticket := public.host_monthly_ticket_gmv(v_uid, p_at);

  select coalesce(sum(pf.gross_coins), 0)::int into v_gift
  from public.platform_fees pf
  where pf.host_id = v_uid and pf.kind = 'gift'
    and pf.created_at >= v_start and pf.created_at < v_end;

  select coalesce(sum(pf.fee_coins), 0)::int into v_fee
  from public.platform_fees pf
  where pf.host_id = v_uid
    and pf.created_at >= v_start and pf.created_at < v_end;

  -- 次のティア(超過累進の次の段)
  select t.upper_bound, t.rate into v_next_bound, v_cur_rate
  from public.host_fee_tiers t
  where t.upper_bound is null or v_ticket < t.upper_bound
  order by t.step
  limit 1;

  select t.rate into v_next_rate
  from public.host_fee_tiers t
  where t.step = (
    select min(step) + 1 from public.host_fee_tiers
    where upper_bound is null or v_ticket < upper_bound
  );

  v_result := jsonb_build_object(
    'month_start', v_start,
    'ticket_coins', v_ticket,
    'gift_coins', v_gift,
    'gross_coins', v_ticket + v_gift,
    'fee_coins', v_fee,
    'net_coins', (v_ticket + v_gift) - v_fee,
    'effective_rate', case when (v_ticket + v_gift) > 0
                           then round(v_fee::numeric / (v_ticket + v_gift), 4) else 0 end,
    'tier', jsonb_build_object(
      'current_rate', v_cur_rate,
      'next_bound', v_next_bound,
      'next_rate', v_next_rate,
      'remaining_coins', case when v_next_bound is null then null
                              else greatest(0, v_next_bound - v_ticket) end
    )
  );

  -- 日別の売上(予約の確定額)
  v_result := v_result || jsonb_build_object('daily', coalesce((
    select jsonb_agg(jsonb_build_object('day', d.day, 'coins', d.coins) order by d.day)
    from (
      select extract(day from (b.scheduled_at at time zone 'Asia/Tokyo'))::int as day,
             sum(b.coins)::int as coins
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
      group by 1
    ) d
  ), '[]'::jsonb));

  -- 指名リピート(金額ベース)と人数
  v_result := v_result || (
    select jsonb_build_object(
      'repeat', jsonb_build_object(
        'repeat_coins', coalesce(sum(x.coins) filter (where x.is_repeat), 0)::int,
        'total_coins', coalesce(sum(x.coins), 0)::int,
        'repeat_rate', case when coalesce(sum(x.coins), 0) > 0
          then round(coalesce(sum(x.coins) filter (where x.is_repeat), 0)::numeric / sum(x.coins), 4)
          else 0 end,
        -- 「リピーター」は当月に2回目以降の予約が1件でもあるゲスト。
        -- 「新規」は残り。初回と2回目が同じ月にあるゲストを両方に数えないよう、
        -- 差し引きで出す(単純に filter で数えると二重計上になる)。
        'repeater_guests', count(distinct x.guest_id) filter (where x.is_repeat),
        'new_guests', count(distinct x.guest_id)
                      - count(distinct x.guest_id) filter (where x.is_repeat)
      ))
    from (
      select b.guest_id, b.coins,
             exists (
               select 1 from public.bookings p
               where p.host_id = b.host_id and p.guest_id = b.guest_id
                 and p.status = 'completed' and p.scheduled_at < b.scheduled_at
             ) as is_repeat
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
    ) x
  );

  -- 成約率と初回応答の速さ
  -- 承諾されたかどうかは promises の有無で判定する(promiseは approve_booking でしか作られない)
  v_result := v_result || (
    select jsonb_build_object(
      'response', jsonb_build_object(
        'requests', count(*),
        'approved', count(*) filter (where pr.id is not null),
        'approval_rate', case when count(*) > 0
          then round(count(*) filter (where pr.id is not null)::numeric / count(*), 4) else 0 end,
        'median_reply_seconds', percentile_cont(0.5) within group (
          order by extract(epoch from (b.scheduled_at - b.created_at))
        ) filter (where pr.id is not null)
      ))
    from public.bookings b
    left join public.promises pr on pr.booking_id = b.id
    where b.host_id = v_uid
      and b.created_at >= v_start and b.created_at < v_end
  );

  -- 埋まりやすい時間帯(直近4週に自分へ届いたリクエストの 曜日×時間)
  v_result := v_result || jsonb_build_object('heatmap', coalesce((
    select jsonb_agg(jsonb_build_object('dow', h.dow, 'hour', h.hour, 'count', h.c))
    from (
      select extract(isodow from (b.created_at at time zone 'Asia/Tokyo'))::int as dow,
             extract(hour   from (b.created_at at time zone 'Asia/Tokyo'))::int as hour,
             count(*)::int as c
      from public.bookings b
      where b.host_id = v_uid
        and b.created_at >= p_at - interval '28 days'
      group by 1, 2
    ) h
  ), '[]'::jsonb));

  return v_result;
end;
$$;

comment on function public.host_dashboard(timestamptz) is
  'ホスト向けダッシュボードの集計(自分自身の実績のみ)。JSTの暦月基準。金額ベースの他人との順位は意図的に含めない(弁護士Q11-d)。';

revoke all on function public.host_dashboard(timestamptz) from public;
grant execute on function public.host_dashboard(timestamptz) to authenticated;
