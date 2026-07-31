-- ============================================================
-- 95: 仕訳の自動生成(0079)の検証
-- ------------------------------------------------------------
-- accounting_journal は「会計ソフトに取り込む仕訳」を返す。
-- 残高一覧と違って、**間違いに気づく手がかりが無い**のが怖いところ:
-- 数字はもっともらしく出るし、取り込んだ後で気づくことになる。
--
-- そこでここでは、実際の関数だけを使って一通りの取引を起こし、
--   ・1行ごとに貸借が同額であること(単純仕訳の前提)
--   ・科目ごとに積み上げた結果が**元帳の残高と一致**すること
--   ・無償コインが前受金に混ざらないこと
--   ・換金手数料が振込完了まで売上に出ないこと
-- を確かめる。3つ目と4つ目は税理士の指摘そのもの。
--
-- **状態は必ず関数経由で作る。** coin_wallets を直接 update すると
-- 元帳と突合できなくなり、この検証の意味が無くなる。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f0000000-0000-0000-0000-000000000001'),  -- ゲスト
  ('f0000000-0000-0000-0000-000000000002'),  -- ピタメイト
  ('f0000000-0000-0000-0000-000000000009');  -- 運営
insert into public.profiles (id, nickname) values
  ('f0000000-0000-0000-0000-000000000001','ゲスト'),
  ('f0000000-0000-0000-0000-000000000002','ピタメイト'),
  ('f0000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('f0000000-0000-0000-0000-000000000009');
update public.profile_trust_stats set is_verified = true
  where user_id = 'f0000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('f0000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values ('f0000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001',
        '普通','1234567','ピタメイト')
on conflict (user_id) do nothing;

-- 購入は関数経由で作る。有償12000(=12,000円)、サポート料600。
select public.credit_coins_for_purchase(
  'f0000000-0000-0000-0000-000000000001', null, 12000, 0, 12000, 'sess_journal_1');

-- 無償コイン6000を**直接**足す。
--   0083 で購入ボーナスを廃止したため、credit_coins_for_purchase からは
--   無償コインが生まれなくなった。それでもこの検証を残しているのは、
--   **廃止前に付与された無償コインが残っている口座はありうる**ため。
--   仕訳の側が「無償分」を正しく扱えることは、引き続き固定しておく。
--   (廃止後に無償が発生しないこと自体は 98_no_purchase_bonus.sql が見る)
insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('f0000000-0000-0000-0000-000000000001', 'bonus', 6000,
          public.coin_expiry_from(now()));
update public.coin_wallets set bonus_balance = bonus_balance + 6000
  where user_id = 'f0000000-0000-0000-0000-000000000001';
-- サポート料は credit_coins_for_purchase の引数に無い(Webhook 側が
-- 別途書き込む)。coin_purchases は追記専用なので、0044 の逃がし弁を使う。
begin;
set local app.ledger_override = 'on';
update public.coin_purchases set safety_fee_yen = 600 where stripe_session_id = 'sess_journal_1';
commit;

-- 期間は「開業日から当日まで」を模す。journal_check は累計で比べるため。
\set FROM '2000-01-01'
\set TO '2100-01-01'

-- ------------------------------------------------------------
\echo '=== 1. 1行ごとに貸借が同額であること(単純仕訳) ==='
set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_bad int;
begin
  select count(*) into v_bad from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.金額円 <= 0 or j.借方科目 is null or j.貸方科目 is null
     or j.借方科目 = '' or j.貸方科目 = '';
  if v_bad > 0 then
    raise exception 'FAIL: 借方・貸方・金額のどれかが欠けた行が%件ある', v_bad;
  end if;
  raise notice 'OK: 全行に借方・貸方・正の金額が揃っている';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 購入は「前受金」と「サポート料の売上」に分かれる ==='
do $$
declare v_maeuke bigint; v_support bigint; v_rows int;
begin
  select coalesce(sum(j.金額円), 0) into v_maeuke
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = 'コイン購入' and j.貸方科目 = '前受金' and j.貸方補助 = 'コイン';

  select coalesce(sum(j.金額円), 0) into v_support
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '売上高' and j.貸方補助 = 'あんしんサポート料';

  -- 無償3000が前受金に混ざっていないこと(現金を受け取っていない)
  if v_maeuke <> 12000 then
    raise exception 'FAIL: 前受金が有償分と一致しない(期待12000 / 実際%)', v_maeuke;
  end if;
  if v_support <> 600 then
    raise exception 'FAIL: サポート料が売上に立たない(期待600 / 実際%)', v_support;
  end if;

  -- 無償コインの付与では仕訳を起こさない
  select count(*) into v_rows from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.摘要 like '%ボーナス%';
  if v_rows > 0 then
    raise exception 'FAIL: 無償コインの付与で仕訳が立っている(%件)', v_rows;
  end if;
  raise notice 'OK: 前受金%(有償のみ) / サポート料%は売上 / 無償付与は仕訳なし', v_maeuke, v_support;
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 予約成立で、有償分と無償分が別の相手科目になる ==='
-- A: 240分=8000コイン(有償8000を消費。残 有償4000・無償3000)
set test.uid = 'f0000000-0000-0000-0000-000000000001';
select public.create_booking('f0000000-0000-0000-0000-000000000002', 240, 'v1',
  now() + interval '2 days') as bk_a \gset
-- B: 120分=4000コイン(有償4000を消費。残 有償0・無償3000)
select public.create_booking('f0000000-0000-0000-0000-000000000002', 120, 'v1',
  now() + interval '5 days') as bk_b \gset
-- C: 60分=2000コイン(**有償が尽きているので無償から出る**)
select public.create_booking('f0000000-0000-0000-0000-000000000002', 60, 'v1',
  now() + interval '8 days') as bk_c \gset
-- F: 60分=2000コイン。これも無償から出る。**Cはキャンセル、Fは完了**させて、
--    無償コインの2つの行き先(費用の戻し / 純額調整)を両方通す
select public.create_booking('f0000000-0000-0000-0000-000000000002', 60, 'v1',
  now() + interval '14 days') as bk_f \gset

set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_paid bigint; v_bonus bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_paid
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = '予約成立' and j.借方科目 = '前受金' and j.借方補助 = 'コイン';

  select coalesce(sum(j.金額円), 0) into v_bonus
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = '予約成立' and j.借方科目 = '販売促進費';

  if v_paid <> 12000 then
    raise exception 'FAIL: 有償コインの充当が合わない(期待12000 / 実際%)', v_paid;
  end if;
  if v_bonus <> 4000 then
    raise exception 'FAIL: 無償コインの充当が費用に落ちていない(期待4000 / 実際%)', v_bonus;
  end if;
  raise notice 'OK: 有償%は前受金の振替 / 無償%は販売促進費(税理士の第4回回答)', v_paid, v_bonus;
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 完了確定で、利用料だけが売上になる ==='
set test.uid = 'f0000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk_a');
select public.approve_booking(:'bk_f');
set test.uid = 'f0000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk_a');
select public.complete_booking(:'bk_f');

