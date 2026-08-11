-- ============================================================
-- 0113: 募集板を「ピタメイトがゲストを呼ぶ場」に作り直す
--
-- ■ これまで
--   `0011` の募集板は**誰でも投稿でき、誰でも無料で参加表明できる**掲示板だった。
--   「今夜Apexを一緒に」を出して、定員まで人が集まったら締め切る、という形。
--   コインは一切動かない。
--
-- ■ これから
--   **掲載中のピタメイトだけが投稿でき、ゲストは予約の申込みに進む。**
--   募集は「この条件で空いています」という告知で、入口は予約に繋がる。
--
-- ■ ★なぜ「参加表明」を残さないか（ここがいちばん大事）
--   投稿をピタメイトに限ったうえで無料の参加表明を残すと、
--   **板の上に「ピタメイトと無料で遊べる経路」ができる。**
--   ピタフレの役務は予約＝有償で成り立っており、
--     ・税務（対価を得て提供する役務）
--     ・規約 第8条（役務提供契約はゲストとピタメイトの間に成立し、対価が発生する）
--     ・プラットフォーム利用料の徴収
--   のすべてがその前提に乗っている。無料の抜け道を board に作ると、
--   **いちばん使われる導線がその抜け道になる。**
--   なので `join_board_post` は廃止し、`board_participants` ごと落とす。
--
-- ■ capacity を落とす理由
--   予約は1対1（`create_booking(p_host_id, ...)`）。定員3の募集に3人来たら
--   「同時に3人と遊ぶ」のか「3人ぶんの別々の枠」なのか、誰にも分からない。
--   **1募集＝1つの空き枠**にそろえる。
--
-- ■ 料金を投稿に持たせない
--   `host_settings.hourly_rate` から出す。投稿に写すと、料金を変えたときに
--   板だけ古い額を出し続ける。申込前の価格表示なので、ずれると景表法の問題になる。
--
-- ■ 日時は自由記述のまま
--   `when_text`（「今夜 22:00〜」等）は目安として残す。実際の日時は
--   予約画面で選び、`create_booking` の側でリードタイム・枠・重複が検証される。
--   **検証の責任を1か所に集めておく**ため、板では持たない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 参加表明を落とす
-- ------------------------------------------------------------
drop function if exists public.join_board_post(uuid);
-- テーブルを落とせば、それに付いていたトリガーも一緒に落ちる
--   ・`0012` の board_participants_notify_joined（参加の通知）
--   ・`0074` の board_participants_require_consent（みまもり撤回で参加を止める）
drop table if exists public.board_participants;
-- トリガーが消えても関数は残るので、使われなくなったものを片付ける
drop function if exists public._board_participants_require_consent();
drop function if exists public.notify_board_joined();

-- ⚠️ **募集の投稿を止める側（`0074` の board_posts_require_consent）は残す。**
-- みまもりの同意を撤回した人が募集を出せてしまうと、撤回の意味が無くなる。

-- ------------------------------------------------------------
-- 2. 列の入れ替え
-- ------------------------------------------------------------
alter table public.board_posts drop column if exists capacity;

alter table public.board_posts
  add column if not exists duration_minutes int not null default 60;

-- 予約できる長さと同じ集合に縛る。板で選べる長さが予約で通らない、を防ぐ
alter table public.board_posts
  drop constraint if exists board_posts_duration_ok;
alter table public.board_posts
  add constraint board_posts_duration_ok
  check (public.is_valid_booking_duration(duration_minutes));

comment on column public.board_posts.duration_minutes is
  '募集している1枠の長さ(分)。予約画面の初期値になる。0113。';
comment on table public.board_posts is
  'ピタメイトが空き枠を告知する板(0113)。**投稿できるのは掲載中のピタメイトだけ。**ゲストは予約の申込みに進む。無料で参加する経路は持たない。';

-- ------------------------------------------------------------
-- 3. 投稿できるのは掲載中のピタメイトだけ
--
--    RLS の with check ではなくトリガーにする。理由は 0081（居住地）と同じで、
--    **条件を画面の実装に依存させない**ため。エラー名で理由も返せる。
-- ------------------------------------------------------------
create or replace function public._board_posts_require_host()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_host boolean;
  v_rate int;
begin
  select hs.is_host, hs.hourly_rate into v_is_host, v_rate
  from public.host_settings hs where hs.user_id = new.creator_id;

  if not coalesce(v_is_host, false) then
    raise exception 'HOST_ONLY';
  end if;
  -- 料金が無いと、見た人が予約に進んだ先で詰まる
  if coalesce(v_rate, 0) <= 0 then
    raise exception 'HOURLY_RATE_REQUIRED';
  end if;
  return new;
end;
$$;

revoke all on function public._board_posts_require_host() from public, anon;

drop trigger if exists board_posts_require_host on public.board_posts;
create trigger board_posts_require_host
  before insert on public.board_posts
  for each row execute function public._board_posts_require_host();

-- ------------------------------------------------------------
-- 4. 取り消しの通知先を変える
--
--    参加者がいなくなったので、代わりに**この募集から予約を申し込んだゲスト**へ知らせる。
--    予約は板を経由しなくても作れるので、板から来たものだけを結びつける列を持つ。
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_board_post_id uuid references public.board_posts (id) on delete set null;

comment on column public.bookings.from_board_post_id is
  '募集板から申し込まれた予約は、その募集を指す(0113)。募集が取り消されたときに、申込者へ知らせるために使う。';

