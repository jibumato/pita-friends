-- ============================================================
-- 新規登録から報酬コインの換金申請まで、実際の呼び出しだけで通す
--
-- ■ なぜこのテストがいるか
--   個々の機能のテストは 60本以上あるが、**それらは全部モックの入口から
--   始まっている**（`_fixture_host.sql` は auth.users に直接 insert して、
--   コインも coin_lots に直接積む）。つまり「登録した人が、購入して、
--   遊んで、換金を申請できる」という**一本の線は、どこでも検証していない**。
--
--   ここではその線だけを見る。使うのは**アプリが実際に呼ぶもの**に限る:
--     ・画面から呼ぶ RPC（`src/lib/queries.ts` の `.rpc(...)`）
--     ・画面から書くテーブル（`.from(...).insert/upsert`）
--     ・Webhook から呼ぶ `credit_coins_for_purchase`（service_role）
--   **裏口から状態を作らない。**作った瞬間に、この線を見る意味が消える。
--
-- ■ 唯一の例外
--   本人確認の approve と、運営の振込消込は運営側の操作なので、
--   運営コンソールが呼ぶ RPC をそのまま使う（画面が無い操作は作らない）。
-- ============================================================

\set ON_ERROR_STOP on
\timing off

\echo '=== 32: 新規登録 → 換金申請 の一本道 ==='

-- ------------------------------------------------------------
-- 0. 登場人物
-- ------------------------------------------------------------
\set guest '11111111-aaaa-4aaa-8aaa-111111111111'
\set mate  '22222222-bbbb-4bbb-8bbb-222222222222'
\set admin '33333333-cccc-4ccc-8ccc-333333333333'

-- ============================================================
-- 1. 新規登録
--    アプリは supabase.auth.signUp を呼ぶ。DB から見えるのは
--    auth.users への insert だけなので、そこだけを行う。
--    profiles / coin_wallets / notification_prefs が
--    トリガー（0002・0003・0012）で自動的に用意されることを確かめる。
-- ============================================================
\echo '--- 1. 新規登録'
insert into auth.users (id) values (:'guest'), (:'mate'), (:'admin');
insert into public.admins (user_id) values (:'admin') on conflict do nothing;

do $$
begin
  if (select count(*) from public.profiles where id in
        ('11111111-aaaa-4aaa-8aaa-111111111111','22222222-bbbb-4bbb-8bbb-222222222222')) <> 2 then
    raise exception '1-1 NG: 登録しても profiles が作られない';
  end if;
  if (select count(*) from public.coin_wallets where user_id in
        ('11111111-aaaa-4aaa-8aaa-111111111111','22222222-bbbb-4bbb-8bbb-222222222222')) <> 2 then
    raise exception '1-2 NG: 登録しても coin_wallets が作られない';
  end if;
  raise notice '1 OK: 登録で profiles と coin_wallets が用意される';
end $$;

-- プロフィール作成（Setup 画面）
set test.uid = '11111111-aaaa-4aaa-8aaa-111111111111';
update public.profiles set nickname = 'ゲスト太郎' where id = auth.uid();
set test.uid = '22222222-bbbb-4bbb-8bbb-222222222222';
update public.profiles set nickname = 'メイト花子' where id = auth.uid();

-- ============================================================
-- 2. 同意の記録（SignUp 画面・Consent 画面・居住地の申告）
--    規約 第3条6項が「同意の日時と版を記録する」と約束している。
-- ============================================================
\echo '--- 2. 同意の記録'
set test.uid = '11111111-aaaa-4aaa-8aaa-111111111111';
select public.record_policy_consent('terms', '利用規約に同意します（版 2026-08-05）');
select public.record_monitoring_consent('v1');
select public.declare_residency(true, 'v1');

set test.uid = '22222222-bbbb-4bbb-8bbb-222222222222';
select public.record_policy_consent('terms', '利用規約に同意します（版 2026-08-05）');
select public.record_monitoring_consent('v1');
select public.declare_residency(true, 'v1');

