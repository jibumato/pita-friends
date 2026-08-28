-- ============================================================
-- 22: 新規ユーザーの購入上限と、コインの出所(0087・G11前半)
-- ------------------------------------------------------------
-- 規約 第8条の6第5項1号。守っているのは**自作自演型**だけで、
-- 不正利用型は3DS2の責任移転が主防御(同条第4項4号)。
--
-- 固定するのは6つ:
--   ・1回あたりの上限で止まること
--   ・期間累計の上限で止まること(1回では届かない額の積み上げ)
--   ・本人確認済み・登録から一定期間経過なら上限が外れること
--   ・**チャージバック履歴があれば上限が戻ること**
--   ・条文の「最長30日」を超える保留日数を入れられないこと
--   ・購入 → ロット → 消費 → 予約 の鎖がつながること
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f1000000-0000-0000-0000-000000000001'),
  ('f1000000-0000-0000-0000-000000000002');
insert into public.profiles (id, nickname) values
  ('f1000000-0000-0000-0000-000000000001','新規'),
  ('f1000000-0000-0000-0000-000000000002','ピタメイト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f1000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('f1000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- 0119: 購入の判定は居住地の申告から始まる。ここは上限を見るテストなので、
-- 申告は済ませておく(申告そのものの検証は 38 で行う)
set test.uid = 'f1000000-0000-0000-0000-000000000001';
select public.declare_residency(true);

-- ------------------------------------------------------------
\echo '=== 1. 推奨値が入っていること ==='
do $$
declare v_days int; v_per int; v_period int; v_hold int;
begin
  select new_user_days, new_user_purchase_max_yen,
         new_user_period_purchase_max_yen, new_user_payout_hold_days
    into v_days, v_per, v_period, v_hold
  from public.platform_pricing where id = 1;
  if v_days <> 30 or v_per <> 10000 or v_period <> 30000 or v_hold <> 30 then
    raise exception 'FAIL: 既定値が違う(% / % / % / %)', v_days, v_per, v_period, v_hold;
  end if;
  raise notice 'OK: 30日 / 1回10,000円 / 累計30,000円 / 保留30日';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 条文の「最長30日」を超える保留は入れられないこと ==='
-- **規約が画した数値を、運用の都合で越えられないようにする**
do $$
begin
  update public.platform_pricing set new_user_payout_hold_days = 45 where id = 1;
  raise exception 'FAIL: 45日の保留を設定できてしまった(第8条の6第5項2号違反)';
exception when check_violation then
  raise notice 'OK: 30日を超える保留は制約が拒否する';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 新規ユーザーは1回あたりの上限で止まること ==='
do $$
declare v jsonb;
begin
  v := public.purchase_limit_status('f1000000-0000-0000-0000-000000000001');
  if (v->>'is_new_user')::boolean is not true then
    raise exception 'FAIL: 登録直後なのに新規扱いでない(%)', v;
  end if;

  v := public.check_purchase_allowed('f1000000-0000-0000-0000-000000000001', 20000);
  if (v->>'allowed')::boolean is not false or v->>'code' <> 'PURCHASE_LIMIT_PER' then
    raise exception 'FAIL: 1回20,000円が通ってしまった(%)', v;
  end if;

  -- 上限ちょうどは通す(境界で1円ずれると問い合わせになる)
  v := public.check_purchase_allowed('f1000000-0000-0000-0000-000000000001', 10000);
  if (v->>'allowed')::boolean is not true then
    raise exception 'FAIL: 上限ちょうどが弾かれた(%)', v;
  end if;
  raise notice 'OK: 20,000円は不可 / 10,000円ちょうどは可';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 期間累計の上限で止まること ==='
-- 1回では届かない額を、複数回で積み上げる経路を塞ぐ
insert into public.coin_purchases
  (user_id, pack_id, coins_credited, price_yen, stripe_session_id)
values
  ('f1000000-0000-0000-0000-000000000001', null, 10000, 10000, 'sess_lim_1'),
  ('f1000000-0000-0000-0000-000000000001', null, 10000, 10000, 'sess_lim_2'),
  ('f1000000-0000-0000-0000-000000000001', null,  5000,  5000, 'sess_lim_3');

do $$
declare v jsonb;
begin
  v := public.purchase_limit_status('f1000000-0000-0000-0000-000000000001');
  if (v->>'spent_yen')::bigint <> 25000 then
    raise exception 'FAIL: 期間内の購入額が合わない(%)', v;
  end if;
  if (v->>'remaining_yen')::bigint <> 5000 then
    raise exception 'FAIL: 残りが合わない(%)', v;
  end if;

  -- 1回の上限には触れないが、累計で越える額
  v := public.check_purchase_allowed('f1000000-0000-0000-0000-000000000001', 10000);
  if (v->>'allowed')::boolean is not false or v->>'code' <> 'PURCHASE_LIMIT_PERIOD' then
    raise exception 'FAIL: 累計30,000円を越える購入が通った(%)', v;
  end if;

  v := public.check_purchase_allowed('f1000000-0000-0000-0000-000000000001', 5000);
  if (v->>'allowed')::boolean is not true then
    raise exception 'FAIL: 残り5,000円ちょうどが弾かれた(%)', v;
  end if;
  raise notice 'OK: 累計25,000円 → 残り5,000円。10,000円は不可、5,000円は可';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 本人確認済み＋一定期間経過なら上限が外れること ==='
-- **既存の優良顧客に上限をかけると売上の上位が直撃される。**
-- 第5項1号が主体を「登録から一定期間内のユーザー」に限っている理由
update public.profiles set created_at = now() - interval '100 days'
  where id = 'f1000000-0000-0000-0000-000000000001';
update public.profile_trust_stats set is_verified = true
  where user_id = 'f1000000-0000-0000-0000-000000000001';

do $$
declare v jsonb;
begin
  v := public.purchase_limit_status('f1000000-0000-0000-0000-000000000001');
  if (v->>'is_new_user')::boolean is not false then
    raise exception 'FAIL: 条件を満たしたのに上限が外れない(%)', v;
  end if;
  v := public.check_purchase_allowed('f1000000-0000-0000-0000-000000000001', 50000);
  if (v->>'allowed')::boolean is not true then
    raise exception 'FAIL: 上限が外れた利用者が50,000円を買えない(%)', v;
  end if;
  raise notice 'OK: 上限が外れる';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. チャージバック履歴があれば上限が戻ること ==='
-- 一度でも異議を出した相手に、上限なしで買わせる理由が無い
insert into public.payment_disputes
  (user_id, stripe_dispute_id, stripe_charge_id, stripe_payment_intent,
   amount_yen, reason, status)
values ('f1000000-0000-0000-0000-000000000001','dp_test_1','ch_1','pi_1',
        10000,'fraudulent','open');

do $$
declare v jsonb;
begin
  v := public.purchase_limit_status('f1000000-0000-0000-0000-000000000001');
  if (v->>'is_new_user')::boolean is not true then
    raise exception 'FAIL: 係争中の異議があるのに上限が外れたまま(%)', v;
  end if;
  if (v->>'reason_disputed')::boolean is not true then
    raise exception 'FAIL: 理由が画面に出せない(%)', v;
  end if;
  raise notice 'OK: 異議があるあいだは上限が戻る(理由も返る)';
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 未ログイン・一般ユーザーから判定関数を呼べないこと ==='
-- SECURITY DEFINER で他人の購入履歴を読むので、開いていると漏れる
do $$
begin
  if has_function_privilege('anon', 'public.purchase_limit_status(uuid)', 'execute') then
    raise exception 'FAIL: 未ログインが purchase_limit_status を呼べる';
  end if;
  if has_function_privilege('authenticated', 'public.purchase_limit_status(uuid)', 'execute') then
    raise exception 'FAIL: **ログイン済みが他人の購入額を引数で調べられる**';
  end if;
  if has_function_privilege('authenticated', 'public.check_purchase_allowed(uuid, integer)', 'execute') then
    raise exception 'FAIL: ログイン済みが check_purchase_allowed を呼べる';
  end if;
  if not has_function_privilege('authenticated', 'public.my_purchase_limit()', 'execute') then
    raise exception 'FAIL: 自分の上限を画面に出せない';
  end if;
  raise notice 'OK: 自分の分だけ my_purchase_limit() で見える';
end $$;

-- ------------------------------------------------------------
\echo '=== 8. 購入 → ロット → 消費 → 予約 の鎖がつながること ==='
-- 規約第8条の6第4項1号が控除の対象を
-- 「**当該失効した購入から現に充当された**予約およびギフト」に限っている。
-- **鎖が切れていると、条文どおりの特定ができない**
select public.credit_coins_for_purchase(
  'f1000000-0000-0000-0000-000000000002', null, 3000, 0, 3000, 'sess_chain') ;

set test.uid = 'f1000000-0000-0000-0000-000000000002';
do $$
declare v_lot uuid; v_purchase uuid;
begin
  select l.id, l.purchase_id into v_lot, v_purchase
  from public.coin_lots l
  where l.user_id = 'f1000000-0000-0000-0000-000000000002'
  order by l.created_at desc limit 1;

  if v_purchase is null then
    raise exception 'FAIL: ロットに購入が紐づいていない(出所をたどれない)';
  end if;
  if not exists (select 1 from public.coin_purchases p
                  where p.id = v_purchase and p.stripe_session_id = 'sess_chain') then
    raise exception 'FAIL: 紐づけ先の購入が違う';
  end if;
  raise notice 'OK: 購入 → ロット がつながっている';
end $$;

-- 予約で消費して、消費記録がロットを指すこと
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('f1000000-0000-0000-0000-000000000001', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f1000000-0000-0000-0000-000000000001';

select public.create_booking('f1000000-0000-0000-0000-000000000001', 60) as bk \gset

-- psql の変数は $$ の中では展開されない。一時表に置いてから読む
create temporary table _bk as select :'bk'::uuid as id;

do $$
declare v_n int;
begin
  select count(*) into v_n
  from public.coin_lot_consumptions c
  join public.coin_lots l on l.id = c.lot_id
  join public.coin_purchases p on p.id = l.purchase_id
  where c.booking_id = (select id from _bk) and p.stripe_session_id = 'sess_chain';
  if v_n < 1 then
    raise exception
      'FAIL: 消費 → ロット → 購入 がたどれない。第8条の6第4項1号の特定ができない';
  end if;
  raise notice 'OK: 予約から購入までさかのぼれる(%件)', v_n;
end $$;

\echo '=== 22: 購入上限とコインの出所 すべて通過 ==='
