-- ============================================================
-- 70: 募集の取り消し
--
-- 0113 で募集板が「ピタメイトが空き枠を告知する場」になり、
-- **無料の参加表明が無くなった**ので、取り消しの通知先も
-- 「参加表明した人」から「この募集から予約を申し込んだゲスト」に変わった。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('d1111111-1111-1111-1111-111111111111'),
  ('d2222222-2222-2222-2222-222222222222'),
  ('d3333333-3333-3333-3333-333333333333');
insert into public.profiles (id, nickname) values
  ('d1111111-1111-1111-1111-111111111111','ぬし'),
  ('d2222222-2222-2222-2222-222222222222','ゲスト1'),
  ('d3333333-3333-3333-3333-333333333333','ゲスト2')
  on conflict (id) do update set nickname = excluded.nickname;
-- ★投稿者も本人確認が要る。ピタメイトになること自体が
--   本人確認済みを条件にしている(check_host_requires_verification)ので、
--   0113 の「投稿できるのはピタメイトだけ」は
--   **「本人確認を済ませたピタメイトだけ」と同じ意味になる。**
update public.profile_trust_stats set is_verified = true
  where user_id in ('d1111111-1111-1111-1111-111111111111',
                    'd2222222-2222-2222-2222-222222222222',
                    'd3333333-3333-3333-3333-333333333333');

