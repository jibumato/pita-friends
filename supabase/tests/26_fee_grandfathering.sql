-- ============================================================
-- 26: 料率の遡及適用を止める(0091・G3)
-- ------------------------------------------------------------
-- 規約 第8条の2第3の2項・4項・5項。弁護士(論点3)が
-- 「**上限のない変更権は『青天井』と評価される最大の弱点**」
-- 「**実質的な離脱の自由は『辞めても、稼いだ分は従前の条件で
--   回収できる』ことで初めて担保される**」と指摘した箇所。
--
-- 固定するのは6つ:
--   ・上限(予約30%/ギフト40%)を**制約で**越えられないこと
--   ・変更は**30日以上先**でしか予約できないこと
--   ・**理由なしに変更できない**こと
--   ・予約したら**ピタメイト全員に個別通知**が飛ぶこと
--   ・**変更前に成立した予約には旧料率**が適用されること(5項の本体)
--   ・表示(第3項)がいま有効な組と、予告を返すこと
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d4000000-0000-0000-0000-000000000001'),
  ('d4000000-0000-0000-0000-000000000002'),
  ('d4000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('d4000000-0000-0000-0000-000000000001','ゲスト'),
  ('d4000000-0000-0000-0000-000000000002','ピタメイト'),
  ('d4000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('d4000000-0000-0000-0000-000000000001',
                    'd4000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('d4000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.admins (user_id) values ('d4000000-0000-0000-0000-000000000009');

-- ------------------------------------------------------------
\echo '=== 1. 上限を制約で越えられないこと(第3の2項) ==='
-- **紳士協定にしない。** 規約が画した数値は制約で守る
do $$
begin
  insert into public.host_fee_tiers (effective_from, step, upper_bound, rate)
  values ('2030-01-01', 1, null, 0.350);
  raise exception 'FAIL: 予約の率を35%%にできてしまった(上限30%%)';
exception when check_violation then
  raise notice 'OK: 予約は30%%を超えられない';
end $$;

do $$
begin
  insert into public.gift_fee_rates (effective_from, rate) values ('2030-01-01', 0.500);
  raise exception 'FAIL: ギフトの率を50%%にできてしまった(上限40%%)';
exception when check_violation then
  raise notice 'OK: ギフトは40%%を超えられない';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 変更は30日以上先でしか予約できないこと(第4項) ==='
set test.uid = 'd4000000-0000-0000-0000-000000000009';
do $$
begin
  perform public.admin_schedule_fee_change(
    now() + interval '10 days', '値上げ',
    '[{"upperBound": null, "percent": 25}]'::jsonb, 35);
  raise exception 'FAIL: 10日後の変更を登録できてしまった';
exception when others then
  if sqlerrm <> 'NOTICE_PERIOD_TOO_SHORT' then raise; end if;
  raise notice 'OK: NOTICE_PERIOD_TOO_SHORT で止まる';
end $$;

\echo '--- 理由なしには登録できないこと ---'
do $$
begin
  perform public.admin_schedule_fee_change(
    now() + interval '40 days', '  ',
    '[{"upperBound": null, "percent": 25}]'::jsonb, 35);
  raise exception 'FAIL: 理由なしで登録できてしまった';
exception when others then
  if sqlerrm <> 'REASON_REQUIRED' then raise; end if;
  raise notice 'OK: REASON_REQUIRED で止まる';
end $$;

\echo '--- 関数からも上限を越えられないこと ---'
do $$
begin
  perform public.admin_schedule_fee_change(
    now() + interval '40 days', '値上げ',
    '[{"upperBound": null, "percent": 31}]'::jsonb, 35);
  raise exception 'FAIL: 31%%を登録できてしまった';
exception when others then
  if sqlerrm <> 'BOOKING_RATE_OVER_CAP' then raise; end if;
  raise notice 'OK: BOOKING_RATE_OVER_CAP で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 予約すると全ピタメイトに個別通知が飛ぶこと(第4項) ==='
do $$
declare v jsonb; v_n int;
begin
  v := public.admin_schedule_fee_change(
    now() + interval '40 days', '決済手数料の上昇のため',
    '[{"upperBound": 30000, "percent": 25}, {"upperBound": null, "percent": 20}]'::jsonb,
    38);
  if (v->>'notified_hosts')::int < 1 then
    raise exception 'FAIL: 誰にも通知していない(%)', v;
  end if;

  select count(*) into v_n from public.notifications
   where user_id = 'd4000000-0000-0000-0000-000000000002'
     and title like '%利用料の率が変わります%';
  if v_n <> 1 then raise exception 'FAIL: 個別通知が届いていない(%)', v_n; end if;

  -- **旧料率が続くことを通知に書いているか。**5項の説明が無いと不安になる
  if not exists (
    select 1 from public.notifications
     where user_id = 'd4000000-0000-0000-0000-000000000002'
       and body like '%変更前の率をそのまま適用します%'
       and body like '%決済手数料の上昇のため%') then
    raise exception 'FAIL: 理由または旧料率の継続が通知に無い';
  end if;
  raise notice 'OK: %名へ個別通知。理由と5項の説明つき', (v->>'notified_hosts')::int;
end $$;

\echo '--- 同じ日付を二度登録できないこと ---'
do $$
begin
  perform public.admin_schedule_fee_change(
    (select effective_from from public.fee_change_notices limit 1), 'もう一度',
    '[{"upperBound": null, "percent": 20}]'::jsonb, 35);
  raise exception 'FAIL: 同じ施行日を二度登録できた';
exception when others then
  if sqlerrm <> 'ALREADY_SCHEDULED' then raise; end if;
  raise notice 'OK: ALREADY_SCHEDULED で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 施行前は、まだ旧料率であること ==='
do $$
declare v jsonb;
begin
  v := public.fee_rates();
  if (v->'bookingTiers'->0->>'percent')::numeric <> 20.0 then
    raise exception 'FAIL: 施行前なのに新料率が表示されている(%)', v->'bookingTiers';
  end if;
  if (v->>'giftPercent')::numeric <> 35.0 then
    raise exception 'FAIL: ギフトの率が先に変わっている(%)', v->>'giftPercent';
  end if;
  -- 予告が画面に出せること(第4項)
  if v->'scheduledChange'->>'effectiveFrom' is null then
    raise exception 'FAIL: 予告を表示に出せない(%)', v;
  end if;
  if v->'scheduledChange'->>'reason' is null then
    raise exception 'FAIL: 予告に理由が無い';
  end if;
  raise notice 'OK: いまは20%%/35%%。予告は% から', v->'scheduledChange'->>'effectiveFrom';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. **変更前に成立した予約には旧料率**(第5項の本体) ==='
-- ここが G3 の中身。**確定の時点ではなく、成立の時点で決まる**
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('d4000000-0000-0000-0000-000000000001','paid', 20000, now() + interval '100 days');
update public.coin_wallets set balance = 20000
  where user_id = 'd4000000-0000-0000-0000-000000000001';

set test.uid = 'd4000000-0000-0000-0000-000000000001';
select public.create_booking('d4000000-0000-0000-0000-000000000002', 600) as bk \gset
set test.uid = 'd4000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
create temporary table _bk as select :'bk'::uuid as id;

-- **予約は施行日より前に成立していた**という状態を作る。
-- 成立(承諾)が2日前、施行が1日前。台帳は追記専用なので明示的に解除する
begin;
set local app.ledger_override = 'on';
update public.bookings set confirmed_at = now() - interval '2 days'
  where id = (select id from _bk);
commit;

-- 施行日を過ぎた状態にする(新料率25%が現行になる)
update public.fee_change_notices set effective_from = now() - interval '1 day';
update public.host_fee_tiers set effective_from = now() - interval '1 day'
  where effective_from > now();
update public.gift_fee_rates set effective_from = now() - interval '1 day'
  where effective_from > now();

do $$
declare v jsonb;
begin
  v := public.fee_rates();
  if (v->'bookingTiers'->0->>'percent')::numeric <> 25.0 then
    raise exception 'FAIL: 施行後なのに新料率になっていない(%)', v->'bookingTiers';
  end if;
  raise notice 'OK: 現行は25%%になった';
end $$;

-- 予約は**施行前に成立している**ので、確定は施行後でも旧料率(20%)
set test.uid = 'd4000000-0000-0000-0000-000000000001';
select public.complete_booking((select id from _bk));

do $$
declare v_rate numeric; v_fee int; v_gross int;
begin
  select applied_rate, fee_coins, gross_coins into v_rate, v_fee, v_gross
  from public.platform_fees
  where booking_id = (select id from _bk) and kind = 'booking';

  if v_gross <> 10000 then
    raise exception 'FAIL: 予約額が合わない(%)。時給1000×10時間', v_gross;
  end if;
  -- 旧料率: 30,000まで20% → 10,000コインなら2,000
  if v_fee <> 2000 then
    raise exception
      'FAIL: **確定時の新料率(25%%)で引かれた(手数料%)。** 第8条の2第5項違反', v_fee;
  end if;
  if v_rate <> 0.2000 then
    raise exception 'FAIL: 記録された率が旧料率でない(%)', v_rate;
  end if;
  raise notice 'OK: 成立時の20%%が適用された(手数料%コイン)', v_fee;
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 施行後に成立した予約は、新料率になること ==='
-- 旧料率が「ずっと続く」のも間違い。切り替わることも確かめる
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('d4000000-0000-0000-0000-000000000001','paid', 20000, now() + interval '100 days');
update public.coin_wallets set balance = balance + 20000
  where user_id = 'd4000000-0000-0000-0000-000000000001';

set test.uid = 'd4000000-0000-0000-0000-000000000001';
select public.create_booking('d4000000-0000-0000-0000-000000000002', 60) as bk2 \gset
set test.uid = 'd4000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk2');
create temporary table _bk2 as select :'bk2'::uuid as id;
set test.uid = 'd4000000-0000-0000-0000-000000000001';
select public.complete_booking((select id from _bk2));

do $$
declare v_rate numeric;
begin
  select applied_rate into v_rate from public.platform_fees
   where booking_id = (select id from _bk2) and kind = 'booking';
  -- 当月累計は11,000コインなので1段目(新料率25%)。
  -- 同じゲストとの2回目なので指名リピート3ptが引かれて22%。
  -- **旧料率のままなら 20% − 3pt = 17%** なので、ここで新旧が見分けられる
  if v_rate <> 0.2200 then
    raise exception
      'FAIL: 施行後の予約に新料率が適用されていない(%)。旧料率なら0.1700になる', v_rate;
  end if;
  raise notice 'OK: 施行後に成立した予約は新料率(25%% − リピート3pt = 22%%)';
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 一般ユーザーは料率を変えられないこと ==='
do $$
begin
  perform public.admin_schedule_fee_change(
    now() + interval '40 days', '勝手に', '[{"upperBound": null, "percent": 5}]'::jsonb, 5);
  raise exception 'FAIL: 一般ユーザーが料率を変えられた';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK: NOT_ADMIN で止まる';
end $$;

\echo '=== 26: 料率の遡及適用の防止 すべて通過 ==='
