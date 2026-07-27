-- ============================================================
-- 0050_no_show_auto.sql
-- 無断欠席を、運営の判断なしに自動で解決する
-- ------------------------------------------------------------
-- 【解きたい問題】
-- 相手が来なかったゲストが取れる自己解決の手段が「キャンセル」しかなく、
-- それは**ゲスト都合**として処理されます。相手が来なかったのにゲストが
-- 没収されるのは筋が通りません。正しい行き先は通報ですが、「通報」という
-- 言葉は心理的に重く、面倒がって黙って去る人が出ます(E-12で見送った論点)。
--
-- 【運営が判断しない設計にする】
-- 「相手が来たか」は運営には観測できません。Discordに移って遊ぶことが普通に
-- あるので、チャットの沈黙は不在の証拠になりません(0042で自動保留を見送った
-- 理由)。そこで**運営が観測しようとせず、当事者の不作為で決まる**形にします。
--
--   開始時刻を過ぎると、両者に「はじめました」ボタン
--     ※ ピタメイトがメッセージを1通でも送れば自動でチェックイン扱い
--   開始+15分: ゲストのみチェックイン済みなら → 自動で保留(お金が止まる)
--   保留中にピタメイトがチェックイン → 自動で保留解除。通常フローへ
--   保留から24時間、一度も反応なし → 自動で no_show_host。全額返還
--
-- 【なぜ成立するか】
--   ・ゲストは嘘をつけない。結果を決めるのはゲストのボタンではなく、
--     **ピタメイトの不作為**。ピタメイトが一言でも喋れば無効になる。
--   ・ピタメイトも不当に損をしない。15分後に通知が飛び、24時間の猶予があり、
--     ボタンでもメッセージでも救われる。自分の行動で結果を完全に決められる。
--   ・押した瞬間に全額返還にはしない。それでは「無料キャンセルの抜け道」に
--     なる。押して起きるのは**お金を止めること**だけ。
--
-- なお no_show_host / no_show_guest は 0017 で宣言されて以来、**どのRPCも
-- セットしていない死んだ状態**でした。ここで初めて実際に使われます。
-- ============================================================

-- ------------------------------------------------------------
-- 1. チェックインの記録とパラメータ
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists guest_checked_in_at timestamptz,
  add column if not exists host_checked_in_at timestamptz;

comment on column public.bookings.guest_checked_in_at is
  'ゲストが「はじめました」を押した時刻。無断欠席の自動判定に使う。';
comment on column public.bookings.host_checked_in_at is
  'ピタメイトが「はじめました」を押した(またはメッセージを送った)時刻。';

alter table public.platform_pricing
  -- 開始からこの時間を過ぎてもピタメイトが現れなければ保留する
  add column if not exists checkin_grace_minutes int not null default 15,
  -- 保留してからこの時間、ピタメイトが一度も反応しなければ無断欠席で確定する
  add column if not exists no_show_resolve_hours int not null default 24;

comment on column public.platform_pricing.checkin_grace_minutes is
  '開始からこの分数を過ぎてもピタメイトのチェックインが無ければ自動で保留する。既定15分。';
comment on column public.platform_pricing.no_show_resolve_hours is
  '無断欠席で保留してから、ピタメイトの反応が無いまま自動確定するまでの時間。既定24時間。';

-- 保留の理由に無断欠席を追加
alter table public.bookings drop constraint if exists bookings_hold_reason_check;
alter table public.bookings
  add constraint bookings_hold_reason_check
  check (hold_reason is null or hold_reason in ('claim', 'report', 'manual', 'no_show'));

-- 通知の種類に無断欠席まわりを追加
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled',
    'integrity_alert', 'booking_no_show'
  ));

create index if not exists bookings_no_show_watch_idx
  on public.bookings (scheduled_at)
  where status = 'confirmed' and host_checked_in_at is null;

