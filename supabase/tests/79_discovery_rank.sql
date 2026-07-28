-- 掲載順(0060)の検証。
--
-- 重点は**始めたばかりの人が埋もれないこと**。
-- 「実績が無い」を「実績が悪い」と同じ扱いにすると、新しく入った人は
-- 永久に下に沈み、供給が育たない。母数が小さいうちは0.25へ寄せる設計が
-- 意図どおり効いているかを、境目の数字で確かめる。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('c0000000-0000-0000-0000-0000000000a1'::uuid),  -- 実績あり・よく戻られる
  ('c0000000-0000-0000-0000-0000000000a2'::uuid),  -- 実績あり・誰も戻らない
  ('c0000000-0000-0000-0000-0000000000a3'::uuid),  -- まだ誰も来ていない
  ('c0000000-0000-0000-0000-0000000000a4'::uuid),  -- 1人来て1回リピート
  ('c0000000-0000-0000-0000-0000000000b1'::uuid),
  ('c0000000-0000-0000-0000-0000000000b2'::uuid),
  ('c0000000-0000-0000-0000-0000000000b3'::uuid),
  ('c0000000-0000-0000-0000-0000000000b4'::uuid),
  ('c0000000-0000-0000-0000-0000000000b5'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname)
select id, 'R' || right(id::text, 2) from unnest(array[
  'c0000000-0000-0000-0000-0000000000a1','c0000000-0000-0000-0000-0000000000a2',
  'c0000000-0000-0000-0000-0000000000a3','c0000000-0000-0000-0000-0000000000a4',
  'c0000000-0000-0000-0000-0000000000b1','c0000000-0000-0000-0000-0000000000b2',
  'c0000000-0000-0000-0000-0000000000b3','c0000000-0000-0000-0000-0000000000b4',
  'c0000000-0000-0000-0000-0000000000b5']::uuid[]) as id
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true, manner_score = 4.5
  where user_id::text like 'c0000000-%';
insert into public.host_settings (user_id, is_host, hourly_rate)
select id, true, 1000 from unnest(array[
  'c0000000-0000-0000-0000-0000000000a1','c0000000-0000-0000-0000-0000000000a2',
  'c0000000-0000-0000-0000-0000000000a3','c0000000-0000-0000-0000-0000000000a4']::uuid[]) as id
on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- a1: 5人来て4人が2回以上 / a2: 5人来て誰も戻らない / a4: 1人来て2回
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select g.id, 'c0000000-0000-0000-0000-0000000000a1'::uuid, 60, 1000, 'completed',
       now() - interval '5 days', now() - interval '5 days'
from unnest(array[
  'c0000000-0000-0000-0000-0000000000b1','c0000000-0000-0000-0000-0000000000b2',
  'c0000000-0000-0000-0000-0000000000b3','c0000000-0000-0000-0000-0000000000b4',
  'c0000000-0000-0000-0000-0000000000b5']::uuid[]) as g(id);
-- b1〜b4 は2回目も来る
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select g.id, 'c0000000-0000-0000-0000-0000000000a1'::uuid, 60, 1000, 'completed',
       now() - interval '2 days', now() - interval '2 days'
from unnest(array[
  'c0000000-0000-0000-0000-0000000000b1','c0000000-0000-0000-0000-0000000000b2',
  'c0000000-0000-0000-0000-0000000000b3','c0000000-0000-0000-0000-0000000000b4']::uuid[]) as g(id);
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select g.id, 'c0000000-0000-0000-0000-0000000000a2'::uuid, 60, 1000, 'completed',
       now() - interval '5 days', now() - interval '5 days'
from unnest(array[
  'c0000000-0000-0000-0000-0000000000b1','c0000000-0000-0000-0000-0000000000b2',
  'c0000000-0000-0000-0000-0000000000b3','c0000000-0000-0000-0000-0000000000b4',
  'c0000000-0000-0000-0000-0000000000b5']::uuid[]) as g(id);
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, confirmed_at)
select 'c0000000-0000-0000-0000-0000000000b1'::uuid, 'c0000000-0000-0000-0000-0000000000a4'::uuid,
       60, 1000, 'completed', now() - (i || ' days')::interval, now() - (i || ' days')::interval
