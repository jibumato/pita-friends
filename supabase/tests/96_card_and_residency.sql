-- ============================================================
-- 96: カードフィンガープリントの監視(0080)と居住地の自己申告(0081)
-- ------------------------------------------------------------
-- どちらも「規約や弁護士の指摘にはあるのに実装が無かった」穴を埋めたもの。
--   ・E-9  カード共有の検知 … 端末(0021)・IP(0022)と揃えて3つ目
--   ・G4   居住地の自己申告 … 規約第3条3項に申告欄も確認も無かった
--
-- ここで確かめるのは、**遮断と非遮断の線引きが設計どおりか**が中心。
-- 締めすぎると正当な利用者(家族カード・同居)を締め出し、緩すぎると
-- 自作自演が通る。両側から挟む。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('c0000000-0000-0000-0000-000000000001'),  -- 本人A
  ('c0000000-0000-0000-0000-000000000002'),  -- 別アカウントB(同じカード)
  ('c0000000-0000-0000-0000-000000000003'),  -- 無関係C
  ('c0000000-0000-0000-0000-000000000009');  -- 運営
insert into public.profiles (id, nickname) values
  ('c0000000-0000-0000-0000-000000000001','A'),
  ('c0000000-0000-0000-0000-000000000002','B'),
  ('c0000000-0000-0000-0000-000000000003','C'),
  ('c0000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('c0000000-0000-0000-0000-000000000009');

-- ------------------------------------------------------------
\echo '=== 1. カードの記録は一般利用者から呼べないこと ==='
-- 詐称できると、他人との共有関係を捏造して通報や凍結を誘発できる。
-- **テストは superuser で流れるので、実際に呼んでも止まらない。**
-- 権限そのものを見る(93_payment_dispute_freeze と同じやり方)。
do $$
begin
  if has_function_privilege('authenticated',
       'public.record_payment_card(uuid,text,text,text)', 'execute') then
    raise exception 'FAIL: record_payment_card が authenticated に開いている';
  end if;
  if has_function_privilege('anon',
       'public.record_payment_card(uuid,text,text,text)', 'execute') then
    raise exception 'FAIL: record_payment_card が anon に開いている';
  end if;
  if has_function_privilege('authenticated',
       'public._shares_payment_card(uuid,uuid)', 'execute') then
    raise exception 'FAIL: _shares_payment_card が authenticated に開いている';
  end if;
  raise notice 'OK: record_payment_card / _shares_payment_card は service_role 専用';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. カード番号を保存しない(持っているのは指紋・ブランド・下4桁だけ) ==='
do $$
declare v_cols text;
begin
  select string_agg(column_name, ',' order by ordinal_position) into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'user_payment_cards';
  if v_cols like '%number%' or v_cols like '%pan%' or v_cols like '%cvc%' then
    raise exception 'FAIL: カード番号らしき列がある(%)', v_cols;
  end if;
  raise notice 'OK: 列は % のみ', v_cols;
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 同じカードを使うと共有として検知されること ==='
-- webhook 相当(service_role)の書き込みを直接行う
select public.record_payment_card('c0000000-0000-0000-0000-000000000001', 'fp_same', 'visa', '4242');
select public.record_payment_card('c0000000-0000-0000-0000-000000000002', 'fp_same', 'visa', '4242');
select public.record_payment_card('c0000000-0000-0000-0000-000000000003', 'fp_other', 'visa', '1111');

do $$
declare v_ab boolean; v_ac boolean; v_uses int;
begin
  select public._shares_payment_card(
    'c0000000-0000-0000-0000-000000000001',
    'c0000000-0000-0000-0000-000000000002') into v_ab;
  select public._shares_payment_card(
    'c0000000-0000-0000-0000-000000000001',
    'c0000000-0000-0000-0000-000000000003') into v_ac;
  if not v_ab then raise exception 'FAIL: 同じカードなのに共有と判定されない'; end if;
  if v_ac then raise exception 'FAIL: 違うカードなのに共有と判定された'; end if;

  -- 2回目の購入は行を増やさず uses が上がる
  perform public.record_payment_card('c0000000-0000-0000-0000-000000000001', 'fp_same');
  select uses into v_uses from public.user_payment_cards
   where user_id = 'c0000000-0000-0000-0000-000000000001' and fingerprint = 'fp_same';
  if v_uses <> 2 then raise exception 'FAIL: 再購入で uses が増えない(%)', v_uses; end if;
  raise notice 'OK: A↔B は共有 / A↔C は非共有 / 再購入で uses=%', v_uses;
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 上書きで brand/last4 を失わないこと ==='
-- 2回目の記録では引数を省略している(webhook が取れないことがある)。
-- ここで null 上書きすると、目視照合の手がかりが消える
do $$
declare v_brand text; v_last4 text;
begin
  select brand, last4 into v_brand, v_last4
  from public.user_payment_cards
  where user_id = 'c0000000-0000-0000-0000-000000000001' and fingerprint = 'fp_same';
  if v_brand is distinct from 'visa' or v_last4 is distinct from '4242' then
    raise exception 'FAIL: 再記録で brand/last4 が失われた(%/%)', v_brand, v_last4;
  end if;
  raise notice 'OK: 再記録しても brand=% last4=% が残る', v_brand, v_last4;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. カード共有は「遮断」ではなく「フラグ」であること ==='
-- 家族カード・同一世帯で正当に一致しうるので、送金は止めない。
-- 止めるのは端末一致(0021)だけ。
update public.profile_trust_stats set is_verified = true
  where user_id = 'c0000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('c0000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- A が B と1回遊んでおく(ギフトは完了した予約のある相手にしか贈れない)
set test.uid = 'c0000000-0000-0000-0000-000000000001';
select public.credit_coins_for_purchase(
  'c0000000-0000-0000-0000-000000000001', null, 20000, 0, 20000, 'sess_card_1');
select public.create_booking('c0000000-0000-0000-0000-000000000002', 240, 'v1',
  now() + interval '2 days') as bk \gset
set test.uid = 'c0000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
set test.uid = 'c0000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk');