set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_kakutei bigint; v_fee bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_kakutei
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = '報酬確定';

  select coalesce(sum(j.金額円), 0) into v_fee
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '売上高' and j.貸方補助 = 'PF利用料(予約)';

  -- 報酬は**総額**でエスクローから預り金へ移り、利用料はそこから引かれる
  -- A(8000・有償) + F(2000・無償) = 10000
  if v_kakutei <> 10000 then
    raise exception 'FAIL: 報酬確定が総額で立っていない(期待10000 / 実際%)', v_kakutei;
  end if;
  if v_fee <= 0 then
    raise exception 'FAIL: 完了したのに利用料が売上に立っていない';
  end if;
  if v_fee >= v_kakutei then
    raise exception 'FAIL: 利用料%が報酬総額%以上になっている', v_fee, v_kakutei;
  end if;
  raise notice 'OK: 報酬確定%(総額) / うち利用料%が売上', v_kakutei, v_fee;
end $$;

-- ------------------------------------------------------------
\echo '=== 4-b. 無償コイン起因の利用料が「純額調整」で売上から落ちること ==='
-- 両建てのままだと課税売上高が水増しされ、1,000万円の判定が実態より
-- 早く来る(税理士の第4回回答)。純額処理を採るときはこの行を使う。
do $$
declare v_chosei bigint; v_fee_f bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_chosei
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = '純額調整';

  -- F は全額が無償コインなので、F の利用料がまるごと調整対象になる
  select coalesce(sum(f.fee_coins), 0) into v_fee_f
  from public.platform_fees f
  join public.bookings b on b.id = f.booking_id
  where f.kind = 'booking' and b.bonus_coins = b.coins;

  if v_fee_f <= 0 then
    raise exception 'FAIL: 検証の前提が崩れている(無償だけの予約に利用料が付いていない)';
  end if;
  if v_chosei <> v_fee_f then
    raise exception 'FAIL: 純額調整が無償起因の利用料と一致しない(期待% / 実際%)',
      v_fee_f, v_chosei;
  end if;

  -- 調整は借方が売上高。売上を**増やして**いないこと
  if exists (
    select 1 from public.accounting_journal('2000-01-01','2100-01-01') j
    where j.区分 = '純額調整' and j.貸方科目 = '売上高'
  ) then
    raise exception 'FAIL: 純額調整が売上の貸方に立っている(向きが逆)';
  end if;
  raise notice 'OK: 純額調整%が売上から落ちる(採らない場合は区分で除外して出力)', v_chosei;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 返金は、有償分と無償分がそれぞれ元の科目へ戻る ==='