do $$
begin
  if (select count(*) from public.policy_consents where kind = 'terms') <> 2 then
    raise exception '2-1 NG: 規約への同意が記録されていない';
  end if;
  if (select count(*) from public.residency_declarations) < 2 then
    raise exception '2-2 NG: 居住地の申告が記録されていない';
  end if;
  raise notice '2 OK: 規約・みまもり・居住地の同意が残る';
end $$;

-- ============================================================
-- 3. 本人確認
--    利用者が書類を出し（画面が insert する）、運営が承認する。
-- ============================================================
\echo '--- 3. 本人確認'
set test.uid = '22222222-bbbb-4bbb-8bbb-222222222222';
insert into public.identity_verifications (user_id, status, document_path, selfie_path)
  values (auth.uid(), 'pending', 'id/mate.jpg', 'selfie/mate.jpg');

-- 運営が承認（AdminVerifications 画面が呼ぶ RPC）
set test.uid = '33333333-cccc-4ccc-8ccc-333333333333';
select public.approve_identity_verification(id, true)
  from public.identity_verifications
  where user_id = '22222222-bbbb-4bbb-8bbb-222222222222';

do $$
begin
  if not (select is_verified from public.profile_trust_stats
          where user_id = '22222222-bbbb-4bbb-8bbb-222222222222') then
    raise exception '3 NG: 承認しても is_verified が立たない';
  end if;
  raise notice '3 OK: 本人確認の承認が信頼情報に反映される';
end $$;

-- ゲスト側も本人確認を通す（予約には相手側の確認も要る運用）
set test.uid = '11111111-aaaa-4aaa-8aaa-111111111111';
insert into public.identity_verifications (user_id, status, document_path, selfie_path)
  values (auth.uid(), 'pending', 'id/guest.jpg', 'selfie/guest.jpg');
set test.uid = '33333333-cccc-4ccc-8ccc-333333333333';
select public.approve_identity_verification(id, true)
  from public.identity_verifications
  where user_id = '11111111-aaaa-4aaa-8aaa-111111111111';

-- ============================================================
-- 4. コインの購入
--    Stripe の Webhook が service_role で呼ぶ経路。
--    アプリ側から残高を直接いじる道は無いので、ここだけは
--    Webhook と同じ関数を使う。
-- ============================================================
\echo '--- 4. コインの購入'
set role postgres;
select public.credit_coins_for_purchase(
  '11111111-aaaa-4aaa-8aaa-111111111111', 'pack_20000', 20000, 0, 20000, 'cs_e2e_0001', 'pi_e2e_0001');

do $$
declare v_bal int; v_lot int;
begin
  select balance into v_bal from public.coin_wallets
    where user_id = '11111111-aaaa-4aaa-8aaa-111111111111';
  select coalesce(sum(remaining),0) into v_lot from public.coin_lots
    where user_id = '11111111-aaaa-4aaa-8aaa-111111111111' and kind = 'paid';
  if v_bal <> 20000 then raise exception '4-1 NG: 購入しても残高が増えない(%)', v_bal; end if;
  if v_lot <> 20000 then raise exception '4-2 NG: ロットが積まれていない(%)', v_lot; end if;
  raise notice '4 OK: 購入で残高とロットが 20,000 になる';
end $$;

-- 同じ session が二度届いても増えない（Stripe は再送する）
set role postgres;
select public.credit_coins_for_purchase(
  '11111111-aaaa-4aaa-8aaa-111111111111', 'pack_20000', 20000, 0, 20000, 'cs_e2e_0001', 'pi_e2e_0001');
do $$
begin
  if (select balance from public.coin_wallets
      where user_id = '11111111-aaaa-4aaa-8aaa-111111111111') <> 20000 then
    raise exception '4-3 NG: 同じ session の再送で二重に付与された';
  end if;
  raise notice '4-3 OK: Webhook の再送で二重付与にならない';
end $$;

-- ============================================================
-- 5. ピタメイトになる（HostSettings 画面）
-- ============================================================
\echo '--- 5. ピタメイトの設定'
set test.uid = '22222222-bbbb-4bbb-8bbb-222222222222';
update public.host_settings
   set is_host = true, hourly_rate = 2000, games = array['Apex'], bio = 'まったり派です'
 where user_id = auth.uid();

