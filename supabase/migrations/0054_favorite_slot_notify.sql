-- ============================================================
-- 0054_favorite_slot_notify.sql
-- 推しているピタメイトが枠を開けたら知らせる
-- ------------------------------------------------------------
-- 0051で週間の募集枠を持てるようにしたが、**枠を開けても誰にも伝わらなかった**。
-- ファンが毎日スケジュールを見に来ることはないので、開けた枠が埋まらないまま
-- 終わる。0053の推し登録と繋いで、開けたときに知らせる。
--
-- 設計で気をつけたこと:
--   ・**増えた枠だけ**を対象にする。減らしただけで通知が飛ぶのはおかしい。
--   ・**24時間に1回まで**に絞る。編集は続けて何度も行われるので、
--     素直に流すと推し1人あたり1日に何通も届く。
--   ・**誰が推しているかはピタメイトに伝えない。** 通知は各ファンの行として
--     入るだけで、関数は件数も返さない(0053の方針をここでも守る)。
--   ・通知を止めたい人は推しを解除すればよい。細かい設定は今は持たない
--     (使われない設定を増やすより、外せることが分かるほうが良い)。
-- ============================================================

-- 通知の種別を追加(既存の種別を欠かさないこと)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled',
    'integrity_alert', 'booking_no_show',
    'host_slots_opened'
  ));

-- 連投を抑えるための最終通知時刻
alter table public.host_settings
  add column if not exists slots_notified_at timestamptz;

comment on column public.host_settings.slots_notified_at is
  '推しへ「枠を開けました」を最後に送った時刻。24時間に1回までに絞るために使う。';

-- ------------------------------------------------------------
-- set_host_availability(): 枠の保存時に、増えた分があれば推しへ知らせる
-- ------------------------------------------------------------
create or replace function public.set_host_availability(p_slots jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cooldown constant interval := interval '24 hours';
  v_uid uuid := auth.uid();
  v_count int;
  v_added int;
  v_sample text;
  v_name text;
  v_last timestamptz;
  v_is_host boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if jsonb_typeof(coalesce(p_slots, '[]'::jsonb)) <> 'array' then
    raise exception 'INVALID_SLOTS';
  end if;

  -- 新しく指定された枠を一時表に取る(重複と範囲外はここで落とす)
  create temporary table if not exists _new_slots (weekday smallint, hour smallint) on commit drop;
  delete from _new_slots;
  insert into _new_slots (weekday, hour)
  select distinct (s->>'weekday')::smallint, (s->>'hour')::smallint
  from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) s
  where (s->>'weekday')::int between 0 and 6
    and (s->>'hour')::int between 0 and 23;

  -- **入れ替える前に**「増えた枠」を数える。減った枠は対象にしない。
  select count(*),
         string_agg(
           case n.weekday when 0 then '日' when 1 then '月' when 2 then '火' when 3 then '水'
                          when 4 then '木' when 5 then '金' else '土' end
           || n.hour || '時', '・' order by n.weekday, n.hour)
    into v_added, v_sample
  from _new_slots n
  where not exists (
    select 1 from public.host_availability a
    where a.user_id = v_uid and a.weekday = n.weekday and a.hour = n.hour
  );

  delete from public.host_availability where user_id = v_uid;

  insert into public.host_availability (user_id, weekday, hour)
  select v_uid, weekday, hour from _new_slots;

  get diagnostics v_count = row_count;

  -- ここから通知。掲載中のピタメイトが枠を増やしたときだけ。
  select coalesce(h.is_host, false), h.slots_notified_at
    into v_is_host, v_last
  from public.host_settings h where h.user_id = v_uid;

  if coalesce(v_added, 0) > 0
     and coalesce(v_is_host, false)
     and (v_last is null or v_last < now() - c_cooldown)
  then
    select nickname into v_name from public.profiles where id = v_uid;

    insert into public.notifications (user_id, type, title, body, related_id)
    select f.user_id,
           'host_slots_opened',
           coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが枠を開けました',
           -- 長くなりすぎないよう、先頭のいくつかだけ見せる
           case when v_added > 3
                then split_part(v_sample, '・', 1) || '・' || split_part(v_sample, '・', 2)
                     || ' ほか' || (v_added - 2) || '枠'
                else v_sample end,
           v_uid
    from public.favorites f
    where f.host_id = v_uid
      -- ブロック関係があれば送らない
      and not exists (
        select 1 from public.blocks b
        where (b.blocker_id = f.user_id and b.blocked_id = v_uid)
           or (b.blocker_id = v_uid and b.blocked_id = f.user_id)
      );

    update public.host_settings set slots_notified_at = now() where user_id = v_uid;
  end if;

  -- **件数は返さない。** 誰が推しているかに繋がる情報を渡さない(0053の方針)。
  return v_count;
end;
$$;

comment on function public.set_host_availability(jsonb) is
  '週間の募集枠を丸ごと入れ替える。0054で、枠が増えたときに推しているファンへ通知する(24時間に1回まで・増えた分のみ)。';

revoke all on function public.set_host_availability(jsonb) from public;
grant execute on function public.set_host_availability(jsonb) to authenticated;