set test.uid = 'f0000000-0000-0000-0000-000000000001';
select public.cancel_booking(:'bk_b', 'テスト');  -- 承諾前 → 全額返還(有償4000)
select public.cancel_booking(:'bk_c', 'テスト');  -- 承諾前 → 全額返還(無償2000)

set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_back_paid bigint; v_back_bonus bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_back_paid
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = '返金' and j.貸方科目 = '前受金' and j.貸方補助 = 'コイン';

  select coalesce(sum(j.金額円), 0) into v_back_bonus
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.区分 = '返金' and j.貸方科目 = '販売促進費';

  if v_back_paid <> 4000 then
    raise exception 'FAIL: 有償分の返金が合わない(期待4000 / 実際%)', v_back_paid;
  end if;
  if v_back_bonus <> 2000 then
    raise exception 'FAIL: 無償分の費用の戻しが合わない(期待2000 / 実際%)', v_back_bonus;
  end if;
  raise notice 'OK: 返金 有償%は前受金へ / 無償%は販売促進費の戻し', v_back_paid, v_back_bonus;
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 換金手数料は、振込が完了するまで売上にならない(Q7-b) ==='
set test.uid = 'f0000000-0000-0000-0000-000000000002';
select public.request_bank_payout(6000) as po \gset

set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_karimae bigint; v_uriage bigint; v_shinsei bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_karimae
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '仮受金';
  select coalesce(sum(j.金額円), 0) into v_uriage
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '売上高' and j.貸方補助 = '換金事務手数料';
  select coalesce(sum(j.金額円), 0) into v_shinsei
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '預り金' and j.貸方補助 = '換金申請中';

  if v_karimae <> 300 then
    raise exception 'FAIL: 仮受金(換金手数料)が立たない(期待300 / 実際%)', v_karimae;
  end if;
  if v_uriage <> 0 then
    raise exception 'FAIL: 振込前なのに手数料が売上に立っている(%)', v_uriage;
  end if;
  if v_shinsei <> 5700 then
    raise exception 'FAIL: 振込予定額が合わない(期待5700 / 実際%)', v_shinsei;
  end if;
  raise notice 'OK: 申請時は 振込予定%+仮受金% のみ。売上はまだ0', v_shinsei, v_karimae;
end $$;

select public.mark_payout_paid(:'po');
set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_uriage bigint; v_furikomi bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_uriage
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '売上高' and j.貸方補助 = '換金事務手数料';
  select coalesce(sum(j.金額円), 0) into v_furikomi
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '普通預金';

  if v_uriage <> 300 then
    raise exception 'FAIL: 振込完了後も手数料が売上に出ない(期待300 / 実際%)', v_uriage;
  end if;
  if v_furikomi <> 5700 then
    raise exception 'FAIL: 現金の出が立たない(期待5700 / 実際%)', v_furikomi;
  end if;
  raise notice 'OK: 振込完了で 現金%が出て、手数料%が売上に振り替わる', v_furikomi, v_uriage;
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 残高が動いている状態で、仕訳の積み上げが元帳と一致すること ==='
-- **ここが本体。** 1〜6は個別の確認で、抜けがあっても気づけない。
-- accounting_journal_check は「仕訳を全部足したら元帳と同じになるか」を見る。
--
-- 検証の前に**未完了の予約を1件作る**。全部が決済し終わった状態だと
-- 3科目とも0になり、0と0を比べるだけの素通りする検証になってしまう。
set test.uid = 'f0000000-0000-0000-0000-000000000001';
select public.create_booking('f0000000-0000-0000-0000-000000000002', 60, 'v1',
  now() + interval '11 days') as bk_d \gset