-- 遊べる時間帯（枠が無いと深夜でも予約が入る＝0051）
select public.set_host_availability(
  '[{"weekday":1,"startMin":1200,"endMin":1440},
    {"weekday":2,"startMin":1200,"endMin":1440},
    {"weekday":3,"startMin":1200,"endMin":1440},
    {"weekday":4,"startMin":1200,"endMin":1440},
    {"weekday":5,"startMin":1200,"endMin":1440},
    {"weekday":6,"startMin":1200,"endMin":1440},
    {"weekday":0,"startMin":1200,"endMin":1440}]'::jsonb);

do $$
begin
  if not (select is_host from public.host_settings
          where user_id = '22222222-bbbb-4bbb-8bbb-222222222222') then
    raise exception '5 NG: ピタメイトとして掲載されない';
  end if;
  raise notice '5 OK: ピタメイトの設定と枠が入る';
end $$;

-- さがす画面に出るか（未ログインからも見えるカード）
do $$
begin
  if not exists (
    select 1 from public.public_host_cards() c
     where c.host_id = '22222222-bbbb-4bbb-8bbb-222222222222') then
    raise exception '5-2 NG: 掲載したのに さがす画面のカードに出てこない';
  end if;
  raise notice '5-2 OK: さがす画面のカードに出る';
end $$;

-- ============================================================
-- 6. 予約 → 承認 → 完了
--    金額が 20,000 コインを超えるように、長めの予約を1件通す。
--    2,000コイン/時 × 60分 = 2,000コイン。換金の最低額(5,000)を
--    超えるまで繰り返す。
-- ============================================================
\echo '--- 6. 予約から完了まで'
do $$
declare v_id uuid; i int;
begin
  for i in 1..5 loop
    perform set_config('test.uid','11111111-aaaa-4aaa-8aaa-111111111111', false);
    v_id := public.create_booking('22222222-bbbb-4bbb-8bbb-222222222222', 60, 'v1');

    perform set_config('test.uid','22222222-bbbb-4bbb-8bbb-222222222222', false);
    perform public.approve_booking(v_id);

    perform set_config('test.uid','11111111-aaaa-4aaa-8aaa-111111111111', false);
    perform public.complete_booking(v_id);
  end loop;
  raise notice '6 OK: 予約→承認→完了 を5件通した';
end $$;

do $$
declare v_guest int; v_earned int; v_done int;
begin
  select balance into v_guest from public.coin_wallets
    where user_id = '11111111-aaaa-4aaa-8aaa-111111111111';
  select earned_balance into v_earned from public.coin_wallets
    where user_id = '22222222-bbbb-4bbb-8bbb-222222222222';
  select count(*) into v_done from public.bookings
    where host_id = '22222222-bbbb-4bbb-8bbb-222222222222' and status = 'completed';

  if v_done <> 5 then raise exception '6-1 NG: 完了した予約が5件でない(%)', v_done; end if;
  -- 2,000 × 5 = 10,000 コインぶんの予約
  if v_guest <> 10000 then
    raise exception '6-2 NG: ゲストの残高が合わない(期待 10000 / 実際 %)', v_guest;
  end if;
  -- 手数料が引かれているので、報酬は 10,000 より小さく、0 より大きい
  if v_earned <= 0 or v_earned >= 10000 then
    raise exception '6-3 NG: 報酬コインの額がおかしい(%)', v_earned;
  end if;
  raise notice '6 OK: ゲスト残高 % / ピタメイト報酬 %（手数料控除後）', v_guest, v_earned;
end $$;

-- 購入コインと報酬コインが別の残高であること（恒久的制約）
do $$
begin
  if (select balance from public.coin_wallets
      where user_id = '22222222-bbbb-4bbb-8bbb-222222222222') <> 0 then
    raise exception '6-4 NG: 報酬が購入コインの残高(balance)に混ざっている';
  end if;
  raise notice '6-4 OK: 報酬コインは購入コインと別の残高のまま';
end $$;

