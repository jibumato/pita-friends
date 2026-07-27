-- ============================================================
-- 予約の開始時刻をゲストが指定できるようにし、キャンセルを段階制にする
-- ------------------------------------------------------------
-- これまでは approve_booking() が scheduled_at を now() で上書きしていたため、
-- 「開始1時間前まで全額返還」という説明が**構造上ずっと成立しない**状態だった
-- (承諾した瞬間が開始時刻なので、承諾直後のキャンセルでも常に「1時間前以降」)。
-- open-issues.md の E-10、弁護士質問 Q14-b/c の本体。
--
-- ■ 受付の締切とキャンセル猶予を「別の基準」にする
--   締切を1つの数字で決めようとすると必ずどちらかが壊れる。直前まで予約できる
--   ようにすると、そのゲストには無料でキャンセルできる時間が最初から存在しない。
--   そこで2本立てにする。
--     * 開始時刻を基準とする猶予  … 開始1時間前まで全額
--     * 承諾時刻を基準とする猶予  … 承諾から5分以内は全額(誤タップ・翻意の救済)
--   どちらか有利なほうを適用する。これで、
--     3日先の予約   → 開始1時間前まで自由にキャンセルできる
--     30分後の予約  → 承諾から5分は全額戻る
--   と、どちらのケースでも逃げ道が残る。
--
-- ■ 100%没収をやめ、段階制にする
--   消費者契約法9条(平均的な損害を超えるキャンセル料は無効)への対応。
--   開始1時間前を切ってからは一部返還とし、開始後・無断欠席のみ返還なしとする。
--   **返還率・猶予の数値は platform_pricing に置く**。弁護士の回答(Q14-b/c)で
--   数値が変わってもコードを触らずに済むようにするため。
--
-- ■ 「今すぐ」も残す
--   requested_start_at が null なら従来どおり承諾時点が開始時刻。
--   このアプリの中心にある「今夜すぐ」の体験を壊さない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 予約に「希望開始時刻」と「承諾時刻」を持たせる
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists requested_start_at timestamptz;
alter table public.bookings
  add column if not exists confirmed_at timestamptz;

comment on column public.bookings.requested_start_at is
  'ゲストが指定した希望開始時刻。null なら「今すぐ」(承諾時点が開始時刻)。';
comment on column public.bookings.confirmed_at is
  'ホストが承諾した時刻。キャンセル猶予の起点。0040以前の行は null。';

-- 既存行は「承諾時点＝開始時刻」だったので、確定済みのものはそこを承諾時刻とみなす
update public.bookings
  set confirmed_at = scheduled_at
  where confirmed_at is null
    and status in ('confirmed', 'completed', 'cancelled_by_guest', 'cancelled_by_host',
                   'no_show_host', 'no_show_guest');

-- ------------------------------------------------------------
-- 2. キャンセルポリシーの数値を platform_pricing に集約する
-- ------------------------------------------------------------
alter table public.platform_pricing
  add column if not exists free_cancel_hours numeric(4, 2) not null default 1;
alter table public.platform_pricing
  add column if not exists cancel_grace_minutes int not null default 5;
alter table public.platform_pricing
  add column if not exists late_cancel_refund_percent int not null default 50;
alter table public.platform_pricing
  add column if not exists min_lead_minutes int not null default 30;
alter table public.platform_pricing
  add column if not exists max_lead_days int not null default 7;

alter table public.platform_pricing
  drop constraint if exists platform_pricing_late_refund_check;
alter table public.platform_pricing
  add constraint platform_pricing_late_refund_check
  check (late_cancel_refund_percent between 0 and 100);

comment on column public.platform_pricing.free_cancel_hours is
  '全額返還となる「開始の何時間前まで」。';
comment on column public.platform_pricing.cancel_grace_minutes is
  '承諾から何分以内なら全額返還とするか。「今すぐ」の予約では開始＝承諾なので、'
  'この猶予だけが誤タップ・翻意の救済になる。長すぎると「無料で遊べる時間」に'
  'なってしまうため短く取る(既定5分。最短予約枠30分の1/6)。';
comment on column public.platform_pricing.late_cancel_refund_percent is
  '開始直前(無料枠を過ぎてから開始まで)のキャンセルで返還する割合(%)。'
  '消費者契約法9条の「平均的な損害」との関係で、弁護士回答により変わりうる数値。';
comment on column public.platform_pricing.min_lead_minutes is
  '開始時刻を指定する場合、いま から最短で何分先を選べるか。';
comment on column public.platform_pricing.max_lead_days is
  '開始時刻を指定する場合、いま から最長で何日先を選べるか。';

