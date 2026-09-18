-- ============================================================
-- 46: ペア予約（0126）
--
-- 見ているもの:
--   ① ペア相手でない2人は予約できない
--   ② 正常系：2件のbookingsが同時刻・同じゲストで作られる
--   ③ 片方が承認待ちのうちにもう片方が断られたら、連鎖して全額返還される
--   ④ 両方confirmed後の片方キャンセルは連鎖しない(設計どおり)
--   ⑤ 手数料・GMV・リピート判定はホストごとに独立(0122のロジックは不変)
--   ⑥ 既存の1対1予約(create_bookingの4引数版)は今までどおり動く
--   ⑦ ペアの相方どうしの重複はGUEST_SLOT_TAKENにならない
--   ⑧ ブロックされている組は予約できない
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('46000000-0000-0000-0000-000000000001'),  -- ホストA
  ('46000000-0000-0000-0000-000000000002'),  -- ホストB
  ('46000000-0000-0000-0000-000000000003'),  -- ホストC(ペア相手ではない)
  ('46000000-0000-0000-0000-000000000004'),  -- ホストD(ホストEとブロック関係)
  ('46000000-0000-0000-0000-000000000005'),  -- ホストE
  ('46000000-0000-0000-0000-000000000091')   -- ゲスト
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('46000000-0000-0000-0000-000000000001','ホストA'),
  ('46000000-0000-0000-0000-000000000002','ホストB'),
  ('46000000-0000-0000-0000-000000000003','ホストC'),
  ('46000000-0000-0000-0000-000000000004','ホストD'),
  ('46000000-0000-0000-0000-000000000005','ホストE'),
  ('46000000-0000-0000-0000-000000000091','ゲスト')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true;

insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('46000000-0000-0000-0000-000000000001', true, 1000),
  ('46000000-0000-0000-0000-000000000002', true, 1200),
  ('46000000-0000-0000-0000-000000000003', true, 800),
  ('46000000-0000-0000-0000-000000000004', true, 1000),
  ('46000000-0000-0000-0000-000000000005', true, 1000)
