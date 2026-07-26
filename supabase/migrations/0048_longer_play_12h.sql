-- ============================================================
-- 0048_longer_play_12h.sql
-- あそぶ時間を最長12時間にする
-- ------------------------------------------------------------
-- 上限を 240分 → 720分 に上げるだけでは、次の3つが壊れます。
--
-- ① 遊んでいる最中に自動確定される
--    auto_complete_bookings は scheduled_at(=開始時刻) + 72時間 を基準に
--    していました。4時間なら終了後68時間の猶予がありますが、長時間化すると
--    縮みます。さらに extend_booking には**総時間の上限が無い**ため、
--    延長を重ねると開始+72時間を追い越し、**プレイ中に報酬が確定**します。
--    → 基準を「終了時刻 + 72時間」に変え、延長にも上限を入れます。
--
-- ② キャンセル時の没収額が消費者契約法9条に触れる
--    時給2,000円×12時間 = 24,000コイン。開始直前キャンセルで50%没収なら
--    12,000円です。「平均的な損害」としてこの額を説明するのは困難です。
--
--    「平均的な損害」の実質は**その枠で他の客を取れなかった機会損失**です。
--    12時間予約する客が別にいる確率は低いので、損害を予約時間に比例させるのは
--    実態に合いません。差し押さえられる時間はせいぜい2〜3時間分、と整理して
--    **没収額に上限**を設けます。
--
--      没収額 = min(従来の計算, 経過時間分 + 上限(既定3時間分))
--
--    経過時間分を足しているのは、開始後のキャンセルでは**既に提供された役務の
--    対価**は当然ピタメイトのものだからです。これを入れないと、12時間予約の
--    11時間目にキャンセルされたピタメイトが3時間分しか受け取れません。
--
--    この式は**4時間以下の予約の挙動をほぼ変えません**(4時間予約の開始直前
--    キャンセルは50%=2時間分で、上限3時間分に届かない)。長時間予約だけが
--    頭打ちになります。唯一変わるのは「開始直後のキャンセル」で、従来の全額
--    没収から「経過分+3時間分」に緩みます。これはゲストに有利な方向であり、
--    9条のリスクを下げるので、弁護士査読前に入れても問題は増えません。
--
-- ③ 予約時間の刻みが細かすぎて選べない
--    30分刻みのままだと720分で24択。4時間を超えたら1時間刻みにして16択に
--    します。サーバ側も同じ規則で検査します(画面とサーバがずれると、
--    選べるのに申込時に INVALID_DURATION で弾かれる)。
--
-- なお**予約時間帯の重複チェックは、いまも入っていません**。12時間予約は
-- 1日の枠を大きく占めるため早めに必要ですが、「必ず壊れる」ものではないので
-- 別の課題として open-issues.md に切り出しています。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 上限と刻みのパラメータ
-- ------------------------------------------------------------
-- 0041 の制約は上限600分だった。12時間(720分)を許すため引き上げる。
alter table public.platform_pricing
  drop constraint if exists platform_pricing_max_duration_check;
alter table public.platform_pricing
  add constraint platform_pricing_max_duration_check
  check (max_duration_minutes between 30 and 1440 and max_duration_minutes % 30 = 0);

update public.platform_pricing set max_duration_minutes = 720 where id = 1;

-- bookings 側の上限も 0035 で 600分に固定されていた。
-- ここは「延長も含めた最終的な長さ」なので、上限と揃える。
alter table public.bookings drop constraint if exists bookings_duration_minutes_check;
alter table public.bookings
  add constraint bookings_duration_minutes_check
  check (duration_minutes >= 30 and duration_minutes <= 1440);

alter table public.platform_pricing
  add column if not exists duration_fine_step_minutes int not null default 30,
  add column if not exists duration_coarse_step_minutes int not null default 60,
  -- 細かい刻みを使う上限。ここを超えたら粗い刻みになる
  add column if not exists duration_fine_until_minutes int not null default 240,
  -- キャンセルで没収できる上限(ピタメイトの時間換算)。機会損失の見積り
  add column if not exists cancel_forfeit_cap_minutes int not null default 180;

comment on column public.platform_pricing.cancel_forfeit_cap_minutes is
  'キャンセル時に没収できる上限を「予約の何分ぶんの対価か」で表す。消費者契約法9条の平均的な損害に寄せるための頭打ち。既定180分(3時間)。';

