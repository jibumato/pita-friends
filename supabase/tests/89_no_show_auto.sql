-- 無断欠席の自動処理(0050)の検証。
--
-- ねらいは「運営が判断しないこと」です。結果を決めるのはゲストの申告ではなく、
-- **ピタメイトの不作為**でなければなりません。したがって重点は:
--   ・ピタメイトが一言でも喋れば無効になるか(救済が効くか)
--   ・ゲストのボタンだけでは何も確定しないか(抜け道になっていないか)
--   ・無反応が続いたときだけ、人手を介さず確定するか

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a3000000-0000-0000-0000-0000000000d1'::uuid),
  ('a3000000-0000-0000-0000-0000000000d2'::uuid),
  ('a3000000-0000-0000-0000-0000000000e1'::uuid),
  ('a3000000-0000-0000-0000-0000000000e2'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('a3000000-0000-0000-0000-0000000000d1'::uuid, '欠席メイト'),
  ('a3000000-0000-0000-0000-0000000000d2'::uuid, '出席メイト'),
  ('a3000000-0000-0000-0000-0000000000e1'::uuid, '欠席ゲスト1'),
  ('a3000000-0000-0000-0000-0000000000e2'::uuid, '欠席ゲスト2')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('a3000000-0000-0000-0000-0000000000d1'::uuid,
                    'a3000000-0000-0000-0000-0000000000d2'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a3000000-0000-0000-0000-0000000000d1'::uuid, true, 1000),
  ('a3000000-0000-0000-0000-0000000000d2'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000, trial_discount_percent = 0;
set app.ledger_override = 'on';
delete from public.coin_lots where user_id in
  ('a3000000-0000-0000-0000-0000000000e1'::uuid, 'a3000000-0000-0000-0000-0000000000e2'::uuid);
reset app.ledger_override;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('a3000000-0000-0000-0000-0000000000e1'::uuid, 'paid', 100000, public.coin_expiry_from(now())),
  ('a3000000-0000-0000-0000-0000000000e2'::uuid, 'paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 100000
  where user_id in ('a3000000-0000-0000-0000-0000000000e1'::uuid,
                    'a3000000-0000-0000-0000-0000000000e2'::uuid);

-- 8時間の予約を作って成立させる(長い予約でも待たされないことが本題)
set test.uid = 'a3000000-0000-0000-0000-0000000000e1';
select public.create_booking('a3000000-0000-0000-0000-0000000000d1'::uuid, 480, 'v3', null) as n1 \gset
set test.n1 = :'n1';
set test.uid = 'a3000000-0000-0000-0000-0000000000d1';
select public.approve_booking(:'n1');

\echo '=== 1. 開始前はチェックインできない ==='
do $$
begin
  update public.bookings set scheduled_at = now() + interval '1 hour'
    where id = current_setting('test.n1', true)::uuid;
  perform public.check_in_booking(current_setting('test.n1', true)::uuid);
  raise exception 'FAIL 開始前に押せてしまった';
exception when others then
  if sqlerrm <> 'NOT_STARTED_YET' then raise; end if;
  raise notice 'OK 開始前のチェックインは NOT_STARTED_YET';
end $$;

\echo '=== 2. ゲストだけがチェックインしても、その場では何も起きない ==='
-- 20分前に始まったことにする(猶予15分を過ぎている)
update public.bookings set scheduled_at = now() - interval '20 minutes'
  where id = :'n1';
set test.uid = 'a3000000-0000-0000-0000-0000000000e1';
select public.check_in_booking(:'n1');
do $$
declare v_b public.bookings;
begin
  select * into v_b from public.bookings where id = current_setting('test.n1', true)::uuid;
  if v_b.guest_checked_in_at is null then raise exception 'FAIL チェックインが記録されていない'; end if;
  if v_b.held_at is not null then raise exception 'FAIL 押した瞬間に保留されてしまった'; end if;
  if v_b.status <> 'confirmed' then raise exception 'FAIL 状態が変わってしまった: %', v_b.status; end if;
  raise notice 'OK ゲストのチェックインは記録されるだけ。押した瞬間には何も確定しない';
end $$;

\echo '=== 3. ★開始+15分の自動判定で保留される(8時間待たない) ==='
do $$
declare v_n int; v_b public.bookings;
begin
  v_n := public.auto_hold_no_show_bookings();
  select * into v_b from public.bookings where id = current_setting('test.n1', true)::uuid;
  if v_b.held_at is null or v_b.hold_reason <> 'no_show' then
    raise exception 'FAIL 保留されていない(held=% reason=%)', v_b.held_at, v_b.hold_reason;
  end if;
  raise notice 'OK 8時間の予約でも、開始20分後には保留されてお金が止まる(% 件)', v_n;
end $$;

\echo '=== 4. 両者に通知が飛ぶ(ピタメイトには「まだ間に合う」と伝える) ==='
do $$
declare v_host int; v_guest int;
begin
  select count(*) into v_host from public.notifications
    where user_id = 'a3000000-0000-0000-0000-0000000000d1'::uuid and type = 'booking_no_show';
  select count(*) into v_guest from public.notifications
    where user_id = 'a3000000-0000-0000-0000-0000000000e1'::uuid and type = 'booking_no_show';
  if v_host < 1 then raise exception 'FAIL ピタメイトに通知が飛んでいない'; end if;
  if v_guest < 1 then raise exception 'FAIL ゲストに通知が飛んでいない'; end if;
  raise notice 'OK ピタメイト%件・ゲスト%件に通知した', v_host, v_guest;
end $$;

\echo '=== 5. 保留中は自動確定されない(報酬が動かない) ==='
do $$
declare v_earned int;
begin
  update public.bookings set scheduled_at = now() - interval '200 hours'
    where id = current_setting('test.n1', true)::uuid;
  perform public.auto_complete_bookings();
  select earned_balance into v_earned from public.coin_wallets
    where user_id = 'a3000000-0000-0000-0000-0000000000d1'::uuid;
  if coalesce(v_earned, 0) <> 0 then
    raise exception 'FAIL 保留中なのに報酬が入った: %', v_earned;
  end if;
  raise notice 'OK 保留中は72時間を過ぎても確定しない';
end $$;

\echo '=== 6. ★ピタメイトがチェックインすれば自動で解除される(運営不要) ==='
set test.uid = 'a3000000-0000-0000-0000-0000000000d1';
select public.check_in_booking(:'n1');
do $$
declare v_b public.bookings;
begin
  select * into v_b from public.bookings where id = current_setting('test.n1', true)::uuid;
  if v_b.held_at is not null then raise exception 'FAIL 保留が解除されていない'; end if;
  if v_b.host_checked_in_at is null then raise exception 'FAIL チェックインが記録されていない'; end if;
  raise notice 'OK ピタメイト本人が現れれば、人手を介さず保留が解ける';
end $$;

\echo '=== 7. 解除後は通常どおり自動確定する ==='
do $$
declare v_st text;
begin
  perform public.auto_complete_bookings();
  select status into v_st from public.bookings where id = current_setting('test.n1', true)::uuid;
  if v_st <> 'completed' then raise exception 'FAIL 解除後に確定しない: %', v_st; end if;
  raise notice 'OK 解除後は通常フローに戻る';
end $$;

\echo '=== 8. ★メッセージ1通でもチェックイン扱いになる(押し忘れの救済) ==='
set test.uid = 'a3000000-0000-0000-0000-0000000000e2';
select public.create_booking('a3000000-0000-0000-0000-0000000000d2'::uuid, 480, 'v3', null) as n2 \gset
set test.n2 = :'n2';
set test.uid = 'a3000000-0000-0000-0000-0000000000d2';
select public.approve_booking(:'n2') as pr2 \gset
set test.pr2 = :'pr2';
update public.bookings set scheduled_at = now() - interval '20 minutes' where id = :'n2';

set test.uid = 'a3000000-0000-0000-0000-0000000000e2';
select public.check_in_booking(:'n2');
do $$
begin
  perform public.auto_hold_no_show_bookings();
  if (select hold_reason from public.bookings
      where id = current_setting('test.n2', true)::uuid) <> 'no_show' then
    raise exception 'FAIL 前提が崩れた(保留されていない)';
  end if;
end $$;

set test.uid = 'a3000000-0000-0000-0000-0000000000d2';
insert into public.messages (promise_id, sender_id, body)
values (current_setting('test.pr2', true)::uuid,
        'a3000000-0000-0000-0000-0000000000d2'::uuid, 'ごめん、いま入ります');
do $$
declare v_b public.bookings;
begin
  select * into v_b from public.bookings where id = current_setting('test.n2', true)::uuid;
  if v_b.host_checked_in_at is null then
    raise exception 'FAIL メッセージでチェックイン扱いになっていない';
  end if;
  if v_b.held_at is not null then
    raise exception 'FAIL メッセージで保留が解けていない';
  end if;
  raise notice 'OK ボタンを押し忘れても、メッセージ1通で救われる';
end $$;

\echo '=== 9. ★無反応が続いたら、人手なしで無断欠席が確定して全額戻る ==='
set test.uid = 'a3000000-0000-0000-0000-0000000000e1';
select public.create_booking('a3000000-0000-0000-0000-0000000000d1'::uuid, 480, 'v3',
  date_trunc('hour', now()) + interval '3 days') as n3 \gset
set test.n3 = :'n3';
set test.uid = 'a3000000-0000-0000-0000-0000000000d1';
select public.approve_booking(:'n3');
update public.bookings set scheduled_at = now() - interval '20 minutes' where id = :'n3';
set test.uid = 'a3000000-0000-0000-0000-0000000000e1';
select public.check_in_booking(:'n3');

do $$
declare v_before int; v_after int; v_st text; v_dota int; v_n int;
begin
  perform public.auto_hold_no_show_bookings();

  select balance into v_before from public.coin_wallets
    where user_id = 'a3000000-0000-0000-0000-0000000000e1'::uuid;
  select dotakyan_count into v_dota from public.profile_trust_stats
    where user_id = 'a3000000-0000-0000-0000-0000000000d1'::uuid;

  -- 24時間より前に保留したことにする
  update public.bookings set held_at = now() - interval '30 hours'
    where id = current_setting('test.n3', true)::uuid;

  v_n := public.auto_resolve_no_show_bookings();

  select status into v_st from public.bookings where id = current_setting('test.n3', true)::uuid;
  select balance into v_after from public.coin_wallets
    where user_id = 'a3000000-0000-0000-0000-0000000000e1'::uuid;

  if v_st <> 'no_show_host' then raise exception 'FAIL 無断欠席にならない: %', v_st; end if;
  if v_after - v_before <> 8000 then
    raise exception 'FAIL 全額戻っていない(期待8000 / 実際%)', v_after - v_before;
  end if;
  if (select dotakyan_count from public.profile_trust_stats
      where user_id = 'a3000000-0000-0000-0000-0000000000d1'::uuid) <> v_dota + 1 then
    raise exception 'FAIL ドタキャン記録が付いていない';
  end if;
  raise notice 'OK 無反応24時間で自動確定。%コイン全額返還+ドタキャン記録(% 件)', v_after - v_before, v_n;
end $$;

\echo '=== 10. 猶予の内側では保留しない ==='
set test.uid = 'a3000000-0000-0000-0000-0000000000e2';
select public.create_booking('a3000000-0000-0000-0000-0000000000d2'::uuid, 60, 'v3',
  date_trunc('hour', now()) + interval '5 days') as n4 \gset
set test.n4 = :'n4';
set test.uid = 'a3000000-0000-0000-0000-0000000000d2';
select public.approve_booking(:'n4');
update public.bookings set scheduled_at = now() - interval '5 minutes' where id = :'n4';
set test.uid = 'a3000000-0000-0000-0000-0000000000e2';
select public.check_in_booking(:'n4');
do $$
begin
  perform public.auto_hold_no_show_bookings();
  if (select held_at from public.bookings
      where id = current_setting('test.n4', true)::uuid) is not null then
    raise exception 'FAIL 猶予(15分)の内側で保留してしまった';
  end if;
  raise notice 'OK 開始5分後はまだ保留しない(猶予15分)';
end $$;

\echo '=== 11. ゲストが押していなければ保留もしない(片側だけでは動かない) ==='
do $$
begin
  update public.bookings set guest_checked_in_at = null,
                             scheduled_at = now() - interval '60 minutes'
    where id = current_setting('test.n4', true)::uuid;
  perform public.auto_hold_no_show_bookings();
  if (select held_at from public.bookings
      where id = current_setting('test.n4', true)::uuid) is not null then
    raise exception 'FAIL ゲストの申告なしに保留してしまった';
  end if;
  raise notice 'OK ゲストのチェックインが無ければ、この仕組みは発動しない';
end $$;

\echo '=== 12. 当事者以外はチェックインできない ==='
set test.uid = 'a3000000-0000-0000-0000-0000000000e1';
do $$
begin
  perform public.check_in_booking(current_setting('test.n4', true)::uuid);
  raise exception 'FAIL 無関係な人が押せてしまった';
exception when others then
  if sqlerrm <> 'FORBIDDEN' then raise; end if;
  raise notice 'OK 当事者以外は FORBIDDEN';
end $$;

\echo '=== 13. 画面用の状態が取れる ==='
set test.uid = 'a3000000-0000-0000-0000-0000000000e2';
do $$
declare v_s jsonb;
begin
  v_s := public.my_booking_checkin_state(current_setting('test.n4', true)::uuid);
  if (v_s->>'started')::boolean is not true then raise exception 'FAIL 開始判定が違う: %', v_s; end if;
  if (v_s->>'i_am_guest')::boolean is not true then raise exception 'FAIL 立場の判定が違う: %', v_s; end if;
  if (v_s->>'grace_minutes')::int <> 15 then raise exception 'FAIL 猶予が違う: %', v_s; end if;
  raise notice 'OK 画面用の状態: %', v_s;
end $$;

\echo '=== 完了 ==='
