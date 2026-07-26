-- ============================================================
-- 初回お試し割引を「最初に予約した分」だけに限定する
-- ------------------------------------------------------------
-- 0038 では延長にも同じ割引率を引き継いでいたが、これをやめて
-- 延長分は通常価格で請求する。
--
-- 理由:
--  1. ホストの持ち出しに上限が無かった。割引率はホストが90%まで
--     設定できるため、引き継ぎ方式だと「30分だけ安く試してもらう」
--     つもりで設定したホストが、延長を重ねられて何時間ぶんもの時間を
--     1割の単価で提供する状態になりうる。割引の対象を「最初に予約した
--     時間」に閉じると、ホストが負担する上限が予約時点で確定する。
--  2. 結果として、最初から長めに予約したほうが得になる。
--     (例: 30分1000コイン・初回30%OFF のホストで1時間遊ぶ場合)
--       最初から60分   … 定価2000 → 1400
--       30分+30分延長  … 700 + 1000 = 1700
--
-- 表示について:
--   「初回30%OFF」と見せた取引の一部が割引対象外になるため、
--   予約画面と延長の導線の両方で、延長分が通常価格であることを
--   明示する必要がある(景表法の有利誤認・特商法の価格表示)。
--   規約 第8条の4 第6項、特商法表記もあわせて改めている。
-- ============================================================

comment on column public.bookings.discount_percent is
  '最初に予約した分に適用した初回お試し割引の割引率(%)。予約成立時点の値で固定する。延長分には適用しない(0039)。';

create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  -- 予約作成時と同じく、消費したロットの当初の期限を記録する。
  -- これを忘れると延長分がキャンセル返金で期限を引き直されてしまう(0030参照)。
  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  -- 延長分は割引が無いので、定価(list_coins)と請求額(coins)には同額を積む
  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

comment on function public.extend_booking(uuid, int) is
  'ゲストが進行中の予約を延長する。0039で、延長分は通常価格(初回お試し割引の対象外)に変更した。';
