-- ============================================================
-- 41: 利用者が想定外の順序で操作したときに、黙って間違わないか
--
-- ■ このファイルの主眼
--   エラーになること自体は問題ではない。**エラーにならずに、頼んでいない
--   結果が確定すること**が問題。だから「例外が出るか」より
--   「何が確定したか」を見る。
--
--   とくに 0120（ゲストのリクエスト）は、応じた行そのものが空き枠の根拠なので、
--   **片方が動かしたものが、もう片方の画面と食い違いやすい。**
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('41000000-0000-0000-0000-000000000001'),  -- ピタメイト
  ('41000000-0000-0000-0000-000000000002'),  -- 別のピタメイト
  ('41000000-0000-0000-0000-000000000009'),  -- ゲストA
  ('41000000-0000-0000-0000-000000000008')   -- ゲストB
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('41000000-0000-0000-0000-000000000001','ホスト'),
  ('41000000-0000-0000-0000-000000000002','ホスト2'),
  ('41000000-0000-0000-0000-000000000009','ゲストA'),
  ('41000000-0000-0000-0000-000000000008','ゲストB')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id in ('41000000-0000-0000-0000-000000000001',
                    '41000000-0000-0000-0000-000000000002',
                    '41000000-0000-0000-0000-000000000009',
                    '41000000-0000-0000-0000-000000000008');

insert into public.host_settings (user_id, is_host, hourly_rate, games) values
  ('41000000-0000-0000-0000-000000000001', true, 1000, array['Apex']),
  ('41000000-0000-0000-0000-000000000002', true, 1000, array['Apex'])
on conflict (user_id) do update
  set is_host = true, hourly_rate = 1000, games = excluded.games, trial_discount_percent = 0;

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('41000000-0000-0000-0000-000000000009','paid', 500000, public.coin_expiry_from(now())),
  ('41000000-0000-0000-0000-000000000008','paid', 500000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 500000
  where user_id in ('41000000-0000-0000-0000-000000000009',
                    '41000000-0000-0000-0000-000000000008');

-- 基準: 明後日の 20:00(日本時間)。常連先行(0057)を確実に跨がせる
create temporary table t as
select (date_trunc('day', (now() at time zone 'Asia/Tokyo') + interval '2 days')
        + interval '20 hours') at time zone 'Asia/Tokyo' as at20;

-- ⚠️ **ホスト2にだけ、無関係な週の枠を1つ入れておく。**
--   `host_has_availability` が false のピタメイトは `host_is_open_at` が
--   常に true を返す(0051)。つまり枠を1つも持たないホストでは
--   「応じて開いた／閉じた」を観測できない。
--   ホスト1は枠なし(＝いつでも予約できる)のまま、予約そのものの検査に使う。
set test.uid = '41000000-0000-0000-0000-000000000002';
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  perform public.set_host_availability(jsonb_build_array(jsonb_build_object(
    'weekday', extract(dow from ((v_at + interval '1 day') at time zone 'Asia/Tokyo'))::int,
    'hour', 4)));
end $$;

\echo '=== 1. 予約の二重送信（連打）で2件作られないか ==='
do $$
declare v_at timestamptz; v_b1 uuid; v_n int;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);

  v_b1 := public.create_booking('41000000-0000-0000-0000-000000000001', 60, 'v1', v_at);
  -- 同じ内容をもう一度。画面の連打に相当する
  begin
    perform public.create_booking('41000000-0000-0000-0000-000000000001', 60, 'v1', v_at);
    raise exception 'NG: 同じ枠の予約が2件通ってしまった（コインが二重に引かれる）';
  exception when others then
    if sqlerrm not in ('HOST_SLOT_TAKEN', 'GUEST_SLOT_TAKEN') then raise; end if;
  end;

  select count(*) into v_n from public.bookings
  where guest_id = '41000000-0000-0000-0000-000000000009'
    and host_id = '41000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'NG: 予約が % 件ある', v_n; end if;

  -- 後始末（以降のテストで枠を塞がないように）
  perform public.cancel_booking(v_b1);
  raise notice 'ok 連打は枠の重複検査で止まる（1件だけ）';
end $$;

\echo '=== 2. 応じてもらったあとホストが掲載を取り下げたら ==='
do $$
declare v_at timestamptz; v_req uuid;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  v_req := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  perform public.respond_to_guest_request(v_req, v_at);

  -- ホストが掲載をやめる
  update public.host_settings set is_host = false
    where user_id = '41000000-0000-0000-0000-000000000001';

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  begin
    perform public.create_booking_from_request(
      v_req, '41000000-0000-0000-0000-000000000001', 'v1', v_at);
    raise exception 'NG: 掲載をやめたピタメイトの予約が通った';
  exception when others then
    if sqlerrm <> 'HOST_NOT_AVAILABLE' then raise; end if;
  end;

  -- **リクエストは open のまま**であること（予約が通っていないのに閉じない）
  if (select status from public.guest_requests where id = v_req) <> 'open' then
    raise exception 'NG: 予約が失敗したのにリクエストが閉じた';
  end if;

  update public.host_settings set is_host = true
    where user_id = '41000000-0000-0000-0000-000000000001';
  perform public.cancel_guest_request(v_req);
  raise notice 'ok 掲載をやめたら予約は通らず、リクエストは開いたまま';
