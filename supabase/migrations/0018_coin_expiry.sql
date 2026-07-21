-- ============================================================
-- コインの有効期限(取得日から6か月未満)を実装する
-- ------------------------------------------------------------
-- 事業判断(2026-07-21): コインの有効期限を「取得日から起算して6か月を
-- 経過する日の前日まで」= 6か月未満に設定する。これにより資金決済法上の
-- 適用除外(発行の日から6月内に限り使用できる前払式支払手段)の要件を満たし、
-- 表示義務・届出・供託が不要になりうる(最終文言は弁護士確認: Q10)。
--
-- 適用除外を「本当に」成立させるには、コインが実際に6か月で失効する必要が
-- あるため、ロット(取得ロット)単位で有効期限を管理し、期限切れを失効させる。
--   ・購入コイン(paid)とボーナスコイン(bonus)は 前払式支払手段 として失効対象。
--   ・報酬コイン(earned_balance)は役務対価の未払金であり前払式ではないため、
--     この失効の対象外(換金で精算される)。
--   ・消費は「期限が近いロットから先に(FIFO)」引く。有償先消費(0016)は維持。
--   ・balance / bonus_balance は「未失効ロット合計」のキャッシュとして維持し、
--     フロントの残高表示はこれまでどおり動く。
-- ============================================================

-- coin_transactions.type に失効(expire)を追加
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in ('purchase', 'booking_spend', 'refund', 'bonus', 'booking_earned', 'payout', 'expire'));

-- ------------------------------------------------------------
-- coin_lots: 取得ロット(有効期限つき)。paid/bonusのみを管理する。
-- ------------------------------------------------------------
create table public.coin_lots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('paid', 'bonus')),
  remaining int not null check (remaining >= 0),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

comment on table public.coin_lots is
  '購入/ボーナスコインの取得ロット。残(remaining)と有効期限(expires_at)を持ち、期限が近い順に消費・失効する。balance/bonus_balanceは未失効ロット合計のキャッシュ。';

alter table public.coin_lots enable row level security;

create policy "coin_lots_select_own"
  on public.coin_lots for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは SECURITY DEFINER 関数経由のみ(INSERT/UPDATEポリシーは作らない)。

create index coin_lots_consume_idx on public.coin_lots (user_id, kind, expires_at) where remaining > 0;

-- コインの有効期限(取得日から6か月を経過する日の前日まで)
create function public.coin_expiry_from(p_ts timestamptz)
returns timestamptz
language sql
immutable
as $$
  select p_ts + interval '6 months' - interval '1 day';
$$;

-- ------------------------------------------------------------
-- _consume_coin_lots: 指定種別のロットを期限が近い順に p_amount 減らす。
-- 内部ヘルパー(残高チェックは呼び出し側で済ませている前提。ロットが
-- キャッシュに満たない場合(移行前の残高等)は減らせる分だけ減らす)。
-- ------------------------------------------------------------
create function public._consume_coin_lots(p_user_id uuid, p_kind text, p_amount int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_left int := p_amount;
  v_lot record;
  v_take int;
begin
  if p_amount <= 0 then
    return;
  end if;
  for v_lot in
    select id, remaining from public.coin_lots
    where user_id = p_user_id and kind = p_kind and remaining > 0
    order by expires_at asc
    for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.remaining, v_left);
    update public.coin_lots set remaining = remaining - v_take where id = v_lot.id;
    v_left := v_left - v_take;
  end loop;
end;
$$;

revoke all on function public._consume_coin_lots(uuid, text, int) from public;

-- ------------------------------------------------------------
-- 既存残高のロットを埋める(移行): balance/bonus_balance>0で
-- ロットが無いユーザーに、6か月の有効期限でロットを作る。
-- ------------------------------------------------------------
insert into public.coin_lots (user_id, kind, remaining, expires_at)
select w.user_id, 'paid', w.balance, public.coin_expiry_from(now())
from public.coin_wallets w
where w.balance > 0
  and not exists (select 1 from public.coin_lots l where l.user_id = w.user_id and l.kind = 'paid');

insert into public.coin_lots (user_id, kind, remaining, expires_at)
select w.user_id, 'bonus', w.bonus_balance, public.coin_expiry_from(now())
from public.coin_wallets w
where w.bonus_balance > 0
  and not exists (select 1 from public.coin_lots l where l.user_id = w.user_id and l.kind = 'bonus');

