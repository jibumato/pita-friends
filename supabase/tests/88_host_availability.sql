-- ピタメイトの募集枠と公開スケジュール(0051)の検証。
--
-- これまで「いつ遊べるのか」を表す情報がどこにもなく、空いている時間が
-- 「募集しているから空いている」のか「そもそも出ていない」のか区別できません
-- でした。深夜3時に申し込んでよいのか、ゲストには分かりません。
--
-- 重点は「枠を設定していないピタメイトを締め出さないこと」です。
-- いきなり予約不可にすると、既存のピタメイトが黙って消えます。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a4000000-0000-0000-0000-0000000000f1'::uuid),
  ('a4000000-0000-0000-0000-0000000000f2'::uuid),
  ('a4000000-0000-0000-0000-0000000000f9'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('a4000000-0000-0000-0000-0000000000f1'::uuid, '枠ありメイト'),
  ('a4000000-0000-0000-0000-0000000000f2'::uuid, '枠なしメイト'),
  ('a4000000-0000-0000-0000-0000000000f9'::uuid, '枠ゲスト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('a4000000-0000-0000-0000-0000000000f1'::uuid,
                    'a4000000-0000-0000-0000-0000000000f2'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a4000000-0000-0000-0000-0000000000f1'::uuid, true, 1000),
  ('a4000000-0000-0000-0000-0000000000f2'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000, trial_discount_percent = 0;
set app.ledger_override = 'on';
delete from public.coin_lots where user_id = 'a4000000-0000-0000-0000-0000000000f9'::uuid;
reset app.ledger_override;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('a4000000-0000-0000-0000-0000000000f9'::uuid, 'paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 100000
  where user_id = 'a4000000-0000-0000-0000-0000000000f9'::uuid;

\echo '=== 1. 枠を1つも設定していなければ「いつでも可」 ==='
do $$
begin
  if public.host_has_availability('a4000000-0000-0000-0000-0000000000f2'::uuid) then
    raise exception 'FAIL 前提が崩れた';
  end if;
  if not public.host_is_open_at('a4000000-0000-0000-0000-0000000000f2'::uuid,
       now() + interval '3 days') then
    raise exception 'FAIL 未設定のピタメイトが閉じている扱いになった';
  end if;
  raise notice 'OK 未設定のピタメイトは従来どおり、いつでも受け付ける';
end $$;

\echo '=== 2. 全曜日の20時台だけ募集する設定を保存できる ==='
set test.uid = 'a4000000-0000-0000-0000-0000000000f1';
do $$
declare v_n int; v_slots jsonb := '[]'::jsonb;
begin
  for i in 0..6 loop
    v_slots := v_slots || jsonb_build_array(jsonb_build_object('weekday', i, 'hour', 20));
    v_slots := v_slots || jsonb_build_array(jsonb_build_object('weekday', i, 'hour', 21));
  end loop;
  v_n := public.set_host_availability(v_slots);
  if v_n <> 14 then raise exception 'FAIL 保存件数が合わない: %', v_n; end if;
  raise notice 'OK 7曜日 × 20時台/21時台 = %枠を保存した', v_n;
end $$;

\echo '=== 3. 保存は「置き換え」で、前の設定が残らない ==='
do $$
declare v_n int;
begin
  v_n := public.set_host_availability('[{"weekday":3,"hour":10}]'::jsonb);
  select count(*) into v_n from public.host_availability
    where user_id = 'a4000000-0000-0000-0000-0000000000f1'::uuid;
  if v_n <> 1 then raise exception 'FAIL 前の設定が残っている: %件', v_n; end if;
  raise notice 'OK 保存は全体の置き換え(前の14枠は消えた)';
end $$;

-- 以降のテスト用に、全曜日の20〜22時台を開けておく
do $$
declare v_slots jsonb := '[]'::jsonb;
begin
  for i in 0..6 loop
    for h in 20..22 loop
      v_slots := v_slots || jsonb_build_array(jsonb_build_object('weekday', i, 'hour', h));
    end loop;
  end loop;
  perform public.set_host_availability(v_slots);
end $$;

\echo '=== 4. 曜日・時は日本時間で解釈される ==='
do $$
declare v_at timestamptz;
begin
  -- 日本時間の明日20:30
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '1 day'
           + interval '20 hours 30 minutes') at time zone 'Asia/Tokyo';
  if not public.host_is_open_at('a4000000-0000-0000-0000-0000000000f1'::uuid, v_at) then
    raise exception 'FAIL 日本時間の20時台が開いていない';
  end if;
  -- 日本時間の明日3:00 は閉じている
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '1 day'
           + interval '3 hours') at time zone 'Asia/Tokyo';
  if public.host_is_open_at('a4000000-0000-0000-0000-0000000000f1'::uuid, v_at) then
    raise exception 'FAIL 深夜3時が開いている扱いになった';
  end if;
  raise notice 'OK 曜日・時は日本時間で判定される';
end $$;

\echo '=== 5. ★募集していない時間には申し込めない ==='
set test.uid = 'a4000000-0000-0000-0000-0000000000f9';
do $$
declare v_at timestamptz;
begin
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '2 days'
           + interval '3 hours') at time zone 'Asia/Tokyo';
  perform public.create_booking('a4000000-0000-0000-0000-0000000000f1'::uuid, 60, 'v3', v_at);
  raise exception 'FAIL 募集枠の外を予約できてしまった';
exception when others then
  if sqlerrm <> 'HOST_NOT_OPEN' then raise; end if;
  raise notice 'OK 募集枠の外は HOST_NOT_OPEN';
end $$;

\echo '=== 6. 募集枠の中なら申し込める(:30開始もできる) ==='
do $$
declare v_at timestamptz; v_b uuid;
begin
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '2 days'
           + interval '20 hours 30 minutes') at time zone 'Asia/Tokyo';
  v_b := public.create_booking('a4000000-0000-0000-0000-0000000000f1'::uuid, 60, 'v3', v_at);
  if v_b is null then raise exception 'FAIL 枠内なのに予約できない'; end if;
  perform set_config('test.ok1', v_b::text, false);
  raise notice 'OK 20:30開始・1時間(20時台と21時台をまたぐ)は取れる';