set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_rec record; v_ng int := 0; v_zero int := 0;
begin
  for v_rec in
    select * from public.accounting_journal_check('2000-01-01','2100-01-01')
  loop
    raise notice '  % … 仕訳% / 元帳% / 差%  →  %',
      v_rec.項目, v_rec.仕訳から円, v_rec.元帳から円, v_rec.差額円, v_rec.判定;
    if v_rec.判定 <> 'OK' then v_ng := v_ng + 1; end if;
    if v_rec.元帳から円 = 0 then v_zero := v_zero + 1; end if;
  end loop;
  if v_ng > 0 then
    raise exception 'FAIL: 仕訳と元帳が合わない科目が%件ある', v_ng;
  end if;
  if v_zero > 0 then
    raise exception 'FAIL: 残高0の科目が%件ある。0と0を比べても検証にならない', v_zero;
  end if;
  raise notice 'OK: 3科目とも残高が動いた状態で仕訳と元帳が一致した';
end $$;

-- ------------------------------------------------------------
\echo '=== 8. コイン失効は有償分だけが雑収入になる ==='
-- 有償・無償の両方を期限切れにして、片方だけが仕訳になることを見る
update public.coin_lots set expires_at = now() - interval '1 day'
  where user_id = 'f0000000-0000-0000-0000-000000000001' and remaining > 0;
select public.expire_coins();

set test.uid = 'f0000000-0000-0000-0000-000000000009';
do $$
declare v_zatsu bigint; v_paid_lost bigint; v_bonus_lost bigint;
begin
  select coalesce(sum(j.金額円), 0) into v_zatsu
  from public.accounting_journal('2000-01-01','2100-01-01') j
  where j.貸方科目 = '雑収入';

  -- 失効したコインの実額を元帳から取る
  select coalesce(-sum(t.amount), 0) into v_paid_lost
  from public.coin_transactions t join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'paid';
  select coalesce(-sum(t.amount), 0) into v_bonus_lost
  from public.coin_transactions t join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'bonus';

  if v_paid_lost <= 0 or v_bonus_lost <= 0 then
    raise exception 'FAIL: 検証の前提が崩れている(有償%/無償%の両方が失効しているはず)',
      v_paid_lost, v_bonus_lost;
  end if;
  if v_zatsu <> v_paid_lost then
    raise exception 'FAIL: 雑収入が有償の失効額と一致しない(期待% / 実際%)', v_paid_lost, v_zatsu;
  end if;
  raise notice 'OK: 雑収入%=有償の失効額。無償%は仕訳なし(前受金を立てていないため)',
    v_zatsu, v_bonus_lost;
end $$;

-- ------------------------------------------------------------
\echo '=== 9. 失効まで済んだ後も、仕訳と元帳が一致し続けること ==='
do $$
declare v_rec record; v_ng int := 0;
begin
  for v_rec in
    select * from public.accounting_journal_check('2000-01-01','2100-01-01')
  loop
    raise notice '  % … 仕訳% / 元帳% / 差%  →  %',
      v_rec.項目, v_rec.仕訳から円, v_rec.元帳から円, v_rec.差額円, v_rec.判定;
    if v_rec.判定 <> 'OK' then
      v_ng := v_ng + 1;
    end if;
  end loop;
  if v_ng > 0 then
    raise exception 'FAIL: 仕訳と元帳が合わない科目が%件ある', v_ng;
  end if;
  raise notice 'OK: 3科目とも仕訳の積み上げが元帳の残高と一致した';
end $$;

-- ------------------------------------------------------------
\echo '=== 10. 運営以外は呼べないこと ==='
set test.uid = 'f0000000-0000-0000-0000-000000000001';
do $$
begin
  perform * from public.accounting_journal('2000-01-01','2100-01-01');
  raise exception 'FAIL: 一般利用者が仕訳を取得できてしまった';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK: 一般利用者は NOT_ADMIN で拒否される';
end $$;

do $$
begin
  perform * from public.accounting_journal_check('2000-01-01','2100-01-01');
  raise exception 'FAIL: 一般利用者が自己検証を呼べてしまった';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK: 自己検証も運営のみ';
end $$;

\echo '=== 95: 仕訳の自動生成 すべて通過 ==='
