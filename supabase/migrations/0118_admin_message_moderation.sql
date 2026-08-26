-- ============================================================
-- 0118: トークのメッセージを運営が削除できるようにする
--
-- ■ なぜ
--   通報は受け取れる（`admin_reports` が `message_snapshot` を返す）のに、
--   **その中身を消す手段が無かった。** `docs/admin-console.md` の
--   「まだ画面が無いもの」に、唯一「手段がありません」と書いてある項目。
--
--   募集は 0112 で取り下げられるようになったが、トークは残っていた。
--   外部への誘導・金銭の要求・嫌がらせの文言が通報されても、運営にできるのは
--   利用停止だけで、**相手の画面に残った文言はそのまま**になる。
--
-- ■ 行は消さない（0112 と同じ）
--   通報の裏取り・異議申立て・チャージバックの立証に要る。
--   `deleted_at` を立てて「消えた事実」を残す。
--
-- ■ ★本文はDBから消し、証跡は運営しか読めない場所へ移す
--   `deleted_at` を立てるだけだと、**本文は messages に残ったまま**で、
--   相手のクライアントにも普通に届く（画面が読み込む select は
--   `body` をそのまま取っている）。画面側で隠す実装にすると、
--   「隠しているだけで送信はしている」状態になる。
--
--   そこで本文は `message_deletions`（運営のみ）へ移し、
--   `messages.body` は空にする。**CHECK 制約で、削除済みなら本文が
--   空であることを強制する**ので、実装の抜けで本文が残ることがない。
--
-- ■ 消えたことは相手にも見せる（黙って消さない）
--   黙って消すと、受け取った側は会話の流れが飛んで混乱し、
--   送った側は何が悪かったのか分からないまま同じことを繰り返す。
--   画面には「運営が削除しました」を出し、**送信者には理由つきで通知**する
--   （規約 第10条の2 6項。0112 の板の取り下げと同じ扱い）。
--
-- ■ 読むこと自体を記録する
--   スレッドを開く関数は、**中身を見た事実を admin_actions に残す**。
--   0068 が `admin_reports` に入れた仕組みと同じ。
--   運営がトークを自由に読める仕組みを作る以上、記録が無い状態にはしない。
-- ============================================================

alter table public.messages
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_reason text,
  add column if not exists deleted_by uuid references auth.users (id) on delete set null;

comment on column public.messages.deleted_at is
  '運営が削除した日時(0118)。入っていると本文は空で、原文は message_deletions にある。';

-- ★削除済みなら本文が残っていないことを、制約で保証する。
--   画面側の実装に依存させない
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages
  add constraint messages_body_check check (
    (deleted_at is null and char_length(body) between 1 and 2000)
    or (deleted_at is not null and char_length(body) = 0)
  );

create index if not exists messages_deleted_idx
  on public.messages (promise_id) where deleted_at is not null;

-- ------------------------------------------------------------
-- 原文の保管（運営のみ）
-- ------------------------------------------------------------
create table if not exists public.message_deletions (
  message_id uuid primary key references public.messages (id) on delete cascade,
  promise_id uuid not null,
  sender_id uuid,
  body text not null,
  reason text not null,
  deleted_by uuid references auth.users (id) on delete set null,
  deleted_at timestamptz not null default now()
);

comment on table public.message_deletions is
  '運営が削除したメッセージの原文(0118)。通報の裏取り・異議申立ての立証に使う。'
  '当事者には見せない(消したものを別の場所から読めては、消した意味が無い)。';

alter table public.message_deletions enable row level security;
-- ポリシーを1つも作らない = 運営の security definer 関数からしか読めない