-- ------------------------------------------------------------
-- 3. 返還率の判定(1か所に集約し、画面とサーバで必ず同じ答えを出す)
-- ------------------------------------------------------------
create or replace function public.booking_refund_percent(
  p_status text,
  p_confirmed_at timestamptz,
  p_scheduled_at timestamptz,
  p_at timestamptz default now()
)
returns int
language sql
stable
set search_path = public
as $$
  select case
    -- 承諾前(リクエスト中)の取り消しは全額
    when p_status = 'requested' then 100
    when p_status <> 'confirmed' then 0
    -- 承諾から一定時間内は全額(直前予約でも猶予が残るように)
    -- 「今すぐ」の予約は開始時刻＝承諾時刻なので、ここに「開始前」の条件を
    -- 付けると猶予そのものが打ち消される(まさに E-10 で問題にしている
    -- 「承諾の瞬間から100%没収」が残ってしまう)。開始時刻とは切り離す。
    when p_confirmed_at is not null
     and p_at < p_confirmed_at + make_interval(mins => (select cancel_grace_minutes from public.platform_pricing where id = 1)) then 100
    -- 開始の一定時間前までは全額
    when p_at < p_scheduled_at - make_interval(mins => (select round(free_cancel_hours * 60)::int from public.platform_pricing where id = 1)) then 100
    -- 開始までは一部返還
    when p_at < p_scheduled_at then (select late_cancel_refund_percent from public.platform_pricing where id = 1)
    -- 開始後は返還なし
    else 0
  end;
$$;

comment on function public.booking_refund_percent(text, timestamptz, timestamptz, timestamptz) is
  'ゲスト都合でキャンセルしたときに返還される割合(%)。画面の見積りとサーバの実処理で必ず同じ式を使う。';

-- 画面表示用。自分が当事者の予約について、いまキャンセルしたら何%戻るかを返す。
create or replace function public.my_booking_refund_percent(p_booking_id uuid)
returns int
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;
  return public.booking_refund_percent(v_b.status, v_b.confirmed_at, v_b.scheduled_at, now());
end;
$$;

revoke all on function public.my_booking_refund_percent(uuid) from public;
grant execute on function public.my_booking_refund_percent(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4. create_booking: 希望開始時刻を受け取れるようにする
--    引数を増やすため、旧3引数版は薄いラッパーとして残す
--    (main にマージすると即デプロイされるので、フロントの反映順と競合しうる)
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
  v_min_lead int;
  v_max_days int;
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

  -- 開始時刻を指定する場合の受付範囲を確かめる
  if p_scheduled_at is not null then
    select min_lead_minutes, max_lead_days into v_min_lead, v_max_days
    from public.platform_pricing where id = 1;
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_days) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings where user_id = p_host_id for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

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
    policy_version, policy_agreed_at, list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
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
    v_coins || 'コイン・' || p_duration_minutes || '分'
      || case when p_scheduled_at is null then '(今すぐ)'
              else '(' || to_char(p_scheduled_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜)' end
      || '。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

-- 旧3引数版は「今すぐ」として新版へ委譲する(経過措置)
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text
)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.create_booking(p_host_id, p_duration_minutes, p_policy_version, null::timestamptz);
$$;

comment on function public.create_booking(uuid, int, text) is
  '経過措置。開始時刻を指定しない(=今すぐ)申込み。フロントのデプロイ完了後に削除してよい。';

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 5. approve_booking: 希望開始時刻があればそれを尊重する
-- ------------------------------------------------------------
create or replace function public.approve_booking(p_booking_id uuid)
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
  v_start timestamptz;
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

  -- 指定があればその時刻、無ければ従来どおり承諾時点が開始時刻。
  -- 承諾時刻は別に持つ(キャンセル猶予の起点になるため。0040以前は
  -- scheduled_at が承諾時刻を兼ねていた)。
  v_start := coalesce(v_booking.requested_start_at, now());

  update public.bookings
    set status = 'confirmed', scheduled_at = v_start, confirmed_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ピタメイト') || 'さんが予約を承諾しました',
    case when v_booking.requested_start_at is null
         then 'トークが始まりました。プレイの準備をしましょう'
         else to_char(v_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜 で成立しました' end,
    v_promise_id
  );

  return v_promise_id;
end;
$$;

-- ------------------------------------------------------------
-- 6. ロットの返還を一部返還に対応させる
--    p_paid / p_bonus に「戻す枚数」を渡す。null なら全部戻す(従来どおり)。
--    戻さなかった分は没収(ホストの報酬)になるので、restored_at は立てて
--    しまってよい。予約は取り消しで終端状態になり、二重返還は起きない。
-- ------------------------------------------------------------
-- 旧(1引数)と新(3引数)の両方を落としてから作る。新しいほうも落とすのは、
-- このファイルをもう一度流したときに「同じ引数の関数が既にある」で
-- 止まらないようにするため(適用済みか分からなくなったとき、番号順に
-- 流し直せるほうが安全)。
drop function if exists public._refund_coin_lots_for_booking(uuid);
drop function if exists public._refund_coin_lots_for_booking(uuid, int, int);

