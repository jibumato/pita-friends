-- 取引データの日次整合性チェック(0043)の検証。
--
-- 前半は「実際のRPCだけで一通りの取引を回したあと、全チェックが ok になるか」。
-- ここが通ることで、0043 が前提にしている不変条件
--   Σ coin_transactions.amount == balance + bonus_balance + earned_balance
-- が、0003〜0042 の実装に対して本当に成り立っていることを確かめられる。
--
-- 後半は「わざと壊したときに検知できるか」。検知できない検知機能は無意味なので、
-- 壊し方ごとにどのチェックが鳴るかまで確認する。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d0000000-0000-0000-0000-0000000000e1'::uuid),
  ('d0000000-0000-0000-0000-0000000000e2'::uuid),
  ('d0000000-0000-0000-0000-0000000000e9'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('d0000000-0000-0000-0000-0000000000e1'::uuid, '整合メイト'),
  ('d0000000-0000-0000-0000-0000000000e2'::uuid, '整合ゲスト'),
  ('d0000000-0000-0000-0000-0000000000e9'::uuid, '整合運営')
on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('d0000000-0000-0000-0000-0000000000e9'::uuid)
  on conflict do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id in ('d0000000-0000-0000-0000-0000000000e1'::uuid,
                    'd0000000-0000-0000-0000-0000000000e2'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('d0000000-0000-0000-0000-0000000000e1'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000, trial_discount_percent = 0;
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
  values ('d0000000-0000-0000-0000-0000000000e1'::uuid,
          'テスト銀行', '0001', 'テスト支店', '001', '普通', '1234567', 'セイゴウメイト')
  on conflict (user_id) do nothing;

\echo '=== 1. 実際のRPCだけで一通り取引を回す ==='
-- 購入(Stripe経路): 有償30000 + ボーナス500
-- (0063で最低換金額が5,000コインになったので、報酬がそこに届く規模にしている)
select public.credit_coins_for_purchase(
  'd0000000-0000-0000-0000-0000000000e2'::uuid, 'pack_5000',
  30000, 500, 30000, 'sess_integrity_1', 'pi_integrity_1');

-- 予約→承諾→完了(報酬と手数料が動く)
set test.uid = 'd0000000-0000-0000-0000-0000000000e2';
select public.create_booking('d0000000-0000-0000-0000-0000000000e1'::uuid, 60, 'v2', null) as bk1 \gset
set test.uid = 'd0000000-0000-0000-0000-0000000000e1';
select public.approve_booking(:'bk1');
set test.uid = 'd0000000-0000-0000-0000-0000000000e2';
select public.complete_booking(:'bk1');

-- 予約→承諾→ゲストキャンセル(返還が動く)
select public.create_booking('d0000000-0000-0000-0000-0000000000e1'::uuid, 60, 'v2', null) as bk2 \gset
set test.uid = 'd0000000-0000-0000-0000-0000000000e1';
select public.approve_booking(:'bk2');
set test.uid = 'd0000000-0000-0000-0000-0000000000e2';
select public.cancel_booking(:'bk2');

-- 予約したまま未完了(預かり中のコインを作る)
select public.create_booking('d0000000-0000-0000-0000-0000000000e1'::uuid, 60, 'v2', null) as bk3 \gset

-- ギフト(有償→報酬への移動)。チャージ直後は贈れない仕様なので購入を過去にずらす
-- (0044で入金記録は追記専用なので、明示的に解除する)
set app.ledger_override = 'on';
update public.coin_purchases set created_at = now() - interval '2 days'
  where stripe_session_id = 'sess_integrity_1';
reset app.ledger_override;
select id as promise_id from public.promises where booking_id = :'bk1' \gset
-- 8,000にしているのは、0063で最低換金額が5,000コインになったため。
-- 予約を長くすると3件の枠が重なる(0049)ので、ギフトで積む。
select public.send_gift(:'promise_id', 8000, 'dev-integrity-guest', '10.0.0.1');

-- 受領直後のギフトは7日間換金保留になる(0069。0063で消えていたのを復活させた)。
-- ここで見たいのは整合チェックであって保留の挙動ではないので、
-- 受領を過去にずらして保留を外す。保留そのものの検証は 89 で行う。
update public.gifts set created_at = now() - interval '8 days'
  where promise_id = :'promise_id';

-- 換金申請(報酬から引かれ、payouts に積まれる)
set test.uid = 'd0000000-0000-0000-0000-0000000000e1';
select public.request_bank_payout(5000);

\echo '=== 2. この時点で全チェックが ok になること ==='
set test.uid = 'd0000000-0000-0000-0000-0000000000e9';
do $$
declare v_err int; v_bad text;
begin
  v_err := public.run_integrity_checks();
  if v_err <> 0 then
    select string_agg(check_name || '(' || affected_count || '件/' || total_gap || 'コイン)', ', ')
      into v_bad from public.integrity_latest where severity = 'error';
    raise exception 'FAIL 正常な取引なのにエラーが出た: %', v_bad;
  end if;
  raise notice 'OK 実RPCで回した取引はすべて整合している(errors=%)', v_err;
end $$;

\echo '=== 3. 預かり中・未使用残高の指標が記録されていること ==='
do $$
declare v_escrow bigint; v_unused bigint;
begin
  select total_gap into v_escrow from public.integrity_latest where check_name = 'escrow_outstanding';
  select total_gap into v_unused from public.integrity_latest where check_name = 'unused_coin_balance';
  -- bk3(60分×2000円/時)が預かり中
  if v_escrow <> 2000 then raise exception 'FAIL 預かり中コインが合わない: %', v_escrow; end if;
  if v_unused <= 0 then raise exception 'FAIL 未使用残高が記録されていない: %', v_unused; end if;
  raise notice 'OK 預かり中=%コイン / 未使用=%コイン を記録している', v_escrow, v_unused;
end $$;

\echo '=== 4. 残高を直接書き換えると検知される(管理画面での誤操作を想定) ==='
update public.coin_wallets set balance = balance + 1000
  where user_id = 'd0000000-0000-0000-0000-0000000000e2'::uuid;
do $$
declare v_err int; v_lots text; v_ledger text; v_gap bigint;
begin
  v_err := public.run_integrity_checks();
  select severity, total_gap into v_lots, v_gap from public.integrity_latest
    where check_name = 'wallet_vs_lots_paid';
  select severity into v_ledger from public.integrity_latest where check_name = 'wallet_vs_ledger';
  if v_lots <> 'error' then raise exception 'FAIL ロットとのズレを検知できていない'; end if;
  if v_ledger <> 'error' then raise exception 'FAIL 履歴とのズレを検知できていない'; end if;
  if v_gap <> 1000 then raise exception 'FAIL ズレの大きさが合わない: %', v_gap; end if;
  raise notice 'OK 残高の直接書き換えを2つのチェックが検知した(ズレ%コイン)', v_gap;
end $$;

\echo '=== 5. エラー時に管理者へ通知が飛ぶこと ==='
do $$
declare v_n int;
begin
  select count(*) into v_n from public.notifications
    where user_id = 'd0000000-0000-0000-0000-0000000000e9'::uuid and type = 'integrity_alert';
  if v_n < 1 then raise exception 'FAIL 管理者に通知が飛んでいない'; end if;
  raise notice 'OK 管理者に整合性アラートが届いている(% 件)', v_n;
end $$;

-- 元に戻す
update public.coin_wallets set balance = balance - 1000
  where user_id = 'd0000000-0000-0000-0000-0000000000e2'::uuid;

\echo '=== 6. 履歴を消すと検知される(台帳の改ざん・欠落を想定) ==='
-- 0044の保護があるので、破損を模すには明示的な解除が要る
-- (裏を返せば、うっかりでは起きなくなっている)
-- 0083で購入ボーナスを廃止したため、'bonus' の行はもう作られない。
-- 欠落を模す対象を 'purchase' の行に変えた(C4は purchase と bonus の
-- 合計を見るので、どちらが欠けても検知できるのが正しい)
set app.ledger_override = 'on';
delete from public.coin_transactions
  where user_id = 'd0000000-0000-0000-0000-0000000000e2'::uuid
    and type = 'purchase' and note = 'stripe:sess_integrity_1';
reset app.ledger_override;
do $$
declare v_purchase text; v_ledger text;
begin
  perform public.run_integrity_checks();
  select severity into v_purchase from public.integrity_latest where check_name = 'purchase_vs_ledger';
  select severity into v_ledger from public.integrity_latest where check_name = 'wallet_vs_ledger';
  if v_purchase <> 'error' then raise exception 'FAIL 入金記録とのズレを検知できていない'; end if;
  if v_ledger <> 'error' then raise exception 'FAIL 履歴の欠落を検知できていない'; end if;
  raise notice 'OK 履歴1行の欠落を入金照合と残高照合の両方が検知した';
end $$;
-- 元に戻す
insert into public.coin_transactions (user_id, amount, type, note)
  values ('d0000000-0000-0000-0000-0000000000e2'::uuid, 30000, 'purchase', 'stripe:sess_integrity_1');

\echo '=== 7. 換金申請と履歴のズレを検知すること ==='
set app.ledger_override = 'on';
update public.payouts set coins = coins + 500
  where user_id = 'd0000000-0000-0000-0000-0000000000e1'::uuid;
reset app.ledger_override;
do $$
declare v_sev text; v_gap bigint;
begin
  perform public.run_integrity_checks();
  select severity, total_gap into v_sev, v_gap from public.integrity_latest
    where check_name = 'payout_vs_ledger';
  if v_sev <> 'error' then raise exception 'FAIL 換金のズレを検知できていない'; end if;
  if v_gap <> 500 then raise exception 'FAIL ズレの大きさが合わない: %', v_gap; end if;
  raise notice 'OK 換金申請と履歴のズレを検知した(%コイン)', v_gap;
end $$;
set app.ledger_override = 'on';
update public.payouts set coins = coins - 500
  where user_id = 'd0000000-0000-0000-0000-0000000000e1'::uuid;
reset app.ledger_override;

\echo '=== 8. 失効処理が止まっていることを警告できる ==='
-- 期限切れなのに残っているロットを作る。残高・履歴の側は辻褄を合わせておき、
-- stale_expired_lots だけが鳴ることを確かめる。
insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('d0000000-0000-0000-0000-0000000000e2'::uuid, 'paid', 100, now() - interval '10 days');
update public.coin_wallets set balance = balance + 100
  where user_id = 'd0000000-0000-0000-0000-0000000000e2'::uuid;
insert into public.coin_transactions (user_id, amount, type, note)
  values ('d0000000-0000-0000-0000-0000000000e2'::uuid, 100, 'bonus', 'test:stale-lot');
do $$
declare v_err int; v_sev text; v_n int;
begin
  v_err := public.run_integrity_checks();
  select severity, affected_count into v_sev, v_n from public.integrity_latest
    where check_name = 'stale_expired_lots';
  if v_sev <> 'warn' then raise exception 'FAIL 失効漏れを警告できていない: %', v_sev; end if;
  if v_err <> 0 then raise exception 'FAIL 警告のはずがエラー扱いになっている'; end if;
  raise notice 'OK 失効漏れを警告として検知した(% 件・errorにはしない)', v_n;
end $$;

\echo '=== 9. 実際に expire_coins を動かせば警告が消えること ==='
do $$
declare v_sev text; v_err int;
begin
  perform public.expire_coins();
  v_err := public.run_integrity_checks();
  select severity into v_sev from public.integrity_latest where check_name = 'stale_expired_lots';
  if v_sev <> 'ok' then raise exception 'FAIL 失効後も警告が残っている: %', v_sev; end if;
  if v_err <> 0 then raise exception 'FAIL 失効処理が残高と履歴をズラしている(errors=%)', v_err; end if;
  raise notice 'OK 失効処理を動かすと警告が解消し、残高と履歴もズレない';
end $$;

\echo '=== 10. 管理者以外は実行できない ==='
set test.uid = 'd0000000-0000-0000-0000-0000000000e2';
do $$
begin
  perform public.run_integrity_checks();
  raise exception 'FAIL 一般ユーザーが実行できてしまった';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK 一般ユーザーの実行は NOT_ADMIN';
end $$;

\echo '=== 11. 記録が積み上がり、最新分だけがビューに出ること ==='
do $$
declare v_runs int; v_latest int;
begin
  select count(distinct ran_at) into v_runs from public.integrity_checks;
  select count(*) into v_latest from public.integrity_latest;
  if v_runs < 5 then raise exception 'FAIL 実行履歴が積まれていない: %', v_runs; end if;
  if v_latest <> 9 then raise exception 'FAIL 最新の結果が9件でない: %', v_latest; end if;
  raise notice 'OK 実行履歴%回分を保持し、ビューには最新の9チェックだけが出る', v_runs;
end $$;

\echo '=== 完了 ==='
