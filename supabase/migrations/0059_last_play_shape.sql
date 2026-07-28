-- ============================================================
-- 0059_last_play_shape.sql
-- 「前回と同じ条件」を出せるようにする
-- ------------------------------------------------------------
-- 続けて遊ぶ相手が決まっているのに、毎回ゼロから時間と長さを選び直させている。
-- 決まりきった相手・決まりきった曜日でも、予約のたびに同じ操作をさせられる。
-- ここが面倒だと「まあ今週はいいか」で終わる。値引きより、この摩擦を取るほうが
-- 繰り返しには効く。
--
-- 0055 の my_play_history_with に、前回の**長さ**と**日時**を足すだけ。
-- 画面側はこれを見て「前回と同じ(金22時・60分)」を1タップで出せる。
--
-- 自分が当事者の予約しか見ない点は0055のまま。ここを緩めると、他人同士が
-- いつ何分遊んでいるかまで読めるようになる。
-- ============================================================

create or replace function public.my_play_history_with(p_other uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select b.duration_minutes,
           coalesce(b.confirmed_at, b.scheduled_at) as played_at,
           b.scheduled_at
    from public.bookings b
    where b.status = 'completed'
      -- **自分が当事者である予約に限る。** ここを外すと他人同士の回数が引ける。
      and (
        (b.guest_id = auth.uid() and b.host_id = p_other)
        or (b.host_id = auth.uid() and b.guest_id = p_other)
      )
  ),
  last_one as (
    select * from mine order by played_at desc limit 1
  )
  select jsonb_build_object(
    'count', (select count(*) from mine),
    'last_played_at', (select max(played_at) from mine),
    -- 前回の長さと開始時刻。「前回と同じ」の材料にする
    'last_duration_minutes', (select duration_minutes from last_one),
    'last_scheduled_at', (select scheduled_at from last_one)
  );
$$;

comment on function public.my_play_history_with(uuid) is
  '自分とこの相手が一緒に遊んだ回数・最後に遊んだ日と、前回の長さ・開始時刻。自分が当事者の予約しか見ない。0059で前回の条件を追加。';

revoke all on function public.my_play_history_with(uuid) from public;
grant execute on function public.my_play_history_with(uuid) to authenticated;
