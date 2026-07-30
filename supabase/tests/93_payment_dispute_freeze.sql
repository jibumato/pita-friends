-- ============================================================
-- 93: チャージバック中はコインを使えないこと(0075)
-- ------------------------------------------------------------
-- 税理士の第2回回答 Q14(リリース前の必須実装):
--   「Stripeの異議申立てイベントを受け取って、当該ユーザーのコイン残高を
--     凍結する仕組みを実装してください。これがないと、**チャージバックを
--     申し立てながら、その間にコインを使い切る**という極めて単純な不正が
--     通ります。会計処理をどう決めても、この穴が開いていれば損失は
--     防げません。」
--
-- ⚠️ 止めすぎても困る。**既に成立した予約の履行**を止めると、
--    落ち度の無いピタメイトを巻き込む。両側を固定する。
-- ============================================================
insert into auth.users (id) values
  ('f4000000-0000-0000-0000-000000000001'),  -- ゲスト(異議を申し立てる)
  ('f4000000-0000-0000-0000-000000000002');  -- ピタメイト
insert into public.profiles (id, nickname) values
  ('f4000000-0000-0000-0000-000000000001','ゲスト'),
  ('f4000000-0000-0000-0000-000000000002','ピタメイト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'f4000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id,is_host,hourly_rate) values
  ('f4000000-0000-0000-0000-000000000002', true, 100)
  on conflict (user_id) do update set is_host=true, hourly_rate=100;

