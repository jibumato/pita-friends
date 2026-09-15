-- ============================================================
-- 42: 料率の制度に穴が無いか（0122）
--
-- ■ このファイルの主眼
--   **例外は出ないのに、黙ってホストに有利／不利に働く**ものを見る。
--   41 が「操作の順序」だったのに対し、こちらは「お金の数え方」。
--
--   0122 より前は、次の2つが通っていた（実測で確認したうえで塞いだ）:
--     ・全額返金された予約（受取 0）が、月間GMVに満額計上される
--     ・全額返金された予約でも「リピート」が成立する
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('42000000-0000-0000-0000-000000000001'),  -- ピタメイト
  ('42000000-0000-0000-0000-000000000009'),  -- ゲストA
  ('42000000-0000-0000-0000-000000000008')   -- ゲストB
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('42000000-0000-0000-0000-000000000001','ホスト'),
  ('42000000-0000-0000-0000-000000000009','ゲストA'),
  ('42000000-0000-0000-0000-000000000008','ゲストB')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id in ('42000000-0000-0000-0000-000000000001',
                    '42000000-0000-0000-0000-000000000009',
                    '42000000-0000-0000-0000-000000000008');

insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('42000000-0000-0000-0000-000000000001', true, 1000)
on conflict (user_id) do update
  set is_host = true, hourly_rate = 1000, trial_discount_percent = 0;

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('42000000-0000-0000-0000-000000000009','paid', 900000, public.coin_expiry_from(now())),
  ('42000000-0000-0000-0000-000000000008','paid', 900000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 900000
  where user_id in ('42000000-0000-0000-0000-000000000009',
                    '42000000-0000-0000-0000-000000000008');

-- 運営操作（保留の解除）を使うので、ゲストAを運営にしておく
insert into public.admins (user_id) values ('42000000-0000-0000-0000-000000000009')
  on conflict do nothing;

\echo '=== ★1. 全額返金された予約は、月間GMVに入らない ==='
do $$
declare v_b uuid; v_gmv_before int; v_gmv_after int; v_earned int; v_fee int;
begin
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000009', false);
  v_gmv_before := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());

  -- 10時間（10,000コイン）の予約を作り、保留してから全額返金で終わらせる
  v_b := public.create_booking('42000000-0000-0000-0000-000000000001', 600, 'v1',
                               now() + interval '3 days');
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b);
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000009', false);
  perform public.hold_booking(v_b, 'manual');
  perform public.release_hold_and_refund(v_b, 100);

  -- 状態は completed だが、ホストは1円も受け取っていない
  if (select status from public.bookings where id = v_b) <> 'completed' then
    raise exception 'NG: 前提が崩れた（completed になっていない）';
  end if;
  select coalesce(sum(amount),0) into v_earned from public.coin_transactions
    where related_booking_id = v_b and type = 'booking_earned';
  if v_earned <> 0 then raise exception 'NG: 全額返金なのに % 付与されている', v_earned; end if;

  v_gmv_after := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());

  -- ★本題。0122 より前はここで 10,000 増えていた
  if v_gmv_after <> v_gmv_before then
    raise exception 'NG: 受取 0 の予約で GMV が % → % に増えた（段が不当に上がる）',
      v_gmv_before, v_gmv_after;
  end if;
  perform set_config('test.repaid_booking', v_b::text, false);
  raise notice 'ok 全額返金された予約は GMV に入らない';
end $$;

\echo '=== ★2. 全額返金された予約では「リピート」が成立しない ==='
do $$
declare v_b uuid; v_repeat boolean; v_rate numeric;
begin
  -- 上の全額返金(ゲストA)のあと、同じゲストAで普通の予約を完了させる
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000009', false);
  v_b := public.create_booking('42000000-0000-0000-0000-000000000001', 60, 'v1',
                               now() + interval '5 days');
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b);
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000009', false);
  perform public.complete_booking(v_b);

  select repeat_discounted, applied_rate into v_repeat, v_rate
    from public.platform_fees where booking_id = v_b;

  -- ★本題。0122 より前は t（3pt引きで 17%）になっていた
  if v_repeat then
    raise exception 'NG: 受取 0 の予約でリピートが成立した（適用率 %）', v_rate;
  end if;
  if v_rate <> 0.2000 then
    raise exception 'NG: 新規なのに 20%% ではない（%）', v_rate;
  end if;
  raise notice 'ok 受取 0 の予約ではリピートにならない（20%% のまま）';
