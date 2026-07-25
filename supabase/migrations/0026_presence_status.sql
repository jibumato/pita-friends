-- ============================================================
-- オンラインステータス(最終ログイン + 手動ステータス)
-- ------------------------------------------------------------
-- これまでのオンライン表示は Realtime Presence のみで、
-- 「いまアプリを開いている人」しか出せなかった。ユーザーが少ない間は
-- 一覧がほぼ空になるため、profiles に last_seen_at を持たせて
-- 「5分前」「1時間前」といった表示ができるようにする。
--
-- あわせて、オンライン=誘ってよい とは限らないので、本人が意思表示できる
-- presence_status(ready/online/busy)を用意する。
--
-- プライバシー: safety_prefs は本人しか select できない一方、profiles は
-- 全ユーザーが select できる。そのため公開可否は「書き込み時」に制御する。
--   ・show_online = false の間は last_seen_at を更新しない
--   ・show_online を false にした瞬間に last_seen_at を null に戻す(トリガー)
-- これにより、非公開の人の在席情報が profiles に残らない。
-- ============================================================

-- ------------------------------------------------------------
-- profiles: 最終在席時刻と手動ステータス
-- ------------------------------------------------------------
alter table public.profiles
  add column last_seen_at timestamptz,
  add column presence_status text not null default 'online'
    check (presence_status in ('ready', 'online', 'busy'));

comment on column public.profiles.last_seen_at is
  '最後にアプリを開いていた時刻。オンライン状態を公開している人のみ記録され、非公開にすると null に戻る。';
comment on column public.profiles.presence_status is
  '本人が選ぶ状態。ready=今すぐ遊べる / online=オンライン / busy=取り込み中。';

-- 一覧を「最近いた順」で並べるため
create index profiles_last_seen_at_idx
  on public.profiles (last_seen_at desc nulls last);

-- ------------------------------------------------------------
-- touch_presence: 在席を記録する(アプリを開いている間、定期的に呼ぶ)
-- show_online が false のときは何もしない(非公開の人は記録しない)。
-- ------------------------------------------------------------
create function public.touch_presence()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.safety_prefs
    where user_id = v_uid and show_online
  ) then
    return;
  end if;
  update public.profiles set last_seen_at = now() where id = v_uid;
end;
$$;

revoke all on function public.touch_presence() from public;
grant execute on function public.touch_presence() to authenticated;

-- ------------------------------------------------------------
-- set_presence_status: 本人が状態を選ぶ
-- ------------------------------------------------------------
create function public.set_presence_status(p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_status not in ('ready', 'online', 'busy') then
    raise exception 'INVALID_STATUS';
  end if;
  update public.profiles set presence_status = p_status where id = v_uid;
end;
$$;

revoke all on function public.set_presence_status(text) from public;
grant execute on function public.set_presence_status(text) to authenticated;

-- ------------------------------------------------------------
-- オンライン状態を非公開にしたら、記録済みの last_seen_at を消す。
-- 「非公開にしたのに最終ログインが残っている」を防ぐための要。
-- ------------------------------------------------------------
create function public.clear_last_seen_on_hide()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.show_online and not new.show_online then
    update public.profiles set last_seen_at = null where id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger safety_prefs_clear_last_seen
  after update of show_online on public.safety_prefs
  for each row
  execute function public.clear_last_seen_on_hide();