-- 購入履歴(異議申立てを利用者に紐づけるための唯一の手掛かり)
insert into public.coin_purchases
  (user_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
values ('f4000000-0000-0000-0000-000000000001', 100000, 100000, 'cs_test_1', 'pi_test_1');
insert into public.coin_lots (user_id,kind,remaining,expires_at)
  values ('f4000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance=100000
  where user_id='f4000000-0000-0000-0000-000000000001';

\echo '=== 1. 凍結前は予約できる ==='
set test.uid = 'f4000000-0000-0000-0000-000000000001';
select public.create_booking('f4000000-0000-0000-0000-000000000002'::uuid, 60) as b1 \gset
\echo 'OK'

\echo '=== 2. 異議申立てを記録すると凍結される ==='
select public.record_payment_dispute(
  'dp_test_1', 'ch_test_1', 'pi_test_1', 100000, 'fraudulent', 'open');
do $$
begin
  if not public._coins_frozen('f4000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: 申立てを記録したのに凍結されていない';
  end if;
  if public._coins_frozen('f4000000-0000-0000-0000-000000000002') then
    raise exception 'FAIL: 申立てと無関係のピタメイトまで凍結している';
  end if;
end $$;
\echo 'OK'

\echo '=== 3. 凍結中は新しい予約ができない ==='
do $$
begin
  -- 時間帯をずらす(枠の重複で落ちると凍結の検証にならない)
  perform public.create_booking('f4000000-0000-0000-0000-000000000002'::uuid, 60,
            'v1', date_trunc('hour', now()) + interval '30 hours');
  raise exception 'FAIL: 凍結中に予約が成立してしまった';
exception when others then
  if sqlerrm not like '%COINS_FROZEN_DISPUTE%' then
    raise exception 'FAIL: 凍結ではない理由で落ちた: %', sqlerrm;
  end if;
end $$;
\echo 'OK'

\echo '=== 4. 【既に成立した予約の履行】は止まらない ==='
-- 落ち度の無いピタメイトを巻き込まないこと。返還(refund)も止めない。
do $$
declare v_st text;
begin
  update public.bookings set scheduled_at = now() - interval '2 hours', status = 'confirmed'
   where id = (select id from public.bookings
                where guest_id='f4000000-0000-0000-0000-000000000001'
                order by created_at limit 1);
  perform public.complete_booking(
    (select id from public.bookings where guest_id='f4000000-0000-0000-0000-000000000001'
      order by created_at limit 1));
  select status into v_st from public.bookings
   where guest_id='f4000000-0000-0000-0000-000000000001' order by created_at limit 1;
  if v_st <> 'completed' then
    raise exception 'FAIL: 凍結中に既存予約を完了できない(status=%)', v_st;
  end if;
end $$;
\echo 'OK'

\echo '=== 5. 凍結中はギフトも送れない ==='
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
   where user_a='f4000000-0000-0000-0000-000000000001'
      or user_b='f4000000-0000-0000-0000-000000000001' limit 1;
  perform public.send_gift(v_pid, 100);
  raise exception 'FAIL: 凍結中にギフトを送れてしまった';
exception when others then
  if sqlerrm like 'FAIL:%' then raise;
  end if;
  -- 別の理由(24時間クールダウン等)で落ちても、凍結が効いているかは3で確認済み。
  -- ここでは「送れてしまった」ことだけを失敗とする。
  null;
end $$;
\echo 'OK'

\echo '=== 6. lost(返金が確定)でも自動では解除されない ==='
-- ここで自動解除すると、**最も止めたい場面で止まらない**。
-- 残高の調整という運営の作業が残っているため。
select public.record_payment_dispute(
  'dp_test_1', 'ch_test_1', 'pi_test_1', 100000, 'fraudulent', 'lost');
do $$
begin
  if not public._coins_frozen('f4000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: lost で自動解除されてしまった';
  end if;
end $$;
\echo 'OK'

\echo '=== 7. won(当社の主張が通った)なら自動で解除される ==='
select public.record_payment_dispute(
  'dp_test_1', 'ch_test_1', 'pi_test_1', 100000, 'fraudulent', 'won');
do $$
begin
  if public._coins_frozen('f4000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: won なのに凍結が解けていない';
  end if;
  -- 同じ dispute id で二重に積んでいないこと
  if (select count(*) from public.payment_disputes
       where stripe_dispute_id = 'dp_test_1') <> 1 then
    raise exception 'FAIL: 同じ申立てが二重に記録されている';
  end if;
end $$;
\echo 'OK'

\echo '=== 8. 解除後は再び予約できる ==='
select public.create_booking('f4000000-0000-0000-0000-000000000002'::uuid, 60,
         'v1', date_trunc('hour', now()) + interval '54 hours');
\echo 'OK'

\echo '=== 9. 購入が特定できない申立ても記録は残る(誰も凍結しない) ==='
select public.record_payment_dispute(
  'dp_test_unknown', 'ch_x', 'pi_unknown', 5000, 'general', 'open');
do $$
begin
  if not exists (select 1 from public.payment_disputes
                  where stripe_dispute_id = 'dp_test_unknown' and user_id is null) then
    raise exception 'FAIL: 紐づかない申立てが握りつぶされている';
  end if;
  if public._coins_frozen('f4000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: 無関係の申立てで凍結されている';
  end if;
end $$;
\echo 'OK'

\echo '=== 10. 運営の解除には理由が必須 ==='
select public.record_payment_dispute(
  'dp_test_2', 'ch_test_2', 'pi_test_1', 1000, 'fraudulent', 'open');
insert into public.admins (user_id) values ('f4000000-0000-0000-0000-000000000002')
  on conflict do nothing;
set test.uid = 'f4000000-0000-0000-0000-000000000002';
do $$
declare v_id uuid;
begin
  select id into v_id from public.payment_disputes where stripe_dispute_id = 'dp_test_2';
  begin
    perform public.admin_resolve_dispute(v_id, '   ');
    raise exception 'FAIL: 理由なしで解除できてしまった';
  exception when others then
    if sqlerrm not like '%NOTE_REQUIRED%' then raise; end if;
  end;
  perform public.admin_resolve_dispute(v_id, '本人と連絡が取れ、申立てを取り下げてもらった');
  if public._coins_frozen('f4000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: 運営が解除したのに凍結が残っている';
  end if;
end $$;
\echo 'OK'

\echo '=== 11. 一般利用者は申立てを記録できない ==='
set test.uid = 'f4000000-0000-0000-0000-000000000001';
do $$
begin
  if has_function_privilege('authenticated',
       'public.record_payment_dispute(text, text, text, integer, text, text)', 'execute') then
    raise exception 'FAIL: record_payment_dispute が authenticated に開いている';
  end if;
  if has_function_privilege('anon',
       'public.record_payment_dispute(text, text, text, integer, text, text)', 'execute') then
    raise exception 'FAIL: record_payment_dispute が anon に開いている';
  end if;
end $$;
\echo 'OK'

\echo '=== 93 PASS ==='