on conflict (user_id) do update set is_host = true, hourly_rate = excluded.hourly_rate;

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('46000000-0000-0000-0000-000000000091','paid', 500000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 500000
  where user_id = '46000000-0000-0000-0000-000000000091';

-- A・Bをペア相手にする
do $$
declare v_id uuid;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000001', false);
  v_id := public.propose_pair_partner('46000000-0000-0000-0000-000000000002');
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000002', false);
  perform public.respond_pair_partner(v_id, true);
end $$;

-- D・Eもペア相手にしたあと、ブロックする(成立後にブロックされた組の検証用)
do $$
declare v_id uuid;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000004', false);
  v_id := public.propose_pair_partner('46000000-0000-0000-0000-000000000005');
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000005', false);
  perform public.respond_pair_partner(v_id, true);
end $$;
insert into public.blocks (blocker_id, blocked_id) values
  ('46000000-0000-0000-0000-000000000004', '46000000-0000-0000-0000-000000000005');

-- ------------------------------------------------------------
\echo '=== ★1. ペア相手でない2人は予約できない ==='
do $$
declare v_msg text;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  begin
    perform public.create_paired_booking(
      '46000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000003',
      60, 'v1', now() + interval '3 days');
    raise exception 'NG: ペア相手でない2人で予約できてしまった';
  exception when others then
    v_msg := sqlerrm;
    if v_msg not like '%NOT_PAIR_PARTNERS%' then raise; end if;
  end;
  raise notice 'ok ペア相手でない2人は予約できない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★8. 成立後にブロックされた組は予約できない ==='
do $$
declare v_msg text;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  begin
    perform public.create_paired_booking(
      '46000000-0000-0000-0000-000000000004', '46000000-0000-0000-0000-000000000005',
      60, 'v1', now() + interval '3 days');
    raise exception 'NG: ブロック関係のある組で予約できてしまった';
  exception when others then
    v_msg := sqlerrm;
    if v_msg not like '%PARTNER_BLOCKED%' then raise; end if;
  end;
  raise notice 'ok 成立後にブロックされた組は予約できない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★2. 正常系：同時刻・同じゲストで2件できる ==='
do $$
declare v_pair uuid; v_a uuid; v_b uuid; v_start_a timestamptz; v_start_b timestamptz;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  v_pair := public.create_paired_booking(
    '46000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000002',
    60, 'v1', now() + interval '3 days');
  perform set_config('test.pair', v_pair::text, false);

  select booking_a, booking_b into v_a, v_b from public.booking_pairs where id = v_pair;
  if v_a is null or v_b is null then raise exception 'NG: bookingsが紐付いていない'; end if;

  perform set_config('test.ba', v_a::text, false);
  perform set_config('test.bb', v_b::text, false);

  select requested_start_at into v_start_a from public.bookings where id = v_a;
  select requested_start_at into v_start_b from public.bookings where id = v_b;
  if v_start_a <> v_start_b then
    raise exception 'NG: 開始時刻が違う（% / %）', v_start_a, v_start_b;
  end if;

  if (select guest_id from public.bookings where id = v_a) <> '46000000-0000-0000-0000-000000000091' then
    raise exception 'NG: guest_idが違う';
  end if;
  if (select status from public.bookings where id = v_a) <> 'requested' then
    raise exception 'NG: 状態がrequestedでない';
  end if;
  raise notice 'ok 2件のbookingsが同時刻・同じゲストで作られた';
end $$;

-- ------------------------------------------------------------
\echo '=== ★7. ペアの相方どうしの重複はGUEST_SLOT_TAKENにならない ==='
-- (すでに上のテストで両方 create_booking が成功していること自体が証明だが、
--  念のため明示的に確認する)
do $$
declare v_a uuid := current_setting('test.ba')::uuid;
        v_b uuid := current_setting('test.bb')::uuid;
begin
  if not exists (select 1 from public.bookings where id = v_a and status = 'requested')
     or not exists (select 1 from public.bookings where id = v_b and status = 'requested') then
    raise exception 'NG: 前提が崩れた';
  end if;
  raise notice 'ok 相方どうしはGUEST_SLOT_TAKENで弾かれていない（両方requested）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★3. 片方が承認待ちのうちに断られたら、連鎖して全額返還される ==='
do $$
declare v_a uuid := current_setting('test.ba')::uuid;
        v_b uuid := current_setting('test.bb')::uuid;
        v_guest_balance_before int; v_guest_balance_after int;
        v_status_b text; v_earned int;
begin
  select balance into v_guest_balance_before from public.coin_wallets
    where user_id = '46000000-0000-0000-0000-000000000091';

  -- ホストAが断る
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000001', false);
  perform public.decline_booking(v_a);

  -- ★ホストBへの申請も自動的に閉じているはず
  select status into v_status_b from public.bookings where id = v_b;
  if v_status_b <> 'cancelled_by_platform' then
    raise exception 'NG: 相方が連鎖して閉じていない（%）', v_status_b;
  end if;

  select balance into v_guest_balance_after from public.coin_wallets
    where user_id = '46000000-0000-0000-0000-000000000091';
  if v_guest_balance_after <> v_guest_balance_before + (
       select coins from public.bookings where id = v_a
     ) + (
       select coins from public.bookings where id = v_b
     ) then
    raise exception 'NG: 両方の全額が返っていない（前% 後%）',
      v_guest_balance_before, v_guest_balance_after;
  end if;
  raise notice 'ok 片方が断られると、もう片方も連鎖して全額返還される';
end $$;

-- ------------------------------------------------------------
\echo '=== ★4. 両方confirmed後の片方キャンセルは連鎖しない ==='
do $$
declare v_pair uuid; v_a uuid; v_b uuid; v_status_b text;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  v_pair := public.create_paired_booking(
    '46000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000002',
    60, 'v1', now() + interval '4 days');
  select booking_a, booking_b into v_a, v_b from public.booking_pairs where id = v_pair;

  -- 両方承認する
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_a);
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000002', false);
  perform public.approve_booking(v_b);

  -- ゲストがAだけキャンセルする(confirmed状態からのキャンセル)
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  perform public.cancel_booking(v_a, 'テスト');

  -- ★Bはconfirmedのまま(連鎖しない)
  select status into v_status_b from public.bookings where id = v_b;
  if v_status_b <> 'confirmed' then
    raise exception 'NG: confirmed後なのにBまで連鎖して % になった', v_status_b;
  end if;
  perform set_config('test.pair4', v_pair::text, false);
  perform set_config('test.b4', v_b::text, false);
  raise notice 'ok 両方confirmed後の片方キャンセルは連鎖しない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★5. 手数料・GMV・リピート判定はホストごとに独立 ==='
-- ⚠️ **完了と、その後の確認を同じdoブロックに入れない。**
--    手数料の適用(_apply_booking_fee)はDEFERRABLE INITIALLY DEFERREDの
--    制約トリガで、コミット時にしか走らない。doブロックの中は1つの
--    トランザクションなので、同じブロックで直後にGMV/platform_feesを
--    見ると「まだ何も無い」まま読んでしまう(26番のテストもこの理由で
--    complete_bookingをトップレベル文として分けている)。
do $$
declare v_gmv_a_before int; v_gmv_b_before int;
begin
  v_gmv_a_before := public.host_monthly_ticket_gmv('46000000-0000-0000-0000-000000000001', now());
  v_gmv_b_before := public.host_monthly_ticket_gmv('46000000-0000-0000-0000-000000000002', now());
  perform set_config('test.gmv_a_before', v_gmv_a_before::text, false);
  perform set_config('test.gmv_b_before', v_gmv_b_before::text, false);
end $$;

-- Bだけ完了させる(Aはすでにキャンセル済みで、この月のGMVに影響しないはず)
set test.uid = '46000000-0000-0000-0000-000000000091';
select public.complete_booking(current_setting('test.b4')::uuid);