-- ============================================================
-- 7. 振込先口座の登録（HostSettings 画面が upsert する）
-- ============================================================
\echo '--- 7. 振込先口座の登録'
set test.uid = '22222222-bbbb-4bbb-8bbb-222222222222';
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values
  (auth.uid(), 'テスト銀行', '0001', 'テスト支店', '001',
   '普通', '1234567', 'メイト ハナコ');

do $$
begin
  if not exists (select 1 from public.host_bank_accounts
                 where user_id = '22222222-bbbb-4bbb-8bbb-222222222222') then
    raise exception '7 NG: 口座が登録できない';
  end if;
  raise notice '7 OK: 振込先口座が登録できる';
end $$;

-- ============================================================
-- 8. 換金申請
-- ============================================================
\echo '--- 8. 換金申請'

-- 8-1. 最低額（5,000コイン）を下回る申請は通らない
do $$
begin
  perform set_config('test.uid','22222222-bbbb-4bbb-8bbb-222222222222', false);
  begin
    perform public.request_bank_payout(4999);
    raise exception '8-1 NG: 5,000コイン未満の申請が通ってしまった';
  exception when others then
    if sqlerrm not like '%MIN_PAYOUT_COINS%' then raise; end if;
  end;
  raise notice '8-1 OK: 最低額を下回る申請は MIN_PAYOUT_COINS で止まる';
end $$;

-- 8-2. 残高を超える申請は通らない
do $$
declare v_earned int;
begin
  perform set_config('test.uid','22222222-bbbb-4bbb-8bbb-222222222222', false);
  select earned_balance into v_earned from public.coin_wallets where user_id = auth.uid();
  begin
    perform public.request_bank_payout(v_earned + 1);
    raise exception '8-2 NG: 残高を超える申請が通ってしまった';
  exception when others then
    if sqlerrm not like '%INSUFFICIENT_EARNED_BALANCE%' then raise; end if;
  end;
  raise notice '8-2 OK: 残高超過は INSUFFICIENT_EARNED_BALANCE で止まる';
end $$;

-- 8-3. 正常な申請
do $$
declare v_before int; v_after int; v_payout public.payouts;
begin
  perform set_config('test.uid','22222222-bbbb-4bbb-8bbb-222222222222', false);
  select earned_balance into v_before from public.coin_wallets where user_id = auth.uid();

  perform public.request_bank_payout(5000);

  select earned_balance into v_after from public.coin_wallets where user_id = auth.uid();
  select * into v_payout from public.payouts
    where user_id = '22222222-bbbb-4bbb-8bbb-222222222222'
    order by created_at desc limit 1;

  if v_payout.id is null then raise exception '8-3 NG: 申請しても payouts に起票されない'; end if;
  if v_after <> v_before - 5000 then
    raise exception '8-3 NG: 申請額が報酬残高から引かれていない(% → %)', v_before, v_after;
  end if;
  if v_payout.coins <> 5000 then
    raise exception '8-3 NG: 起票された額が違う(%)', v_payout.coins;
  end if;
  -- 手数料 300コインを引いた額が振り込まれる
  if v_payout.amount_yen <> 4700 then
    raise exception '8-3 NG: 振込額が 4,700円 でない(%)', v_payout.amount_yen;
  end if;
  -- 起票直後は pending（payouts.status は pending / paid / failed の3値）
  if v_payout.status <> 'pending' then
    raise exception '8-3 NG: 起票直後の状態が pending でない(%)', v_payout.status;
  end if;
  -- 口座情報が申請時点のものとして写し取られている（後で口座を変えても影響しない）
  if v_payout.account_holder_kana is null or v_payout.bank_name is null then
    raise exception '8-3 NG: 申請に口座情報が写されていない';
  end if;
  raise notice '8-3 OK: 5,000コインの申請 → 振込額 %円 / 手数料 %円',
    v_payout.amount_yen, v_payout.fee_yen;
end $$;

