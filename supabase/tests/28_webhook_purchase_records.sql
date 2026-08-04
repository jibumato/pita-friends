-- ============================================================
-- 28: webhook の購入記録は通り、それ以外の改変は今までどおり弾かれる(0104)
-- ------------------------------------------------------------
-- stripe-webhook は付与のあとに safety_fee_yen と payment_method を
-- 素の UPDATE で書く。0104 より前は 0044 の追記専用トリガーが**毎回**
-- これを弾き、サポート料の売上と決済手段が記録されていなかった。
--
-- テスト(90)が INSERT 時に直接値を入れていて経路が違ったのが敗因なので、
-- ここでは **webhook と同じ「あとから UPDATE」** で固定する。
--
-- 固定するのは3つ:
--   ・webhook の2列は「1回だけ」書ける(同値の再送も通る)
--   ・上書き・他の列の変更・削除は今までどおり弾かれる
--   ・override の逃げ道と ledger_audit への記録は生きている
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('28000000-0000-0000-0000-000000000001');
insert into public.profiles (id, nickname) values
  ('28000000-0000-0000-0000-000000000001','買う人')
  on conflict (id) do update set nickname = excluded.nickname;

-- webhook と同じ順序: まず付与(INSERT)
select public.credit_coins_for_purchase(
  '28000000-0000-0000-0000-000000000001', 'pack_5000', 5000, 0, 5000,
  'sess_28_1', 'pi_28_1');

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. webhook の2列は、あとから書ける ==='; end $$;
-- ------------------------------------------------------------
update public.coin_purchases set safety_fee_yen = 250
  where stripe_session_id = 'sess_28_1';
update public.coin_purchases set payment_method = 'card'
  where stripe_session_id = 'sess_28_1';

do $$
declare v_fee int; v_pm text;
begin
  select safety_fee_yen, payment_method into v_fee, v_pm
    from public.coin_purchases where stripe_session_id = 'sess_28_1';
  if v_fee <> 250 or v_pm <> 'card' then
    raise exception 'FAIL 記録できていない: fee=% pm=%', v_fee, v_pm;
  end if;
  raise notice 'OK サポート料250と決済手段cardが記録できた(0104より前は両方失敗)';
end $$;

-- Stripe の再送 = 同じ値をもう一度書く。これは例外にしない
update public.coin_purchases set safety_fee_yen = 250
  where stripe_session_id = 'sess_28_1';
do $$ begin raise notice 'OK 同値の再書き込み(Stripeの再送)は通る'; end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 上書き・他の列・削除は今までどおり弾く ==='; end $$;
-- ------------------------------------------------------------
do $$
begin
  -- 一度書いた値の変更(上書き)は不可
  begin
    update public.coin_purchases set safety_fee_yen = 300
      where stripe_session_id = 'sess_28_1';
    raise exception 'FAIL サポート料を上書きできてしまった';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
    raise notice 'OK safety_fee_yen の上書きは弾かれる';
  end;
  begin
    update public.coin_purchases set payment_method = 'paypay'
      where stripe_session_id = 'sess_28_1';
    raise exception 'FAIL 決済手段を上書きできてしまった';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
    raise notice 'OK payment_method の上書きは弾かれる';
  end;
  -- 金額・ユーザーなど台帳の本体は従来どおり不可
  begin
    update public.coin_purchases set price_yen = 1
      where stripe_session_id = 'sess_28_1';
    raise exception 'FAIL 金額を書き換えられてしまった';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
    raise notice 'OK price_yen の変更は弾かれる';
  end;
  -- 2列と本体を同時に変える抱き合わせも不可
  begin
    update public.coin_purchases set payment_method = 'card', coins_credited = 99999
      where stripe_session_id = 'sess_28_1';
    raise exception 'FAIL 抱き合わせで本体を書き換えられてしまった';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
    raise notice 'OK 2列に混ぜた本体の変更も弾かれる';
  end;
  begin
    delete from public.coin_purchases where stripe_session_id = 'sess_28_1';
    raise exception 'FAIL 削除できてしまった';
  exception when others then
    if sqlerrm not like '%LEDGER_IMMUTABLE%' then raise; end if;
    raise notice 'OK 削除は弾かれる';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. override の逃げ道と記録は生きている ==='; end $$;
-- ------------------------------------------------------------
begin;
set local app.ledger_override = 'on';
update public.coin_purchases set safety_fee_yen = 300
  where stripe_session_id = 'sess_28_1';
commit;

do $$
declare v_fee int; v_n int;
begin
  select safety_fee_yen into v_fee
    from public.coin_purchases where stripe_session_id = 'sess_28_1';
  if v_fee <> 300 then
    raise exception 'FAIL override での訂正が通らない: %', v_fee;
  end if;
  select count(*) into v_n from public.ledger_audit
    where table_name = 'coin_purchases';
  if v_n < 1 then
    raise exception 'FAIL override の操作が ledger_audit に残っていない';
  end if;
  raise notice 'OK override で訂正でき、ledger_audit に%件残った', v_n;
end $$;

do $$ begin raise notice '==== 28: すべて通過 ===='; end $$;
