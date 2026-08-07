-- ============================================================
-- 0111: 経営指標の集計期間が JST になっていなかったのを直す
--
-- ■ 何が起きていたか
--   `0110` が `admin_business_kpis` を書き直したとき（ギフト比率の追加）、
--   集計期間の作り方が `0105` から変わっていた。
--
--     0105（正）: v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
--     0110（誤）: v_from := coalesce(p_from, ...)::timestamptz;
--
--   `date::timestamptz` は**セッションのタイムゾーン**で解釈される。
--   Supabase のセッションは UTC なので、日本時間の日付を渡しても
--   UTC の 00:00 として扱われ、**集計の窓が9時間ずれる**。
--
--   結果として、日本時間の 00:00〜09:00 に発生した手数料が、
--   その日の集計から落ちて前日に入る。日次で見れば毎日ずれ、
--   月次でも月初・月末の境界がずれる。
--
-- ■ なぜ気づきにくかったか
--   母数が0になると各指標は `null` を返す設計になっている。
--   `29_business_kpis.sql` の判定は `(... ->> 'blendedPercent')::numeric <> 17.73`
--   の形で、値が null だと比較結果も null になり、`if null then` は
--   発火しない。**窓がずれて空になっても、テストは黙って通っていた。**
--   落ちたのは activeHosts だけで、これは count(*) が 0 を返すため
--   null にならず、比較が成立したから。
--
--   → 検知できるように、テスト側も「値が入っていること」を先に確かめる形へ
--     直した（`supabase/tests/29_business_kpis.sql`）。
--
-- ■ なぜ直す価値があるか
--   この関数の `giftToBookingPercent` は、**ギフトが従たる地位に留まることを
--   事後的に示すために置いた指標**（`0110`／2026-08-05 の弁護士回答 論点B(b)2）。
--   財務局への説明に使う数字がずれたままなのは、いちばん困る。
--
-- ■ 引数の既定値（null）は 0110 のまま残す
--   運営コンソールが期間を指定せずに呼ぶ経路があるため。
--   ただし既定値の算出も JST の日付から作り、変換も JST で行う。
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_from_d date;
  v_to_d date;
  v_gross bigint := 0;
  v_fee bigint := 0;
  v_booking_gross bigint := 0;
  v_booking_fee bigint := 0;
  v_gift_gross bigint := 0;
  v_gift_fee bigint := 0;
  v_hosts int := 0;
  v_top5 bigint := 0;
  v_top1 bigint := 0;
  v_purchase_yen bigint := 0;
  v_safety_yen bigint := 0;
  v_cb_count int := 0;
  v_cb_yen bigint := 0;
  v_cb_open int := 0;
  v_cb_lost int := 0;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  -- 既定は「JSTの今日から遡って30日」。
  -- **日付は JST で決め、timestamptz への変換も JST で行う。**
  -- `date::timestamptz` はセッションのタイムゾーン(UTC)で解釈されるため使わない。
  v_from_d := coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - 30);
  v_to_d := coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date);
  if v_to_d < v_from_d then
    raise exception 'INVALID_RANGE';
  end if;

  -- JSTの [v_from_d 00:00, v_to_d+1日 00:00)。会計タブ(0086)と同じ切り方
  v_from := (v_from_d::timestamp at time zone 'Asia/Tokyo');
  v_to := ((v_to_d + 1)::timestamp at time zone 'Asia/Tokyo');

  -- ① 利用料の実効率
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ② 上位集中(予約の対価で見る)
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where kind = 'booking' and created_at >= v_from and created_at < v_to
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ③ チャージバック
  select
    coalesce(sum(price_yen), 0),
    coalesce(sum(safety_fee_yen), 0)
  into v_purchase_yen, v_safety_yen
  from public.coin_purchases
  where created_at >= v_from and created_at < v_to;

  select
    count(*),
    coalesce(sum(amount_yen), 0),
    count(*) filter (where status = 'open'),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', v_from_d,
    'to', v_to_d,
    'fees', jsonb_build_object(
      'grossCoins', v_gross,
      'feeCoins', v_fee,
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end,
      -- 0110: ギフトが従たる地位に留まることを事後的に示すための比率
      'giftToBookingPercent', case when v_booking_gross > 0
        then round(v_gift_gross::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'concentration', jsonb_build_object(
      'activeHosts', v_hosts,
      'top5Coins', v_top5,
      'top5Percent', case when v_booking_gross > 0
        then round(v_top5::numeric * 100 / v_booking_gross, 1) else null end,
      'top1Percent', case when v_booking_gross > 0
        then round(v_top1::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'chargebacks', jsonb_build_object(
      'count', v_cb_count,
      'amountYen', v_cb_yen,
      'openCount', v_cb_open,
      'lostCount', v_cb_lost,
      'purchaseYen', v_purchase_yen,
      'safetyFeeYen', v_safety_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    )
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営の要点(運営)。利用料の混合実効率・上位集中・チャージバック率・ギフト比率。0111で集計期間をJSTに直した(0110がセッションのタイムゾーンで日付を変換しており、窓が9時間ずれていた)。母数0は null で返し、0%と区別する。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;