-- ------------------------------------------------------------
-- credit_coins_for_purchase: 付与時に有効期限つきロットも作る(0016版に追加)
-- ------------------------------------------------------------
create or replace function public.credit_coins_for_purchase(
  p_user_id uuid,
  p_pack_id text,
  p_coins int,
  p_bonus_coins int,
  p_price_yen int,
  p_session_id text,
  p_payment_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins + coalesce(p_bonus_coins, 0), p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets
    set balance = balance + p_coins,
        bonus_balance = bonus_balance + coalesce(p_bonus_coins, 0)
    where user_id = p_user_id;

  insert into public.coin_lots (user_id, kind, remaining, expires_at)
    values (p_user_id, 'paid', p_coins, v_expires);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);

  if coalesce(p_bonus_coins, 0) > 0 then
    insert into public.coin_lots (user_id, kind, remaining, expires_at)
      values (p_user_id, 'bonus', p_bonus_coins, v_expires);
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, p_bonus_coins, 'bonus', 'stripe:' || p_session_id);
  end if;
end;
$$;

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- create_booking: 消費時にロットも期限が近い順に減らす(0017版に追加)
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
  from public.host_settings where user_id = p_host_id for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_coins := round(v_hourly_rate * p_duration_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  perform public._consume_coin_lots(v_guest_id, 'paid', v_from_paid);
  perform public._consume_coin_lots(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested')
  returning id into v_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id, 'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

-- ------------------------------------------------------------
-- 返金時のロット復元ヘルパー: 返金分を新しい6か月期限のロットで戻す。
-- (元ロットの期限は追跡しない。返金は稀で、ユーザー有利かつ6か月未満を
--  維持できるため適用除外の趣旨に反しない。)
-- ------------------------------------------------------------
create function public._refund_coin_lots(p_user_id uuid, p_paid int, p_bonus int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
begin
  if p_paid > 0 then
    insert into public.coin_lots (user_id, kind, remaining, expires_at)
      values (p_user_id, 'paid', p_paid, v_expires);
  end if;
  if p_bonus > 0 then
    insert into public.coin_lots (user_id, kind, remaining, expires_at)
      values (p_user_id, 'bonus', p_bonus, v_expires);
  end if;
end;
$$;

revoke all on function public._refund_coin_lots(uuid, int, int) from public;

-- cancel_booking / decline_booking / expire_stale_booking_requests は、
-- 返金時に _refund_coin_lots を呼ぶよう作り直す(0017版がベース)。
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
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');
    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額返却されました', p_booking_id);
    return;
  end if;

  if v_booking.status <> 'confirmed' then raise exception 'BOOKING_NOT_CANCELLABLE'; end if;

  if v_uid = v_booking.host_id then
    v_refund := true; v_new_status := 'cancelled_by_host';
    update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_refund := now() < (v_booking.scheduled_at - interval '1 hour');
    if not v_refund then
      update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  update public.bookings set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund then
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
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
  values (v_other, 'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case when v_refund then 'コインは全額再付与されました'
         else '開始1時間前以降のキャンセルのため、コインはホストの報酬として確定しました' end,
    p_booking_id);
end;
$$;

create or replace function public.decline_booking(p_booking_id uuid)
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
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid <> v_booking.host_id then raise exception 'ONLY_HOST_CAN_DECLINE'; end if;
  if v_booking.status <> 'requested' then raise exception 'BOOKING_NOT_REQUESTED'; end if;

  update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = p_booking_id;
  update public.coin_wallets
    set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
    where user_id = v_booking.guest_id;
  perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'decline_booking');

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.guest_id, 'booking_cancelled',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を辞退しました',
    'コインは全額返却されました', p_booking_id);
end;
$$;

create or replace function public.expire_stale_booking_requests()
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
    where status = 'requested' and created_at + interval '24 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = v_booking.id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', v_booking.id, 'expire_request');
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_booking.guest_id, 'booking_cancelled', '予約リクエストが期限切れになりました',
      'ホストからの応答がなかったため、コインを全額返却しました', v_booking.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.expire_stale_booking_requests() from public;

-- ------------------------------------------------------------
-- expire_coins: 期限切れロットを失効させ、キャッシュ残高を減らす。
-- service_role/cron専用。1日1回の実行を想定。
-- ------------------------------------------------------------
create function public.expire_coins()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot record;
  v_drop int;
  v_count int := 0;
begin
  for v_lot in
    select id, user_id, kind, remaining from public.coin_lots
    where remaining > 0 and expires_at < now()
    for update skip locked
  loop
    v_drop := v_lot.remaining;
    update public.coin_lots set remaining = 0 where id = v_lot.id;

    if v_lot.kind = 'paid' then
      update public.coin_wallets set balance = greatest(0, balance - v_drop) where user_id = v_lot.user_id;
    else
      update public.coin_wallets set bonus_balance = greatest(0, bonus_balance - v_drop) where user_id = v_lot.user_id;
    end if;

    insert into public.coin_transactions (user_id, amount, type, note)
      values (v_lot.user_id, -v_drop, 'expire', 'lot:' || v_lot.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.expire_coins() from public;

-- cronに登録(pg_cronが使える環境のみ。毎日 03:11 に実行)
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('expire-coins', '11 3 * * *', 'select public.expire_coins()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end
$do$;