end $$;

\echo '=== ★3. ホストが応じる時刻を変えたあと、ゲストが古い画面で予約したら ==='
do $$
declare v_at timestamptz; v_req uuid; v_b uuid; v_start timestamptz;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  v_req := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  -- 20:00 で応じる → ゲストの画面には 20:00 が出る
  perform public.respond_to_guest_request(v_req, v_at);
  -- 気が変わって 22:00 に変える（ゲストの画面はまだ 20:00 のまま）
  perform public.respond_to_guest_request(v_req, v_at + interval '2 hours');

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);

  -- ★ここが本題。ゲストの画面は 20:00 のまま。その時刻を渡して申し込む。
  --   0121 より前は引数が無く、応答の行を読み直して **22:00 で成立していた**
  --   （ゲストは 20:00 のつもりで 22:00 の約束を買う）
  begin
    perform public.create_booking_from_request(
      v_req, '41000000-0000-0000-0000-000000000001', 'v1', v_at);
    raise exception 'NG: 画面と違う時刻なのに予約が成立した';
  exception when others then
    if sqlerrm <> 'RESPONSE_TIME_CHANGED' then raise; end if;
  end;

  -- 画面を開き直して、いまの時刻(22:00)で申し込めば通る
  v_b := public.create_booking_from_request(
    v_req, '41000000-0000-0000-0000-000000000001', 'v1', v_at + interval '2 hours');
  select requested_start_at into v_start from public.bookings where id = v_b;
  if v_start <> v_at + interval '2 hours' then
    raise exception 'NG: 渡した時刻と違う時刻で成立した (%)', v_start;
  end if;
  raise notice 'ok 画面が古いと止まり、開き直せば通る';

  perform public.cancel_booking(v_b);
end $$;

\echo '=== 4. 取り下げたリクエストから予約しようとしたら（枠が閉じるかも見る） ==='
do $$
declare v_at timestamptz; v_req uuid;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  v_req := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);
  -- 枠の開閉を観測できるホスト2を使う（週の枠を持っている）
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000002', false);
  perform public.respond_to_guest_request(v_req, v_at);

  -- 応じた時点では開いている
  if not public.host_is_open_at('41000000-0000-0000-0000-000000000002', v_at) then
    raise exception 'NG: 応じたのに枠が開いていない';
  end if;

  -- ゲストが取り下げる（別の端末で、など）
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  perform public.cancel_guest_request(v_req);

  -- 古い画面のまま予約を押す
  begin
    perform public.create_booking_from_request(
      v_req, '41000000-0000-0000-0000-000000000002', 'v1', v_at);
    raise exception 'NG: 取り下げたリクエストから予約が通った';
  exception when others then
    if sqlerrm <> 'REQUEST_NOT_OPEN' then raise; end if;
  end;

  -- 開けていた枠も閉じていること
  if public.host_is_open_at('41000000-0000-0000-0000-000000000002', v_at) then
    raise exception 'NG: 取り下げたのに枠が開いたまま';
  end if;
  raise notice 'ok 取り下げ後は予約できず、枠も閉じる';
end $$;

\echo '=== ★5. 応じて開いた枠を、別のゲストが横から取れるか（仕様の確認） ==='
do $$
declare v_at timestamptz; v_req uuid; v_b uuid;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  v_req := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  perform public.respond_to_guest_request(v_req, v_at);

  -- ゲストB（リクエストしていない人）が、その時間を普通に予約する。
  -- **これは仕様**（「応じる＝その時間を開ける」で、取り置きではない）
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000008', false);
  v_b := public.create_booking('41000000-0000-0000-0000-000000000001', 60, 'v1', v_at);

  -- そのあとゲストA（リクエストした人）が予約しようとすると埋まっている
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  begin
    perform public.create_booking_from_request(
      v_req, '41000000-0000-0000-0000-000000000001', 'v1', v_at);
    raise exception 'NG: 埋まっている枠に2件目が入った';
  exception when others then
    if sqlerrm <> 'HOST_SLOT_TAKEN' then raise; end if;
  end;

  if (select status from public.guest_requests where id = v_req) <> 'open' then
    raise exception 'NG: 予約できなかったのにリクエストが閉じた';
  end if;
  raise notice 'ok 横から取られてもリクエストは開いたまま（出し直せる）';

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000008', false);
  perform public.cancel_booking(v_b);
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  perform public.cancel_guest_request(v_req);
end $$;

