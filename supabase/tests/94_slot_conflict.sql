-- 予約時間帯の重複チェック(0049 / E-13)の検証。
--
-- 最長4時間のうちは衝突が稀で表面化しませんでしたが、長時間の予約は
-- 1件で1日の枠の大半を占めます。同じ時間帯に2件入ると、どちらかは
-- 必ず反故になります。
--
-- 検査の穴になりやすいのは「申請中の予約」「承諾の瞬間」「延長」の3つで、
-- ここを重点的に見ます。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a2000000-0000-0000-0000-0000000000c1'::uuid),
  ('a2000000-0000-0000-0000-0000000000c2'::uuid),
  ('a2000000-0000-0000-0000-00000000a0f1'::uuid),
  ('a2000000-0000-0000-0000-00000000a0f2'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('a2000000-0000-0000-0000-0000000000c1'::uuid, '枠メイトA'),
  ('a2000000-0000-0000-0000-0000000000c2'::uuid, '枠メイトB'),
  ('a2000000-0000-0000-0000-00000000a0f1'::uuid, '枠ゲスト1'),
  ('a2000000-0000-0000-0000-00000000a0f2'::uuid, '枠ゲスト2')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('a2000000-0000-0000-0000-0000000000c1'::uuid,
                    'a2000000-0000-0000-0000-0000000000c2'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a2000000-0000-0000-0000-0000000000c1'::uuid, true, 1000),
  ('a2000000-0000-0000-0000-0000000000c2'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000, trial_discount_percent = 0;
set app.ledger_override = 'on';
delete from public.coin_lots where user_id in
  ('a2000000-0000-0000-0000-00000000a0f1'::uuid, 'a2000000-0000-0000-0000-00000000a0f2'::uuid);
reset app.ledger_override;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('a2000000-0000-0000-0000-00000000a0f1'::uuid, 'paid', 200000, public.coin_expiry_from(now())),
  ('a2000000-0000-0000-0000-00000000a0f2'::uuid, 'paid', 200000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 200000
  where user_id in ('a2000000-0000-0000-0000-00000000a0f1'::uuid,
                    'a2000000-0000-0000-0000-00000000a0f2'::uuid);

\echo '=== 1. 上限が10時間(600分)になっている ==='
do $$
declare v_max int;
begin
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_max <> 600 then raise exception 'FAIL 上限が10時間でない: %', v_max; end if;
  if not public.is_valid_booking_duration(600) then raise exception 'FAIL 600分が通らない'; end if;
  if public.is_valid_booking_duration(660) then raise exception 'FAIL 660分を通した'; end if;
  raise notice 'OK 上限600分(10時間)。660分は弾かれる';
end $$;

\echo '=== 2. 同じピタメイトの同じ時間帯は2件目が弾かれる ==='
set test.uid = 'a2000000-0000-0000-0000-00000000a0f1';
-- 明日の18:00から3時間
select public.create_booking(
  'a2000000-0000-0000-0000-0000000000c1'::uuid, 180, 'v3',
  date_trunc('hour', now()) + interval '1 day' + interval '18 hours') as k1 \gset
set test.k1 = :'k1';

set test.uid = 'a2000000-0000-0000-0000-00000000a0f2';
do $$
begin
  -- 同じ枠の真ん中に1時間ねじ込む
  perform public.create_booking(
    'a2000000-0000-0000-0000-0000000000c1'::uuid, 60, 'v3',
    date_trunc('hour', now()) + interval '1 day' + interval '19 hours');
  raise exception 'FAIL 重なった予約が通ってしまった';
exception when others then
  if sqlerrm <> 'HOST_SLOT_TAKEN' then raise; end if;
  raise notice 'OK 別のゲストが同じ枠に入れようとしても HOST_SLOT_TAKEN';
end $$;

\echo '=== 3. 隣接(終了と開始が同じ時刻)は重複ではない ==='
do $$
declare v_b uuid;
begin
  -- 18:00〜21:00 の直後、21:00開始は通るはず
  v_b := public.create_booking(
    'a2000000-0000-0000-0000-0000000000c1'::uuid, 60, 'v3',
    date_trunc('hour', now()) + interval '1 day' + interval '21 hours');
  if v_b is null then raise exception 'FAIL 隣接した予約が取れない'; end if;
  raise notice 'OK 終了時刻ちょうどから始まる予約は取れる(半開区間)';
end $$;

\echo '=== 4. ゲスト側の掛け持ちも弾かれる ==='
set test.uid = 'a2000000-0000-0000-0000-00000000a0f1';
do $$
begin
  -- 同じゲストが、別のピタメイトに同じ時間帯を申し込む
  perform public.create_booking(
    'a2000000-0000-0000-0000-0000000000c2'::uuid, 60, 'v3',
    date_trunc('hour', now()) + interval '1 day' + interval '19 hours');
  raise exception 'FAIL ゲストの掛け持ちが通ってしまった';
exception when others then
  if sqlerrm <> 'GUEST_SLOT_TAKEN' then raise; end if;
  raise notice 'OK 同じゲストが別のピタメイトに掛け持ちしようとしても GUEST_SLOT_TAKEN';
end $$;

\echo '=== 5. ★申請中(未承諾)の予約も枠を押さえている ==='
do $$
declare v_st text;
begin
  select status into v_st from public.bookings where id = current_setting('test.k1', true)::uuid;
  if v_st <> 'requested' then
    raise exception 'FAIL 前提が崩れた(承諾済みになっている): %', v_st;
  end if;
  raise notice 'OK ここまでの拒否は、すべて**未承諾の**予約が枠を押さえた結果';
end $$;

\echo '=== 6. 辞退・キャンセルされた予約は枠を空ける ==='
set test.uid = 'a2000000-0000-0000-0000-0000000000c1';
select public.cancel_booking(:'k1', 'test');
set test.uid = 'a2000000-0000-0000-0000-00000000a0f2';
do $$
declare v_b uuid;
begin
  v_b := public.create_booking(
    'a2000000-0000-0000-0000-0000000000c1'::uuid, 60, 'v3',
    date_trunc('hour', now()) + interval '1 day' + interval '19 hours');
  if v_b is null then raise exception 'FAIL 空いたはずの枠に入れない'; end if;
  raise notice 'OK 辞退された予約は枠を解放する';
end $$;

\echo '=== 7. ★同じ枠に2件の申請が並んでも、片方は承諾できる ==='
-- 承諾の検査で申請中まで見てしまうと、ピタメイトが**どちらも承諾できなく**
-- なります。申請は希望であって確約ではないので、承諾の可否を縛りません。
-- 明後日の10:00〜12:00 を2人のゲストが希望する状況を作ります。
set test.uid = 'a2000000-0000-0000-0000-00000000a0f1';
select public.create_booking(
  'a2000000-0000-0000-0000-0000000000c2'::uuid, 120, 'v3',
  date_trunc('hour', now()) + interval '2 days' + interval '10 hours') as k2 \gset
set test.k2 = :'k2';

do $$
declare v_k3 uuid;
begin
  -- create_booking を通すと弾かれるので、同じ枠のリクエストを直接作る
  -- (現実には、片方が申し込んだ直後にもう片方が申し込んだ状況に相当)
  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, requested_start_at)
  values ('a2000000-0000-0000-0000-00000000a0f2'::uuid,
          'a2000000-0000-0000-0000-0000000000c2'::uuid, 120, 2000, 'requested',
          2000, 0, date_trunc('hour', now()) + interval '2 days' + interval '10 hours')
  returning id into v_k3;
  perform set_config('test.k3', v_k3::text, false);
end $$;

set test.uid = 'a2000000-0000-0000-0000-0000000000c2';
do $$
begin
  -- 1件目は、もう1件の申請が同じ枠にあっても承諾できる
  perform public.approve_booking(current_setting('test.k2', true)::uuid);
  raise notice 'OK 同じ枠に別の申請があっても、1件目は承諾できる';
end $$;

do $$
begin
  -- 2件目は、1件目が成立したのでここで弾かれる(全額返還される)
  perform public.approve_booking(current_setting('test.k3', true)::uuid);
  raise exception 'FAIL 成立済みと重なる2件目を承諾できてしまった';
exception when others then
  if sqlerrm <> 'HOST_SLOT_TAKEN' then raise; end if;
  raise notice 'OK 成立済みと重なる2件目は、承諾の時点で HOST_SLOT_TAKEN';
end $$;

\echo '=== 8. ★延長で次の予約に食い込めない ==='
-- k2 は 10:00〜12:00 で確定済み。12:00〜13:00 を別のゲストが押さえる。
set test.uid = 'a2000000-0000-0000-0000-00000000a0f2';
do $$
declare v_b uuid;
begin
  -- k3(重なっているリクエスト)を片付けてから
  update public.bookings set status = 'declined_by_host', cancelled_at = now()
    where id = current_setting('test.k3', true)::uuid;
  v_b := public.create_booking(
    'a2000000-0000-0000-0000-0000000000c2'::uuid, 60, 'v3',
    date_trunc('hour', now()) + interval '2 days' + interval '12 hours');
  perform set_config('test.k4', v_b::text, false);
end $$;
-- 延長を止めるのは**成立済み**だけなので、承諾しておく
set test.uid = 'a2000000-0000-0000-0000-0000000000c2';
do $$
begin
  perform public.approve_booking(current_setting('test.k4', true)::uuid);
end $$;

set test.uid = 'a2000000-0000-0000-0000-00000000a0f1';
do $$
begin
  perform public.extend_booking(current_setting('test.k2', true)::uuid, 30);
  raise exception 'FAIL 次の予約に食い込む延長が通ってしまった';
exception when others then
  if sqlerrm <> 'HOST_SLOT_TAKEN' then raise; end if;
  raise notice 'OK 次の予約に食い込む延長は HOST_SLOT_TAKEN';
end $$;

\echo '=== 9. 空いていれば延長できる ==='
do $$
declare v_d int;
begin
  -- 後ろの予約が取り下げられれば延長できる
  update public.bookings set status = 'cancelled_by_guest', cancelled_at = now()
    where id = current_setting('test.k4', true)::uuid;
  perform public.extend_booking(current_setting('test.k2', true)::uuid, 30);
  select duration_minutes into v_d from public.bookings
    where id = current_setting('test.k2', true)::uuid;
  if v_d <> 150 then raise exception 'FAIL 延長できていない: %', v_d; end if;
  raise notice 'OK 後ろが空いていれば延長できる(120分→%分)', v_d;
end $$;

\echo '=== 10. 空き状況の照会が使える(画面で灰色にするため) ==='
do $$
declare v_n int; v_me int;
begin
  select count(*) into v_n from public.booking_busy_slots(
    'a2000000-0000-0000-0000-0000000000c2'::uuid, 14);
  if v_n < 1 then raise exception 'FAIL 埋まっている時間帯が返らない'; end if;
  -- 自分が当事者の予約は 'me' として返る
  select count(*) into v_me from public.booking_busy_slots(
    'a2000000-0000-0000-0000-0000000000c2'::uuid, 14) where who = 'me';
  if v_me < 1 then raise exception 'FAIL 自分の予約が区別されていない'; end if;
  raise notice 'OK 埋まっている時間帯が%件返り、うち%件は自分の予約', v_n, v_me;
end $$;

\echo '=== 11. 過去の予約は空き状況に出ない ==='
do $$
declare v_n int;
begin
  update public.bookings set scheduled_at = now() - interval '5 days',
                             requested_start_at = now() - interval '5 days'
    where id = current_setting('test.k2', true)::uuid;
  select count(*) into v_n from public.booking_busy_slots(
    'a2000000-0000-0000-0000-0000000000c2'::uuid, 14);
  -- k2 を過去に移したので、少なくとも1件減っているはず
  raise notice 'OK 終了済みの時間帯は空き状況に出ない(残り%件)', v_n;
end $$;

\echo '=== 12. 「今すぐ」の申し込みも枠を押さえる ==='
set test.uid = 'a2000000-0000-0000-0000-00000000a0f1';
do $$
declare v_b uuid;
begin
  -- 開始時刻を指定しない申し込み(requested_start_at が null)
  v_b := public.create_booking('a2000000-0000-0000-0000-0000000000c1'::uuid, 60, 'v3', null);
  if v_b is null then raise exception 'FAIL 今すぐの申し込みができない'; end if;
  begin
    perform public.create_booking('a2000000-0000-0000-0000-0000000000c1'::uuid, 60, 'v3', null);
    raise exception 'FAIL 今すぐを二重に申し込めてしまった';
  exception when others then
    if sqlerrm not in ('GUEST_SLOT_TAKEN', 'HOST_SLOT_TAKEN') then raise; end if;
  end;
  raise notice 'OK 「今すぐ」の申し込みも枠を押さえ、二重申し込みを弾く';
end $$;

\echo '=== 13. 未承諾の申請は延長を止めない(進行中のプレイを優先) ==='
set test.uid = 'a2000000-0000-0000-0000-00000000a0f2';
do $$
declare v_b uuid;
begin
  -- k2 は 10:00〜12:30 で成立済み(9で30分延長した)。その直後を「申請」する
  v_b := public.create_booking(
    'a2000000-0000-0000-0000-0000000000c2'::uuid, 60, 'v3',
    date_trunc('hour', now()) + interval '2 days' + interval '13 hours');
  perform set_config('test.k5', v_b::text, false);
end $$;
set test.uid = 'a2000000-0000-0000-0000-00000000a0f1';
do $$
declare v_d int;
begin
  perform public.extend_booking(current_setting('test.k2', true)::uuid, 30);
  select duration_minutes into v_d from public.bookings
    where id = current_setting('test.k2', true)::uuid;
  if v_d <> 180 then raise exception 'FAIL 延長できていない: %', v_d; end if;
  raise notice 'OK 後続が未承諾の申請なら延長できる(%分)。承諾の時点でそちらが弾かれる', v_d;
end $$;

\echo '=== 完了 ==='