-- ============================================================
-- 9. 新規ユーザーの購入を原資とする報酬は、自動で保留される（0088）
--
--    ★これはローンチ直後にそのまま効く。**最初の利用者は全員が新規**なので、
--      最初のうちの換金申請は、原則としてすべて 30日 保留になる。
--      仕様どおりだが、知らないと「換金できない不具合」に見える。
--      `platform_pricing.new_user_payout_hold_days` で運営コンソールから
--      変えられる（既定 30日 / 新規の判定も 30日）。
-- ============================================================
\echo '--- 9. 新規ユーザー原資の保留'
do $$
declare v_id uuid; v_hold timestamptz;
begin
  select id, hold_until into v_id, v_hold from public.payouts
    where user_id = '22222222-bbbb-4bbb-8bbb-222222222222'
    order by created_at desc limit 1;

  if v_hold is null then
    raise exception '9-1 NG: 新規ユーザーの購入が原資なのに保留がかからない';
  end if;

  -- 保留中は消し込めない
  perform set_config('test.uid','33333333-cccc-4ccc-8ccc-333333333333', false);
  begin
    perform public.admin_mark_payout_paid(v_id, null);
    raise exception '9-1 NG: 保留中なのに paid にできてしまった';
  exception when others then
    if sqlerrm not like '%PAYOUT_ON_RISK_HOLD%' then raise; end if;
  end;
  raise notice '9-1 OK: 保留がかかり、期間中は消し込めない（明けるのは %）', v_hold::date;
end $$;

-- ============================================================
-- 9-2. 保留が明けたら消し込める
--      時間の経過は hold_until を過去に倒して作る。
--      **ここだけは裏口だが、30日待つ以外に再現する手が無い。**
-- ============================================================
do $$
declare v_id uuid;
begin
  select id into v_id from public.payouts
    where user_id = '22222222-bbbb-4bbb-8bbb-222222222222'
    order by created_at desc limit 1;

  update public.payouts set hold_until = now() - interval '1 day' where id = v_id;

  perform set_config('test.uid','33333333-cccc-4ccc-8ccc-333333333333', false);
  perform public.admin_mark_payout_paid(v_id, null);

  if (select status from public.payouts where id = v_id) <> 'paid' then
    raise exception '9-2 NG: 保留が明けても paid にならない';
  end if;
  if (select paid_at from public.payouts where id = v_id) is null then
    raise exception '9-2 NG: 支払日が入らない';
  end if;
  raise notice '9-2 OK: 保留が明ければ運営コンソールから paid にできる';
end $$;

-- ============================================================
-- 10. 台帳の整合
--     ここまでの一連で、会計の突合が壊れていないこと。
-- ============================================================
\echo '--- 10. 台帳の整合'
do $$
declare r record; v_ng int := 0;
begin
  perform set_config('test.uid','33333333-cccc-4ccc-8ccc-333333333333', false);
  for r in
    select * from public.accounting_journal_check(
      (now() - interval '1 day')::date, (now() + interval '1 day')::date)
  loop
    if not coalesce((to_jsonb(r) ->> 'ok')::boolean, true) then
      v_ng := v_ng + 1;
      raise warning '10 NG: %', to_jsonb(r)::text;
    end if;
  end loop;
  if v_ng > 0 then
    raise exception '10 NG: 会計の突合が % 件合わない', v_ng;
  end if;
  raise notice '10 OK: 会計の突合が合っている';
end $$;

-- 整合性チェック（運営コンソールの健全性タブが見るもの）
do $$
declare r record; v_ng int := 0;
begin
  perform set_config('test.uid','', false);
  perform public.run_integrity_checks();
  -- severity が 'ok' 以外だけが異常。affected_count は
  -- unused_coin_balance のような**残高そのものを載せる指標**でも増えるので、
  -- 件数で判定してはいけない。
  for r in select * from public.integrity_checks where severity <> 'ok' loop
    v_ng := v_ng + 1;
    raise warning '10-2 NG: % (% 件 / ずれ %) %',
      r.check_name, r.affected_count, r.total_gap, r.detail;
  end loop;
  if v_ng > 0 then
    raise exception '10-2 NG: 整合性チェックが % 件落ちている', v_ng;
  end if;
  raise notice '10-2 OK: 整合性チェックがすべて通る';
end $$;

\echo '=== 32: 一本道を通過 ==='
