-- ============================================================
-- 98: 購入ボーナスの廃止(0083)の検証
-- ------------------------------------------------------------
-- 廃止は**事業判断**であり、法務・税務・資金繰りの3方向で論点が消えている。
-- 静かに戻ると、3つとも静かに戻る。だから戻せないことを固定する。
--
--   法務: 景品表示法5条2号(有利誤認)。弁護士 第3回回答 論点4
--   税務: 無償コイン起因のPF利用料の純額処理。税理士 第4回回答
--   資金: 分別管理規程 第7条2号の「回収されない真の持ち出し」
--
-- ここで固定するのは4つ:
--   ・全パックのボーナスが0で、**0以外を入れられない**こと
--   ・廃止をまたいだ決済が届いても、**有償分だけを付与して落ちない**こと
--   ・台帳の器(kind='bonus' 等)は**壊していない**こと
--   ・会計の集計が、無償が無い状態で0を返すこと(行が消えていないこと)
-- ============================================================
\set ON_ERROR_STOP on

-- ------------------------------------------------------------
\echo '=== 1. 全パックのボーナスが0であること ==='
do $$
declare v_n int;
begin
  select count(*) into v_n from public.coin_packs where bonus_coins <> 0;
  if v_n > 0 then
    raise exception 'FAIL: ボーナスが残っているパックが%件ある', v_n;
  end if;
  raise notice 'OK: 全%件のパックでボーナス0',
    (select count(*) from public.coin_packs);
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 0以外を入れられないこと(データではなく制約で止める) ==='
-- 0にするだけだと、管理画面やSQLから戻せてしまう。
-- 廃止は事業判断なので「戻すときは migration を書く」形にしてある
do $$
begin
  update public.coin_packs set bonus_coins = 100 where id = 'pack_20000';
  raise exception 'FAIL: ボーナスを設定できてしまった(制約が効いていない)';
exception when check_violation then
  raise notice 'OK: coin_packs_no_bonus_check が拒否する';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 廃止をまたいだ決済でも、有償分だけを付与して落ちないこと ==='
-- Webhook のメタデータには決済時点の bonus_coins が残る。
-- **ここで例外にすると、代金を受け取ったのにコインが付与されない事故になる**
insert into auth.users (id) values ('b2000000-0000-0000-0000-000000000001');
insert into public.profiles (id, nickname) values
  ('b2000000-0000-0000-0000-000000000001','ゲスト')
  on conflict (id) do nothing;

select public.credit_coins_for_purchase(
  'b2000000-0000-0000-0000-000000000001', null, 20000, 100, 20000, 'sess_stale_bonus');

do $$
declare v_bal int; v_bonus_bal int; v_paid_lot int; v_bonus_lot int; v_credited int;
begin
  select balance, bonus_balance into v_bal, v_bonus_bal
  from public.coin_wallets where user_id = 'b2000000-0000-0000-0000-000000000001';
  select coalesce(sum(remaining), 0) into v_paid_lot from public.coin_lots
   where user_id = 'b2000000-0000-0000-0000-000000000001' and kind = 'paid';
  select coalesce(sum(remaining), 0) into v_bonus_lot from public.coin_lots
   where user_id = 'b2000000-0000-0000-0000-000000000001' and kind = 'bonus';
  select coins_credited into v_credited from public.coin_purchases
   where stripe_session_id = 'sess_stale_bonus';

  if v_bal <> 20000 then
    raise exception 'FAIL: 有償分の付与が合わない(期待20000 / 実際%)', v_bal;
  end if;
  if coalesce(v_bonus_bal, 0) <> 0 or v_bonus_lot <> 0 then
    raise exception 'FAIL: 無償コインが付与された(残高%/ロット%)', v_bonus_bal, v_bonus_lot;
  end if;
  if v_paid_lot <> 20000 then
    raise exception 'FAIL: 有償ロットが合わない(%)', v_paid_lot;
  end if;
  -- 購入履歴の付与数にもボーナスを混ぜない(会計の前受金と一致させるため)
  if v_credited <> 20000 then
    raise exception 'FAIL: coin_purchases.coins_credited にボーナスが混ざった(%)', v_credited;
  end if;
  raise notice 'OK: 有償%のみ付与。無償は0、履歴の付与数も%', v_bal, v_credited;
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 冪等性を壊していないこと ==='
do $$
declare v_bal int;
begin
  perform public.credit_coins_for_purchase(
    'b2000000-0000-0000-0000-000000000001', null, 20000, 0, 20000, 'sess_stale_bonus');
  select balance into v_bal from public.coin_wallets
   where user_id = 'b2000000-0000-0000-0000-000000000001';
  if v_bal <> 20000 then
    raise exception 'FAIL: 同じsessionで二重付与された(%)', v_bal;
  end if;
  raise notice 'OK: 同じsessionを二度処理しない(残高%のまま)', v_bal;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 不正な額は従来どおり例外にすること ==='