-- ------------------------------------------------------------
-- 通報された相手のトークを探す
-- ------------------------------------------------------------
-- reports は promise_id を持たないので、通報から直接スレッドへ辿れない。
-- 相手のIDから、その人が参加しているスレッドを引けるようにする。
create or replace function public.admin_user_threads(
  p_user_id uuid,
  p_limit int default 30
)
returns table (
  promise_id uuid,
  other_id uuid,
  other_nickname text,
  message_count int,
  last_message_at timestamptz,
  status text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  select pr.id,
         case when pr.user_a = p_user_id then pr.user_b else pr.user_a end,
         coalesce(nullif(p.nickname, ''), '(不明)'),
         (select count(*)::int from public.messages m where m.promise_id = pr.id),
         (select max(m.created_at) from public.messages m where m.promise_id = pr.id),
         pr.status
  from public.promises pr
  left join public.profiles p
    on p.id = case when pr.user_a = p_user_id then pr.user_b else pr.user_a end
  where pr.user_a = p_user_id or pr.user_b = p_user_id
  order by (select max(m.created_at) from public.messages m where m.promise_id = pr.id) desc nulls last
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$$;

comment on function public.admin_user_threads(uuid, int) is
  'その人が参加しているトークの一覧(0118)。中身は返さない(件数と最終発言だけ)ので、ここでは閲覧記録を残さない。';

revoke all on function public.admin_user_threads(uuid, int) from public, anon;
grant execute on function public.admin_user_threads(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- スレッドの中身を読む ★閲覧を記録する
-- ------------------------------------------------------------
create or replace function public.admin_thread_messages(
  p_promise_id uuid,
  p_limit int default 200
)
returns table (
  id uuid,
  sender_id uuid,
  sender_nickname text,
  body text,
  created_at timestamptz,
  deleted_at timestamptz,
  deleted_reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*)::int into v_n from public.messages m where m.promise_id = p_promise_id;

  -- 0068 と同じ。**中身を見た事実を残す。**
  perform public._log_admin_action(
    'view_thread', p_promise_id,
    '該当' || v_n || '件のメッセージを表示');

  return query
  select m.id,
         m.sender_id,
         coalesce(nullif(p.nickname, ''), '(不明)'),
         -- 削除済みは原文を返さない。運営でも、消したものは一覧では読まない
         -- (立証で要るときは message_deletions を直接見る)
         case when m.deleted_at is null then m.body else '' end,
         m.created_at,
         m.deleted_at,
         m.deleted_reason
  from public.messages m
  left join public.profiles p on p.id = m.sender_id
  where m.promise_id = p_promise_id
  order by m.created_at
  limit greatest(1, least(coalesce(p_limit, 200), 500));
end;
$$;

comment on function public.admin_thread_messages(uuid, int) is
  'トークの中身(運営)。**閲覧すると admin_actions に記録が残る**(0068と同じ)。削除済みの原文は返さない。';

revoke all on function public.admin_thread_messages(uuid, int) from public, anon;
grant execute on function public.admin_thread_messages(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 削除する
-- ------------------------------------------------------------
create or replace function public.admin_remove_message(
  p_message_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m public.messages;
begin
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;
  -- 理由は必須。あとから「なぜ消したか」を説明できない削除を作らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_m from public.messages where id = p_message_id for update;
  if v_m.id is null then
    raise exception 'MESSAGE_NOT_FOUND';
  end if;

  -- 連打しても2度目は何もしない(通知が増えない)
  if v_m.deleted_at is not null then
    return;
  end if;

  insert into public.message_deletions
    (message_id, promise_id, sender_id, body, reason, deleted_by)
  values
    (v_m.id, v_m.promise_id, v_m.sender_id, v_m.body, btrim(p_reason), auth.uid());

  update public.messages
    set body = '',
        deleted_at = now(),
        deleted_reason = btrim(p_reason),
        deleted_by = auth.uid()
    where id = p_message_id;

  -- ★送信者には理由を渡す。渡さないと同じことをもう一度書く
  insert into public.notifications (user_id, type, title, body)
  values (v_m.sender_id, 'system', 'メッセージを削除しました',
          '送信したメッセージを運営が削除しました。理由：' || btrim(p_reason)
          || E'\n利用規約に反する内容が続く場合、アカウントの利用を停止することがあります。');

  perform public._log_admin_action('message_removed', p_message_id,
    btrim(p_reason));
end;
$$;

comment on function public.admin_remove_message(uuid, text) is
  'トークのメッセージを運営が削除する(0118)。行は残し、本文は message_deletions へ移す。理由必須。送信者に理由つきで通知(規約 第10条の2 6項)。';

revoke all on function public.admin_remove_message(uuid, text) from public, anon;
grant execute on function public.admin_remove_message(uuid, text) to authenticated;