from generate_series(1, 2) i;
reset app.ledger_override;

\echo '=== 1. 丸めた率が設計どおりの値になる ==='
do $$
declare v numeric;
begin
  -- 5人中4人 → (4 + 5*0.25) / (5+5) = 0.525
  select repeat_score into v from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a1'::uuid]);
  if v <> 0.5250 then raise exception 'FAIL: a1 が 0.5250 でない: %', v; end if;
  -- 5人中0人 → 1.25 / 10 = 0.125
  select repeat_score into v from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a2'::uuid]);
  if v <> 0.1250 then raise exception 'FAIL: a2 が 0.1250 でない: %', v; end if;
  -- 誰も来ていない → 1.25 / 5 = 0.25
  select repeat_score into v from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a3'::uuid]);
  if v <> 0.2500 then raise exception 'FAIL: a3 が 0.2500 でない: %', v; end if;
  -- 1人中1人 → (1 + 1.25) / 6 = 0.375
  select repeat_score into v from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a4'::uuid]);
  if v <> 0.3750 then raise exception 'FAIL: a4 が 0.3750 でない: %', v; end if;
end $$;

\echo '=== 2. 始めたばかりの人が、戻られない人より上に来る ==='
-- ここが崩れると新しく入った人が永久に埋もれ、供給が育たない。
do $$
declare v_new numeric; v_bad numeric;
begin
  select repeat_score into v_new from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a3'::uuid]);
  select repeat_score into v_bad from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a2'::uuid]);
  if not (v_new > v_bad) then
    raise exception 'FAIL: 実績が無い人が、戻られない人より下になっている(% <= %)', v_new, v_bad;
  end if;
end $$;

\echo '=== 3. 1人だけのリピートが独占しない ==='
do $$
declare v_one numeric; v_many numeric;
begin
  select repeat_score into v_one from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a4'::uuid]);
  select repeat_score into v_many from public.host_repeat_stats(array['c0000000-0000-0000-0000-0000000000a1'::uuid]);
  if not (v_many > v_one) then
    raise exception 'FAIL: 1人100%%が、5人中4人より上に来ている(% >= %)', v_one, v_many;
  end if;
end $$;

\echo '=== 4. 掲載カードがこの順に並ぶ ==='
do $$
declare v uuid[];
begin
  select array_agg(host_id order by ord) into v from (
    select host_id, row_number() over () as ord from public.public_host_cards(60)
  ) t where host_id::text like 'c0000000-%';
  if v[1] <> 'c0000000-0000-0000-0000-0000000000a1'::uuid then
    raise exception 'FAIL: よく戻られる人が先頭でない: %', v;
  end if;
  if v[array_length(v,1)] <> 'c0000000-0000-0000-0000-0000000000a2'::uuid then
    raise exception 'FAIL: 戻られない人が最後でない: %', v;
  end if;
end $$;

\echo '=== 5. 実績が無いIDを渡しても行が落ちない ==='
-- 落ちると、一覧の結合で人が消える。
do $$
begin
  if (select count(*) from public.host_repeat_stats(
        array['c0000000-0000-0000-0000-0000000000b1'::uuid,
              'c0000000-0000-0000-0000-0000000000b2'::uuid])) <> 2 then
    raise exception 'FAIL: 行数が渡した数と合わない';
  end if;
end $$;

\echo '=== 6. 金額は返さない ==='
do $$
begin
  if exists (
    select 1 from information_schema.parameters
    where specific_schema = 'public'
      and specific_name like 'host_repeat_stats%'
      and (parameter_name ilike '%coin%' or parameter_name ilike '%yen%'
        or parameter_name ilike '%amount%' or parameter_name ilike '%gmv%')
  ) then
    raise exception 'FAIL: 金額に類する列が含まれている(弁護士Q11(d))';
  end if;
end $$;

reset test.uid;
set app.ledger_override = 'on';
delete from public.bookings where guest_id::text like 'c0000000-%' or host_id::text like 'c0000000-%';
reset app.ledger_override;
delete from public.host_settings where user_id::text like 'c0000000-%';
delete from public.profiles where id::text like 'c0000000-%';
delete from auth.users where id::text like 'c0000000-%';

\echo '=== 79_discovery_rank: 全項目OK ==='