create index if not exists bookings_from_board_post_idx
  on public.bookings (from_board_post_id) where from_board_post_id is not null;

create or replace function public.cancel_board_post(
  p_post_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_name text;
  v_reason text;
  v_guest record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.creator_id <> v_uid then
    raise exception 'ONLY_CREATOR_CAN_CANCEL';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り消しは何もしない(連打対策)
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left(v_reason, 200)
    where id = p_post_id;

  select nickname into v_name from public.profiles where id = v_uid;

  -- この募集から予約を申し込んでいて、まだ終わっていないゲストに知らせる。
  -- **予約そのものは取り消さない。** 予約のキャンセルは返金の規定
  -- （規約 第9条・`cancel_booking`）に乗るので、板の都合で勝手に消さない。
  for v_guest in
    select distinct b.guest_id
    from public.bookings b
    where b.from_board_post_id = p_post_id
      and b.status in ('requested', 'approved')
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_guest.guest_id,
      'board_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが募集を取り下げました',
      v_post.game || '・' || v_post.when_text
        || case when v_reason is null then '' else '（' || v_reason || '）' end
        || ' ※お申し込み済みの予約はそのままです',
      p_post_id
    );
  end loop;
end;
$$;

comment on function public.cancel_board_post(uuid, text) is
  '自分の募集を取り下げる。0113で通知先を「参加表明した人」から「この募集から予約を申し込んだゲスト」に変えた。予約自体は取り消さない(キャンセルは第9条の規定に乗せる)。';

revoke all on function public.cancel_board_post(uuid, text) from public, anon;
grant execute on function public.cancel_board_post(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 5. 募集から予約する
--
--    `create_booking` をそのまま呼ぶ。**検証をここで作り直さない。**
--    リードタイム・枠・重複・残高・本人確認は、すべて向こうが見ている。
--    ここがやるのは「板の条件を満たしているか」と「紐づけ」だけ。
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

  -- ブロック関係は create_booking 側でも見るが、
  -- ここで止めたほうが「なぜ押せないか」を板の文脈で返せる
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  v_booking_id := public.create_booking(
    v_post.creator_id,
    coalesce(p_duration_minutes, v_post.duration_minutes),
    p_policy_version,
    p_scheduled_at
  );

  update public.bookings set from_board_post_id = p_post_id where id = v_booking_id;

  -- **1募集＝1枠。** 申込みが入った時点で板から下ろす。
  -- 断られた場合に開き直さないのは、開け直しの判断を投稿者に委ねるため
  -- （辞退した相手の申込みで枠が消えたままになるより、自分で出し直せるほうが分かりやすい）
  update public.board_posts set status = 'closed' where id = p_post_id;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_board(uuid, text, timestamptz, int) is
  '募集板から予約を申し込む(0113)。板の条件(本人確認・対象・ブロック)を見たうえで create_booking をそのまま呼ぶ。検証は create_booking 側に集約する。申込みが入ったら募集は closed にする(1募集=1枠)。';

revoke all on function public.create_booking_from_board(uuid, text, timestamptz, int) from public, anon;
grant execute on function public.create_booking_from_board(uuid, text, timestamptz, int) to authenticated;

-- ------------------------------------------------------------
-- 5-2. 運営の取り下げも通知先を変える（0112 の作り直し）
--
--      0112 は参加表明した人に通知していた。参加表明が無くなったので、
--      **この募集から予約を申し込んだゲスト**に切り替える。
-- ------------------------------------------------------------
create or replace function public.admin_remove_board_post(
  p_post_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_reason text;
  v_guest record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須。** 記録の要らない削除は、あとから説明できない。
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_post_id;

  -- 投稿者に知らせる。**理由も渡す。**
  -- 規約 第10条の2 6項が「削除の理由をユーザーに通知します」と定めている。
  -- 何が引っかかったのか分からないと、同じ投稿をもう一度出してくる
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_cancelled',
    '募集を取り下げました',
    v_post.game || '・' || v_post.when_text || '（理由：' || v_reason || '）',
    p_post_id
  );

  -- この募集から申し込んでいたゲストにも知らせる。
  -- **理由は載せない**（運営の判断の内容を第三者に配らない）。
  -- **予約は取り消さない**（キャンセルは規約 第9条の規定に乗せる）。
  for v_guest in
    select distinct b.guest_id
    from public.bookings b
    where b.from_board_post_id = p_post_id
      and b.status in ('requested', 'approved')
      and b.guest_id <> v_post.creator_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_guest.guest_id,
      'board_cancelled',
      '申し込んだ募集が取り下げられました',
      v_post.game || '・' || v_post.when_text || ' ※お申し込み済みの予約はそのままです',
      p_post_id
    );
  end loop;

  perform public._log_admin_action('board_post_removed', p_post_id, v_reason);
end;
$$;

comment on function public.admin_remove_board_post(uuid, text) is
  '募集投稿を運営が取り下げる(0112・突合表G21。0113で通知先を予約の申込者に変更)。行は消さず status=cancelled にし、cancel_reason に「運営による取り下げ：」を付けて残す。理由は必須。投稿者には理由つき、申込者には理由なしで通知し、admin_actions に記録する。予約は取り消さない。';

revoke all on function public.admin_remove_board_post(uuid, text) from public, anon;
grant execute on function public.admin_remove_board_post(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 6. 運営の一覧から capacity / participants を外す（0112 の作り直し）
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
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0113で参加人数を「この募集から入った予約の件数」に置き換えた。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;