-- チャージ直後の送信は 0020 で止まるので、購入時刻をずらす
begin;
set local app.ledger_override = 'on';
update public.coin_purchases set created_at = now() - interval '3 days'
  where stripe_session_id = 'sess_card_1';
commit;

set test.uid = 'c0000000-0000-0000-0000-000000000001';
select id from public.promises where booking_id = :'bk' limit 1 \gset pr_
select public.send_gift(:'pr_id', 500, 'ありがとう', null);

do $$
declare v_flag boolean; v_ip boolean;
begin
  select card_flagged, ip_flagged into v_flag, v_ip
  from public.gifts order by created_at desc limit 1;
  if v_flag is null then
    raise exception 'FAIL: ギフトが1件も作られていない(検証の前提が崩れた)';
  end if;
  if not v_flag then
    raise exception 'FAIL: カードを共有しているのに印が付かなかった';
  end if;
  raise notice 'OK: 送金は通り(遮断しない)、card_flagged=% が立った(ip_flagged=%)', v_flag, v_ip;
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 換金リストにカード共有の件数が並ぶこと ==='
-- 別画面に置くと見に行かない。**資金が出る瞬間に目に入る**のが要点
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values ('c0000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001',
        '普通','1234567','ビー')
on conflict (user_id) do nothing;

-- ギフト由来は7日保留(0069)がかかるので、予約報酬だけで申請できる額にする
set test.uid = 'c0000000-0000-0000-0000-000000000002';
select public.request_bank_payout(5000) as po \gset

set test.uid = 'c0000000-0000-0000-0000-000000000009';
do $$
declare v_shared int; v_flagged int;
begin
  select shared_card_count, flagged_gift_count into v_shared, v_flagged
  from public.admin_pending_payouts(100)
  where user_id = 'c0000000-0000-0000-0000-000000000002';
  if v_shared is null then
    raise exception 'FAIL: 換金リストに B の行が出ない';
  end if;
  if v_shared <> 1 then
    raise exception 'FAIL: カードを共有する相手が1人いるはずが %', v_shared;
  end if;
  if v_flagged < 1 then
    raise exception 'FAIL: 要確認ギフトの件数が出ない(%)', v_flagged;
  end if;
  raise notice 'OK: 振込リストに カード共有%人 / 要確認ギフト%件 が並ぶ', v_shared, v_flagged;
end $$;

-- ------------------------------------------------------------
\echo '=== 7. カード共有の一覧は運営だけが見られること ==='
do $$
declare v_n int;
begin
  select count(*) into v_n from public.admin_shared_cards();
  if v_n < 1 then raise exception 'FAIL: 共有の組が出ない'; end if;
  raise notice 'OK: 運営には %組 見える', v_n;
