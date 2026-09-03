-- ============================================================
-- 39: ゲストのリクエスト(0120)
--
-- ■ このテストの主眼
--   **9番「応じた枠で実際に予約が通る」がこのファイルの本体。**
--   応じたのに予約できない／閉じたのに予約できてしまう、のどちらも起きない
--   ことを確かめる。他はその周りの絞り込み。
--
-- ■ 時刻の作り方
--   host_availability は(曜日,時)を日本時間で持つ。固定の日時を書くと
--   流す日によって曜日が変わって落ちるので、now() から逆算する(34 と同じ)。
--   リクエストの範囲は「明後日の20:00〜23:00(日本時間)」を使う。
--   明後日にするのは、常連先行(0057)の 48 時間を確実に跨がせるため。
-- ============================================================
\set ON_ERROR_STOP on

-- 1: 応じるピタメイト（Apex 登録・枠は開けていない）
-- 2: 別のピタメイト（Apex 登録・応じない）
-- 3: 登録ゲームが合わないピタメイト（通知が来てはいけない）
-- 9: ゲスト
insert into auth.users (id) values
  ('39000000-0000-0000-0000-000000000001'),
  ('39000000-0000-0000-0000-000000000002'),
  ('39000000-0000-0000-0000-000000000003'),
  ('39000000-0000-0000-0000-000000000009')
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('39000000-0000-0000-0000-000000000001','応じる人'),
  ('39000000-0000-0000-0000-000000000002','応じない人'),
  ('39000000-0000-0000-0000-000000000003','別ゲーム'),
  ('39000000-0000-0000-0000-000000000009','ゲスト')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id in ('39000000-0000-0000-0000-000000000001',
                    '39000000-0000-0000-0000-000000000002',
                    '39000000-0000-0000-0000-000000000003',
                    '39000000-0000-0000-0000-000000000009');

insert into public.host_settings (user_id, is_host, hourly_rate, games) values
  ('39000000-0000-0000-0000-000000000001', true, 1000, array['Apex']),
  ('39000000-0000-0000-0000-000000000002', true, 1000, array['Apex']),
  ('39000000-0000-0000-0000-000000000003', true, 1000, array['スプラ'])
on conflict (user_id) do update
  set is_host = true, hourly_rate = 1000, games = excluded.games, trial_discount_percent = 0;

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('39000000-0000-0000-0000-000000000009','paid', 200000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 200000
  where user_id = '39000000-0000-0000-0000-000000000009';

-- 基準: 明後日の 20:00(日本時間)
create temporary table t as
select (date_trunc('day', (now() at time zone 'Asia/Tokyo') + interval '2 days')
        + interval '20 hours') at time zone 'Asia/Tokyo' as at20;

-- 「応じる人」は**その時間に枠を開けていない**（別の曜日・時に1枠だけ置く）。
-- 枠が1つも無いと host_has_availability が false になり「常に開いている」に
-- なってしまうので、**判定を効かせるために、無関係な枠を1つ入れておく**
set test.uid = '39000000-0000-0000-0000-000000000001';
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  perform public.set_host_availability(jsonb_build_array(jsonb_build_object(
    'weekday', extract(dow from ((v_at + interval '1 day') at time zone 'Asia/Tokyo'))::int,
    'hour', 3)));
end $$;

-- 常連先行を効かせる(72時間)。応じた枠がこれを飛び越えることを見る
update public.host_settings set regulars_first_hours = 72
  where user_id = '39000000-0000-0000-0000-000000000001';

\echo '=== 1. 出す前: その時間に予約できるピタメイトは居ない ==='
set test.uid = '39000000-0000-0000-0000-000000000009';
do $$
declare v_at timestamptz; v_n int;
begin
  select at20 into v_at from t;
  select count(*) into v_n
  from public.hosts_open_at(v_at, v_at + interval '3 hours', 60)
  where host_id = '39000000-0000-0000-0000-000000000001';
  if v_n <> 0 then
    raise exception 'NG: 枠を開けていないのに hosts_open_at に出た (%)', v_n;
  end if;
  raise notice 'ok 応じる前は候補に出ない';
end $$;

\echo '=== 2. リクエストを出すと、ゲームの合う人にだけ通知が届く ==='
do $$
declare v_at timestamptz; v_id uuid; v_n int;
begin
  select at20 into v_at from t;
  v_id := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60, 'まったりで');
  perform set_config('test.request_id', v_id::text, false);

  select count(*) into v_n from public.notifications
  where type = 'guest_request_received' and related_id = v_id;
  if v_n <> 2 then
    raise exception 'NG: 通知先が2人のはずが % 人', v_n;
  end if;
  if exists (select 1 from public.notifications
             where related_id = v_id and user_id = '39000000-0000-0000-0000-000000000003') then
    raise exception 'NG: 登録ゲームが違う人に通知が届いた';
  end if;
  raise notice 'ok 通知は Apex 登録の2人だけ';
