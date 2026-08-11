-- ============================================================
-- 0114: 募集に「受付の範囲」を持たせる
--
-- ■ 直前の状態
--   `0113` で募集板をピタメイト専用にしたが、日時は `when_text` の自由記述
--   （画面では3択 `WHENS = ['今夜 22:00〜', '明日 21:00〜', '日時を指定']`）
--   のままだった。
--
--   ここには2つ問題があった。
--     ① **「日時を指定」を選んでも、日時を入れる欄が無い。** 投稿にそのまま
--        「日時を指定」という文字列が入る
--     ② **書いた内容と予約画面が無関係。** 「今夜22時〜」と書いてあっても、
--        ゲストは翌日の昼を選べてしまう
--
-- ■ 1点の日時ではなく「範囲」にする理由
--   1点固定だと硬すぎる。22:00ちょうどしか取れないと、少しズレただけで
--   成立せず、1件の募集で1人しか拾えない。
--   範囲なら、**広く取れば「相談で」・狭く取れば「この時間だけ」**になり、
--   柔軟さの度合いをピタメイト自身が決められる。
--
--     window_start / window_end がどちらも null … 日時は相談で
--     8/12 20:00 〜 8/12 24:00               … その日の夜のあいだで
--     8/15 00:00 〜 8/17 24:00               … その週末のどこかで
--
-- ■ 遊べる時間帯の枠（`set_host_availability`）とは別物
--   枠は「毎週この曜日のこの時間」。募集の範囲は「今回この日程で募集します」。
--   **予約は両方を満たす必要がある**（枠は `create_booking` が見ている）。
--   枠の外に範囲を書くと予約画面で全部弾かれるので、画面側で警告を出す。
--   ただし**ここでは弾かない**——枠を後から足す運用があるため。
--
-- ■ 期限切れを自動で下ろす
--   いまは「今夜」と書いた募集が1週間残る。`window_end` があれば過ぎたものを
--   閉じられる。**板が死んだ投稿で埋まるのは、公開直後にいちばん効く問題。**
-- ============================================================

alter table public.board_posts
  add column if not exists window_start timestamptz,
  add column if not exists window_end timestamptz;

-- 片方だけ入っている状態を作らない。範囲として意味を成さない
alter table public.board_posts
  drop constraint if exists board_posts_window_pair;
alter table public.board_posts
  add constraint board_posts_window_pair
  check (
    (window_start is null and window_end is null)
    or (window_start is not null and window_end is not null and window_end > window_start)
  );

comment on column public.board_posts.window_start is
  '受付を開始する日時。null なら「相談で」(0114)。';
comment on column public.board_posts.window_end is
  '受付を締め切る日時。null なら「相談で」(0114)。過ぎた募集は close_expired_board_posts が閉じる。';

create index if not exists board_posts_window_end_idx
  on public.board_posts (window_end) where status = 'open' and window_end is not null;

-- ------------------------------------------------------------
-- 範囲の中でしか申し込めないようにする
-- ------------------------------------------------------------
create or replace function public.create_booking_from_board(
  p_post_id uuid,
  p_policy_version text,
  p_scheduled_at timestamptz default null,
  p_duration_minutes int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_verified boolean;
  v_my_gender text;
  v_creator_gender text;
  v_booking_id uuid;
  v_minutes int;
  v_end timestamptz;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_uid then
    raise exception 'CANNOT_BOOK_OWN_POST';
  end if;

  -- 板の側の条件（0011 から引き継ぐ）
  if v_post.verified_only then
    select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
    if not coalesce(v_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_my_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  v_minutes := coalesce(p_duration_minutes, v_post.duration_minutes);

  -- 0114: 範囲が指定されている募集は、その中に**収まる**こと。
  -- 開始だけ範囲内で終わりがはみ出す申込みは、告知した時間を超えるので通さない
  if v_post.window_start is not null then
    if p_scheduled_at is null then
      raise exception 'START_TIME_REQUIRED';
    end if;
    v_end := p_scheduled_at + make_interval(mins => v_minutes);
    if p_scheduled_at < v_post.window_start or v_end > v_post.window_end then
      raise exception 'OUTSIDE_BOARD_WINDOW';
    end if;
    -- 締め切りを過ぎた募集は、cron が閉じる前でも受け付けない
    if now() >= v_post.window_end then
      raise exception 'BOARD_WINDOW_PASSED';
    end if;
  end if;

  v_booking_id := public.create_booking(
    v_post.creator_id,
    v_minutes,
    p_policy_version,
    p_scheduled_at
  );

  update public.bookings set from_board_post_id = p_post_id where id = v_booking_id;
  update public.board_posts set status = 'closed' where id = p_post_id;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_board(uuid, text, timestamptz, int) is
  '募集板から予約を申し込む(0113、0114で受付の範囲を追加)。範囲が指定されている募集は、開始から終了まで範囲に収まる申込みだけを通す。板の条件を見たうえで create_booking をそのまま呼ぶ(リードタイム・枠・重複・残高の検証は向こうに集約)。申込みが入ったら募集は closed。';

revoke all on function public.create_booking_from_board(uuid, text, timestamptz, int) from public, anon;
grant execute on function public.create_booking_from_board(uuid, text, timestamptz, int) to authenticated;

-- ------------------------------------------------------------
-- 締め切りを過ぎた募集を閉じる
--
-- **取り消し(cancelled)ではなく closed。** 投稿者が下ろしたわけではないので、
-- 取り消しと同じ状態にすると、あとから「なぜ消えたか」が読めなくなる。
-- 申込みが入って締まったのと同じ扱いにする。
-- ------------------------------------------------------------
create or replace function public.close_expired_board_posts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update public.board_posts
    set status = 'closed'
    where status = 'open'
      and window_end is not null
      and window_end <= now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.close_expired_board_posts() is
  '受付の締め切りを過ぎた募集を閉じる(0114)。cancelled ではなく closed にする(投稿者が下ろしたわけではないため)。';

revoke all on function public.close_expired_board_posts() from public, anon, authenticated;

select cron.unschedule('close-expired-board-posts')
  where exists (select 1 from cron.job where jobname = 'close-expired-board-posts');

-- 15分おき。締め切りちょうどに消える必要は無いが、
-- 1時間も残ると「もう終わった募集」を押させてしまう
select cron.schedule('close-expired-board-posts', '*/15 * * * *',
  $cron$select public.close_expired_board_posts();$cron$);

-- ------------------------------------------------------------
-- 運営の一覧にも範囲を出す
-- ------------------------------------------------------------
drop function if exists public.admin_board_posts(text, int);

create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  duration_minutes int,
  window_start timestamptz,
  window_end timestamptz,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  bookings int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.duration_minutes,
    b.window_start,
    b.window_end,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.bookings bk where bk.from_board_post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0114で受付の範囲を追加。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;