end $$;

\echo '=== 3. 報酬が実際に出た予約のあとは、ちゃんとリピートになる ==='
do $$
declare v_b uuid; v_repeat boolean; v_rate numeric;
begin
  -- 2 で 1件完了しているので、同じゲストAの次はリピート
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000009', false);
  v_b := public.create_booking('42000000-0000-0000-0000-000000000001', 60, 'v1',
                               now() + interval '6 days');
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b);
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000009', false);
  perform public.complete_booking(v_b);

  select repeat_discounted, applied_rate into v_repeat, v_rate
    from public.platform_fees where booking_id = v_b;
  if not v_repeat then raise exception 'NG: リピートにならなかった'; end if;
  if v_rate <> 0.1700 then raise exception 'NG: 3pt引きになっていない（%）', v_rate; end if;
  raise notice 'ok 報酬が出た予約のあとは 3pt 引き（17%%）';
end $$;

\echo '=== 4. GMV は「実際に発生した報酬」の合計になっている ==='
do $$
declare v_gmv int; v_sum int;
begin
  v_gmv := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());
  select coalesce(sum(t.amount), 0)::int into v_sum
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  where t.user_id = '42000000-0000-0000-0000-000000000001'
    and t.type = 'booking_earned'
    and date_trunc('month', (b.scheduled_at at time zone 'Asia/Tokyo'))
        = date_trunc('month', (now() at time zone 'Asia/Tokyo'));
  if v_gmv <> v_sum then
    raise exception 'NG: GMV(%) と報酬の合計(%) が食い違う', v_gmv, v_sum;
  end if;
  -- 2 と 3 で 1,000 ずつ、計 2,000 のはず（全額返金の分は入らない）
  if v_gmv <> 2000 then
    raise exception 'NG: GMV が想定と違う（% / 期待 2000）', v_gmv;
  end if;
  raise notice 'ok GMV = 実際に発生した報酬の合計（%）', v_gmv;
end $$;

\echo '=== ★5. 遊んだあとのキャンセルで発生した報酬も GMV に数える ==='
do $$
declare v_b uuid; v_gmv_before int; v_gmv_after int; v_earned int;
begin
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000008', false);
  v_gmv_before := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());

  -- 開始が過ぎてからゲストがキャンセルすると、遊んだ分がホストに渡る(0102)。
  -- create_booking はリードタイムを要求するので、行を直接ずらして再現する
  v_b := public.create_booking('42000000-0000-0000-0000-000000000001', 120, 'v1',
                               now() + interval '7 days');
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b);
  -- ⚠️ **confirmed_at もずらすこと。** 承諾から cancel_grace_minutes(5分)は
  --    全額返金になる(0040)ので、ずらさないと v_to_host が 0 になり、
  --    このテストが「報酬が出なかった」で skip して**何も検証しない**
  update public.bookings
     set scheduled_at = now() - interval '30 minutes',
         requested_start_at = now() - interval '30 minutes',
         confirmed_at = now() - interval '2 hours'
   where id = v_b;

  -- ⚠️ **両方チェックインさせること。** ここを飛ばすと「誰も現れなかった」=
  --    無断欠席の没収になる(0102 の v_played が false)。没収は遊んでいないので
  --    0122 では GMV に数えない側であり、このテストの題材ではない
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000008', false);
  perform public.check_in_booking(v_b);
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.check_in_booking(v_b);

  perform set_config('test.uid', '42000000-0000-0000-0000-000000000008', false);
  perform public.cancel_booking(v_b);

  select coalesce(sum(amount),0) into v_earned from public.coin_transactions
    where related_booking_id = v_b and type = 'booking_earned';
  -- **skip しない。** ここまで条件を整えて 0 なら前提が壊れている
  if v_earned <= 0 then
    raise exception 'NG: 遊んだあとのキャンセルなのに報酬が 0（前提が崩れている）';
  end if;

  -- 状態は cancelled_* だが、報酬は発生している
  if (select status from public.bookings where id = v_b) = 'completed' then
    raise exception 'NG: 前提が崩れた（completed になっている）';
  end if;

  v_gmv_after := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());

  -- ★本題。0122 より前は status='completed' で絞っていたので**数えられていなかった**
  if v_gmv_after <> v_gmv_before + v_earned then
    raise exception 'NG: 発生した報酬 % が GMV に入っていない（% → %）',
      v_earned, v_gmv_before, v_gmv_after;
  end if;
  raise notice 'ok 遊んだあとのキャンセルで出た報酬（%）も GMV に入る', v_earned;
