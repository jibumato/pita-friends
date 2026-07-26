-- ============================================================
-- ホストが自分で設定する「初回お試し割引」
-- ------------------------------------------------------------
-- ホストがマイページ(ホスト設定)から割引率を自由に決められるようにする。
-- そのホストと初めて遊ぶゲストにだけ適用される。
--
-- 設計の要点:
--  * 割引率はホストが 0〜90% の範囲で自由に設定(0=キャンペーンなし)。
--    100%(無料)は bookings.coins > 0 制約に反するうえ、無償提供は
--    「一緒に遊ぶ時間の対価」という建て付けを崩すため認めない。
--  * 手数料は**割引後の金額**(=ゲストが実際に払ったコイン)に対してかかる。
--    _apply_booking_fee() は new.coins を基準にしているため、割引後の額を
--    coins に入れておけば自動的にそうなる(0033は変更不要)。
--  * 定価(list_coins)と割引率(discount_percent)を予約に残す。
--    特商法の価格表示・領収の裏づけと、キャンセル時の「平均的な損害」の
--    立証材料(0032)のために、いくらの取引だったのかを後から辿れるようにする。
--  * 既存の「指名リピート割引」(0033)はホストの**手数料率**を下げるもので、
--    2回目以降が対象。本キャンペーンはゲストの**支払額**を下げるもので、
--    初回のみが対象。軸も対象も違うため衝突しない(1件の予約が両方の
--    条件を満たすことはない)。
--
-- 「初回」の判定:
--   そのホストとの間に、ゲスト側に帰属する予約が1件も無いこと。
--   ホスト都合で流れたもの(辞退・ホストキャンセル・ホスト無断欠席)は
--   カウントしない。ゲストのせいで成立しなかったわけではないため。
--   一方 requested(承諾待ち)は含める。含めないと、承諾される前に
--   何件でも割引価格で申し込めてしまう。
-- ============================================================

alter table public.host_settings
  add column if not exists trial_discount_percent int not null default 0;

alter table public.host_settings
  drop constraint if exists host_settings_trial_discount_percent_check;
alter table public.host_settings
  add constraint host_settings_trial_discount_percent_check
  check (trial_discount_percent between 0 and 90);

comment on column public.host_settings.trial_discount_percent is
  '初回お試し割引の割引率(%)。0でキャンペーンなし。ホストが自分で設定する。';

-- 予約に「定価」と「適用した割引率」を残す。
-- 既存行は割引なしの扱い(list_coins = coins)。
alter table public.bookings
  add column if not exists list_coins int;
alter table public.bookings
  add column if not exists discount_percent int not null default 0;

update public.bookings set list_coins = coins where list_coins is null;

comment on column public.bookings.list_coins is
  '割引前の定価(コイン)。割引が無い場合は coins と同じ。';
comment on column public.bookings.discount_percent is
  '適用した初回お試し割引の割引率(%)。予約成立時点の値で固定する。';

-- ------------------------------------------------------------
-- 適用される割引率を返す(対象外なら0)
-- ------------------------------------------------------------
create or replace function public.host_trial_discount_for(p_host_id uuid, p_guest_id uuid)
returns int
language sql
security definer
set search_path = public
stable
as $$
  select case
           when p_host_id is null or p_guest_id is null then 0
           when p_host_id = p_guest_id then 0
           when exists (
             select 1 from public.bookings b
             where b.host_id = p_host_id
               and b.guest_id = p_guest_id
               -- ホスト都合で流れたものは「利用済み」と見なさない
               and b.status in (
                 'requested', 'confirmed', 'completed',
                 'cancelled_by_guest', 'no_show_guest'
               )
           ) then 0
           else coalesce(
             (select hs.trial_discount_percent
              from public.host_settings hs
              where hs.user_id = p_host_id and hs.is_host), 0)
         end;
$$;

comment on function public.host_trial_discount_for(uuid, uuid) is
  'そのゲストにいま適用される初回お試し割引の割引率(%)。対象外・未設定なら0。';

-- フロント表示用。自分(auth.uid())がゲストの場合の割引率を返す。
create or replace function public.my_trial_discount(p_host_id uuid)
returns int
language sql
security definer
set search_path = public
stable
as $$
  select public.host_trial_discount_for(p_host_id, auth.uid());
$$;

comment on function public.my_trial_discount(uuid) is
  '予約画面の価格表示用。自分に適用される初回お試し割引の割引率(%)を返す。';

revoke all on function public.host_trial_discount_for(uuid, uuid) from public;
revoke all on function public.my_trial_discount(uuid) from public;
grant execute on function public.host_trial_discount_for(uuid, uuid) to authenticated;
grant execute on function public.my_trial_discount(uuid) to authenticated;

-- ------------------------------------------------------------
-- create_booking: 割引後の金額で消費・記録する
--   引数は変えない(mainにマージすると即デプロイされるため、
--   RPCのシグネチャ変更はフロントのデプロイ順と競合しうる)。
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_discount int;
  v_list_coins int;
  v_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_guest_name text;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
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

  -- 定価 → 初回お試し割引 → 実際に払う額。
  -- 割引率はこの時点の値で固定し、予約に残す。
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

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

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at, list_coins, discount_percent
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end,
    v_list_coins, v_discount
  )
  returning id into v_booking_id;

  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

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

comment on function public.create_booking(uuid, int, text) is
  '予約リクエストを作成し、コインをエスクローする。0038で初回お試し割引に対応(割引後の額を coins に入れるため、手数料も割引後の額にかかる)。';

-- ------------------------------------------------------------
-- extend_booking: 元の予約と同じ割引率で延長する
--   同じセッションの途中で単価が変わると説明がつかない(特商法の
--   価格表示上も不親切)ため、予約時に固定した割引率を引き継ぐ。
-- ------------------------------------------------------------
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
  v_list_add int;
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

  v_list_add := round(v_hourly_rate * p_additional_minutes / 60.0);
  v_add_coins := greatest(1, round(v_list_add * (100 - coalesce(v_booking.discount_percent, 0)) / 100.0));

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

  -- 延長分もロットの消費として記録する。記録しないと、返金(0030)のときに
  -- 当初の有効期限を引き直せず、資金決済法の適用除外(6か月)が崩れる。
  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_list_add
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
  'ゲストが進行中の予約を延長する。0038で、元の予約に適用した初回お試し割引を引き継ぐようにした。';