do $$
declare v_b uuid := current_setting('test.b4')::uuid;
        v_gmv_a_before int := current_setting('test.gmv_a_before')::int;
        v_gmv_b_before int := current_setting('test.gmv_b_before')::int;
        v_gmv_a_after int; v_gmv_b_after int;
        v_fee_rows int;
begin
  v_gmv_a_after := public.host_monthly_ticket_gmv('46000000-0000-0000-0000-000000000001', now());
  v_gmv_b_after := public.host_monthly_ticket_gmv('46000000-0000-0000-0000-000000000002', now());

  if v_gmv_a_after <> v_gmv_a_before then
    raise exception 'NG: 相方(ホストB)の完了でホストAのGMVが動いた（% → %）',
      v_gmv_a_before, v_gmv_a_after;
  end if;
  if v_gmv_b_after <> v_gmv_b_before + (select coins from public.bookings where id = v_b) then
    raise exception 'NG: ホストBのGMVが増えていない（% → %）', v_gmv_b_before, v_gmv_b_after;
  end if;

  -- platform_feesの明細もホストBの分だけ
  select count(*) into v_fee_rows from public.platform_fees
    where kind = 'booking' and host_id = '46000000-0000-0000-0000-000000000001';
  if v_fee_rows <> 0 then
    raise exception 'NG: キャンセルしたホストAに利用料の明細ができた';
  end if;
  select count(*) into v_fee_rows from public.platform_fees
    where kind = 'booking' and host_id = '46000000-0000-0000-0000-000000000002' and booking_id = v_b;
  if v_fee_rows <> 1 then
    raise exception 'NG: 完了したホストBに利用料の明細が無い';
  end if;
  raise notice 'ok 手数料・GMVはホストごとに独立(相方の結果に影響されない)';
end $$;

-- ------------------------------------------------------------
\echo '=== ★6. 既存の1対1予約(4引数版)は今までどおり動く ==='
do $$
declare v_b uuid; v_pair_id uuid;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  v_b := public.create_booking(
    '46000000-0000-0000-0000-000000000003', 60, 'v1', now() + interval '5 days');
  select from_pair_id into v_pair_id from public.bookings where id = v_b;
  if v_pair_id is not null then
    raise exception 'NG: 単独予約なのにfrom_pair_idが付いた';
  end if;
  if (select status from public.bookings where id = v_b) <> 'requested' then
    raise exception 'NG: 単独予約の状態がおかしい';
  end if;
  raise notice 'ok 既存の1対1予約(4引数版)は今までどおり動く(from_pair_id=null)';
end $$;

-- ------------------------------------------------------------
\echo '=== ★9. ペア予約は延長できる(相方が「重複」と誤判定されない) ==='
do $$
declare v_pair uuid; v_a uuid; v_b uuid;
begin
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  v_pair := public.create_paired_booking(
    '46000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000002',
    60, 'v1', now() + interval '6 days');
  select booking_a, booking_b into v_a, v_b from public.booking_pairs where id = v_pair;

  perform set_config('test.uid', '46000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_a);
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000002', false);
  perform public.approve_booking(v_b);

  -- ★本題。相方(v_b)は同じ開始時刻の別予約として必ず重なって見えるが、
  -- from_pair_id が同じなので衝突として扱われないはず
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  perform public.extend_booking(v_a, 30);

  if (select duration_minutes from public.bookings where id = v_a) <> 90 then
    raise exception 'NG: 延長されていない';
  end if;
  -- 相方(v_b)は延長していないので60分のまま(片方だけ延長できる=連動しない、が今回の仕様)
  if (select duration_minutes from public.bookings where id = v_b) <> 60 then
    raise exception 'NG: 延長していない相方まで変わった';
  end if;
  raise notice 'ok ペア予約は延長できる(相方は「重複」にならない・連動もしない)';
end $$;

-- ------------------------------------------------------------
\echo '=== ★10. ペア相手の一覧は誰でも呼べる(公開情報) ==='
do $$
declare v_ids uuid[];
begin
  -- ゲスト(当事者ではない)から呼んでも見える
  perform set_config('test.uid', '46000000-0000-0000-0000-000000000091', false);
  select array_agg(partner_id) into v_ids
    from public.host_pair_partners_of('46000000-0000-0000-0000-000000000001');
  if not (v_ids @> array['46000000-0000-0000-0000-000000000002'::uuid]) then
    raise exception 'NG: 当事者でない人から見えない（%）', v_ids;
  end if;
  -- ブロックし合っている(D・E)側は、成立自体していないので出ない
  select array_agg(partner_id) into v_ids
    from public.host_pair_partners_of('46000000-0000-0000-0000-000000000003');
  if v_ids is not null then
    raise exception 'NG: ペア相手がいないホストで何か返った（%）', v_ids;
  end if;
  raise notice 'ok ペア相手の一覧は誰でも呼べる';
end $$;

\echo '=== 46: すべて ok ==='