create function public._refund_coin_lots_for_booking(
  p_booking_id uuid,
  p_paid int default null,
  p_bonus int default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_rec record;
  v_found boolean := false;
  v_lapsed_paid int := 0;
  v_lapsed_bonus int := 0;
  v_left_paid int;
  v_left_bonus int;
  v_take int;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null then
    return;
  end if;

  v_left_paid := coalesce(p_paid, v_booking.paid_coins);
  v_left_bonus := coalesce(p_bonus, v_booking.bonus_coins);

  -- 期限の近いものから戻す(消費したときと同じ順序)
  for v_rec in
    select id, kind, expires_at, coins
    from public.coin_lot_consumptions
    where booking_id = p_booking_id and restored_at is null
    order by expires_at
    for update
  loop
    v_found := true;

    if v_rec.kind = 'paid' then
      v_take := least(v_left_paid, v_rec.coins);
      v_left_paid := v_left_paid - v_take;
    else
      v_take := least(v_left_bonus, v_rec.coins);
      v_left_bonus := v_left_bonus - v_take;
    end if;

    if v_take > 0 then
      if v_rec.expires_at > now() then
        insert into public.coin_lots (user_id, kind, remaining, expires_at)
          values (v_booking.guest_id, v_rec.kind, v_take, v_rec.expires_at);
      elsif v_rec.kind = 'paid' then
        v_lapsed_paid := v_lapsed_paid + v_take;
      else
        v_lapsed_bonus := v_lapsed_bonus + v_take;
      end if;
    end if;

    update public.coin_lot_consumptions set restored_at = now() where id = v_rec.id;
  end loop;

  -- 0030 より前の予約(消費記録なし)。予約作成時刻を基準に引き直す。
  if not v_found then
    if v_left_paid > 0 then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, 'paid', v_left_paid, public.coin_expiry_from(v_booking.created_at));
    end if;
    if v_left_bonus > 0 then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, 'bonus', v_left_bonus, public.coin_expiry_from(v_booking.created_at));
    end if;
  end if;

  -- 当初の期限をすでに過ぎていた分は戻さない。呼び出し側が足したキャッシュ残高から引く。
  if v_lapsed_paid > 0 or v_lapsed_bonus > 0 then
    update public.coin_wallets
      set balance = greatest(0, balance - v_lapsed_paid),
          bonus_balance = greatest(0, bonus_balance - v_lapsed_bonus)
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, -(v_lapsed_paid + v_lapsed_bonus), 'expire', p_booking_id,
              'refund_lapsed');
  end if;
end;
$$;

revoke all on function public._refund_coin_lots_for_booking(uuid, int, int) from public;

-- ------------------------------------------------------------
-- 7. cancel_booking: 段階制の返還にする
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

  -- 返す枚数。購入コインから先に返す(消費したときと同じ順序)
  v_refund_total := round(v_booking.coins * v_pct / 100.0);
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
    case when v_pct = 100 then 'コインは全額戻りました'
         when v_pct = 0 then '開始後のキャンセルのため、コインは報酬として確定しました'
         else v_pct || '%のコインが戻り、残りは報酬として確定しました' end,
    p_booking_id);
end;
$$;

-- ------------------------------------------------------------
-- 8. 立証材料ビューを承諾時刻ベースに直す
--    0032 では scheduled_at が承諾時刻を兼ねていたため
--    `scheduled_at as approved_at` としていたが、開始時刻を指定できるように
--    なった以上その等式は成り立たない。
-- ------------------------------------------------------------
drop view if exists public.guest_cancellation_evidence;

create view public.guest_cancellation_evidence
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.status,
  b.policy_version,
  b.policy_agreed_at,
  b.created_at as requested_at,
  b.confirmed_at as approved_at,
  b.requested_start_at,
  b.scheduled_at as starts_at,
  b.cancelled_at,
  b.coins,
  b.list_coins,
  b.discount_percent,
  extract(epoch from (b.cancelled_at - b.confirmed_at))::int as seconds_after_approval,
  extract(epoch from (b.scheduled_at - b.cancelled_at))::int as seconds_before_start,
  public.booking_refund_percent(b.status, b.confirmed_at, b.scheduled_at, b.cancelled_at)
    as refund_percent_at_cancel
from public.bookings b
where b.cancelled_at is not null;

comment on view public.guest_cancellation_evidence is
  'キャンセルの実態(承諾からの経過・開始までの残り・適用された返還率)。'
  '消費者契約法9条の「平均的な損害」を検討するための材料。0040で承諾時刻ベースに修正。';