end $$;

set test.uid = 'c0000000-0000-0000-0000-000000000001';
do $$
begin
  perform * from public.admin_shared_cards();
  raise exception 'FAIL: 一般利用者が他人のカード共有を見られてしまった';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK: 一般利用者は NOT_ADMIN で拒否される';
end $$;

-- ============================================================
\echo '=== 8. 居住地を申告していないと本人確認を出せないこと(G4) ==='
set test.uid = 'c0000000-0000-0000-0000-000000000003';
do $$
begin
  insert into public.identity_verifications (user_id, status)
    values ('c0000000-0000-0000-0000-000000000003', 'pending');
  raise exception 'FAIL: 居住地を申告せずに本人確認を提出できてしまった';
exception when others then
  if sqlerrm <> 'RESIDENCY_NOT_DECLARED' then raise; end if;
  raise notice 'OK: RESIDENCY_NOT_DECLARED で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 9. 「いいえ」と答えた場合は別のエラーになること ==='
-- 画面で出す文言が違う(未申告=チェックしてください / いいえ=ご利用いただけません)
select public.declare_residency(false, 'v1');
do $$
begin
  insert into public.identity_verifications (user_id, status)
    values ('c0000000-0000-0000-0000-000000000003', 'pending');
  raise exception 'FAIL: 国外居住の申告でも本人確認を提出できてしまった';
exception when others then
  if sqlerrm <> 'RESIDENCY_OUTSIDE_JAPAN' then raise; end if;
  raise notice 'OK: RESIDENCY_OUTSIDE_JAPAN で止まる(未申告とは別のエラー)';
end $$;

-- ------------------------------------------------------------
\echo '=== 10. 申告すれば通り、履歴が上書きされずに積まれること ==='
-- 引っ越しで変わりうるので、最新1件ではなく履歴で持つ
select public.declare_residency(true, 'v1');
insert into public.identity_verifications (user_id, status)
  values ('c0000000-0000-0000-0000-000000000003', 'pending');

do $$
declare v_n int; v_latest jsonb;
begin
  select count(*) into v_n from public.residency_declarations
   where user_id = 'c0000000-0000-0000-0000-000000000003';
  if v_n <> 2 then
    raise exception 'FAIL: 申告が履歴として積まれていない(期待2件 / 実際%)', v_n;
  end if;
  select public.my_residency_declaration() into v_latest;
  if (v_latest->>'declaredJapan')::boolean is not true then
    raise exception 'FAIL: 最新の申告が読めない(%)', v_latest;
  end if;
  raise notice 'OK: 提出でき、履歴は%件。最新は %', v_n, v_latest;
end $$;

-- ------------------------------------------------------------
\echo '=== 11. 申告とカードの記録が本人以外に漏れないこと ==='
-- **テストは superuser で流れるので RLS は素通りする。**
-- 74_anon_surface と同じく、RLSが有効で本人限定のポリシーだけが
-- 付いていることを確認する。
do $$
declare v_rec record; v_n int;
begin
  for v_rec in
    select t.tbl from (values ('residency_declarations'), ('user_payment_cards')) t(tbl)
  loop
    if not (select relrowsecurity from pg_class
             where oid = ('public.' || v_rec.tbl)::regclass) then
      raise exception 'FAIL: % のRLSが無効', v_rec.tbl;
    end if;
    -- SELECT 以外のポリシーが無い(書き込みは関数経由のみ)
    select count(*) into v_n from pg_policies
     where schemaname = 'public' and tablename = v_rec.tbl and cmd <> 'SELECT';
    if v_n > 0 then
      raise exception 'FAIL: % に書き込みポリシーがある(%件)', v_rec.tbl, v_n;
    end if;
    -- SELECT は user_id = auth.uid() の1本だけ
    select count(*) into v_n from pg_policies
     where schemaname = 'public' and tablename = v_rec.tbl
       and cmd = 'SELECT' and qual like '%auth.uid()%';
    if v_n <> 1 then
      raise exception 'FAIL: % の本人限定SELECTポリシーが%本', v_rec.tbl, v_n;
    end if;
  end loop;
  raise notice 'OK: 2表ともRLS有効・本人限定SELECTのみ・書き込みポリシー無し';
end $$;

\echo '=== 96: カード監視と居住地の申告 すべて通過 ==='