\echo '=== 6. 受付が終わったリクエストに、cron が走る前に応じたら ==='
do $$
declare v_id uuid;
begin
  -- 期限切れの行を直接作る（create_guest_request は過去を受け付けない）
  insert into public.guest_requests
    (guest_id, game, window_start, window_end, duration_minutes)
  values ('41000000-0000-0000-0000-000000000009', 'Apex',
          now() - interval '3 hours', now() - interval '1 hour', 60)
  returning id into v_id;

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  begin
    perform public.respond_to_guest_request(v_id, date_trunc('hour', now() - interval '2 hours'));
    raise exception 'NG: 終わったリクエストに応じられた';
  exception when others then
    -- 範囲内だが過去なので START_TOO_SOON。どちらで止まってもよい
    if sqlerrm not in ('START_TOO_SOON', 'OUTSIDE_REQUEST_WINDOW') then raise; end if;
  end;
  raise notice 'ok 終わったリクエストには応じられない（cron 前でも）';
  delete from public.guest_requests where id = v_id;
end $$;

\echo '=== 7. 応じたあとブロックされたら、予約は通らないか ==='
do $$
declare v_at timestamptz; v_req uuid;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  v_req := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  perform public.respond_to_guest_request(v_req, v_at);

  -- ホストがゲストをブロックする
  insert into public.blocks (blocker_id, blocked_id)
  values ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000009')
  on conflict do nothing;

  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  begin
    perform public.create_booking_from_request(
      v_req, '41000000-0000-0000-0000-000000000001', 'v1', v_at);
    raise exception 'NG: ブロックされているのに予約が通った';
  exception when others then
    if sqlerrm <> 'BLOCKED' then raise; end if;
  end;
  raise notice 'ok ブロック後は予約できない';

  delete from public.blocks
   where blocker_id = '41000000-0000-0000-0000-000000000001'
     and blocked_id = '41000000-0000-0000-0000-000000000009';
end $$;

\echo '=== 8. ブロックは、リクエスト以外の経路でも効くか ==='
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  insert into public.blocks (blocker_id, blocked_id)
  values ('41000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000009')
  on conflict do nothing;

  -- さがす画面・お気に入り・再予約はどれも create_booking を直接通る。
  -- **0121 より前はここに検査が無く、全部素通りだった**
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  begin
    perform public.create_booking('41000000-0000-0000-0000-000000000001', 60, 'v1', v_at);
    raise exception 'NG: ブロックされているのに通常の予約が通った';
  exception when others then
    if sqlerrm <> 'BLOCKED' then raise; end if;
  end;

  -- ブロックされた側からも同じ（向きを問わない）
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  begin
    perform public.create_booking('41000000-0000-0000-0000-000000000009', 60, 'v1', v_at);
    raise exception 'NG: 逆向きの予約が通った';
  exception when others then
    if sqlerrm not in ('BLOCKED', 'HOST_NOT_AVAILABLE') then raise; end if;
  end;

  delete from public.blocks
   where blocker_id = '41000000-0000-0000-0000-000000000001'
     and blocked_id = '41000000-0000-0000-0000-000000000009';
  raise notice 'ok 通常の予約経路でもブロックが効く';
end $$;

\echo '=== ★9. 一緒に遊んだあとブロックしても、既存のトークから送れてしまわないか ==='
do $$
declare v_at timestamptz; v_b uuid; v_promise uuid;
begin
  select at20 into v_at from t;
  -- 予約 → 承諾 でトークが開く
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  v_b := public.create_booking('41000000-0000-0000-0000-000000000001', 60, 'v1', v_at);
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000001', false);
  perform public.approve_booking(v_b);

  select id into v_promise from public.promises where booking_id = v_b;
  if v_promise is null then raise exception 'NG: トークが開いていない'; end if;

  -- ここまでは送れる
  insert into public.messages (promise_id, sender_id, body) values (v_promise, '41000000-0000-0000-0000-000000000001', 'よろしく');

  -- ゲストがホストをブロックする
  perform set_config('test.uid', '41000000-0000-0000-0000-000000000009', false);
  insert into public.blocks (blocker_id, blocked_id)
  values ('41000000-0000-0000-0000-000000000009', '41000000-0000-0000-0000-000000000001')
  on conflict do nothing;

  -- ★0121 より前は、ここから**送れてしまっていた**。
  --   messages の RLS は「約束の当事者か」しか見ておらず、ブロックを見ていない
  begin
    insert into public.messages (promise_id, sender_id, body) values (v_promise, '41000000-0000-0000-0000-000000000001', 'まだ送れる？');
    raise exception 'NG: ブロックされた相手から、既存のトークで送れてしまった';
  exception when others then
    if sqlerrm <> 'BLOCKED' then raise; end if;
  end;
  raise notice 'ok ブロック後は既存のトークでも送れない';
end $$;

\echo '=== 41: すべて ok ==='
