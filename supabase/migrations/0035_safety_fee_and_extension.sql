-- ============================================================
-- 収益施策: (1) あんしん保証料  (3) 延長課金
-- ------------------------------------------------------------
-- ■ あんしん保証料
--   コイン購入時に価格の一定率を上乗せして預かる。ホストの取り分には
--   一切触れないため、既存ホストの手取りを下げずにテイクレートを上げられる。
--   根拠は承認制・本人確認・通報ブロック・トラブル時の返金対応という
--   既存の安全機能で、その提供の対価として受け取る。
--
--   ⚠️ 名称に「保険」を使わないこと。返金保証を「保険料」と称すると
--      保険業法の議論を招く。当社が提供する役務の対価として書く。
--   ⚠️ 特商法表記の「商品代金以外の必要料金」への記載が必須。
--
--   料率は1行だけの設定表に持たせる。パックごとに持たせると改定のたびに
--   全行を書き換えることになり、取りこぼしが出るため。
--
-- ■ 延長課金
--   進行中(confirmed)の予約に時間とコインを追加する。単価を上げずに
--   分母を増やせる、最も摩擦の少ない導線。
--
--   実装上の注意: 予約作成時と同じく、消費したロットの有効期限を
--   coin_lot_consumptions に記録する必要がある。これを忘れると、
--   延長した予約をキャンセルしたときに 0030 の「当初の期限で戻す」処理が
--   延長分を取りこぼす(記録が無い＝旧予約とみなされ、予約作成時刻を基準に
--   期限が引き直されてしまう)。
-- ============================================================

-- ------------------------------------------------------------
-- 価格設定(1行のみ)
-- ------------------------------------------------------------
create table public.platform_pricing (
  id smallint primary key default 1 check (id = 1),
  -- コイン購入時に上乗せする「あんしん保証料」の率
  safety_fee_rate numeric(4, 3) not null default 0.050
    check (safety_fee_rate >= 0 and safety_fee_rate <= 0.5),
  updated_at timestamptz not null default now()
);

comment on table public.platform_pricing is
  'プラットフォームの価格設定(1行のみ)。あんしん保証料の率など、改定しうる数値をここに集約する。';

insert into public.platform_pricing (id) values (1);

alter table public.platform_pricing enable row level security;

-- 料率は購入前に利用者へ示す情報なので誰でも読める
create policy "platform_pricing_select_all"
  on public.platform_pricing for select
  to authenticated
  using (true);

-- 購入履歴に、預かった保証料を残す
alter table public.coin_purchases
  add column safety_fee_yen int not null default 0 check (safety_fee_yen >= 0);

comment on column public.coin_purchases.safety_fee_yen is
  'コイン代金に上乗せして預かったあんしん保証料(円)。price_yen はコイン本体の価格で、請求総額は price_yen + safety_fee_yen。';

-- ------------------------------------------------------------
-- safety_fee_for: 指定価格に対する保証料(円)。Edge Function から使う
-- ------------------------------------------------------------
create function public.safety_fee_for(p_price_yen int)
returns int
language sql
stable
set search_path = public
as $$
  select greatest(0, round(p_price_yen * (select safety_fee_rate from public.platform_pricing where id = 1)))::int;
$$;

comment on function public.safety_fee_for(int) is
  'コイン価格に対するあんしん保証料(円)。料率は platform_pricing に持つ。';

-- ------------------------------------------------------------
-- extend_booking: 進行中の予約に時間とコインを追加する
-- ------------------------------------------------------------
create function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
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
  -- 進行中のものだけ。完了後・キャンセル後は延長できない
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

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

  -- 予約本体に積み増す。完了時の手数料は増えた後の coins に対してかかる
  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus
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

revoke all on function public.extend_booking(uuid, int) from public;
grant execute on function public.extend_booking(uuid, int) to authenticated;

-- 通知種別に延長を追加(既存の種別を落とさないこと。既存行が制約違反になる)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended'
  ));

-- duration_minutes は 30/60/120 固定だったが、延長で任意の合計になりうる
alter table public.bookings drop constraint if exists bookings_duration_minutes_check;
alter table public.bookings
  add constraint bookings_duration_minutes_check
  check (duration_minutes >= 30 and duration_minutes <= 600);