end $$;

\echo '=== 3. 同時に開けるのは3件まで ==='
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  perform public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);
  perform public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);
  begin
    perform public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);
    raise exception 'NG: 4件目が通ってしまった';
  exception when others then
    if sqlerrm <> 'TOO_MANY_OPEN_REQUESTS' then raise; end if;
    raise notice 'ok 4件目は TOO_MANY_OPEN_REQUESTS';
  end;
end $$;

\echo '=== 4. 範囲の検査（短すぎ・広すぎ・近すぎ） ==='
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  -- 先に3件を畳んでおく(上限に当たらないように)
  update public.guest_requests set status = 'cancelled', closed_at = now()
   where guest_id = '39000000-0000-0000-0000-000000000009'
     and status = 'open'
     and id <> current_setting('test.request_id')::uuid;

  begin
    perform public.create_guest_request('Apex', v_at, v_at + interval '30 minutes', 60);
    raise exception 'NG: 長さより狭い範囲が通った';
  exception when others then
    if sqlerrm <> 'WINDOW_TOO_SHORT' then raise; end if;
  end;

  begin
    perform public.create_guest_request('Apex', v_at, v_at + interval '10 days', 60);
    raise exception 'NG: 広すぎる範囲が通った';
  exception when others then
    -- max_lead_days(既定35日)より 10 日は手前なので、広さの側で落ちる
    if sqlerrm <> 'WINDOW_TOO_WIDE' then raise; end if;
  end;

  begin
    perform public.create_guest_request('Apex', now() + interval '5 minutes', now() + interval '3 hours', 60);
    raise exception 'NG: リードタイムより近い範囲が通った';
  exception when others then
    if sqlerrm <> 'WINDOW_TOO_SOON' then raise; end if;
  end;
  raise notice 'ok 範囲の検査が効いている';
end $$;

\echo '=== 5. 応じられるのは掲載中のピタメイトだけ・毎正時だけ ==='
do $$
declare v_at timestamptz; v_req uuid;
begin
  select at20 into v_at from t;
  v_req := current_setting('test.request_id')::uuid;

  -- ゲスト自身
  set local role none;
  perform set_config('test.uid', '39000000-0000-0000-0000-000000000009', true);
  begin
    perform public.respond_to_guest_request(v_req, v_at);
    raise exception 'NG: 自分のリクエストに応じられてしまった';
  exception when others then
    if sqlerrm <> 'CANNOT_ANSWER_OWN_REQUEST' then raise; end if;
  end;

  -- 毎正時でない
  perform set_config('test.uid', '39000000-0000-0000-0000-000000000001', true);
  begin
    perform public.respond_to_guest_request(v_req, v_at + interval '30 minutes');
    raise exception 'NG: 30分ずれた開始が通った';
  exception when others then
    if sqlerrm <> 'START_MUST_BE_ON_THE_HOUR' then raise; end if;
  end;

  -- 範囲の外(3時間の範囲に60分は 22:00 開始まで)
  begin
    perform public.respond_to_guest_request(v_req, v_at + interval '3 hours');
    raise exception 'NG: 範囲の外が通った';
  exception when others then
    if sqlerrm <> 'OUTSIDE_REQUEST_WINDOW' then raise; end if;
  end;
  raise notice 'ok 応じる側の検査が効いている';
