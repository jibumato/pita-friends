-- ============================================================
-- ボーナスコイン(無償)を有償コインと分離し、有償を先に消費する
-- ------------------------------------------------------------
-- 弁護士回答Q3③への対応:
--   ・無償ボーナス分は対価性がなく、換金されると当社の受領額を超える
--     払出し(=販促費の流出)になる。これを最小化するため:
--       ① 残高を「有償(balance)」「無償ボーナス(bonus_balance)」に分離
--       ② 予約消費は有償分から先に減らす(有償先消費)
--       ③ ボーナス付与は type='bonus' で明示的に記録する
--   ・あわせてコインパックのボーナス率をGameRoom水準(ほぼ0、大口のみ
--     0.5〜1%)に引き下げる。換金があるサービスでは大きなボーナスは
--     そのまま現金流出・不正換金の温床になるため。
--
--   注: 会計の呼称
--     balance         = 有償の購入コイン(換金不可・予約に使える)
--     bonus_balance   = 無償ボーナスコイン(換金不可・予約に使える。有償の後に消費)
--     earned_balance  = ホストの報酬コイン(換金可能・0013)
-- ============================================================

-- ------------------------------------------------------------
-- coin_wallets: 無償ボーナス残高を分離
-- ------------------------------------------------------------
alter table public.coin_wallets
  add column bonus_balance int not null default 0 check (bonus_balance >= 0);

comment on column public.coin_wallets.bonus_balance is
  '無償で付与されたボーナスコインの残高。予約に使えるが、有償コイン(balance)を使い切った後に消費される。換金は不可。';

-- ------------------------------------------------------------
-- bookings: 消費したコインの有償/無償の内訳を記録
-- (キャンセル時に正しいバケットへ払い戻すため)
-- ------------------------------------------------------------
alter table public.bookings
  add column paid_coins int not null default 0 check (paid_coins >= 0),
  add column bonus_coins int not null default 0 check (bonus_coins >= 0);

comment on column public.bookings.paid_coins is '予約消費のうち有償コインから引いた分。';
comment on column public.bookings.bonus_coins is '予約消費のうち無償ボーナスコインから引いた分。';

-- ------------------------------------------------------------
-- credit_coins_for_purchase: 有償分とボーナス分を別会計で付与
-- (webhookから p_coins=有償, p_bonus_coins=無償 を受け取る)
-- ------------------------------------------------------------
drop function if exists public.credit_coins_for_purchase(uuid, text, int, int, text, text);

create function public.credit_coins_for_purchase(
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
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 既に処理済みのセッションなら冪等に終了
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

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);

  if coalesce(p_bonus_coins, 0) > 0 then
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, p_bonus_coins, 'bonus', 'stripe:' || p_session_id);
  end if;
end;
$$;

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- create_booking: 有償先消費に変更(0010版をベースに)
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
  v_promise_id uuid;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_duration_minutes not in (30, 60, 120) then
    raise exception 'INVALID_DURATION';
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

  -- 有償分から先に消費し、足りない分だけボーナスから引く
  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus)
  returning id into v_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  insert into public.promises (booking_id, user_a, user_b)
  values (v_booking_id, v_guest_id, p_host_id)
  returning id into v_promise_id;

  return v_promise_id;
end;
$$;

-- ------------------------------------------------------------
-- cancel_booking: 払い戻しを有償/無償の元バケットへ戻す(0015版をベースに)
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
    -- 消費した内訳どおり、有償は有償へ・ボーナスはボーナスへ払い戻す
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 直前のゲスト都合キャンセル: 没収分はホストの報酬として付与(機会損失の補償)
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
-- コインパックのボーナスをGameRoom水準に引き下げ、ラインナップを更新
--   ¥500〜¥10,000: ボーナスなし / ¥20,000: +100(0.5%) / ¥50,000: +500(1%)
-- ------------------------------------------------------------
update public.coin_packs set active = false;

insert into public.coin_packs (id, coins, bonus_coins, price_yen, sort, active) values
  ('pack_500',    500,     0,   500, 1, true),
  ('pack_1000',   1000,    0,  1000, 2, true),
  ('pack_3000',   3000,    0,  3000, 3, true),
  ('pack_5000',   5000,    0,  5000, 4, true),
  ('pack_10000',  10000,   0, 10000, 5, true),
  ('pack_20000',  20000,  100, 20000, 6, true),
  ('pack_50000',  50000,  500, 50000, 7, true)
on conflict (id) do update
  set coins = excluded.coins,
      bonus_coins = excluded.bonus_coins,
      price_yen = excluded.price_yen,
      sort = excluded.sort,
      active = true;