-- ------------------------------------------------------------
-- 2. 予約時間の妥当性。画面とサーバで同じ規則を使うため関数に切り出す
-- ------------------------------------------------------------
create or replace function public.is_valid_booking_duration(p_minutes int)
returns boolean
language sql
stable
set search_path = public
as $$
  select case
    when p_minutes is null then false
    else exists (
      select 1 from public.platform_pricing p
      where p.id = 1
        and p_minutes >= p.duration_fine_step_minutes
        and p_minutes <= p.max_duration_minutes
        and case
              when p_minutes <= p.duration_fine_until_minutes
                then p_minutes % p.duration_fine_step_minutes = 0
              else p_minutes % p.duration_coarse_step_minutes = 0
            end
    )
  end;
$$;

comment on function public.is_valid_booking_duration(int) is
  'あそぶ時間として受け付ける値か。4時間までは30分刻み、それ以降は1時間刻み(既定)。';

-- ------------------------------------------------------------
-- 3. create_booking: 刻みの判定を関数に委ねる
--    (0041版から、時間の検査部分だけを差し替える)
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
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
  v_verified boolean;
  v_coins int;
  v_list_coins int;
  v_discount int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_lead int;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_lead) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hs.hourly_rate, hs.is_host into v_hourly_rate, v_is_host
  from public.host_settings hs where hs.user_id = p_host_id for share;
  if not coalesce(v_is_host, false) or v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  select pts.is_verified into v_verified
  from public.profile_trust_stats pts where pts.user_id = p_host_id;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
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

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, policy_version, policy_agreed_at,
    list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
  )
  returning id into v_booking_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$$;

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 4. extend_booking: 合計時間に上限を入れる
--    これが無いと、延長を重ねて自動確定の72時間を追い越せてしまう。
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
  v_add_coins int;
  v_max int;
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

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
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

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

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
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

