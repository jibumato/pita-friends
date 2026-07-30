-- ============================================================
-- 92: みまもり同意の撤回に実際の効果があること(0074)
-- ------------------------------------------------------------
-- 弁護士回答 Q16:「撤回された場合、当社はメッセージ機能その他の
-- 利用者間のやりとりに関する機能の提供を停止します。この場合も、
-- **既に成立した予約の履行および換金の手続については、本規約の定めに
-- 従います。**」
-- 弁護士回答 Q19:「メッセージは送信者と受信者の**双方の通信**であるため、
-- 有効な同意は両当事者から得られている必要がある。」
--
-- ⚠️ このテストは条文の履行を固定している。壊れた場合、直すのは
--    実装であってテストではない。止める範囲を狭めれば「監視できない通信を
--    提供している」ことになり、止める範囲を広げれば「既に成立した予約の
--    履行」を妨げて債務不履行になる。**両側から挟まれている。**
-- ============================================================
insert into auth.users (id) values
  ('f3000000-0000-0000-0000-000000000001'),  -- ゲスト(のちに撤回する)
  ('f3000000-0000-0000-0000-000000000002');  -- ピタメイト(同意を維持)
insert into public.profiles (id, nickname) values
  ('f3000000-0000-0000-0000-000000000001','ゲスト'),
  ('f3000000-0000-0000-0000-000000000002','ピタメイト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('f3000000-0000-0000-0000-000000000001',
                    'f3000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id,is_host,hourly_rate) values
  ('f3000000-0000-0000-0000-000000000002', true, 100)
  on conflict (user_id) do update set is_host=true, hourly_rate=100;
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('f3000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='f3000000-0000-0000-0000-000000000001';

-- 両者が同意した状態を作る(登録時の導線と同じRPC)
set test.uid = 'f3000000-0000-0000-0000-000000000001';
select public.record_monitoring_consent('2026-07-30');
set test.uid = 'f3000000-0000-0000-0000-000000000002';
select public.record_monitoring_consent('2026-07-30');

-- 撤回より【前】に成立した予約(履行が続くことの確認に使う)
insert into public.bookings (id, guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status, scheduled_at)
values ('f3000000-0000-0000-0000-0000000000b1',
        'f3000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000002',
        60, 100, 100, 0, 'confirmed', now() - interval '2 hours');
insert into public.promises (booking_id, user_a, user_b, scheduled_at)
values ('f3000000-0000-0000-0000-0000000000b1',
        'f3000000-0000-0000-0000-000000000001','f3000000-0000-0000-0000-000000000002',
        now() - interval '2 hours')
returning id \gset promise_

\echo '=== 1. 撤回する前はメッセージを送れる ==='
set test.uid = 'f3000000-0000-0000-0000-000000000001';
insert into public.messages (promise_id, sender_id, body)
values (:'promise_id','f3000000-0000-0000-0000-000000000001','同意している間の送信');

\echo '=== 2. 撤回すると本人はメッセージを送れなくなる ==='
select public.revoke_monitoring_consent();
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
   where booking_id = 'f3000000-0000-0000-0000-0000000000b1';
  insert into public.messages (promise_id, sender_id, body)
  values (v_pid, 'f3000000-0000-0000-0000-000000000001', 'x');
  raise exception 'FAIL: 撤回後に送信できてしまった';
exception when others then
  if sqlerrm not like '%MONITORING_CONSENT_REVOKED%' then
    raise exception 'FAIL: 撤回(MONITORING_CONSENT_REVOKED)ではない理由で落ちた: %', sqlerrm;
  end if;
  if sqlerrm like '%PARTNER_MONITORING_CONSENT_REVOKED%' then
    raise exception 'FAIL: 本人の撤回なのに相手側のエラーになっている';
  end if;
end $$;
\echo 'OK'

\echo '=== 3. 相手(撤回していない側)からも送れなくなる ==='
-- Q19: メッセージは双方の通信。片方が撤回した通信は監視できない。
set test.uid = 'f3000000-0000-0000-0000-000000000002';
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
   where booking_id = 'f3000000-0000-0000-0000-0000000000b1';
  insert into public.messages (promise_id, sender_id, body)
  values (v_pid, 'f3000000-0000-0000-0000-000000000002', 'x');
  raise exception 'FAIL: 相手が撤回しているのに送信できてしまった';
exception when others then
  if sqlerrm not like '%PARTNER_MONITORING_CONSENT_REVOKED%' then
    raise exception 'FAIL: 相手側の撤回として検出されていない: %', sqlerrm;
  end if;
end $$;
\echo 'OK'

\echo '=== 4. 新しい予約は成立しない ==='
set test.uid = 'f3000000-0000-0000-0000-000000000001';
do $$
begin
  perform public.create_booking('f3000000-0000-0000-0000-000000000002'::uuid, 60);
  raise exception 'FAIL: 撤回後に予約が成立してしまった';
exception when others then
  if sqlerrm not like '%MONITORING_CONSENT_REVOKED%' then
    raise exception 'FAIL: 撤回ではない理由で落ちた: %', sqlerrm;
  end if;
end $$;
\echo 'OK'

\echo '=== 5. 募集の投稿もできない ==='
do $$
begin
  insert into public.board_posts (creator_id, game, when_text)
  values ('f3000000-0000-0000-0000-000000000001','テスト','いま');
  raise exception 'FAIL: 撤回後に募集を投稿できてしまった';
exception when others then
  if sqlerrm not like '%MONITORING_CONSENT_REVOKED%' then
    raise exception 'FAIL: 撤回ではない理由で落ちた: %', sqlerrm;
  end if;
end $$;
\echo 'OK'

\echo '=== 6. 誘いも送れない ==='
do $$
begin
  insert into public.invites (from_user, to_user, game, when_text)
  values ('f3000000-0000-0000-0000-000000000001',
          'f3000000-0000-0000-0000-000000000002','テスト','いま');
  raise exception 'FAIL: 撤回後に誘いを送れてしまった';
exception when others then
  if sqlerrm not like '%MONITORING_CONSENT_REVOKED%' then
    raise exception 'FAIL: 撤回ではない理由で落ちた: %', sqlerrm;
  end if;
end $$;
\echo 'OK'

\echo '=== 7. 【既に成立した予約の履行】は止まらない(規約の但し書き) ==='
-- チェックイン → 完了 → レビュー。撤回してもここは通らなければならない。
do $$
declare v_st text;
begin
  perform public.check_in_booking('f3000000-0000-0000-0000-0000000000b1'::uuid);
  perform public.complete_booking('f3000000-0000-0000-0000-0000000000b1'::uuid);
  select status into v_st from public.bookings
   where id = 'f3000000-0000-0000-0000-0000000000b1';
  if v_st <> 'completed' then
    raise exception 'FAIL: 撤回後に既存予約を完了できない(status=%)', v_st;
  end if;
end $$;
\echo 'OK'

\echo '=== 8. 【換金の手続】も止まらない(規約の但し書き) ==='
-- ピタメイト側で口座を登録して換金申請ができること。
-- (撤回したのはゲスト側だが、換金は通信ではないので誰の撤回でも止めない)
set test.uid = 'f3000000-0000-0000-0000-000000000002';
select public.record_monitoring_consent('2026-07-30');  -- 念のため有効な状態に
select public.revoke_monitoring_consent();               -- ピタメイト側も撤回してみる
do $$
begin
  update public.coin_wallets set earned_balance = 10000
    where user_id = 'f3000000-0000-0000-0000-000000000002';
  insert into public.host_bank_accounts
    (user_id, bank_name, bank_code, branch_name, branch_code,
     account_type, account_number, account_holder_kana)
  values ('f3000000-0000-0000-0000-000000000002',
          'テスト銀行','0001','テスト支店','001','普通','1234567','ピタマテ')
  on conflict (user_id) do nothing;
  perform public.request_bank_payout(5000);
exception when others then
  raise exception 'FAIL: 撤回後に換金申請ができない: %', sqlerrm;
end $$;
\echo 'OK'

\echo '=== 9. 再同意すると元に戻る ==='
set test.uid = 'f3000000-0000-0000-0000-000000000001';
select public.record_monitoring_consent('2026-07-30');
set test.uid = 'f3000000-0000-0000-0000-000000000002';
select public.record_monitoring_consent('2026-07-30');
set test.uid = 'f3000000-0000-0000-0000-000000000001';
insert into public.messages (promise_id, sender_id, body)
values (:'promise_id','f3000000-0000-0000-0000-000000000001','再同意したので送れる');
\echo 'OK'

\echo '=== 10. 同意の記録が1件も無い利用者は締め出さない ==='
-- 0031より前の登録者・記録の失敗を握りつぶした場合。行が無いことを
-- 「未同意」と扱うと、当社側の事情で送信できなくなる(0074冒頭の注記)。
insert into auth.users (id) values ('f3000000-0000-0000-0000-000000000003');
insert into public.profiles (id, nickname) values
  ('f3000000-0000-0000-0000-000000000003','記録なし')
  on conflict (id) do nothing;
do $$
begin
  if public._monitoring_consent_revoked('f3000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL: 記録が無い利用者が撤回扱いになっている';
  end if;
end $$;
insert into public.board_posts (creator_id, game, when_text)
values ('f3000000-0000-0000-0000-000000000003','テスト','いま');
\echo 'OK'

\echo '=== 11. my_monitoring_consent の表示内容 ==='
do $$
declare v jsonb;
begin
  -- 有効な状態
  perform set_config('test.uid','f3000000-0000-0000-0000-000000000001', true);
  v := public.my_monitoring_consent();
  if (v->>'active') <> 'true' then
    raise exception 'FAIL: 同意中なのに active=false: %', v;
  end if;
  if (v->>'version') <> '2026-07-30' then
    raise exception 'FAIL: バージョンが返らない: %', v;
  end if;
  if (v->>'unrecorded') <> 'false' then
    raise exception 'FAIL: 記録があるのに unrecorded=true: %', v;
  end if;

  -- 撤回した状態
  perform public.revoke_monitoring_consent();
  v := public.my_monitoring_consent();
  if (v->>'active') <> 'false' then
    raise exception 'FAIL: 撤回したのに active=true: %', v;
  end if;
  if (v->>'revokedAt') is null then
    raise exception 'FAIL: 撤回日時が返らない: %', v;
  end if;

  -- 記録が無い利用者
  perform set_config('test.uid','f3000000-0000-0000-0000-000000000003', true);
  v := public.my_monitoring_consent();
  if (v->>'unrecorded') <> 'true' then
    raise exception 'FAIL: 記録が無いのに unrecorded=false: %', v;
  end if;
  if (v->>'active') <> 'true' then
    raise exception 'FAIL: 記録が無い利用者を停止扱いにしている: %', v;
  end if;
end $$;
\echo 'OK'

\echo '=== 92 PASS ==='
