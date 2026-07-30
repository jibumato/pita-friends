-- 「また呼ばれている」実績(0058)の検証。
--
-- 重点は**人数だけで、誰かは返さないこと**。誰と誰が繰り返し遊んでいるかが
-- 読めると、0053(お気に入り)・0055(二人の回数)で閉じた穴がここから開く。
-- あわせて「1回来ただけの人」を数えていないことを確かめる。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('b9000000-0000-0000-0000-000000000001'::uuid),  -- 3回来た人
  ('b9000000-0000-0000-0000-000000000002'::uuid),  -- 2回来た人
  ('b9000000-0000-0000-0000-000000000003'::uuid),  -- 1回だけの人
  ('b9000000-0000-0000-0000-000000000009'::uuid),  -- ピタメイト
  ('b9000000-0000-0000-0000-00000000000e'::uuid)   -- 別のピタメイト(混ざらないこと)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('b9000000-0000-0000-0000-000000000001'::uuid, '3回'),
  ('b9000000-0000-0000-0000-000000000002'::uuid, '2回'),
  ('b9000000-0000-0000-0000-000000000003'::uuid, '1回'),
  ('b9000000-0000-0000-0000-000000000009'::uuid, 'リピメイト'),
  ('b9000000-0000-0000-0000-00000000000e'::uuid, '別メイト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('b9000000-0000-0000-0000-000000000009'::uuid,
                    'b9000000-0000-0000-0000-00000000000e'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('b9000000-0000-0000-0000-000000000009'::uuid, true, 1000),
  ('b9000000-0000-0000-0000-00000000000e'::uuid, true, 1000)
  on conflict (user_id) do update set is_host = true;

\echo '=== 1. 一度も遊んでいなければ0 ==='
do $$
begin
  if public.host_repeat_guests('b9000000-0000-0000-0000-000000000009'::uuid) <> 0 then
    raise exception 'FAIL: 0でない';
  end if;
end $$;

\echo '=== 2. 2回以上の人だけを数える(1回だけの人は数えない) ==='
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select g, 'b9000000-0000-0000-0000-000000000009'::uuid, 60, 1000, 'completed',
       now() - (i || ' days')::interval, now() - (i || ' days')::interval
from (values
  ('b9000000-0000-0000-0000-000000000001'::uuid, 1),
  ('b9000000-0000-0000-0000-000000000001'::uuid, 2),
  ('b9000000-0000-0000-0000-000000000001'::uuid, 3),
  ('b9000000-0000-0000-0000-000000000002'::uuid, 4),
  ('b9000000-0000-0000-0000-000000000002'::uuid, 5),
  ('b9000000-0000-0000-0000-000000000003'::uuid, 6)
) as t(g, i);
do $$
begin
  -- 3回の人と2回の人で2人。1回だけの人は入らない
  if public.host_repeat_guests('b9000000-0000-0000-0000-000000000009'::uuid) <> 2 then
    raise exception 'FAIL: 2人のはずが %',
      public.host_repeat_guests('b9000000-0000-0000-0000-000000000009'::uuid);
  end if;
end $$;

\echo '=== 3. 完了していない予約は数えない ==='
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at)
values
  ('b9000000-0000-0000-0000-000000000003'::uuid, 'b9000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'cancelled_by_guest', now() - interval '7 days'),
  ('b9000000-0000-0000-0000-000000000003'::uuid, 'b9000000-0000-0000-0000-000000000009'::uuid,
   60, 1000, 'confirmed', now() + interval '1 day');
do $$
begin
  if public.host_repeat_guests('b9000000-0000-0000-0000-000000000009'::uuid) <> 2 then
    raise exception 'FAIL: キャンセル・未完了が数えられている';
  end if;
end $$;

\echo '=== 4. 別のピタメイトの分が混ざらない ==='
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select 'b9000000-0000-0000-0000-000000000001'::uuid, 'b9000000-0000-0000-0000-00000000000e'::uuid,
       60, 1000, 'completed', now() - (i || ' days')::interval, now() - (i || ' days')::interval
from generate_series(8, 12) i;
do $$
begin
  if public.host_repeat_guests('b9000000-0000-0000-0000-000000000009'::uuid) <> 2 then
    raise exception 'FAIL: 別のピタメイトの分が混ざった';
  end if;
  if public.host_repeat_guests('b9000000-0000-0000-0000-00000000000e'::uuid) <> 1 then
    raise exception 'FAIL: 別のピタメイトの数が合わない';
  end if;
end $$;

\echo '=== 5. まとめて取っても同じ数になる(0060で host_repeat_stats に統合) ==='
do $$
declare v_a int; v_b int;
begin
  select repeat_guests into v_a from public.host_repeat_stats(
    array['b9000000-0000-0000-0000-000000000009'::uuid, 'b9000000-0000-0000-0000-00000000000e'::uuid])
  where host_id = 'b9000000-0000-0000-0000-000000000009'::uuid;
  select repeat_guests into v_b from public.host_repeat_stats(
    array['b9000000-0000-0000-0000-000000000009'::uuid, 'b9000000-0000-0000-0000-00000000000e'::uuid])
  where host_id = 'b9000000-0000-0000-0000-00000000000e'::uuid;
  if v_a <> 2 or v_b <> 1 then
    raise exception 'FAIL: まとめ取得の数が違う(% / %)', v_a, v_b;
  end if;
  -- 実績が無いIDを混ぜても行が落ちず0で返ること(一覧の並びが崩れないように)
  if (select repeat_guests from public.host_repeat_stats(
        array['b9000000-0000-0000-0000-000000000003'::uuid])
      where host_id = 'b9000000-0000-0000-0000-000000000003'::uuid) <> 0 then
    raise exception 'FAIL: 実績が無いIDの行が0で返らない';
  end if;
end $$;

\echo '=== 6. 掲載カードにも載る ==='
do $$
begin
  if (select repeat_guests from public.public_host_cards(60)
      where host_id = 'b9000000-0000-0000-0000-000000000009'::uuid) <> 2 then
    raise exception 'FAIL: 掲載カードにリピーター数が出ない';
  end if;
end $$;

\echo '=== 7. 「誰が」は返らない ==='
-- 返り値の列に guest を指す列が無いこと。人数を返す口しか公開していない。
do $$
declare v text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like '%repeat%';
  if v is distinct from 'host_repeat_guests, host_repeat_stats' then
    raise exception 'FAIL: 想定外のリピート関数がある: %', coalesce(v, '(なし)');
  end if;
  if exists (
    select 1 from information_schema.parameters
    where specific_schema = 'public'
      and specific_name like 'host_repeat%'
      and parameter_mode = 'TABLE'
      and parameter_name ilike '%guest_id%'
  ) then
    raise exception 'FAIL: 戻り値にゲストのIDが含まれている';
  end if;
end $$;

reset test.uid;
set app.ledger_override = 'on';
delete from public.bookings where guest_id::text like 'b9000000-%' or host_id::text like 'b9000000-%';
reset app.ledger_override;
delete from public.host_settings where user_id::text like 'b9000000-%';
delete from public.profiles where id::text like 'b9000000-%';
delete from auth.users where id::text like 'b9000000-%';

\echo '=== 82_repeat_proof: 全項目OK ==='
