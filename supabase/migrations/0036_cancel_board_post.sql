-- ============================================================
-- 募集の取り消し(論理削除)と、更新経路の絞り込み
-- ------------------------------------------------------------
-- ■ 取り消し導線が無かった問題
--   board_posts は open/closed/cancelled の状態を持っていたが、作成者が
--   自分の募集を取り消す手段がアプリ内に無く、定員が埋まるまで残り続けていた。
--
-- ■ 更新ポリシーが緩すぎた問題
--   0011 の board_posts_update_own_status には
--   「定員等の直接改変は不可」とコメントされていたが、実際には**全カラムを
--   更新できる**状態だった。PostgreSQL の RLS はカラム単位の制限ができず
--   (それは列レベル GRANT の役割)、列レベルの grant も置かれていなかったため。
--
--   このままだと作成者は、参加者が集まった後にゲーム名・定員・募集文を
--   書き換えられる。「Apexのエンジョイ枠」に参加したら別ゲームのガチ募集に
--   変わっている、ということが起こりうる。
--
--   直接 UPDATE を禁止し、状態変更は本マイグレーションの RPC 経由に一本化する。
--
-- ■ 物理削除はしない
--   参加者がいる募集がレコードごと消えると、参加履歴や通報の追跡ができなく
--   なるため、cancelled にする論理削除にとどめる(delete ポリシーは作らない)。
-- ============================================================

-- 直接更新を禁止する。以後、状態の変更は cancel_board_post / join_board_post のみ。
drop policy if exists "board_posts_update_own_status" on public.board_posts;

-- 取り消し理由(任意)。運営が経緯を追えるように残す。
alter table public.board_posts
  add column cancelled_at timestamptz,
  add column cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 200);

comment on column public.board_posts.cancelled_at is
  '作成者が募集を取り消した時刻。物理削除はせず、この列で論理削除を表す。';

-- 通知種別に募集の取り消しを追加(既存の種別を落とさないこと。既存行が制約違反になる)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled'
  ));

-- ------------------------------------------------------------
-- cancel_board_post: 作成者が自分の募集を取り消す。
-- 参加者がいる場合は全員に通知する(黙って消えると、参加者は待ち続けてしまう)。
-- ------------------------------------------------------------
create function public.cancel_board_post(p_post_id uuid, p_reason text default null)
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
  v_participant record;
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

  -- 参加表明していた人に知らせる
  for v_participant in
    select user_id from public.board_participants where post_id = p_post_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_participant.user_id,
      'board_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが募集を取り消しました',
      v_post.game || '・' || v_post.when_text
        || case when v_reason is null then '' else '（' || v_reason || '）' end,
      p_post_id
    );
  end loop;
end;
$$;

revoke all on function public.cancel_board_post(uuid, text) from public;
grant execute on function public.cancel_board_post(uuid, text) to authenticated;
