-- ============================================================
-- 29: 経営指標が、事業計画書の前提と同じ計算になっている(0105)
-- ------------------------------------------------------------
-- この3つは「構造の欠陥」を探すためではなく、**計画の前提が実績と
-- ずれたことに早く気づく**ために置いている。数字がずれていたら
-- 気づけないので、計算そのものを固定する。
--
--   ・混合実効率 … 計画の「実効18%」と突き合わせる数字
--   ・上位集中   … 実効率が下がる原因であり、チャーンリスクでもある
--   ・チャージバック … 分母は**GMVではなく購入額(円)**
--
-- 固定するのは5つ:
--   ・運営以外は読めない
--   ・混合実効率が platform_fees の合計から正しく出る
--   ・予約とギフトを**混ぜた数字と分けた数字の両方**が出る
--     (ギフト35%が混ざると、合算だけ見ていたら実効率が上がって見える)
--   ・上位集中が予約のGMVだけで計算される
--   ・決済手段の「(記録なし)」を 'card' に丸めない(0104の再発検知)
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('29000000-0000-0000-0000-000000000001'),  -- ゲスト
  ('29000000-0000-0000-0000-00000000000a'),  -- ピタメイトA(たくさん稼ぐ)
  ('29000000-0000-0000-0000-00000000000b'),  -- ピタメイトB
  ('29000000-0000-0000-0000-0000000000ad');  -- 運営