end $$;

\echo '=== 6. 一覧に出る（ゲームの合う人だけ） ==='
do $$
declare v_n int;
begin
  perform set_config('test.uid', '39000000-0000-0000-0000-000000000001', false);
  select count(*) into v_n from public.guest_requests_for_host(30);
  if v_n <> 1 then raise exception 'NG: 応じる人の一覧が % 件', v_n; end if;

  perform set_config('test.uid', '39000000-0000-0000-0000-000000000003', false);
  select count(*) into v_n from public.guest_requests_for_host(30);
  if v_n <> 0 then raise exception 'NG: 別ゲームの人に % 件出た', v_n; end if;
  raise notice 'ok 一覧は通知と同じ絞り込み';
end $$;

\echo '=== 7. 応じると、その時間だけが開く ==='
set test.uid = '39000000-0000-0000-0000-000000000001';
do $$
declare v_at timestamptz; v_req uuid;
begin
  select at20 into v_at from t;
  v_req := current_setting('test.request_id')::uuid;
  perform public.respond_to_guest_request(v_req, v_at + interval '1 hour'); -- 21:00〜

  if not public.host_is_open_at('39000000-0000-0000-0000-000000000001', v_at + interval '1 hour') then
    raise exception 'NG: 応じた時間が開いていない';
  end if;
  if public.host_is_open_at('39000000-0000-0000-0000-000000000001', v_at) then
    raise exception 'NG: 応じていない 20時台まで開いてしまった';
  end if;
  if public.host_is_open_at('39000000-0000-0000-0000-000000000001', v_at + interval '2 hours') then
    raise exception 'NG: 応じていない 22時台まで開いてしまった';
  end if;
  raise notice 'ok 応じた1時間だけが開く';
end $$;

\echo '=== 8. ゲストに通知が届き、候補として読める ==='
do $$
declare v_req uuid; v_n int; v_start timestamptz; v_at timestamptz;
begin
  v_req := current_setting('test.request_id')::uuid;
  select at20 into v_at from t;

  select count(*) into v_n from public.notifications
  where type = 'guest_request_answered'
    and user_id = '39000000-0000-0000-0000-000000000009' and related_id = v_req;
  if v_n <> 1 then raise exception 'NG: 応答の通知が % 件', v_n; end if;

  perform set_config('test.uid', '39000000-0000-0000-0000-000000000009', false);
  select count(*), min(a.starts_at) into v_n, v_start
  from public.guest_request_answers(v_req) a;
  if v_n <> 1 then raise exception 'NG: 候補が % 件', v_n; end if;
  if v_start <> v_at + interval '1 hour' then
    raise exception 'NG: 候補の開始時刻がずれている (%)', v_start;
  end if;
  raise notice 'ok 候補として読める';
end $$;