end $$;

\echo '=== 7. ★プレイ時間が枠からはみ出す場合は弾く ==='
do $$
declare v_at timestamptz;
begin
  -- 22:00から2時間 → 23時台が閉じているのではみ出す
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '3 days'
           + interval '22 hours') at time zone 'Asia/Tokyo';
  perform public.create_booking('a4000000-0000-0000-0000-0000000000f1'::uuid, 120, 'v3', v_at);
  raise exception 'FAIL 枠からはみ出す予約が通ってしまった';
exception when others then
  if sqlerrm <> 'HOST_NOT_OPEN' then raise; end if;
  raise notice 'OK 終わりが枠を越える予約も HOST_NOT_OPEN(全体が収まる必要がある)';
end $$;

\echo '=== 8. 枠を設定していないピタメイトは、深夜でも予約できる ==='
do $$
declare v_at timestamptz; v_b uuid;
begin
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '4 days'
           + interval '3 hours') at time zone 'Asia/Tokyo';
  v_b := public.create_booking('a4000000-0000-0000-0000-0000000000f2'::uuid, 60, 'v3', v_at);
  if v_b is null then raise exception 'FAIL 未設定のピタメイトが予約できない'; end if;
  raise notice 'OK 枠を設定していないピタメイトは締め出されない';
end $$;