-- ------------------------------------------------------------
-- 2. チェックイン
--    どちらの当事者も押せる。冪等(2回押しても最初の時刻を保つ)。
--    ピタメイトのチェックインは、無断欠席の保留を自動的に解除する。
-- ------------------------------------------------------------
create or replace function public.check_in_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_b public.bookings;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_b.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_ACTIVE';
  end if;
  -- 開始前に押せてしまうと「押したのに来ない」が起きるので、開始後だけ。
  if now() < v_b.scheduled_at then
    raise exception 'NOT_STARTED_YET';
  end if;

  if v_uid = v_b.guest_id then
    update public.bookings
      set guest_checked_in_at = coalesce(guest_checked_in_at, now())
      where id = p_booking_id;
    return;
  end if;

  update public.bookings
    set host_checked_in_at = coalesce(host_checked_in_at, now())
    where id = p_booking_id;

  -- 無断欠席で保留していたなら、本人が現れたので自動で解く。
  -- ここに運営の判断は要らない。
  if v_b.held_at is not null and v_b.hold_reason = 'no_show' then
    update public.bookings set held_at = null, hold_reason = null
      where id = p_booking_id;

    select nickname into v_name from public.profiles where id = v_b.host_id;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.guest_id, 'booking_no_show',
      coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが参加しました',
      '一時停止していたコインの確定を再開しました。', p_booking_id);
  end if;
end;
$$;

comment on function public.check_in_booking(uuid) is
  'プレイの開始を記録する。ピタメイトのチェックインは無断欠席の保留を自動解除する。';

revoke all on function public.check_in_booking(uuid) from public;
grant execute on function public.check_in_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. メッセージを送ったら自動でチェックイン扱いにする
--    「ボタンを押し忘れただけ」で無断欠席にされるのを防ぐ最大の安全弁。
--    実際に参加している人は、まず何か喋る。
-- ------------------------------------------------------------
create or replace function public._checkin_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  select b.* into v_b
  from public.bookings b
  join public.promises p on p.booking_id = b.id
  where p.id = NEW.promise_id and b.status = 'confirmed' and now() >= b.scheduled_at
  for update;

  if v_b.id is null then
    return NEW;
  end if;

  if NEW.sender_id = v_b.guest_id then
    update public.bookings
      set guest_checked_in_at = coalesce(guest_checked_in_at, now())
      where id = v_b.id;
  elsif NEW.sender_id = v_b.host_id then
    update public.bookings
      set host_checked_in_at = coalesce(host_checked_in_at, now())
      where id = v_b.id;
    -- 保留中なら解除(check_in_booking と同じ扱い)
    if v_b.held_at is not null and v_b.hold_reason = 'no_show' then
      update public.bookings set held_at = null, hold_reason = null where id = v_b.id;
      insert into public.notifications (user_id, type, title, body, related_id)
      values (v_b.guest_id, 'booking_no_show',
        'ピタメイトさんが参加しました',
        '一時停止していたコインの確定を再開しました。', v_b.id);
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists messages_checkin on public.messages;
create trigger messages_checkin
  after insert on public.messages
  for each row execute function public._checkin_on_message();

-- ------------------------------------------------------------
-- 4. 開始+猶予でピタメイト未チェックインなら自動で保留する
--    お金を止めるだけ。ここでは何も確定させない。
-- ------------------------------------------------------------
create or replace function public.auto_hold_no_show_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
  v_grace int;
  v_count int := 0;
begin
  select checkin_grace_minutes into v_grace from public.platform_pricing where id = 1;

  for v_b in
    select id, guest_id, host_id
    from public.bookings
    where status = 'confirmed'
      and held_at is null
      -- ゲストは来ている(自分で申告した)が、ピタメイトの気配がない
      and guest_checked_in_at is not null
      and host_checked_in_at is null
      and now() >= scheduled_at + make_interval(mins => v_grace)
    for update skip locked
  loop
    update public.bookings
      set held_at = now(), hold_reason = 'no_show'
      where id = v_b.id;

    -- ピタメイトには「まだ間に合う」ことを伝える。ここが救済の要。
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.host_id, 'booking_no_show',
      'プレイの開始が確認できていません',
      'トークで「はじめました」を押すか、メッセージを送ってください。'
        || 'このまま反応が無いと、無断欠席としてコインがゲストへ返還されます。',
      v_b.id);

    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.guest_id, 'booking_no_show',
      'コインの確定を一時停止しました',
      '相手の参加が確認できていないため、コインが相手に渡らないよう止めました。'
        || '相手が参加すれば自動で再開します。',
      v_b.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.auto_hold_no_show_bookings() is
  'ゲストだけがチェックインした予約を、開始+猶予で自動的に保留する。お金を止めるだけで確定はしない。';

