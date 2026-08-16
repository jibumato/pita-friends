-- ============================================================
-- 34: 「その時間に遊べるピタメイト」を一度に引く(0115)
--
-- ■ このテストの主眼
--   `hosts_open_at` に出たのに `create_booking` で弾かれる、が最悪の体験になる。
--   なので **9番目「出た時刻で実際に予約が通る」がこのファイルの本体**で、
--   他はその周りの絞り込みが効いているかの確認。
--
-- ■ 時刻の作り方
--   host_availability は (曜日, 時) を**日本時間で**持つ。テストは now() を
--   基準に「明日の同じ時刻」を取り、そこから曜日と時を逆算して枠を入れる。
--   固定の日時を書くと、流す日によって曜日が変わって落ちる。
-- ============================================================
\set ON_ERROR_STOP on

\set h1 '34000000-0000-0000-0000-0000000000h1'
\set g  '34000000-0000-0000-0000-0000000000g1'

insert into auth.users (id) values
  ('34000000-0000-0000-0000-000000000001'),  -- 枠あり(20時台のみ)
  ('34000000-0000-0000-0000-000000000002'),  -- 枠なし(いつでも)
  ('34000000-0000-0000-0000-000000000003'),  -- 本人確認していない
  ('34000000-0000-0000-0000-000000000007'),  -- 別のピタメイト(ゲストの先約用)
  ('34000000-0000-0000-0000-000000000008'),  -- 別のゲスト(枠を埋める用)
  ('34000000-0000-0000-0000-000000000009')   -- ゲスト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('34000000-0000-0000-0000-000000000001','枠あり'),
  ('34000000-0000-0000-0000-000000000002','枠なし'),
  ('34000000-0000-0000-0000-000000000003','未確認'),
  ('34000000-0000-0000-0000-000000000009','ゲスト')
on conflict (id) do update set nickname = excluded.nickname;

-- 掲載するには本人確認が要る(0003 のトリガー)。0003 は**掲載したあとで
-- 本人確認を取り消された**状態を作りたいので、いったん true にしてから戻す
update public.profile_trust_stats set is_verified = true
  where user_id in ('34000000-0000-0000-0000-000000000001',
                    '34000000-0000-0000-0000-000000000002',
                    '34000000-0000-0000-0000-000000000003',
                    '34000000-0000-0000-0000-000000000009');

insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('34000000-0000-0000-0000-000000000001', true, 1000),
  ('34000000-0000-0000-0000-000000000002', true, 1000),
  ('34000000-0000-0000-0000-000000000003', true, 1000)
on conflict (user_id) do update
  set is_host = true, hourly_rate = 1000, trial_discount_percent = 0;