\echo '=== ★9. 応じた枠で実際に予約が通る（常連先行も飛び越える） ==='
do $$
declare v_req uuid; v_at timestamptz; v_b uuid; v_n int;
begin
  v_req := current_setting('test.request_id')::uuid;
  select at20 into v_at from t;
  perform set_config('test.uid', '39000000-0000-0000-0000-000000000009', false);

  -- 先に、探す画面にも出るようになっていること(0115 と判定が揃っている)
  select count(*) into v_n
  from public.hosts_open_at(v_at, v_at + interval '3 hours', 60)
  where host_id = '39000000-0000-0000-0000-000000000001';
  if v_n <> 1 then
    raise exception 'NG: 応じたのに hosts_open_at に出ない';
  end if;

  v_b := public.create_booking_from_request(
    v_req, '39000000-0000-0000-0000-000000000001', 'v1');

  if (select from_guest_request_id from public.bookings where id = v_b) is distinct from v_req then
    raise exception 'NG: 予約がリクエストに紐づいていない';
  end if;
  -- 承認までは requested_start_at が希望時刻（scheduled_at は承認時に入る）
  if (select requested_start_at from public.bookings where id = v_b) <> v_at + interval '1 hour' then
    raise exception 'NG: 予約の開始時刻がずれている';
  end if;
  if (select status from public.guest_requests where id = v_req) <> 'matched' then
    raise exception 'NG: リクエストが matched になっていない';
  end if;
  raise notice 'ok 応じた枠で予約が成立し、リクエストが閉じた';
end $$;

\echo '=== 10. 閉じたら枠も閉じる（開けっぱなしにならない） ==='
do $$
declare v_at timestamptz;
begin
  select at20 into v_at from t;
  -- 予約そのものは booking_slots が押さえているので、
  -- 「開いているか」の判定だけを見る
  if public.host_is_open_at('39000000-0000-0000-0000-000000000001', v_at + interval '1 hour') then
    raise exception 'NG: リクエストが閉じたのに枠が開いたまま';
  end if;
  raise notice 'ok リクエストが閉じると枠も閉じる';
end $$;

\echo '=== 11. 期限切れ ==='
do $$
declare v_id uuid; v_n int;
begin
  perform set_config('test.uid', '39000000-0000-0000-0000-000000000009', false);
  -- 期限切れを作るために、範囲を直接過去へ倒す
  -- (create_guest_request は過去の範囲を受け付けないため)
  insert into public.guest_requests (guest_id, game, window_start, window_end, duration_minutes)
  values ('39000000-0000-0000-0000-000000000009', 'Apex',
          now() - interval '3 hours', now() - interval '1 hour', 60)
  returning id into v_id;

  v_n := public.expire_guest_requests();
  if v_n < 1 then raise exception 'NG: 期限切れが0件'; end if;
  if (select status from public.guest_requests where id = v_id) <> 'expired' then
    raise exception 'NG: expired になっていない';
  end if;
  select count(*) into v_n from public.notifications
  where related_id = v_id and user_id = '39000000-0000-0000-0000-000000000009';
  if v_n <> 1 then raise exception 'NG: 誰も応じなかった通知が % 件', v_n; end if;
  raise notice 'ok 期限切れで閉じ、本人に知らせる';
end $$;

\echo '=== 12. 運営から下ろせる（理由は必須） ==='
do $$
declare v_at timestamptz; v_id uuid;
begin
  select at20 into v_at from t;
  perform set_config('test.uid', '39000000-0000-0000-0000-000000000009', false);
  v_id := public.create_guest_request('Apex', v_at, v_at + interval '3 hours', 60);

  insert into public.admins (user_id) values ('39000000-0000-0000-0000-000000000009')
    on conflict do nothing;

  begin
    perform public.admin_remove_guest_request(v_id, '   ');
    raise exception 'NG: 理由なしで下ろせた';
  exception when others then
    if sqlerrm <> 'REASON_REQUIRED' then raise; end if;
  end;

  perform public.admin_remove_guest_request(v_id, '規約に反する内容');
  if (select status from public.guest_requests where id = v_id) <> 'cancelled' then
    raise exception 'NG: cancelled になっていない';
  end if;
  if not exists (select 1 from public.admin_actions
                 where kind = 'guest_request_removed' and target_id = v_id) then
    raise exception 'NG: admin_actions に残っていない';
  end if;
  raise notice 'ok 運営から下ろせて、記録が残る';
end $$;

\echo '=== 39: すべて ok ==='
