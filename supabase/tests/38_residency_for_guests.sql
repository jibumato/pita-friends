-- ============================================================
-- 38: 居住地の確認がゲストにも効くこと／購入時の居住国が残ること(0119)
--
-- ■ 直そうとしている穴
--   規約 第3条3項はサービス全体を日本国内居住者に限っているのに、
--   `0081` の強制は本人確認の INSERT トリガー1か所だけだった。
--   **本人確認を出さないゲストは素通り**で、登録も購入もできてしまう。
--
-- ■ このテストの主眼
--   3番目「未申告のゲストは買えない」と、
--   7番目「購入時点の申告国が購入に残る」。
--   後者は**あとから遡って区分できない**ので、日本限定のあいだも
--   記録されていることを固定する。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('38000000-0000-0000-0000-000000000001'),  -- 未申告のゲスト
  ('38000000-0000-0000-0000-000000000002'),  -- 「いいえ」と答えたゲスト
  ('38000000-0000-0000-0000-000000000003')   -- 申告済みのゲスト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('38000000-0000-0000-0000-000000000001','未申告'),
  ('38000000-0000-0000-0000-000000000002','海外'),
  ('38000000-0000-0000-0000-000000000003','申告済み')
on conflict (id) do update set nickname = excluded.nickname;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 申告すると国コードが JP で残る ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '38000000-0000-0000-0000-000000000003';
do $$
declare r public.residency_declarations;
begin
  perform public.declare_residency(true);
  select * into r from public.residency_declarations
    where user_id = '38000000-0000-0000-0000-000000000003'
    order by declared_at desc limit 1;
  if not r.declared_japan then raise exception 'FAIL 申告が記録されていない'; end if;
  if r.country_code <> 'JP' then
    raise exception 'FAIL 国コードが JP でない: %', r.country_code;
  end if;
  raise notice 'OK 「日本に居住」なら国は JP で確定する';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 申告は上書きせず積む(0081の方針を維持) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  perform public.declare_residency(true);
  select count(*) into v_n from public.residency_declarations
    where user_id = '38000000-0000-0000-0000-000000000003';
  if v_n <> 2 then raise exception 'FAIL 履歴が積まれていない: %', v_n; end if;
  raise notice 'OK 履歴として積む(件数=%)', v_n;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. ★未申告のゲストは買えない ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb;
begin
  v := public.check_purchase_allowed('38000000-0000-0000-0000-000000000001', 1000);
  if (v->>'allowed')::boolean then
    raise exception 'FAIL 未申告なのに購入が通った: %', v;
  end if;
  if v->>'code' <> 'RESIDENCY_NOT_DECLARED' then
    raise exception 'FAIL コードが違う: %', v->>'code';
  end if;
  raise notice 'OK RESIDENCY_NOT_DECLARED で止まる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 「いいえ」は別のコードで止まる(画面の文言が違うため) ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '38000000-0000-0000-0000-000000000002';
do $$
declare v jsonb;
begin
  perform public.declare_residency(false, 'v1', 'TW');
  v := public.check_purchase_allowed('38000000-0000-0000-0000-000000000002', 1000);
  if (v->>'allowed')::boolean then
    raise exception 'FAIL 国外居住なのに購入が通った: %', v;
  end if;
  if v->>'code' <> 'RESIDENCY_OUTSIDE_JAPAN' then
    raise exception 'FAIL コードが違う: %', v->>'code';
  end if;
  -- 「いいえ」のときは、申告された国をそのまま残す(将来開くときの材料)
  if (select country_code from public.residency_declarations
      where user_id = '38000000-0000-0000-0000-000000000002'
      order by declared_at desc limit 1) <> 'TW' then
    raise exception 'FAIL 申告された国が残っていない';
  end if;
  raise notice 'OK RESIDENCY_OUTSIDE_JAPAN・申告国も残る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 申告済みなら通る(上限の判定に進む) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb;
begin
  v := public.check_purchase_allowed('38000000-0000-0000-0000-000000000003', 1000);
  if not (v->>'allowed')::boolean then
    raise exception 'FAIL 申告済みなのに止まった: %', v;
  end if;
  raise notice 'OK 申告済みは通る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 居住地の判定は上限より先に効く ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb;
begin
  -- 未申告 かつ 1回の上限(10,000円)を超える額。
  -- **居住地のほうが先**に返らないと、順序が入れ替わっている
  v := public.check_purchase_allowed('38000000-0000-0000-0000-000000000001', 50000);
  if v->>'code' <> 'RESIDENCY_NOT_DECLARED' then
    raise exception 'FAIL 上限のコードが先に返った: %', v->>'code';
  end if;
  raise notice 'OK そもそも使える人かを先に見る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 7. ★購入時点の申告国が購入に残る ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_country text;
begin
  perform public.credit_coins_for_purchase(
    '38000000-0000-0000-0000-000000000003', 'pack_1000', 1000, 0, 1000,
    'cs_test_38_a', 'pi_test_38_a');

  select buyer_country into v_country from public.coin_purchases
    where stripe_session_id = 'cs_test_38_a';
  if v_country is distinct from 'JP' then
    raise exception 'FAIL 購入に居住国が残っていない: %', v_country;
  end if;
  raise notice 'OK 購入時点の申告国(JP)が残る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 8. あとで申告が変わっても、済んだ購入は動かない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '38000000-0000-0000-0000-000000000003';
do $$
declare v_country text;
begin
  -- 引っ越したことにする
  perform public.declare_residency(false, 'v1', 'KR');

  select buyer_country into v_country from public.coin_purchases
    where stripe_session_id = 'cs_test_38_a';
  if v_country <> 'JP' then
    raise exception 'FAIL 過去の購入の国が書き換わった: %', v_country;
  end if;
  raise notice 'OK 済んだ購入は当時の国のまま(税務の区分が後から動かない)';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 9. 決済国は一度だけ書ける(追記専用は維持) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_country text;
begin
  update public.coin_purchases set payment_country = 'JP'
    where stripe_session_id = 'cs_test_38_a';
  select payment_country into v_country from public.coin_purchases
    where stripe_session_id = 'cs_test_38_a';
  if v_country <> 'JP' then raise exception 'FAIL 決済国が書けない'; end if;

  -- 二度目は通らない
  begin
    update public.coin_purchases set payment_country = 'US'
      where stripe_session_id = 'cs_test_38_a';
    raise exception 'FAIL 決済国を書き換えられた';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
  end;

  -- 金額は従来どおり変更できない
  begin
    update public.coin_purchases set price_yen = 1
      where stripe_session_id = 'cs_test_38_a';
    raise exception 'FAIL 金額が書き換えられた';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
  end;
  raise notice 'OK 決済国は初回だけ・金額は不変のまま';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 10. 本人確認の入口(0081)は従来どおり効く ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '38000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    insert into public.identity_verifications (user_id)
      values ('38000000-0000-0000-0000-000000000001');
    raise exception 'FAIL 未申告で本人確認を出せた';
  exception when others then
    if sqlerrm not like '%RESIDENCY_NOT_DECLARED%' then raise; end if;
  end;
  raise notice 'OK 0081 のゲートは壊していない';
end $$;

\echo '==== 38: すべて通過 ===='