-- 0083で本文を書き直したので、元の防御が消えていないかを見る
do $$
begin
  perform public.credit_coins_for_purchase(
    'b2000000-0000-0000-0000-000000000001', null, 0, 0, 0, 'sess_zero');
  raise exception 'FAIL: 0コインの付与が通ってしまった';
exception when others then
  if sqlerrm <> 'INVALID_AMOUNT' then raise; end if;
  raise notice 'OK: INVALID_AMOUNT は残っている';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 台帳の器を壊していないこと ==='
-- 追記専用の台帳(0044)なので、列や種別を落とすと復元の経路まで壊れる。
-- 再開の判断があったときに作り直さずに済むよう、器はそのまま残す
do $$
declare v_n int;
begin
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'bookings' and column_name = 'bonus_coins';
  if v_n <> 1 then raise exception 'FAIL: bookings.bonus_coins を落としてしまった'; end if;

  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'coin_wallets' and column_name = 'bonus_balance';
  if v_n <> 1 then raise exception 'FAIL: coin_wallets.bonus_balance を落としてしまった'; end if;

  -- coin_lots.kind と coin_transactions.type の 'bonus' が制約から消えていないこと
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.coin_lots'::regclass
       and pg_get_constraintdef(oid) like '%bonus%'
  ) then
    raise exception 'FAIL: coin_lots.kind から bonus が消えた';
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.coin_transactions'::regclass
       and pg_get_constraintdef(oid) like '%''bonus''%'
  ) then
    raise exception 'FAIL: coin_transactions.type から bonus が消えた';
  end if;
  raise notice 'OK: 台帳の列・種別はそのまま(再開時に作り直さずに済む)';
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 会計の集計が、行を消さずに0を返すこと ==='
-- **行ごと消さないのが要点。** 0が出ることが「発生していない」ことの確認になる。
-- 行を消すと、再開したときに気づかず両建てのまま記帳してしまう
insert into auth.users (id) values ('b2000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('b2000000-0000-0000-0000-000000000009','運営') on conflict (id) do nothing;
insert into public.admins (user_id) values ('b2000000-0000-0000-0000-000000000009');

set test.uid = 'b2000000-0000-0000-0000-000000000009';
do $$
declare v_uchisuu bigint; v_bonus_zan bigint; v_n int;
begin
  select 金額円 into v_uchisuu from public.accounting_revenue('2000-01-01','2100-01-01')
   where 科目 = 'PF利用料のうち無償コイン起因';
  if v_uchisuu is null then
    raise exception 'FAIL: 「無償コイン起因」の行が集計から消えた(0を出し続けること)';
  end if;
  if v_uchisuu <> 0 then
    raise exception 'FAIL: 無償が無いのに内数が0でない(%)', v_uchisuu;
  end if;

  select 金額円 into v_bonus_zan from public.accounting_balances()
   where 勘定科目 = '無償コイン残(ボーナス)';
  if v_bonus_zan is null then
    raise exception 'FAIL: 「無償コイン残」の行が残高から消えた';
  end if;
  if v_bonus_zan <> 0 then
    raise exception 'FAIL: 無償コイン残が0でない(%)', v_bonus_zan;
  end if;

  -- 仕訳側: 販売促進費と純額調整の行が1本も出ないこと
  select count(*) into v_n from public.accounting_journal('2000-01-01','2100-01-01')
   where 借方科目 = '販売促進費' or 貸方科目 = '販売促進費';
  if v_n > 0 then
    raise exception 'FAIL: 販売促進費の仕訳が%件出た(無償コインが無いはず)', v_n;
  end if;

  raise notice 'OK: 内数0 / 無償コイン残0 / 販売促進費の仕訳0件(行は残っている)';
end $$;

\echo '=== 98: 購入ボーナスの廃止 すべて通過 ==='