\echo '=== 9. ★公開スケジュールが4つの状態で返る ==='
do $$
declare v_open int; v_closed int; v_booked int; v_past int; v_total int;
begin
  select count(*) filter (where state = 'open'),
         count(*) filter (where state = 'closed'),
         count(*) filter (where state = 'booked'),
         count(*) filter (where state = 'past'),
         count(*)
    into v_open, v_closed, v_booked, v_past, v_total
  from public.host_schedule('a4000000-0000-0000-0000-0000000000f1'::uuid, 7);

  if v_total <> 168 then raise exception 'FAIL 7日×24時間になっていない: %', v_total; end if;
  if v_booked < 1 then raise exception 'FAIL 予約済みの枠が出ていない'; end if;
  if v_open < 1 then raise exception 'FAIL 募集中の枠が出ていない'; end if;
  if v_closed < 1 then raise exception 'FAIL 募集していない枠が出ていない'; end if;
  raise notice 'OK 168枠: 募集中% / 予約済% / 募集外% / 過去%', v_open, v_booked, v_closed, v_past;
end $$;

\echo '=== 10. 予約が入った枠は booked になり、open ではなくなる ==='
do $$
declare v_state text; v_at timestamptz;
begin
  v_at := (date_trunc('day', (now() at time zone 'Asia/Tokyo')) + interval '2 days'
           + interval '21 hours') at time zone 'Asia/Tokyo';
  select state into v_state from public.host_schedule('a4000000-0000-0000-0000-0000000000f1'::uuid, 7)
    where slot_at = v_at;
  if v_state <> 'booked' then
    raise exception 'FAIL 予約が入っている枠が booked でない: %', v_state;
  end if;
  raise notice 'OK 20:30〜21:30 の予約により、21時台は booked になる';
end $$;

\echo '=== 11. 誰でも他人のスケジュールを見られる(タイル表示の土台) ==='
set test.uid = 'a4000000-0000-0000-0000-0000000000f2';
do $$
declare v_n int;
begin
  select count(*) into v_n from public.host_schedule('a4000000-0000-0000-0000-0000000000f1'::uuid, 7);
  if v_n <> 168 then raise exception 'FAIL 他人のスケジュールが見えない: %', v_n; end if;
  select count(*) into v_n from public.host_availability
    where user_id = 'a4000000-0000-0000-0000-0000000000f1'::uuid;
  if v_n < 1 then raise exception 'FAIL 他人の募集枠が読めない'; end if;
  raise notice 'OK 他人の募集枠・スケジュールは誰でも読める';
end $$;

\echo '=== 12. 書き込みは本人に限られている(ポリシーの確認) ==='
-- テストは superuser で流れるため RLS が素通りする。ここではポリシーの
-- 定義そのものを見る(他のテストでも同じやり方をしている)。
do $$
declare v_qual text; v_check text;
begin
  select qual, with_check into v_qual, v_check from pg_policies
    where tablename = 'host_availability' and policyname = 'host_availability_write_own';
  if v_qual is null then raise exception 'FAIL 書き込みポリシーが無い'; end if;
  if v_qual not like '%auth.uid()%' or v_check not like '%auth.uid()%' then
    raise exception 'FAIL 本人限定になっていない(using=% check=%)', v_qual, v_check;
  end if;
  if not exists (select 1 from pg_policies
                 where tablename = 'host_availability'
                   and policyname = 'host_availability_select_all' and cmd = 'SELECT') then
    raise exception 'FAIL 閲覧ポリシーが無い(誰でも見られる必要がある)';
  end if;
  raise notice 'OK 閲覧は全員・書き込みは本人のみ';
end $$;

\echo '=== 13. 「いま募集中か」が取れる ==='
do $$
declare v_now boolean;
begin
  -- 枠を設定していないピタメイトは常に募集中(直近に予約が無ければ)
  v_now := public.host_open_now('a4000000-0000-0000-0000-0000000000f2'::uuid);
  if v_now is null then raise exception 'FAIL 判定が取れない'; end if;
  raise notice 'OK いま募集中か = %(枠未設定のピタメイト)', v_now;
end $$;

\echo '=== 完了 ==='
