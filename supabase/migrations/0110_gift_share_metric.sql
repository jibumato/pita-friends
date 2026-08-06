-- ============================================================
-- 0110: ギフトが「従たる地位」に留まっていることを、月次で残す
--
-- 2026-08-05 の弁護士回答（論点B(b)2）:
--
--   「**月次モニタリング指標の設定** — ギフト流通総額／予約対価総額の比率を
--    継続的に記録し、**ギフトが従たる地位に留まることを事後的に立証できる**
--    ようにする（分析メモの実証パート）。」
--
-- ■ なぜ数字が要るのか
--
--   ギフトを「為替取引に当たらない」と整理する根拠のひとつは、
--   **ギフトが主たる収益源ではなく、役務提供に付随する任意の追加対価に
--   すぎない**ことにある。これは条文で宣言するだけでは足りず、
--   **実績で示せなければ、財務局への照会でも紛争でも通らない。**
--
--   逆に、この比率が上がり続けているのに放置していると、
--   「実態としては送金の仕組みだった」という評価を自ら裏づけることになる。
--
-- ■ どこに出すか
--   運営コンソールの「経営」タブ（`admin_business_kpis`）に1行足す。
--   混合実効率・上位集中・チャージバック率と同じ場所で毎月見る。
--   **別画面にすると見なくなる。**
--
-- ■ 母数が0のときは null
--   0105 と同じ扱い。**「0%」と「まだ取引が無い」を区別する。**
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
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

  v_from := coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - 30)::timestamptz;
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date) + 1)::timestamptz;

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
    count(*) filter (where resolved_at is null),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
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
      -- 0110: **ギフトが従たる地位に留まっているか。**
      -- 為替取引に当たらないという整理の実証パート
      -- (2026-08-05の弁護士回答 論点B(b)2)。
      -- 分母は予約の対価。**上がり続けているのに放置しない。**
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
  '経営の要点(運営)。利用料の混合実効率・上位集中・チャージバック率。0110で「ギフト流通総額／予約対価総額」を追加(ギフトが従たる地位に留まることを事後的に立証するため。2026-08-05の弁護士回答 論点B(b)2)。母数0は null で返し、0%と区別する。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;
