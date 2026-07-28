-- 「この人とは何回遊んだか」(0055)の検証。
--
-- 重点は**他人同士の回数が引けないこと**。自分が関わっていない予約まで
-- 数えると、誰と誰が繰り返し遊んでいるかが外から読めてしまう。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('e6000000-0000-0000-0000-000000000001'::uuid),  -- 自分(ゲスト)
  ('e6000000-0000-0000-0000-000000000009'::uuid),  -- 相手(ピタメイト)
  ('e6000000-0000-0000-0000-00000000000c'::uuid)   -- 無関係の第三者
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('e6000000-0000-0000-0000-000000000001'::uuid, '自分'),
  ('e6000000-0000-0000-0000-000000000009'::uuid, '相手'),
  ('e6000000-0000-0000-0000-00000000000c'::uuid, '第三者')
on conflict (id) do update set nickname = excluded.nickname;

\echo '=== 1. 一度も遊んでいなければ0 ==='
set test.uid = 'e6000000-0000-0000-0000-000000000001';
do $$
begin
  if (public.my_play_history_with('e6000000-0000-0000-0000-000000000009'::uuid)->>'count')::int <> 0 then
    raise exception 'FAIL: 遊んでいないのに0でない';
  end if;
  if public.my_play_history_with('e6000000-0000-0000-0000-000000000009'::uuid)->>'last_played_at' is not null then
    raise exception 'FAIL: 遊んでいないのに最終日が入っている';
  end if;
end $$;

\echo '=== 2. 完了した予約だけを数える ==='
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at) values
  ('e6000000-0000-0000-0000-000000000001'::uuid, 'e6000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'completed', now() - interval '10 days', now() - interval '10 days'),
  ('e6000000-0000-0000-0000-000000000001'::uuid, 'e6000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'completed', now() - interval '2 days', now() - interval '2 days'),
  -- 以下は数えてはいけない
  ('e6000000-0000-0000-0000-000000000001'::uuid, 'e6000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'cancelled_by_guest', now() - interval '5 days', null),
  ('e6000000-0000-0000-0000-000000000001'::uuid, 'e6000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'no_show_host', now() - interval '4 days', null),
  ('e6000000-0000-0000-0000-000000000001'::uuid, 'e6000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'confirmed', now() + interval '1 day', null);
do $$
declare v jsonb;
begin
  v := public.my_play_history_with('e6000000-0000-0000-0000-000000000009'::uuid);
  if (v->>'count')::int <> 2 then
    raise exception 'FAIL: 完了2件のはずが %', v->>'count';
  end if;
  -- 最終日は新しいほう(2日前)
  if (v->>'last_played_at')::timestamptz < now() - interval '3 days' then
    raise exception 'FAIL: 最終日が古いほうを指している: %', v->>'last_played_at';
  end if;
end $$;

\echo '=== 3. 向きを問わない(ピタメイトとして遊んだ回も合算) ==='
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
  values ('e6000000-0000-0000-0000-000000000009'::uuid, 'e6000000-0000-0000-0000-000000000001'::uuid,
          60, 1000, 'completed', now() - interval '1 day', now() - interval '1 day');
do $$
begin
  if (public.my_play_history_with('e6000000-0000-0000-0000-000000000009'::uuid)->>'count')::int <> 3 then
    raise exception 'FAIL: 逆向きの予約が合算されていない';
  end if;
end $$;

\echo '=== 4. 他人同士の回数は引けない ==='
-- 相手と第三者が5回遊んでいても、自分から見た第三者との回数は0のまま。
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select 'e6000000-0000-0000-0000-00000000000c'::uuid, 'e6000000-0000-0000-0000-000000000009'::uuid,
       60, 1000, 'completed', now() - interval '3 days', now() - interval '3 days'
from generate_series(1, 5);
do $$
begin
  if (public.my_play_history_with('e6000000-0000-0000-0000-00000000000c'::uuid)->>'count')::int <> 0 then
    raise exception 'FAIL: 自分が関わっていない予約まで数えている';
  end if;
  -- 相手との回数も、第三者の分が混ざって増えていないこと
  if (public.my_play_history_with('e6000000-0000-0000-0000-000000000009'::uuid)->>'count')::int <> 3 then
    raise exception 'FAIL: 第三者との予約が自分の回数に混ざった';
  end if;
end $$;

\echo '=== 5. 前回の条件(長さ・開始時刻)が返る(0059) ==='
-- 「前回と同じで予約」を出すための材料。いちばん新しい完了予約のもの。
do $$
declare v jsonb;
begin
  -- 直近は「3. 向きを問わない」で入れた1日前・60分の予約
  v := public.my_play_history_with('e6000000-0000-0000-0000-000000000009'::uuid);
  if (v->>'last_duration_minutes')::int <> 60 then
    raise exception 'FAIL: 前回の長さが返らない: %', v->>'last_duration_minutes';
  end if;
  if (v->>'last_scheduled_at')::timestamptz < now() - interval '2 days' then
    raise exception 'FAIL: 前回の開始時刻が古いほうを指している: %', v->>'last_scheduled_at';
  end if;
end $$;

\echo '=== 6. 遊んでいない相手には前回の条件も返らない ==='
do $$
declare v jsonb;
begin
  v := public.my_play_history_with('e6000000-0000-0000-0000-00000000000c'::uuid);
  if v->>'last_duration_minutes' is not null or v->>'last_scheduled_at' is not null then
    raise exception 'FAIL: 遊んでいないのに前回の条件が入っている';
  end if;
end $$;

\echo '=== 7. 未ログインでは引けない ==='
do $$
begin
  if has_function_privilege('anon', 'public.my_play_history_with(uuid)', 'execute') then
    raise exception 'FAIL: anonが引ける';
  end if;
end $$;

reset test.uid;
-- 予約は追記専用(0044)なので、後片付けだけは明示的に例外を宣言する
set app.ledger_override = 'on';
delete from public.bookings where guest_id::text like 'e6000000-%' or host_id::text like 'e6000000-%';
reset app.ledger_override;
delete from public.profiles where id::text like 'e6000000-%';
delete from auth.users where id::text like 'e6000000-%';

\echo '=== 83_play_history_with: 全項目OK ==='
