-- ============================================================
-- ホストの予約諾否(GameRoom式「承諾で契約成立」)
-- ------------------------------------------------------------
-- 弁護士回答Q8への対応(労務リスクの低減):
--   予約は即時確定ではなく、ホストが承諾して初めて成立する。
--   これにより「ホストは諾否の自由を持つ独立した役務提供者」という
--   整理が明確になる(当社が一方的に労務を割り当てる構造ではない)。
--
-- 状態遷移:
--   requested  … ゲストが申込み、コインは確保(有償先消費)。ホストの応答待ち
--     ├─ approve_booking(ホスト) → confirmed (約束=トークが成立)
--     ├─ decline_booking(ホスト) → declined_by_host (コイン全額返却)
--     ├─ cancel_booking(ゲスト)  → cancelled_by_guest (コイン全額返却・無ペナルティ)
--     └─ 24時間無応答          → expire_stale_booking_requests で自動辞退・返却
--   confirmed 以降は 0015 のとおり(complete / cancel / 72h自動確定)
-- ============================================================

-- 予約ステータスに requested / declined_by_host を追加
alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings
  add constraint bookings_status_check
  check (status in (
    'requested', 'confirmed', 'completed',
    'cancelled_by_guest', 'cancelled_by_host', 'declined_by_host',
    'no_show_host', 'no_show_guest'
  ));

-- 通知タイプに booking_requested / booking_approved を追加
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved'
  ));

-- ------------------------------------------------------------
-- create_booking: 即時確定をやめ、requested(承諾待ち)で作る。
-- コインは確保(有償先消費)するが、約束(トーク)はまだ作らない。
-- 戻り値は booking_id(承諾待ち画面用。約束はまだ無い)。
-- ------------------------------------------------------------
create or replace function public.create_booking(p_host_id uuid, p_duration_minutes int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_guest_name text;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_duration_minutes not in (30, 60, 120) then
    raise exception 'INVALID_DURATION';
  end if;
  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings
  where user_id = p_host_id
  for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_coins := round(v_hourly_rate * p_duration_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets
  where user_id = v_guest_id
  for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested')
  returning id into v_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  -- ホストに予約リクエストを通知
  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id,
    'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

-- ------------------------------------------------------------
-- approve_booking: ホストが予約を承諾する。約束(トーク)が成立する。
-- 戻り値は promise_id(トークを開くのに使う)。
-- ------------------------------------------------------------
create function public.approve_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 承諾時点を役務の開始時刻とみなす(72時間自動確定の起点をここに合わせる)
  update public.bookings
    set status = 'confirmed', scheduled_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を承諾しました',
    'トークが始まりました。プレイの準備をしましょう',
    v_promise_id
  );

  return v_promise_id;
end;
$$;

revoke all on function public.approve_booking(uuid) from public;
grant execute on function public.approve_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- decline_booking: ホストが予約を辞退する。コインを全額返却する。
-- ------------------------------------------------------------
create function public.decline_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_host_name text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_DECLINE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = p_booking_id;

  -- 消費した内訳どおりに全額返却
  update public.coin_wallets
    set balance = balance + v_booking.paid_coins,
        bonus_balance = bonus_balance + v_booking.bonus_coins
    where user_id = v_booking.guest_id;
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'decline_booking');

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_cancelled',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を辞退しました',
    'コインは全額返却されました',
    p_booking_id
  );
end;
$$;

revoke all on function public.decline_booking(uuid) from public;
grant execute on function public.decline_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- cancel_booking: requested(承諾待ち)のゲスト取消にも対応(0016版を拡張)。
--   requested → 全額返却・無ペナルティ(まだ約束は成立していない)
--   confirmed 以降は従来どおり(1時間ルール・ドタキャン反映)
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

  -- 承諾待ちの取消: 誰が取り消しても全額返却・無ペナルティ・約束なし
  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;

    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');

    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other,
      'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額返却されました',
      p_booking_id
    );
    return;
  end if;

  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_CANCELLABLE';
  end if;

  if v_uid = v_booking.host_id then
    v_refund := true;
    v_new_status := 'cancelled_by_host';
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
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_booking');
  else
    update public.coin_wallets set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

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
-- expire_stale_booking_requests: 24時間ホストが応答しない requested を
-- 自動辞退し、コインを返却する。service_role/cron専用。
-- ------------------------------------------------------------
create function public.expire_stale_booking_requests()
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
    where status = 'requested'
      and created_at + interval '24 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = v_booking.id;

    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', v_booking.id, 'expire_request');

    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_booking.guest_id,
      'booking_cancelled',
      '予約リクエストが期限切れになりました',
      'ホストからの応答がなかったため、コインを全額返却しました',
      v_booking.id
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_stale_booking_requests() from public;

-- cronに登録(pg_cronが使える環境のみ。毎時47分に実行)
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule(
      'expire-stale-booking-requests',
      '47 * * * *',
      'select public.expire_stale_booking_requests()'
    );
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end
$do$;
