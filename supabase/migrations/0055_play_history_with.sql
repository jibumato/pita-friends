-- ============================================================
-- 0055_play_history_with.sql
-- 「この人とは何回遊んだか」を返す
-- ------------------------------------------------------------
-- プロフィールに出ている「一緒に遊んだ」はその人の**通算**の回数で、
-- 見ている自分との関係は何も表していない。3回一緒に遊んだ相手も、
-- 今日はじめて見た相手も、同じ画面に見える。
--
-- お気に入りに入れてもらうには、積み上がっているものが本人に見えている必要がある。
-- 「あなたとは3回目」と出れば、次も同じ人に頼む理由になる。
--
-- 気をつけたこと:
--   ・**自分が関わった予約しか数えない。** 他人同士の回数は返さない
--     (第三者の交友関係が読めてしまう)。
--   ・完了した予約だけを数える。キャンセルや無断欠席は入れない。
--   ・向きは問わない。ゲストとして遊んだ回とピタメイトとして遊んだ回を
--     合算する(同じ相手との回数であることに変わりはない)。
-- ============================================================

create or replace function public.my_play_history_with(p_other uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'count', count(*),
    'last_played_at', max(coalesce(b.confirmed_at, b.scheduled_at))
  )
  from public.bookings b
  where b.status = 'completed'
    -- **自分が当事者である予約に限る。** ここを外すと他人同士の回数が引ける。
    and (
      (b.guest_id = auth.uid() and b.host_id = p_other)
      or (b.host_id = auth.uid() and b.guest_id = p_other)
    );
$$;

comment on function public.my_play_history_with(uuid) is
  '自分とこの相手が一緒に遊んだ回数と、最後に遊んだ日。自分が当事者の予約しか数えない。';

revoke all on function public.my_play_history_with(uuid) from public;
grant execute on function public.my_play_history_with(uuid) to authenticated;
