-- ============================================================
-- 「みまもり」一次検知のエスカレーション記録
-- 設計: docs/trust-safety-spec.md §4.2
-- ------------------------------------------------------------
-- 送信前の自動検知(外部連絡先・金銭要求・出会い目的)でヒットした事実を
-- 記録し、人による確認の対象を絞り込むためのテーブル。
--
-- 方針(§4.2):
--   ・検知しても送信はブロックしない。記録するだけ
--   ・「金銭要求」は1回でも確認対象(needs_review = true)
--   ・同一ユーザーで繰り返しヒットした場合も確認対象に上げる
--
-- 本文そのものは保存しない。一致した短い断片(matched)のみ残す。
-- 会話の全文保存は「みまもり」同意の範囲を超えるため意図的に避けている。
-- ============================================================

create table public.content_flags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  category text not null check (category in ('contact', 'money', 'dating')),
  -- どこで検知したか(message=トーク, board=募集文, profile=プロフィール文)
  surface text not null check (surface in ('message', 'board', 'profile')),
  -- 一致した断片のみ。本文は保存しない
  matched text not null check (char_length(matched) <= 200),
  -- 本人が警告を見たうえで送信を続行したか
  proceeded boolean not null default false,
  needs_review boolean not null default false,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table public.content_flags is
  '送信前の自動検知(みまもり)のヒット記録。本文は保存せず一致断片のみ。運営の確認対象の絞り込みに使う。';

alter table public.content_flags enable row level security;

-- 本人にも他ユーザーにも開示しない(運営のみがservice roleで参照する)。
-- select ポリシーを置かないことで既定の拒否になる。

create index content_flags_review_idx
  on public.content_flags (needs_review, created_at desc)
  where needs_review and reviewed_at is null;

create index content_flags_user_idx
  on public.content_flags (user_id, created_at desc);

-- ------------------------------------------------------------
-- record_content_flag: 検知結果を記録する(本人のみ・本人の分だけ)
-- 直近24時間に3件以上ヒットしている場合も確認対象に引き上げる。
-- ------------------------------------------------------------
create function public.record_content_flag(
  p_category text,
  p_surface text,
  p_matched text,
  p_proceeded boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_recent int;
  v_needs boolean;
begin
  if v_uid is null then
    return;
  end if;
  if p_category not in ('contact', 'money', 'dating') then
    return;
  end if;
  if p_surface not in ('message', 'board', 'profile') then
    return;
  end if;

  -- 金銭要求は1回でも確認対象(§4.2-3)
  v_needs := (p_category = 'money');

  -- 繰り返しヒットも確認対象に上げる
  if not v_needs then
    select count(*) into v_recent
    from public.content_flags
    where user_id = v_uid and created_at > now() - interval '24 hours';
    if v_recent >= 2 then
      v_needs := true;
    end if;
  end if;

  insert into public.content_flags (user_id, category, surface, matched, proceeded, needs_review)
  values (v_uid, p_category, p_surface, left(coalesce(p_matched, ''), 200), coalesce(p_proceeded, false), v_needs);
end;
$$;

revoke all on function public.record_content_flag(text, text, text, boolean) from public;
grant execute on function public.record_content_flag(text, text, text, boolean) to authenticated;
