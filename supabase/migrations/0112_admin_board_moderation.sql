-- ============================================================
-- 0112: 募集投稿を運営コンソールから取り下げられるようにする  ★突合表 G21
--
-- ■ 何が無かったか
--   募集掲示板（`board_posts`）に不適切な投稿が出たとき、
--   **運営に消す手段が無かった。**
--     ・`cancel_board_post` は `creator_id <> auth.uid()` で弾くので投稿者専用
--     ・通報（`reports`）は**人**に対するもので、投稿を指せない
--     ・運営コンソールに募集を見るタブが無い
--   つまり「見つけても消せない」状態だった。
--   規約 第13条は当社が投稿を削除できると定めているのに、実装が無い。
--
-- ■ なぜ運営の裁量に寄せるか
--   「今後は運営作業は運営コンソールから操作できるようにして下さい」という
--   方針に従う。SQL Editor で `update board_posts set status='cancelled'` を
--   打つ運用にすると、**誰がいつ何を消したかが残らない。**
--
-- ■ 消さずに取り下げる
--   行は削除せず `status = 'cancelled'` にする。投稿者専用の取り消しと
--   同じ状態にそろえる。**証跡を消さない**ためで、通報の裏取りにも要る。
--   区別は `cancel_reason` の頭に「運営による取り下げ：」を付けて残す。
--
-- ■ 投稿者にも必ず知らせる
--   投稿者専用の `cancel_board_post` は、参加表明した人にだけ通知する
--   （投稿者は自分で消しているので知らせる必要が無い）。
--   運営が取り下げる場合は逆で、**投稿者が知らないと何が起きたか分からない。**
--   両方に通知する。
-- ============================================================

-- ------------------------------------------------------------
-- 一覧（運営コンソールの「募集」タブ）
--
-- 掲示板の公開クエリと違い、**取り下げ済みも見える**ようにする。
-- 「消したはずのものが本当に消えているか」を確かめる場所でもあるため。
-- ------------------------------------------------------------
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
  capacity int,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  participants int,
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
    b.capacity,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.board_participants bp where bp.post_id = b.id),
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
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0112。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;

-- ------------------------------------------------------------
-- 取り下げ
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
  v_participant record;
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
  -- 何が引っかかったのか分からないと、同じ投稿をもう一度出してくる
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_cancelled',
    '募集を取り下げました',
    v_post.game || '・' || v_post.when_text || '（理由：' || v_reason || '）',
    p_post_id
  );

  -- 参加表明していた人にも知らせる。
  -- 待っている側からすると、理由より「無くなった」ことのほうが要る情報なので、
  -- 理由は載せない（運営の判断の内容を第三者に配らない）
  for v_participant in
    select user_id from public.board_participants where post_id = p_post_id
  loop
    if v_participant.user_id <> v_post.creator_id then
      insert into public.notifications (user_id, type, title, body, related_id)
      values (
        v_participant.user_id,
        'board_cancelled',
        '参加予定だった募集が取り下げられました',
        v_post.game || '・' || v_post.when_text,
        p_post_id
      );
    end if;
  end loop;

  perform public._log_admin_action('board_post_removed', p_post_id, v_reason);
end;
$$;

comment on function public.admin_remove_board_post(uuid, text) is
  '募集投稿を運営が取り下げる(0112・突合表G21)。行は消さず status=cancelled にし、cancel_reason に「運営による取り下げ：」を付けて残す。理由は必須。投稿者と参加者の双方に通知し、admin_actions に記録する。';

revoke all on function public.admin_remove_board_post(uuid, text) from public, anon;
grant execute on function public.admin_remove_board_post(uuid, text) to authenticated;