end $$;

\echo '=== ★6. 無断欠席の没収は GMV にもリピートにも数えない ==='
-- この区別は 26_played_then_cancelled.sql が 0122 の最初の設計を落として教えてくれた。
-- 没収(0102 の v_played=false)は「遊んでいないのに渡る分」=機会損失の補償であって
-- 役務の対価ではない。だから platform_fees の明細が作られず、
--   ・段(GMV)を上げない
--   ・「前回遊んだ相手」にもならない
-- という扱いになる。**booking_earned の合計で数えると、ここが壊れる。**
insert into auth.users (id) values ('42000000-0000-0000-0000-000000000007')
  on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('42000000-0000-0000-0000-000000000007','ゲストC')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '42000000-0000-0000-0000-000000000007';
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('42000000-0000-0000-0000-000000000007','paid', 900000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 900000
  where user_id = '42000000-0000-0000-0000-000000000007';

do $$
declare v_b uuid; v_b2 uuid; v_gmv_before int; v_gmv_after int;
        v_earned int; v_rate numeric; v_repeat boolean;
begin
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000007', false);
  v_gmv_before := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());

  v_b := public.create_booking('42000000-0000-0000-0000-000000000001', 60, 'v1',
                               now() + interval '8 days');
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b);
  -- 開始を過ぎさせる。**チェックインはしない**(＝誰も現れなかった)
  update public.bookings
     set scheduled_at = now() - interval '10 minutes',
         requested_start_at = now() - interval '10 minutes',
         confirmed_at = now() - interval '2 hours'
   where id = v_b;
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000007', false);
  perform public.cancel_booking(v_b);

  -- 没収なので、ホストには渡っている(＝booking_earned はある)
  select coalesce(sum(amount),0) into v_earned from public.coin_transactions
    where related_booking_id = v_b and type = 'booking_earned';
  if v_earned <= 0 then
    raise exception 'NG: 前提が崩れた（没収が起きていない）';
  end if;
  if exists (select 1 from public.platform_fees where booking_id = v_b) then
    raise exception 'NG: 前提が崩れた（遊んでいないのに利用料の明細ができた）';
  end if;

  -- ★6-1. 渡っていても GMV は増えない
  v_gmv_after := public.host_monthly_ticket_gmv('42000000-0000-0000-0000-000000000001', now());
  if v_gmv_after <> v_gmv_before then
    raise exception 'NG: 没収（%）で GMV が % → % に増えた', v_earned, v_gmv_before, v_gmv_after;
  end if;

  -- ★6-2. 同じゲストの次の予約は「新規」のまま(＝一度も遊んでいない)
  v_b2 := public.create_booking('42000000-0000-0000-0000-000000000001', 60, 'v1',
                                now() + interval '9 days');
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b2);
  perform set_config('test.uid', '42000000-0000-0000-0000-000000000007', false);
  perform public.complete_booking(v_b2);

  select repeat_discounted, applied_rate into v_repeat, v_rate
    from public.platform_fees where booking_id = v_b2;
  if v_repeat then
    raise exception 'NG: 没収だけの相手でリピートが成立した（適用率 %）', v_rate;
  end if;
  raise notice 'ok 没収は GMV にもリピートにも入らない（没収額 %）', v_earned;
end $$;

\echo '=== 42: すべて ok ==='
