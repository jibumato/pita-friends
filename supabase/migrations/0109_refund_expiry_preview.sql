-- ============================================================
-- 0109: キャンセルの前に、戻るコインの有効期限を知らせる
--
-- 規約 第9条5の2 後段（2026-07-31 新設）:
--
--   「当社は、キャンセルの手続を行う画面において、**返還されるコインの
--    有効期限が近い場合はその旨を事前に表示します。**」
--
-- **書いたが、実装していなかった。** 2026-08-05 の横断点検（G18）で判明。
-- `my_booking_refund_quote()` は枚数と率しか返しておらず、期限を返していない。
--
-- ■ なぜ「守れない約束」の中でも重いのか
--
--   コインの返還は、**消費したときの期限をそのまま引き継ぐ**（同項前段）。
--   したがって、
--     ・当初の期限を**既に過ぎている分は、戻らずに消える**
--     ・戻っても**残りわずかで、使い切れずに失効する**
--   という事態が現に起こる。
--
--   ゲスト都合のキャンセルでは、消えた分の金銭返金もない
--   （第9条5の3の対象は**ゲスト無帰責**の場合だけ）。
--   **押す前に知らせないと「知らされずに消えた」という話になる。**
--
-- ■ 何を返すか
--
--   `_refund_coin_lots_for_booking()` の割当てを**書き込まずに**なぞる。
--   実際に戻す処理と同じ順序（期限の早い順）・同じ有償/無償の配分で数え、
--     ・lapsed_coins … 既に期限切れで**戻らない**枚数（うち有償分も）
--     ・soon_coins   … 戻るが**期限が近い**枚数（既定14日以内）
--     ・soonest_expires_at … 戻る分のうち最も早い期限
--     ・cash_refund_coins  … 消えた分のうち**金銭で返す**枚数
--   を返す。
--
--   ⚠️ **画面で計算し直さないこと。** 割当ての規則が2か所になると、
--   表示と実際がずれる（0048 で率から実額が出せなくなったのと同じ轍）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 割当てのなぞり（書き込みなし）
--
-- _refund_coin_lots_for_booking と**同じループ**にしてある。
-- どちらかを直すときは、必ず両方を直すこと。
-- ------------------------------------------------------------
create or replace function public._refund_lot_forecast(
  p_booking_id uuid,
  p_paid int,
  p_bonus int,
  p_soon_days int default 14
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_booking public.bookings;
  v_rec record;
  v_found boolean := false;
  v_left_paid int;
  v_left_bonus int;
  v_take int;
  v_lapsed_paid int := 0;
  v_lapsed_bonus int := 0;
  v_soon int := 0;
  v_soonest timestamptz;
  v_expiry timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null then
    return jsonb_build_object('lapsed_coins', 0, 'lapsed_paid_coins', 0,
                              'soon_coins', 0, 'soonest_expires_at', null);
  end if;

  v_left_paid := coalesce(p_paid, v_booking.paid_coins);
  v_left_bonus := coalesce(p_bonus, v_booking.bonus_coins);

  for v_rec in
    select kind, expires_at, coins
    from public.coin_lot_consumptions
    where booking_id = p_booking_id and restored_at is null
    order by expires_at
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
        if v_soonest is null or v_rec.expires_at < v_soonest then
          v_soonest := v_rec.expires_at;
        end if;
        if v_rec.expires_at < now() + make_interval(days => p_soon_days) then
          v_soon := v_soon + v_take;
        end if;
      elsif v_rec.kind = 'paid' then
        v_lapsed_paid := v_lapsed_paid + v_take;
      else
        v_lapsed_bonus := v_lapsed_bonus + v_take;
      end if;
    end if;
  end loop;

  -- 0030 より前の予約(消費記録なし)。本体と同じく作成時刻から引き直す。
  if not v_found then
    v_expiry := public.coin_expiry_from(v_booking.created_at);
    if v_expiry > now() then
      v_soonest := v_expiry;
      if v_expiry < now() + make_interval(days => p_soon_days) then
        v_soon := v_left_paid + v_left_bonus;
      end if;
    else
      v_lapsed_paid := v_left_paid;
      v_lapsed_bonus := v_left_bonus;
    end if;
  end if;

  return jsonb_build_object(
    'lapsed_coins', v_lapsed_paid + v_lapsed_bonus,
    'lapsed_paid_coins', v_lapsed_paid,
    'soon_coins', v_soon,
    'soonest_expires_at', v_soonest
  );
end;
$$;

comment on function public._refund_lot_forecast(uuid, int, int, int) is
  'キャンセルで戻るコインの期限を、書き込まずに見積もる(規約 第9条5の2後段・0109)。_refund_coin_lots_for_booking と同じ順序・同じ配分でなぞる。**片方だけ直さないこと。**';

revoke all on function public._refund_lot_forecast(uuid, int, int, int) from public, anon;

-- ------------------------------------------------------------
-- 2. 見積りに期限を足す
-- ------------------------------------------------------------
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
  v_refund_paid int;
  v_refund_bonus int;
  v_fc jsonb;
  v_soon_days int;
  v_guest_fault boolean;
  v_cash int;
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

  -- cancel_booking と同じ配分(有償から先に戻す)
  v_refund_paid := least(v_b.paid_coins, v_refund);
  v_refund_bonus := v_refund - v_refund_paid;

  -- 「期限が近い」の目安は、失効の事前通知(0089)と同じ日数を使う。
  -- **2か所に別の数字があると、通知が来ない期間に警告だけ出る**ような
  -- ちぐはぐが起きる
  select coalesce(expiry_notice_days, 14) into v_soon_days
    from public.platform_pricing where id = 1;

  v_fc := public._refund_lot_forecast(
    p_booking_id, v_refund_paid, v_refund_bonus, coalesce(v_soon_days, 14));

  -- いま押そうとしているのがゲストなら guest_fault。
  -- **ゲスト都合だと、消えた分の金銭返金は無い**(第9条5の3はゲスト無帰責のみ)。
  -- ここを取り違えると、消える話を「返金されます」と伝えてしまう
  v_guest_fault := auth.uid() = v_b.guest_id;
  v_cash := case when v_guest_fault then 0
                 else (v_fc ->> 'lapsed_paid_coins')::int end;

  return jsonb_build_object(
    'coins', v_b.coins,
    'refund_coins', v_refund,
    'forfeit_coins', v_b.coins - v_refund,
    'base_percent', v_pct,
    'capped', v_refund > round(v_b.coins * v_pct / 100.0),
    'played', v_b.guest_checked_in_at is not null and v_b.host_checked_in_at is not null,
    -- 0109(規約 第9条5の2後段)
    'lapsed_coins', (v_fc ->> 'lapsed_coins')::int,
    'soon_coins', (v_fc ->> 'soon_coins')::int,
    'soonest_expires_at', v_fc ->> 'soonest_expires_at',
    'soon_days', coalesce(v_soon_days, 14),
    'cash_refund_coins', v_cash
  );
end;
$$;

comment on function public.my_booking_refund_quote(uuid) is
  'いまキャンセルしたら何コイン戻るか。0109で、戻るコインの有効期限(既に切れて戻らない分・期限が近い分・最も早い期限)と、消えた分の金銭返金の有無を足した(規約 第9条5の2後段・5の3)。';

revoke all on function public.my_booking_refund_quote(uuid) from public, anon;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;
