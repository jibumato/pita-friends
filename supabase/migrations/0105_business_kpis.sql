-- ============================================================
-- 0105: 収益構造を見張る3つの指標(運営コンソール「経営」タブ)
-- ------------------------------------------------------------
-- 事業計画書(docs/business-plan-2026-08.md)の収益構造は、平常時は堅い。
-- 崩れるとしたら**構造の欠陥ではなく、前提が実績とずれたとき**なので、
-- ずれを早く見つけるための数字だけをここに集める。
--
-- ■ ① 混合実効率 … 計画は「実効利用料率18%」を置いている
--   利用料は超過累進なので、**稼ぐピタメイトほど率が下がる。**
--   マーケットプレイスのGMVは上位に集中する(べき分布になる)のが通例なので、
--   全体をならした実効率は計画の18%より**下振れしうる**。
--   16%を切ったら段の見直しを検討する(変更の予約は0091で実装済み・30日前告知)。
--
-- ■ ② 上位集中 … 上位5人のGMVシェア
--   実効率が下がる原因であり、同時に**チャーンリスク**でもある。
--   1人が抜けると売上の何割が消えるのかを、数字で見えるようにしておく。
--
-- ■ ③ チャージバック … 件数・金額・GMV比
--   平常時の収支は堅いが、**一撃で月次を壊せる唯一の項目**。
--   税理士の第3回回答が「支払手数料(チャージバック)」を独立科目にして
--   早期警戒指標に使うよう設計した、その画面側。
--
-- ■ おまけ: 決済手段の内訳
--   PayPay はカードより手数料が低いので、比率が上がるほど貢献利益率
--   (計画では19.4%)が改善する。0096で payment_method を記録しているので
--   ここで一緒に出す。**0096より前の購入は null**(当時はカードのみ)。
--
-- ■ この関数は数えるだけで、何も書き換えない
--   運営が読む用。stable + 管理者チェックのみ。
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date,
  p_to date
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
  v_gross bigint;
  v_fee bigint;
  v_booking_gross bigint;
  v_booking_fee bigint;
  v_gift_gross bigint;
  v_gift_fee bigint;
  v_hosts int;
  v_top5 bigint;
  v_top1 bigint;
  v_purchase_yen bigint;
  v_safety_yen bigint;
  v_cb_count int;
  v_cb_yen bigint;
  v_cb_open int;
  v_cb_lost int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;

  -- JSTの[p_from 00:00, p_to+1日 00:00)。会計タブ(0086)と同じ切り方にする
  v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
  v_to := ((p_to + 1)::timestamp at time zone 'Asia/Tokyo');

  -- ------------------------------------------------------------
  -- ① 混合実効率
  --
  -- **platform_fees が唯一の出典。** 予約とギフトで率がまったく違う
  -- (予約20〜12% / ギフト35%)ので、合算した「混合」と、内訳の両方を出す。
  -- 合算だけ見ていると、ギフトが増えただけで実効率が上がったように見える。
  -- ------------------------------------------------------------
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins)   filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins)   filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ------------------------------------------------------------
  -- ② 上位集中(予約のGMVで見る。ギフトは母数が別物なので混ぜない)
  -- ------------------------------------------------------------
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where created_at >= v_from and created_at < v_to and kind = 'booking'
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ------------------------------------------------------------
  -- ③ チャージバック
  --
  -- **GMVではなく購入額(円)に対する比で見る。** 申立ては購入に対して
  -- 起きるので、分母は売った額でなければ意味が合わない。
  -- ------------------------------------------------------------
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
      -- 混合実効率(%)。母数0なら null を返す。**0%と区別する**
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end
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
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    ),
    'safetyFeeYen', v_safety_yen
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営指標(運営)。混合実効率・上位集中・チャージバック比率を返す。'
  '事業計画書の前提(実効18%・貢献利益率19.4%)が実績とずれていないかを見張るためのもの。0105。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;

-- ------------------------------------------------------------
-- 決済手段の内訳(0096)
--
-- **別の関数にしてある。** 上のKPIは「構造がずれていないか」で、
-- こちらは「原価が下がる余地があるか」。混ぜると読む目的がぼやける。
-- ------------------------------------------------------------
create or replace function public.admin_payment_method_mix(
  p_from date,
  p_to date
)
returns table (
  method text,
  purchases int,
  amount_yen bigint,
  share_percent numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;

  v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
  v_to := ((p_to + 1)::timestamp at time zone 'Asia/Tokyo');

  return query
  with p as (
    select
      -- 0096より前の購入は null。**'card' に丸めない。**
      -- 「カードだった」と「記録が無い」は別のことで、
      -- 丸めると 0104 で直した記録漏れが見えなくなる
      coalesce(cp.payment_method, '(記録なし)') as m,
      cp.price_yen + cp.safety_fee_yen as yen
    from public.coin_purchases cp
    where cp.created_at >= v_from and cp.created_at < v_to
  ),
  total as (select coalesce(sum(yen), 0) as t from p)
  select
    p.m,
    count(*)::int,
    coalesce(sum(p.yen), 0)::bigint,
    case when (select t from total) > 0
      then round(sum(p.yen)::numeric * 100 / (select t from total), 1)
      else null end
  from p
  group by p.m
  order by 3 desc;
end;
$$;

comment on function public.admin_payment_method_mix(date, date) is
  '決済手段の内訳(運営)。PayPayはカードより手数料が低いので、比率が上がるほど貢献利益率が改善する。0096で記録した payment_method を集計する。0105。';

revoke all on function public.admin_payment_method_mix(date, date) from public, anon;
grant execute on function public.admin_payment_method_mix(date, date) to authenticated;