revoke all on function public.extend_booking(uuid, int) from public;
grant execute on function public.extend_booking(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 5. 返還額の計算。率だけでなく「没収の上限」を効かせる
--    率(booking_refund_percent)はそのまま残し、額の算出をここに集約する。
-- ------------------------------------------------------------
create or replace function public.booking_refund_coins(
  p_coins int,
  p_duration_minutes int,
  p_percent int,
  p_scheduled_at timestamptz,
  p_at timestamptz default now()
)
returns int
language sql
stable
set search_path = public
as $$
  with p as (select cancel_forfeit_cap_minutes as cap from public.platform_pricing where id = 1),
  calc as (
    select
      -- 1分あたりの対価。割引後の実額(coins)を基準にする
      p_coins::numeric / greatest(p_duration_minutes, 1) as per_min,
      -- 開始からの経過(分)。開始前は0
      greatest(0, extract(epoch from (p_at - p_scheduled_at)) / 60.0) as elapsed_min,
      (select cap from p) as cap_min
  )
  select greatest(0, least(
    p_coins,
    -- 返還額 = 予約額 − 没収額
    p_coins - least(
      -- 従来の計算(率による没収)
      p_coins - round(p_coins * p_percent / 100.0),
      -- 上限: 提供済みの分 + 機会損失の上限
      round(least(calc.per_min * calc.elapsed_min, p_coins::numeric))
        + round(calc.per_min * calc.cap_min)
    )
  ))::int
  from calc;
$$;

comment on function public.booking_refund_coins(int, int, int, timestamptz, timestamptz) is
  'キャンセル時に実際に返すコイン数。率による没収に「提供済み分+機会損失の上限」の頭打ちをかける。'
  '消費者契約法9条の平均的な損害に寄せるための調整で、4時間以下の予約ではほぼ従来どおり。';

-- 画面表示用。いまキャンセルしたら実際に何コイン戻るかを返す。
-- 率だけでは上限が反映されないため、フロントでの掛け算をやめてこちらを使う。
create or replace function public.my_booking_refund_quote(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
  v_pct int;
  v_refund int;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;

  v_pct := public.booking_refund_percent(v_b.status, v_b.confirmed_at, v_b.scheduled_at, now());
  v_refund := public.booking_refund_coins(
    v_b.coins, v_b.duration_minutes, v_pct, v_b.scheduled_at, now());

  return jsonb_build_object(
    'coins', v_b.coins,
    'refund_coins', v_refund,
    'forfeit_coins', v_b.coins - v_refund,
    'base_percent', v_pct,
    -- 上限が効いたか(効いていれば、率から期待される額より多く戻る)
    'capped', v_refund > round(v_b.coins * v_pct / 100.0)
  );
end;
$$;

revoke all on function public.my_booking_refund_quote(uuid) from public;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. cancel_booking: 返還額の算出を booking_refund_coins に委ねる
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
  v_new_status text;
  v_other uuid;
  v_name text;
  v_pct int;
  v_refund_total int;
  v_refund_paid int;
  v_refund_bonus int;
  v_to_host int;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  -- 承諾前の取り消しは、どちらからでも全額返還(従来どおり)
  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');
    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額戻りました', p_booking_id);
    return;
  end if;

  if v_booking.status <> 'confirmed' then raise exception 'BOOKING_NOT_CANCELLABLE'; end if;

  if v_uid = v_booking.host_id then
    -- ピタメイト都合はいつでも全額
    v_pct := 100;
    v_new_status := 'cancelled_by_host';
    update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_pct := public.booking_refund_percent(
      v_booking.status, v_booking.confirmed_at, v_booking.scheduled_at, now());
    -- 全額戻らなかった場合だけドタキャンとして記録する
    if v_pct < 100 then
      update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  -- 返す枚数。没収の上限(0048)を効かせてから、購入コインを先に返す
  v_refund_total := public.booking_refund_coins(
    v_booking.coins, v_booking.duration_minutes, v_pct, v_booking.scheduled_at, now());
  v_refund_paid := least(v_booking.paid_coins, v_refund_total);
  v_refund_bonus := v_refund_total - v_refund_paid;
  v_to_host := v_booking.coins - v_refund_total;

  update public.bookings set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund_total > 0 then
    update public.coin_wallets
      set balance = balance + v_refund_paid, bonus_balance = bonus_balance + v_refund_bonus
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id, v_refund_paid, v_refund_bonus);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_refund_total, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 一部も戻らない場合でも、消費記録は閉じておく(期限管理のため)
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0);
  end if;

  if v_to_host > 0 then
    update public.coin_wallets set earned_balance = earned_balance + v_to_host
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_to_host, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case when v_refund_total >= v_booking.coins then 'コインは全額戻りました'
         when v_refund_total = 0 then 'コインは報酬として確定しました'
         else v_refund_total || 'コインが戻り、' || v_to_host || 'コインが報酬として確定しました' end,
    p_booking_id);
end;
$$;

revoke all on function public.cancel_booking(uuid, text) from public;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 7. 自動確定を「終了時刻 + 72時間」に変える
--    開始基準のままだと、長時間予約や延長でプレイ中に確定してしまう。
-- ------------------------------------------------------------
create or replace function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select id, host_id, coins
    from public.bookings
    where status = 'confirmed'
      and held_at is null
      and scheduled_at + make_interval(mins => duration_minutes) + interval '72 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  'ゲストが完了操作をしないまま終了から72時間が過ぎた予約を自動確定する。'
  '保留中(held_at)のものは対象外(E-12)。0048で基準を開始時刻から終了時刻に変更。';

revoke all on function public.auto_complete_bookings() from public;

-- ------------------------------------------------------------
-- 8. 通報による保留の対象範囲も終了時刻ベースに揃える
--    (自動確定の窓と一致していないと、確定済みのものを保留しようとしたり
--     まだ確定していないものを取りこぼしたりする)
-- ------------------------------------------------------------
create or replace function public._hold_bookings_on_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
begin
  for v_b in
    select b.id
    from public.bookings b
    where b.status = 'confirmed'
      and b.held_at is null
      and (
        (b.guest_id = NEW.reporter_id and b.host_id = NEW.reported_id) or
        (b.host_id = NEW.reporter_id and b.guest_id = NEW.reported_id)
      )
      and b.scheduled_at + make_interval(mins => b.duration_minutes) + interval '72 hours' >= now()
  loop
    perform public._hold_booking(v_b.id, 'report');
  end loop;
  return NEW;
end;
$$;

drop trigger if exists reports_hold_bookings on public.reports;
create trigger reports_hold_bookings
  after insert on public.reports
  for each row execute function public._hold_bookings_on_report();