-- ここで取り消す。掲載は残ったまま、本人確認だけが外れた状態
update public.profile_trust_stats set is_verified = false
  where user_id = '34000000-0000-0000-0000-000000000003';

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('34000000-0000-0000-0000-000000000009','paid', 200000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 200000
  where user_id = '34000000-0000-0000-0000-000000000009';

-- 基準になる時刻: 明日の 20:00(日本時間)ちょうど
create temporary table t as
select (date_trunc('day', (now() at time zone 'Asia/Tokyo') + interval '1 day')
        + interval '20 hours') at time zone 'Asia/Tokyo' as at20;

-- 「枠あり」は、その日の 20時台だけ開ける
set test.uid = '34000000-0000-0000-0000-000000000001';
do $$
declare v_at timestamptz; v_n int;
begin
  select at20 into v_at from t;
  v_n := public.set_host_availability(jsonb_build_array(jsonb_build_object(
    'weekday', extract(dow from (v_at at time zone 'Asia/Tokyo'))::int,
    'hour', extract(hour from (v_at at time zone 'Asia/Tokyo'))::int)));
  if v_n <> 1 then raise exception 'FAIL 枠の保存に失敗: %', v_n; end if;
end $$;

set test.uid = '34000000-0000-0000-0000-000000000009';

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 枠の中の時間なら出る / 枠の外だけの範囲では出ない ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz; r record;
begin
  select at20 into v_at from t;

  select * into r from public.hosts_open_at(v_at, v_at + interval '1 hour', 60)
    where host_id = '34000000-0000-0000-0000-000000000001';
  if r.host_id is null then raise exception 'FAIL 枠の中なのに出てこない'; end if;
  if r.next_open_at <> v_at then
    raise exception 'FAIL 最初の開始時刻がずれている: % (期待 %)', r.next_open_at, v_at;
  end if;
  if r.open_starts <> 1 then raise exception 'FAIL 候補数が1でない: %', r.open_starts; end if;

  -- 21時台〜23時台は枠の外
  if exists (
    select 1 from public.hosts_open_at(v_at + interval '1 hour', v_at + interval '3 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'FAIL 枠の外なのに出てきた';
  end if;
  raise notice 'OK 枠の中だけに出る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. プレイ時間の全体が枠に収まらないと出ない ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  -- 開いているのは20時台だけ。90分の予約は21時台にはみ出す
  if exists (
    select 1 from public.hosts_open_at(v_at, v_at + interval '4 hours', 90)
    where host_id = '34000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'FAIL 枠からはみ出す長さで出てきた';
  end if;
  -- 60分なら収まる
  if not exists (
    select 1 from public.hosts_open_at(v_at, v_at + interval '4 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'FAIL 収まる長さなのに出てこない';
  end if;
  raise notice 'OK 開始だけでなく終了まで見ている';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 枠を1つも設定していない人は常に出る ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz; r record;
begin
  select at20 into v_at from t;
  -- 枠ありが閉じている深夜帯でも、枠なしは出る
  select * into r from public.hosts_open_at(v_at + interval '6 hours', v_at + interval '9 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000002';
  if r.host_id is null then raise exception 'FAIL 枠なしが出てこない'; end if;
  if r.open_starts <> 3 then raise exception 'FAIL 候補数が3でない: %', r.open_starts; end if;
  raise notice 'OK 未設定は「制限なし」として扱われる(0051と同じ)';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 本人確認していないピタメイトは出ない ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  if exists (
    select 1 from public.hosts_open_at(v_at, v_at + interval '3 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000003'
  ) then
    raise exception 'FAIL 未確認が出てきた(create_booking は HOST_NOT_VERIFIED で弾く)';
  end if;
  raise notice 'OK 申し込めない相手は出さない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 自分自身は出ない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '34000000-0000-0000-0000-000000000002';
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  if exists (
    select 1 from public.hosts_open_at(v_at, v_at + interval '3 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000002'
  ) then
    raise exception 'FAIL 自分が候補に出た(CANNOT_BOOK_SELF)';
  end if;
  raise notice 'OK 自分は出ない';
end $$;
set test.uid = '34000000-0000-0000-0000-000000000009';

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 直近すぎる時間は出ない(min_lead_minutes) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  -- いまから10分後まで、では候補は作れない
  select count(*) into v_n from public.hosts_open_at(now(), now() + interval '10 minutes', 60);
  if v_n <> 0 then raise exception 'FAIL 受付できない時間帯で候補が出た: %', v_n; end if;
  raise notice 'OK START_TOO_SOON になる枠は出さない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 7. 予約が入っている時間は除かれる ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz; v_before int; v_after int;
begin
  select at20 into v_at from t;
  -- 枠なしメイトの 6時間後〜9時間後(3枠)のうち、真ん中を埋める
  select open_starts into v_before from public.hosts_open_at(
    v_at + interval '6 hours', v_at + interval '9 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000002';

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, requested_start_at)
  values ('34000000-0000-0000-0000-000000000008', '34000000-0000-0000-0000-000000000002',
          60, 1000, 'confirmed', now(), v_at + interval '7 hours');

  select open_starts into v_after from public.hosts_open_at(
    v_at + interval '6 hours', v_at + interval '9 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000002';

  if v_after <> v_before - 1 then
    raise exception 'FAIL 埋まった枠が除かれていない: % → %', v_before, v_after;
  end if;
  raise notice 'OK 予約済みの時間は候補から消える(% → %)', v_before, v_after;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 8. ゲスト自身の予定と重なる時間も除かれる ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz; v_before int; v_after int;
begin
  select at20 into v_at from t;
  select open_starts into v_before from public.hosts_open_at(
    v_at + interval '6 hours', v_at + interval '9 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000002';

  -- ゲストが別のピタメイトと約束している時間(GUEST_SLOT_TAKEN になる)
  insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, requested_start_at)
  values ('34000000-0000-0000-0000-000000000009', '34000000-0000-0000-0000-000000000007',
          60, 1000, 'confirmed', now(), v_at + interval '8 hours');

  select open_starts into v_after from public.hosts_open_at(
    v_at + interval '6 hours', v_at + interval '9 hours', 60)
    where host_id = '34000000-0000-0000-0000-000000000002';

  if v_after <> v_before - 1 then
    raise exception 'FAIL 自分の予定と重なる枠が残っている: % → %', v_before, v_after;
  end if;
  raise notice 'OK 自分の予定と重なる時間も消える(% → %)', v_before, v_after;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 9. ★出た時刻で、実際に予約が通る ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_at timestamptz; v_pick timestamptz; v_booking uuid;
begin
  select at20 into v_at from t;
  select next_open_at into v_pick from public.hosts_open_at(v_at, v_at + interval '1 hour', 60)
    where host_id = '34000000-0000-0000-0000-000000000001';
  if v_pick is null then raise exception 'FAIL 候補が出ない(前提が崩れた)'; end if;

  -- ここが本体。判定が create_booking と揃っていなければ、ここで例外が飛ぶ
  v_booking := public.create_booking(
    '34000000-0000-0000-0000-000000000001', 60, 'v1', v_pick);
  if v_booking is null then raise exception 'FAIL 予約が作れなかった'; end if;

  -- 取ったので、同じ範囲にはもう出てこない
  if exists (
    select 1 from public.hosts_open_at(v_at, v_at + interval '1 hour', 60)
    where host_id = '34000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'FAIL 予約したのにまだ候補に出ている';
  end if;
  raise notice 'OK 出た時刻でそのまま予約でき、取ったあとは消える';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 10. 未ログインでは呼べない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '';
do $$
begin
  begin
    perform public.hosts_open_at(now(), now() + interval '1 day', 60);
    raise exception 'FAIL 未ログインで呼べてしまった';
  exception when others then
    if sqlerrm not like '%NOT_AUTHENTICATED%' then raise; end if;
  end;
  raise notice 'OK NOT_AUTHENTICATED で止まる';
end $$;

\echo '==== 34: すべて通過 ===='