revoke all on function public.auto_hold_no_show_bookings() from public;

-- ------------------------------------------------------------
-- 5. 保留から一定時間、ピタメイトの反応が無ければ無断欠席で確定する
--    全額返還し、ドタキャン記録を付ける。運営の判断は入らない。
-- ------------------------------------------------------------
create or replace function public.auto_resolve_no_show_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
  v_hours int;
  v_count int := 0;
begin
  select no_show_resolve_hours into v_hours from public.platform_pricing where id = 1;

  for v_b in
    select id, guest_id, host_id, coins, paid_coins, bonus_coins
    from public.bookings
    where status = 'confirmed'
      and hold_reason = 'no_show'
      and held_at is not null
      and host_checked_in_at is null
      and held_at < now() - make_interval(hours => v_hours)
    for update skip locked
  loop
    update public.bookings
      set status = 'no_show_host', cancelled_at = now(),
          cancel_reason = 'auto_no_show', held_at = null, hold_reason = null
      where id = v_b.id;

    -- 全額返還。ロットの当初期限を引き継ぐ(0030)
    update public.coin_wallets
      set balance = balance + v_b.paid_coins,
          bonus_balance = bonus_balance + v_b.bonus_coins
      where user_id = v_b.guest_id;
    perform public._refund_coin_lots_for_booking(v_b.id);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_b.guest_id, v_b.coins, 'refund', v_b.id, 'auto_no_show');

    update public.profile_trust_stats
      set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_b.host_id;

    update public.promises set status = 'cancelled' where booking_id = v_b.id;

    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.guest_id, 'booking_no_show',
      '無断欠席として処理しました',
      v_b.coins || 'コインを全額お戻ししました。', v_b.id);

    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.host_id, 'booking_no_show',
      '無断欠席として処理されました',
      '開始の確認ができないまま時間が経過したため、コインはゲストへ返還されました。'
        || 'ドタキャン記録に反映されます。',
      v_b.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.auto_resolve_no_show_bookings() is
  '無断欠席で保留した予約を、一定時間の無反応をもって自動的に確定し全額返還する。運営の判断を要しない。';

revoke all on function public.auto_resolve_no_show_bookings() from public;

-- ------------------------------------------------------------
-- 6. 画面用: この予約でいま何を出すべきか
-- ------------------------------------------------------------
create or replace function public.my_booking_checkin_state(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
  v_grace int;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;

  select checkin_grace_minutes into v_grace from public.platform_pricing where id = 1;

  return jsonb_build_object(
    'started', now() >= v_b.scheduled_at,
    'i_am_guest', auth.uid() = v_b.guest_id,
    'my_checked_in', case when auth.uid() = v_b.guest_id
                          then v_b.guest_checked_in_at is not null
                          else v_b.host_checked_in_at is not null end,
    'partner_checked_in', case when auth.uid() = v_b.guest_id
                               then v_b.host_checked_in_at is not null
                               else v_b.guest_checked_in_at is not null end,
    'held_for_no_show', coalesce(v_b.hold_reason, '') = 'no_show',
    'grace_minutes', v_grace
  );
end;
$$;

revoke all on function public.my_booking_checkin_state(uuid) from public;
grant execute on function public.my_booking_checkin_state(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. cronに登録
--    保留の判定は細かく(5分ごと)、確定は1時間ごとで十分。
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('auto-hold-no-show', '*/5 * * * *',
      'select public.auto_hold_no_show_bookings()');
    perform cron.schedule('auto-resolve-no-show', '13 * * * *',
      'select public.auto_resolve_no_show_bookings()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end;
$$;