-- 投稿者はピタメイトでなければならない(0113)
insert into public.host_settings (user_id, is_host, hourly_rate)
values ('d1111111-1111-1111-1111-111111111111', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- ゲストにコインを積む(予約に要る)
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('d2222222-2222-2222-2222-222222222222','paid',50000, public.coin_expiry_from(now())),
  ('d3333333-3333-3333-3333-333333333333','paid',50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id in ('d2222222-2222-2222-2222-222222222222','d3333333-3333-3333-3333-333333333333');

set test.uid = 'd1111111-1111-1111-1111-111111111111';
insert into public.board_posts (creator_id, game, when_text, duration_minutes, verified_only)
values ('d1111111-1111-1111-1111-111111111111','Apex','今夜 22:00〜', 60, true)
returning id as pid \gset

\echo '=== ピタメイトでない人は投稿できない(HOST_ONLY) ==='
do $$ begin
  perform set_config('test.uid','d2222222-2222-2222-2222-222222222222', false);
  begin
    insert into public.board_posts (creator_id, game, when_text)
    values ('d2222222-2222-2222-2222-222222222222','Apex','明日');
    raise exception 'NG: ゲストが募集を出せてしまった';
  exception when others then
    if sqlerrm not like '%HOST_ONLY%' then raise; end if;
    raise notice 'OK: ゲストの投稿は HOST_ONLY で止まる';
  end;
end $$;

\echo '=== 募集から予約を申し込む ==='
do $$
declare v_id uuid;
begin
  perform set_config('test.uid','d2222222-2222-2222-2222-222222222222', false);
  v_id := public.create_booking_from_board(
    (select id from public.board_posts where status <> 'cancelled' limit 1), 'v1');

  if (select from_board_post_id from public.bookings where id = v_id) is null then
    raise exception 'NG: 予約が募集に紐づいていない';
  end if;
  -- 1募集=1枠。申込みが入ったら板から下りる
  if (select status from public.board_posts
      where id = (select from_board_post_id from public.bookings where id = v_id)) <> 'closed' then
    raise exception 'NG: 申込みが入っても募集が open のまま';
  end if;
  raise notice 'OK: 予約が紐づき、募集は closed になる';
end $$;

\echo '=== 締め切った募集には申し込めない(POST_NOT_OPEN) ==='
do $$ begin
  perform set_config('test.uid','d3333333-3333-3333-3333-333333333333', false);
  begin
    perform public.create_booking_from_board(
      (select id from public.board_posts limit 1), 'v1');
    raise exception 'NG: closed の募集に申し込めてしまった';
  exception when others then
    if sqlerrm not like '%POST_NOT_OPEN%' then raise; end if;
    raise notice 'OK: POST_NOT_OPEN で止まる';
  end;
end $$;

\echo '=== 自分の募集には申し込めない(CANNOT_BOOK_OWN_POST) ==='
do $$
declare v_pid uuid;
begin
  perform set_config('test.uid','d1111111-1111-1111-1111-111111111111', false);
  insert into public.board_posts (creator_id, game, when_text, duration_minutes)
  values ('d1111111-1111-1111-1111-111111111111','スプラ','明日 21:00〜', 60)
  returning id into v_pid;

  begin
    perform public.create_booking_from_board(v_pid, 'v1');
    raise exception 'NG: 自分の募集に申し込めてしまった';
  exception when others then
    if sqlerrm not like '%CANNOT_BOOK_OWN_POST%' then raise; end if;
    raise notice 'OK: CANNOT_BOOK_OWN_POST で止まる';
  end;
end $$;

\echo '=== 他人は取り消せない(ONLY_CREATOR_CAN_CANCEL) ==='
do $$ begin
  perform set_config('test.uid','d2222222-2222-2222-2222-222222222222', false);
  begin
    perform public.cancel_board_post((select id from public.board_posts limit 1), 'いたずら');
    raise exception 'NG: 他人が取り消せてしまった';
  exception when others then
    if sqlerrm not like '%ONLY_CREATOR_CAN_CANCEL%' then raise; end if;
    raise notice 'OK: 他人の取り消しは拒否された';
  end;
end $$;

\echo '=== 作成者が取り消すと、申し込んだゲストに届く ==='
do $$
declare v_pid uuid; v_body text;
begin
  select from_board_post_id into v_pid from public.bookings
    where from_board_post_id is not null limit 1;

  perform set_config('test.uid','d1111111-1111-1111-1111-111111111111', false);
  perform public.cancel_board_post(v_pid, '体調不良のため');

  if (select status from public.board_posts where id = v_pid) <> 'cancelled' then
    raise exception 'NG: 取り消しても cancelled にならない';
  end if;

  select body into v_body from public.notifications
    where user_id = 'd2222222-2222-2222-2222-222222222222' and type = 'board_cancelled';
  if v_body is null then
    raise exception 'NG: 申し込んだゲストに届いていない';
  end if;
  -- ★予約は消さない。キャンセルは第9条の規定に乗せる
  if v_body not like '%予約はそのまま%' then
    raise exception 'NG: 予約が残ることを伝えていない: %', v_body;
  end if;
  if (select count(*) from public.bookings where from_board_post_id = v_pid
      and status in ('requested','approved')) <> 1 then
    raise exception 'NG: 募集の取り消しで予約まで消えている';
  end if;
  raise notice 'OK: ゲストに届き、予約はそのまま残る';
end $$;

\echo '=== 二重取り消しで通知が増えない(連打対策) ==='
do $$
declare v_pid uuid; v_n int;
begin
  select id into v_pid from public.board_posts where status = 'cancelled' limit 1;
  select count(*) into v_n from public.notifications where type = 'board_cancelled';
  perform set_config('test.uid','d1111111-1111-1111-1111-111111111111', false);
  perform public.cancel_board_post(v_pid, 'again');
  if (select count(*) from public.notifications where type = 'board_cancelled') <> v_n then
    raise exception 'NG: 二重取り消しで通知が増えた';
  end if;
  raise notice 'OK: 増えない';
end $$;

\echo '=== 直接UPDATEのポリシーが外れているか ==='
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_policies
    where schemaname='public' and tablename='board_posts' and cmd='UPDATE';
  if v_n <> 0 then
    raise exception 'NG: board_posts に UPDATE ポリシーが残っている(%)', v_n;
  end if;
  raise notice 'OK: authenticated からは1行も更新できない';
end $$;

\echo '==== 70: すべて通過 ===='

-- ============================================================
-- 0114: 受付の範囲
-- ============================================================
\echo '=== 範囲を指定した募集は、その中でしか申し込めない ==='
do $$
declare v_pid uuid; v_from timestamptz; v_to timestamptz;
begin
  -- 明日の 20:00〜24:00 で募集する
  v_from := date_trunc('day', now()) + interval '1 day 20 hours';
  v_to   := date_trunc('day', now()) + interval '2 days';

  perform set_config('test.uid','d1111111-1111-1111-1111-111111111111', false);
  insert into public.board_posts
    (creator_id, game, when_text, duration_minutes, window_start, window_end)
  values ('d1111111-1111-1111-1111-111111111111','Apex','', 60, v_from, v_to)
  returning id into v_pid;

  perform set_config('test.uid','d3333333-3333-3333-3333-333333333333', false);

  -- 範囲より前
  begin
    perform public.create_booking_from_board(v_pid, 'v1', v_from - interval '1 hour');
    raise exception 'NG: 範囲より前で申し込めた';
  exception when others then
    if sqlerrm not like '%OUTSIDE_BOARD_WINDOW%' then raise; end if;
  end;

  -- ★開始は範囲内だが、終了がはみ出す。告知した時間を超えるので通さない
  begin
    perform public.create_booking_from_board(v_pid, 'v1', v_to - interval '30 minutes');
    raise exception 'NG: 終了が範囲からはみ出しても申し込めた';
  exception when others then
    if sqlerrm not like '%OUTSIDE_BOARD_WINDOW%' then raise; end if;
  end;

  -- 開始時刻を渡さない
  begin
    perform public.create_booking_from_board(v_pid, 'v1', null);
    raise exception 'NG: 開始時刻なしで申し込めた';
  exception when others then
    if sqlerrm not like '%START_TIME_REQUIRED%' then raise; end if;
  end;

  -- 範囲にきっちり収まる
  perform public.create_booking_from_board(v_pid, 'v1', v_from);
  if (select status from public.board_posts where id = v_pid) <> 'closed' then
    raise exception 'NG: 申込みが通ったのに closed にならない';
  end if;
  raise notice 'OK: 前後・はみ出し・時刻なしは弾き、収まるものだけ通す';
end $$;

\echo '=== 相談で（範囲なし）は時刻を選ばなくても申し込める ==='
-- ここまでの予約で d1 の枠が埋まっているので、別のピタメイトを立てる
insert into auth.users (id) values ('d4444444-4444-4444-4444-444444444444');
insert into public.profiles (id, nickname) values
  ('d4444444-4444-4444-4444-444444444444','ぬし2')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'd4444444-4444-4444-4444-444444444444';
insert into public.host_settings (user_id, is_host, hourly_rate)
values ('d4444444-4444-4444-4444-444444444444', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

do $$
declare v_pid uuid; v_id uuid;
begin
  perform set_config('test.uid','d4444444-4444-4444-4444-444444444444', false);
  insert into public.board_posts (creator_id, game, when_text, duration_minutes)
  values ('d4444444-4444-4444-4444-444444444444','スプラ','', 60)
  returning id into v_pid;

  -- ゲストも枠が埋まっているので、新しいゲストを立てる
  insert into auth.users (id) values ('d5555555-5555-5555-5555-555555555555');
  insert into public.profiles (id, nickname) values
    ('d5555555-5555-5555-5555-555555555555','ゲスト3')
    on conflict (id) do nothing;
  update public.profile_trust_stats set is_verified = true
    where user_id = 'd5555555-5555-5555-5555-555555555555';
  insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('d5555555-5555-5555-5555-555555555555','paid',50000, public.coin_expiry_from(now()));
  update public.coin_wallets set balance = 50000
    where user_id = 'd5555555-5555-5555-5555-555555555555';

  perform set_config('test.uid','d5555555-5555-5555-5555-555555555555', false);
  v_id := public.create_booking_from_board(v_pid, 'v1');
  if v_id is null then raise exception 'NG: 相談での募集に申し込めない'; end if;
  raise notice 'OK: 範囲なしなら「今すぐ」でも通る';
end $$;

\echo '=== 片方だけの範囲は作れない ==='
do $$ begin
  perform set_config('test.uid','d1111111-1111-1111-1111-111111111111', false);
  begin
    insert into public.board_posts
      (creator_id, game, when_text, window_start)
    values ('d1111111-1111-1111-1111-111111111111','Apex','', now() + interval '1 day');
    raise exception 'NG: 開始だけの範囲が作れてしまった';
  exception when others then
    if sqlerrm not like '%board_posts_window_pair%' then raise; end if;
    raise notice 'OK: 片方だけは CHECK で止まる';
  end;
end $$;

\echo '=== 締め切りを過ぎた募集は閉じる ==='
do $$
declare v_pid uuid; v_n int;
begin
  perform set_config('test.uid','d1111111-1111-1111-1111-111111111111', false);
  insert into public.board_posts
    (creator_id, game, when_text, duration_minutes, window_start, window_end)
  values ('d1111111-1111-1111-1111-111111111111','モンハン','', 60,
          now() + interval '1 hour', now() + interval '3 hours')
  returning id into v_pid;

  -- 時間の経過を作る（cron を待てないので締め切りを過去に倒す）
  update public.board_posts
    set window_start = now() - interval '3 hours', window_end = now() - interval '1 hour'
    where id = v_pid;

  perform set_config('test.uid','', false);
  v_n := public.close_expired_board_posts();
  if v_n < 1 then raise exception 'NG: 1件も閉じられていない'; end if;
  if (select status from public.board_posts where id = v_pid) <> 'closed' then
    raise exception 'NG: 締め切りを過ぎても open のまま';
  end if;
  -- ★cancelled にはしない。投稿者が下ろしたわけではない
  if (select cancelled_at from public.board_posts where id = v_pid) is not null then
    raise exception 'NG: 取り消し扱いになっている';
  end if;
  raise notice 'OK: closed になり、取り消し扱いにはならない';
end $$;

\echo '==== 70(0114分): すべて通過 ===='