insert into public.profiles (id, nickname) values
  ('29000000-0000-0000-0000-000000000001','ゲスト'),
  ('29000000-0000-0000-0000-00000000000a','ピタメイトA'),
  ('29000000-0000-0000-0000-00000000000b','ピタメイトB'),
  ('29000000-0000-0000-0000-0000000000ad','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('29000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 運営以外は読めない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '29000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.admin_business_kpis('2026-08-01', '2026-08-31');
    raise exception 'FAIL 一般ユーザーが経営指標を読めてしまった';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
  begin
    perform * from public.admin_payment_method_mix('2026-08-01', '2026-08-31');
    raise exception 'FAIL 一般ユーザーが決済内訳を読めてしまった';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
  raise notice 'OK どちらも NOT_ADMIN';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 混合実効率と、予約/ギフトの内訳 ==='; end $$;
-- ------------------------------------------------------------
-- 手数料の明細を直接置く。**予約の成立から積むと料率のティアに依存して
-- しまい、ここで見たい「集計の式」が確かめられない**
insert into public.platform_fees
  (host_id, kind, gross_coins, fee_coins, net_coins, applied_rate, created_at)
values
  -- 予約: A が 80,000 で 12,000 (15.0%)、B が 20,000 で 4,000 (20.0%)
  ('29000000-0000-0000-0000-00000000000a','booking', 80000, 12000, 68000, 0.1500, now()),
  ('29000000-0000-0000-0000-00000000000b','booking', 20000,  4000, 16000, 0.2000, now()),
  -- ギフト: 10,000 で 3,500 (35.0%)
  ('29000000-0000-0000-0000-00000000000a','gift',    10000,  3500,  6500, 0.3500, now());

set test.uid = '29000000-0000-0000-0000-0000000000ad';
do $$
declare r jsonb; v_from date := (now() at time zone 'Asia/Tokyo')::date;
begin
  r := public.admin_business_kpis(v_from, v_from);

  -- 混合: (12000+4000+3500) / (80000+20000+10000) = 19500/110000 = 17.73%
  if (r -> 'fees' ->> 'blendedPercent')::numeric <> 17.73 then
    raise exception 'FAIL 混合実効率が違う: %(17.73のはず)', r -> 'fees' ->> 'blendedPercent';
  end if;
  -- 予約だけ: 16000/100000 = 16.00%
  if (r -> 'fees' ->> 'bookingPercent')::numeric <> 16.00 then
    raise exception 'FAIL 予約の実効率が違う: %', r -> 'fees' ->> 'bookingPercent';
  end if;
  -- ギフトだけ: 3500/10000 = 35.00%
  if (r -> 'fees' ->> 'giftPercent')::numeric <> 35.00 then
    raise exception 'FAIL ギフトの実効率が違う: %', r -> 'fees' ->> 'giftPercent';
  end if;

  -- **ここが要点。** 合算(17.73)はギフトに引き上げられていて、
  -- 予約だけ(16.00)は計画の18%を**すでに下回っている**。
  -- 合算しか見ていないと、この下振れに気づけない
  if (r -> 'fees' ->> 'blendedPercent')::numeric
     <= (r -> 'fees' ->> 'bookingPercent')::numeric then
    raise exception 'FAIL ギフトを混ぜたのに合算が上がっていない(内訳の意味が無い)';
  end if;
  raise notice 'OK 合算17.73%% / 予約16.00%% / ギフト35.00%%。内訳を分けて出せている';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 上位集中は予約のGMVだけで計算する ==='; end $$;
-- ------------------------------------------------------------
do $$
declare r jsonb; v_from date := (now() at time zone 'Asia/Tokyo')::date;
begin
  r := public.admin_business_kpis(v_from, v_from);

  if (r -> 'concentration' ->> 'activeHosts')::int <> 2 then
    raise exception 'FAIL 稼働ピタメイト数が違う: %', r -> 'concentration' ->> 'activeHosts';
  end if;
  -- 2人しかいないので上位5人 = 全員 = 100%
  if (r -> 'concentration' ->> 'top5Percent')::numeric <> 100.0 then
    raise exception 'FAIL 上位5人シェアが違う: %', r -> 'concentration' ->> 'top5Percent';
  end if;
  -- 最大の1人(A) = 80,000/100,000 = 80.0%。
  -- **ギフトの10,000が母数に入っていたら 72.7% になる**
  if (r -> 'concentration' ->> 'top1Percent')::numeric <> 80.0 then
    raise exception 'FAIL 最大1人のシェアにギフトが混ざっている: %(80.0のはず)',
      r -> 'concentration' ->> 'top1Percent';
  end if;
  raise notice 'OK 稼働2人・最大1人が80.0%%(ギフトは母数に混ざっていない)';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. チャージバックの分母は購入額(円) ==='; end $$;
-- ------------------------------------------------------------
select public.credit_coins_for_purchase(
  '29000000-0000-0000-0000-000000000001', 'pack_50000', 50000, 0, 50000,
  'sess_29_1', 'pi_29_1');
select public.credit_coins_for_purchase(
  '29000000-0000-0000-0000-000000000001', 'pack_50000', 50000, 0, 50000,
  'sess_29_2', 'pi_29_2');
update public.coin_purchases set payment_method = 'card'
  where stripe_session_id = 'sess_29_1';
-- sess_29_2 は payment_method を書かない(0096より前の購入を模す)

insert into public.payment_disputes
  (user_id, stripe_dispute_id, stripe_charge_id, amount_yen, reason, status)
values
  ('29000000-0000-0000-0000-000000000001','dp_29_1','ch_29_1', 5000, 'fraudulent', 'open');

do $$
declare r jsonb; v_from date := (now() at time zone 'Asia/Tokyo')::date;
begin
  r := public.admin_business_kpis(v_from, v_from);

  if (r -> 'chargebacks' ->> 'count')::int <> 1
     or (r -> 'chargebacks' ->> 'openCount')::int <> 1 then
    raise exception 'FAIL 申立ての件数が違う: %', r -> 'chargebacks';
  end if;
  -- 購入額は 50,000 × 2 = 100,000円。5,000/100,000 = 5.00%
  if (r -> 'chargebacks' ->> 'purchaseYen')::bigint <> 100000 then
    raise exception 'FAIL 分母が購入額になっていない: %', r -> 'chargebacks' ->> 'purchaseYen';
  end if;
  if (r -> 'chargebacks' ->> 'ratePercent')::numeric <> 5.00 then
    raise exception 'FAIL チャージバック率が違う: %(5.00のはず)',
      r -> 'chargebacks' ->> 'ratePercent';
  end if;
  raise notice 'OK 1件5,000円 / 購入100,000円 = 5.00%%';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 決済手段の「(記録なし)」を card に丸めない ==='; end $$;
-- ------------------------------------------------------------
-- **丸めると 0104 で直した記録漏れが二度と見えなくなる。**
-- 「カードだった」と「記録が無かった」は別のこと
do $$
declare v_n int; v_none int;
begin
  select count(*) into v_n from public.admin_payment_method_mix(
    (now() at time zone 'Asia/Tokyo')::date, (now() at time zone 'Asia/Tokyo')::date);
  if v_n <> 2 then
    raise exception 'FAIL 決済手段が2種に分かれていない: %件', v_n;
  end if;
  select purchases into v_none from public.admin_payment_method_mix(
    (now() at time zone 'Asia/Tokyo')::date, (now() at time zone 'Asia/Tokyo')::date)
    where method = '(記録なし)';
  if coalesce(v_none, 0) <> 1 then
    raise exception 'FAIL 記録なしの購入が card に丸められた';
  end if;
  raise notice 'OK card 1件 / (記録なし) 1件 に分かれた';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 母数0のときは 0%% ではなく null ==='; end $$;
-- ------------------------------------------------------------
-- **「率が0%」と「まだ何も起きていない」を区別する。**
-- 0と出ると、実効率が0に落ちたのかデータが無いのか分からない
do $$
declare r jsonb;
begin
  r := public.admin_business_kpis('2020-01-01', '2020-01-31');
  if (r -> 'fees' ->> 'blendedPercent') is not null then
    raise exception 'FAIL 取引が無い期間で実効率が出た: %', r -> 'fees' ->> 'blendedPercent';
  end if;
  if (r -> 'chargebacks' ->> 'ratePercent') is not null then
    raise exception 'FAIL 購入が無い期間でチャージバック率が出た';
  end if;
  raise notice 'OK 母数が無い期間は null(0%%と区別できる)';
end $$;

do $$ begin raise notice '==== 29: すべて通過 ===='; end $$;
