-- ============================================================
-- 予約ライフサイクルの完成: キャンセル連動・自動確定・通知
-- ------------------------------------------------------------
-- GameRoomの方式を参考にした確定ルール:
--   ・直前(開始1時間前以降)のゲスト都合キャンセルは再付与なし。
--     没収分のコインは**ホストの報酬(earned_balance)として付与**する
--     (GameRoomの「出品者都合でない限り売上を出品者に付与」と同思想。
--      運営が没収コインを取り込むと役務なき対価の受領になり法的にも
--      説明しづらいため、機会損失を被ったホストへの補償とする)
--   ・ゲストが「プレイ完了」を確定しない場合、予約時刻から72時間で
--     自動確定してホストに報酬を渡す(フリマアプリの自動受取評価と
--     同方式。ホストの報酬が宙に浮くのを防ぐ)
--
-- このマイグレーションで直すこと:
--   1. cancel_booking が promise(約束)を残したままにするバグ
--      → トークが「予約中」のまま生き続けるので、promiseも閉じて相手に通知
--   2. complete_booking も promise を完了に遷移させ、ホストに通知
--   3. auto_complete_bookings(): 72時間経過分の自動確定(+pg_cronで毎時実行)
-- ============================================================

-- 通知typeを追加(booking_cancelled / booking_completed)
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed'
  ));

-- ------------------------------------------------------------
-- cancel_booking: 0003版に promise の連動と相手への通知を追加
-- (返還ルール自体は0003から変更なし)
-- ------------------------------------------------------------
create or replace function public.cancel_booking(p_booking_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_refund boolean;
  v_new_status text;
  v_other uuid;
  v_name text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_booking.status not in ('confirmed') then
    raise exception 'BOOKING_NOT_CANCELLABLE';
  end if;

  if v_uid = v_booking.host_id then
    v_refund := true;
    v_new_status := 'cancelled_by_host';
    -- ホスト都合のキャンセルはドタキャン実績としてホストのマナースタッツに反映
    update public.profile_trust_stats
      set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_refund := now() < (v_booking.scheduled_at - interval '1 hour');
    if not v_refund then
      update public.profile_trust_stats
        set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  update public.bookings
    set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund then
    update public.coin_wallets set balance = balance + v_booking.coins where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 直前のゲスト都合キャンセル: 没収分はホストの報酬として付与(機会損失の補償)
    update public.coin_wallets set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  -- 約束(トーク)も閉じる
  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  -- 相手に通知
  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_other,
    'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case
      when v_refund then 'コインは全額再付与されました'
      else '開始1時間前以降のキャンセルのため、コインはホストの報酬として確定しました'
    end,
    p_booking_id
  );
end;
$$;

-- ------------------------------------------------------------
-- complete_booking: 0013版に promise の完了遷移とホストへの通知を追加
-- ------------------------------------------------------------
create or replace function public.complete_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_COMPLETE';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_CONFIRMABLE';
  end if;

  update public.bookings set status = 'completed' where id = p_booking_id;

  update public.coin_wallets
    set earned_balance = earned_balance + v_booking.coins
    where user_id = v_booking.host_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'complete_booking');

  update public.promises set status = 'completed' where booking_id = p_booking_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.host_id,
    'booking_completed',
    'プレイ完了が確定しました',
    v_booking.coins || 'コインが報酬として確定しました。ウォレットから換金申請できます',
    p_booking_id
  );
end;
$$;

-- ------------------------------------------------------------
-- auto_complete_bookings: 予約時刻から72時間、ゲストの確定操作が
-- ないconfirmedの予約を自動確定する(規約第9条4項)。
-- service_role専用(pg_cron、または運営が手動実行)。
-- ------------------------------------------------------------
create function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_count int := 0;
begin
  for v_booking in
    select * from public.bookings
    where status = 'confirmed'
      and scheduled_at + interval '72 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    insert into public.notifications (user_id, type, title, body, related_id)
    values
      (v_booking.host_id, 'booking_completed', 'プレイ完了が自動確定しました',
       v_booking.coins || 'コインが報酬として確定しました。ウォレットから換金申請できます', v_booking.id),
      (v_booking.guest_id, 'booking_completed', '予約が自動確定しました',
       '予約時刻から72時間が経過したため、プレイ完了として確定しました', v_booking.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.auto_complete_bookings() from public;
-- authenticatedには意図的にgrantしない(service_role/cron専用)。

-- pg_cronが使える環境(Supabaseは有効化可能)なら毎時実行を登録する。
-- 使えない環境ではスキップされる(その場合は docs の手順に従い手動実行)。
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule(
      'auto-complete-bookings',
      '23 * * * *',
      'select public.auto_complete_bookings()'
    );
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end
$do$;
