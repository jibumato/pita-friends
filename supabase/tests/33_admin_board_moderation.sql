-- ============================================================
-- 33: 募集投稿を運営が取り下げられる（0112・突合表 G21）
--
-- 固定するのは5つ:
--   ・運営以外は一覧も取り下げもできない
--   ・理由なしでは取り下げられない
--   ・行は消えず status=cancelled になり、理由が「運営による取り下げ」と分かる
--   ・投稿者と参加者の双方に通知が届く（投稿者には理由も）
--   ・操作が admin_actions に残る
-- ============================================================
\set ON_ERROR_STOP on

\set poster '33000000-0000-0000-0000-00000000000p'
\set admin  '33000000-0000-0000-0000-0000000000ad'

insert into auth.users (id) values
  ('33000000-0000-0000-0000-000000000001'),  -- 投稿者
  ('33000000-0000-0000-0000-000000000002'),  -- 参加者
  ('33000000-0000-0000-0000-0000000000ad');  -- 運営
insert into public.profiles (id, nickname) values
  ('33000000-0000-0000-0000-000000000001','投稿者'),
  ('33000000-0000-0000-0000-000000000002','参加者'),
  ('33000000-0000-0000-0000-0000000000ad','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('33000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;

-- 0113: 投稿できるのはピタメイトだけ。ピタメイトになるには本人確認が要る
update public.profile_trust_stats set is_verified = true
  where user_id in ('33000000-0000-0000-0000-000000000001',
                    '33000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id, is_host, hourly_rate)
values ('33000000-0000-0000-0000-000000000001', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- ゲストが予約を申し込めるようコインを積む
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('33000000-0000-0000-0000-000000000002','paid',50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id = '33000000-0000-0000-0000-000000000002';

-- 募集を1件立てて、ゲストが1件申し込む
insert into public.board_posts
  (id, creator_id, game, mood, when_text, duration_minutes, vc, audience, verified_only, note)
values
  ('33000000-0000-0000-0000-0000000000b1',
   '33000000-0000-0000-0000-000000000001',
   'Apex', 'エンジョイ', '今夜 22:00〜', 60, 'どちらでも', '全員', false, 'まったりやります');
set test.uid = '33000000-0000-0000-0000-000000000002';
select public.create_booking_from_board('33000000-0000-0000-0000-0000000000b1', 'v1');
-- 申込みで closed になるので、取り下げを試すために open に戻す
-- （運営が取り下げるのは open のものとは限らない。状態にかかわらず効く）
update public.board_posts set status = 'open'
  where id = '33000000-0000-0000-0000-0000000000b1';

-- 通知の件数を数えやすくするため、ここまでの分を消しておく
delete from public.notifications;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 運営以外は触れない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '33000000-0000-0000-0000-000000000001';
do $$
begin
  -- 一覧は _is_admin() が false だと 0件になる(例外ではなく空)
  if exists (select 1 from public.admin_board_posts('all', 50)) then
    raise exception 'FAIL 運営以外に募集の一覧が見えている';
  end if;

  begin
    perform public.admin_remove_board_post(
      '33000000-0000-0000-0000-0000000000b1', '消したい');
    raise exception 'FAIL 運営以外が取り下げられてしまった';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
  raise notice 'OK 一覧は空・取り下げは FORBIDDEN';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 理由は必須 ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '33000000-0000-0000-0000-0000000000ad';
do $$
begin
  begin
    perform public.admin_remove_board_post(
      '33000000-0000-0000-0000-0000000000b1', '   ');
    raise exception 'FAIL 空白だけの理由で取り下げられた';
  exception when others then
    if sqlerrm not like '%REASON_REQUIRED%' then raise; end if;
  end;
  -- 弾かれたあとも、投稿はそのまま
  if (select status from public.board_posts
      where id = '33000000-0000-0000-0000-0000000000b1') <> 'open' then
    raise exception 'FAIL 弾かれたのに状態が変わっている';
  end if;
  raise notice 'OK 理由なしは REASON_REQUIRED で止まる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 取り下げると cancelled になり、理由が残る ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v public.board_posts;
begin
  perform set_config('test.uid','33000000-0000-0000-0000-0000000000ad', false);
  perform public.admin_remove_board_post(
    '33000000-0000-0000-0000-0000000000b1', '外部サービスへの誘導');

  select * into v from public.board_posts where id = '33000000-0000-0000-0000-0000000000b1';

  -- ★行は消さない。通報の裏取りに要る
  if v.id is null then raise exception 'FAIL 行ごと消えている'; end if;
  if v.status <> 'cancelled' then raise exception 'FAIL 状態が cancelled でない: %', v.status; end if;
  if v.cancelled_at is null then raise exception 'FAIL 取り下げ日時が入らない'; end if;
  if v.cancel_reason not like '運営による取り下げ：%' then
    raise exception 'FAIL 運営の取り下げだと分からない: %', v.cancel_reason;
  end if;
  if v.cancel_reason not like '%外部サービスへの誘導%' then
    raise exception 'FAIL 理由が残っていない: %', v.cancel_reason;
  end if;
  raise notice 'OK cancelled + 「%」', v.cancel_reason;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 投稿者と申込者の双方に届く ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_poster text; v_joiner text; v_n int;
begin
  select count(*) into v_n from public.notifications where type = 'board_cancelled';
  if v_n <> 2 then raise exception 'FAIL 通知が2件でない: %', v_n; end if;

  select body into v_poster from public.notifications
    where user_id = '33000000-0000-0000-0000-000000000001' and type = 'board_cancelled';
  select body into v_joiner from public.notifications
    where user_id = '33000000-0000-0000-0000-000000000002' and type = 'board_cancelled';

  if v_poster is null then raise exception 'FAIL 投稿者に届いていない'; end if;
  if v_joiner is null then raise exception 'FAIL 申込者に届いていない'; end if;

  -- ★投稿者には理由を渡す。渡さないと同じ投稿をもう一度出してくる
  if v_poster not like '%外部サービスへの誘導%' then
    raise exception 'FAIL 投稿者への通知に理由が無い: %', v_poster;
  end if;
  -- ★申込者には渡さない。運営の判断の内容を第三者に配らない
  if v_joiner like '%外部サービスへの誘導%' then
    raise exception 'FAIL 申込者への通知に理由が漏れている: %', v_joiner;
  end if;
  raise notice 'OK 投稿者には理由つき / 申込者には理由なし';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 操作記録に残る・二重取り下げは無害 ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from public.admin_actions
    where kind = 'board_post_removed'
      and target_id = '33000000-0000-0000-0000-0000000000b1';
  if v_n <> 1 then raise exception 'FAIL 操作記録が1件でない: %', v_n; end if;

  -- もう一度呼んでも通知は増えない(連打対策)
  perform set_config('test.uid','33000000-0000-0000-0000-0000000000ad', false);
  perform public.admin_remove_board_post(
    '33000000-0000-0000-0000-0000000000b1', '二度目');
  if (select count(*) from public.notifications where type = 'board_cancelled') <> 2 then
    raise exception 'FAIL 二重取り下げで通知が増えた';
  end if;
  raise notice 'OK 操作記録1件・二重取り下げでも増えない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 一覧は取り下げ済みも出せる ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '33000000-0000-0000-0000-0000000000ad';
do $$
declare v_open int; v_all int; r record;
begin
  select count(*) into v_open from public.admin_board_posts('open', 50);
  select count(*) into v_all from public.admin_board_posts('all', 50);
  if v_open <> 0 then raise exception 'FAIL 取り下げ済みが open に出ている: %', v_open; end if;
  if v_all <> 1 then raise exception 'FAIL all で出てこない: %', v_all; end if;

  select * into r from public.admin_board_posts('all', 50) limit 1;
  if r.creator_nickname <> '投稿者' then
    raise exception 'FAIL 投稿者の名前が引けていない: %', r.creator_nickname;
  end if;
  -- 0113: 参加人数ではなく「この募集から入った予約の件数」
  if r.bookings <> 1 then
    raise exception 'FAIL 予約の件数が合わない: %', r.bookings;
  end if;
  raise notice 'OK open=0 / all=1・投稿者名と予約件数が出る';
end $$;

\echo '==== 33: すべて通過 ===='
