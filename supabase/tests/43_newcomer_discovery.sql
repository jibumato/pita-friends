-- ============================================================
-- 43: はじめたばかりのピタメイトが見つけてもらえるか（0123）
--
-- ■ このファイルが守っているもの
--   「予約が入らない → 評価がつかない → 表示されない」の輪を切る3点。
--   どれも**例外は出ない**ので、壊れても気づけるのはここだけ。
--
--     ① 同点だったときの並びが、UUID 順で固定されていないこと
--        （かつ、実績のある人の順序は壊していないこと）
--     ② 新人枠が「使い回せない」こと
--     ③ 見ていた人への通知が、**同意した人にだけ**行くこと
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('43000000-0000-0000-0000-000000000001'),  -- 実績のあるピタメイト
  ('43000000-0000-0000-0000-000000000011'),  -- 新人1
  ('43000000-0000-0000-0000-000000000012'),  -- 新人2
  ('43000000-0000-0000-0000-000000000013'),  -- 新人3
  ('43000000-0000-0000-0000-000000000014'),  -- 新人4（枠なし）
  ('43000000-0000-0000-0000-000000000015'),  -- 新人5（未確認）
  ('43000000-0000-0000-0000-000000000016'),  -- 古参（窓の外）
  ('43000000-0000-0000-0000-000000000091'),  -- ゲストA（お気に入り）
  ('43000000-0000-0000-0000-000000000092'),  -- ゲストB（見ただけ・通知on）
  ('43000000-0000-0000-0000-000000000093'),  -- ゲストC（見ただけ・通知off）
  ('43000000-0000-0000-0000-000000000094'),  -- ゲストD（お気に入り かつ 見た）
  ('43000000-0000-0000-0000-000000000095')   -- ゲストE（見たがブロック済み）
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('43000000-0000-0000-0000-000000000001','実績あり'),
  ('43000000-0000-0000-0000-000000000011','新人1'),
  ('43000000-0000-0000-0000-000000000012','新人2'),
  ('43000000-0000-0000-0000-000000000013','新人3'),
  ('43000000-0000-0000-0000-000000000014','新人4'),
  ('43000000-0000-0000-0000-000000000015','新人5'),
  ('43000000-0000-0000-0000-000000000016','古参'),
  ('43000000-0000-0000-0000-000000000091','ゲストA'),
  ('43000000-0000-0000-0000-000000000092','ゲストB'),
  ('43000000-0000-0000-0000-000000000093','ゲストC'),
  ('43000000-0000-0000-0000-000000000094','ゲストD'),
  ('43000000-0000-0000-0000-000000000095','ゲストE')
on conflict (id) do update set nickname = excluded.nickname;

-- ⚠️ ピタメイトになるには本人確認が要る(HOST_REQUIRES_VERIFICATION)。
--    **先に全員を確認済みにしてから** host_settings を作り、
--    「未確認だと掲載されない」の検証用に新人5だけ後から戻す。
update public.profile_trust_stats set is_verified = true;

insert into public.host_settings (user_id, is_host, hourly_rate)
select u, true, 1000 from unnest(array[
  '43000000-0000-0000-0000-000000000001'::uuid,
  '43000000-0000-0000-0000-000000000011'::uuid,
  '43000000-0000-0000-0000-000000000012'::uuid,
  '43000000-0000-0000-0000-000000000013'::uuid,
  '43000000-0000-0000-0000-000000000014'::uuid,
  '43000000-0000-0000-0000-000000000015'::uuid,
  '43000000-0000-0000-0000-000000000016'::uuid]) u
on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- 新人5を未確認に戻す（掲載の条件を満たさない人の検証用）
update public.profile_trust_stats set is_verified = false
  where user_id = '43000000-0000-0000-0000-000000000015';

-- 枠。新人4だけ**枠を持たせない**
insert into public.host_availability (user_id, weekday, hour)
select u, 3, 20 from unnest(array[
  '43000000-0000-0000-0000-000000000001'::uuid,
  '43000000-0000-0000-0000-000000000011'::uuid,
  '43000000-0000-0000-0000-000000000012'::uuid,
  '43000000-0000-0000-0000-000000000013'::uuid,
  '43000000-0000-0000-0000-000000000015'::uuid,
  '43000000-0000-0000-0000-000000000016'::uuid]) u
on conflict do nothing;

-- 古参は窓の外に置く（トリガが上書きするので、直接 update で押し戻す）
alter table public.host_settings disable trigger host_settings_stamp_host_since;
update public.host_settings set host_since = now() - interval '90 days'
  where user_id = '43000000-0000-0000-0000-000000000016';
alter table public.host_settings enable trigger host_settings_stamp_host_since;

-- 実績あり(…0001)に「2回呼ばれたゲスト」を作り、repeat_score を上げる
insert into public.bookings (guest_id, host_id, coins, duration_minutes, status, scheduled_at)
select '43000000-0000-0000-0000-000000000091', '43000000-0000-0000-0000-000000000001',
       1000, 60, 'completed', now() - (n || ' days')::interval
from generate_series(1, 2) n;

-- ------------------------------------------------------------
\echo '=== ★1. 実績のある人の順序は壊していない ==='
do $$
declare v_first uuid;
begin
  select host_id into v_first from public.public_host_cards(30) limit 1;
  if v_first <> '43000000-0000-0000-0000-000000000001' then
    raise exception 'NG: リピート実績のある人が先頭でない（% が先頭）', v_first;
  end if;
  raise notice 'ok 実績順は据え置き（先頭は実績のある人）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★2. 同点帯の並びは UUID 順ではなく、日替わりの鍵の順 ==='
do $$
declare v_actual uuid[]; v_by_key uuid[]; v_by_uuid uuid[];
begin
  -- 実績のある人を除いた「全員同点」の帯だけを見る
  select array_agg(c.host_id order by c.ord) into v_actual
  from (select host_id, row_number() over () as ord from public.public_host_cards(30)) c
  where c.host_id <> '43000000-0000-0000-0000-000000000001';

  select array_agg(s.host_id order by s.shuffle_key) into v_by_key
  from public.host_discovery_shuffle(v_actual) s;

  select array_agg(x order by x) into v_by_uuid from unnest(v_actual) x;

  -- ★本題。一覧の並びが「鍵の順」と一致していること
  if v_actual is distinct from v_by_key then
    raise exception 'NG: 同点帯の並びが鍵の順になっていない（実際 % / 鍵 %）',
      v_actual, v_by_key;
  end if;

  -- 鍵が UUID 順と一致してしまうと、直した意味が無い。
  -- 5人なら偶然一致する確率は 1/120 ——落ちたら日付を変えて再実行する
  if v_by_key = v_by_uuid then
    raise exception 'NG: 鍵の順が UUID 順と同じ（偶然なら翌日には解消する）';
  end if;
  raise notice 'ok 同点帯は日替わりの鍵の順（UUID 順ではない）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★3. 新人枠は使い回せない（host_since は動かない） ==='
do $$
declare v_since timestamptz; v_after timestamptz;
begin
  select host_since into v_since from public.host_settings
    where user_id = '43000000-0000-0000-0000-000000000011';
  if v_since is null then
    raise exception 'NG: ピタメイトになった日がついていない';
  end if;

  -- ① is_host を切って入れ直す
  update public.host_settings set is_host = false
    where user_id = '43000000-0000-0000-0000-000000000011';
  update public.host_settings set is_host = true
    where user_id = '43000000-0000-0000-0000-000000000011';
  select host_since into v_after from public.host_settings
    where user_id = '43000000-0000-0000-0000-000000000011';
  if v_after is distinct from v_since then
    raise exception 'NG: 出し入れで日付が戻った（% → %）', v_since, v_after;
  end if;

  -- ② 直接書き換える
  update public.host_settings set host_since = now()
    where user_id = '43000000-0000-0000-0000-000000000011';
  select host_since into v_after from public.host_settings
    where user_id = '43000000-0000-0000-0000-000000000011';
  if v_after is distinct from v_since then
    raise exception 'NG: 直接の更新で日付が動いた（% → %）', v_since, v_after;
  end if;
  raise notice 'ok ピタメイトになった日は動かせない';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 新人枠に出る人・出ない人 ==='
do $$
declare v_ids uuid[];
begin
  select array_agg(host_id) into v_ids from public.new_host_cards(30, 14);

  if not (v_ids @> array['43000000-0000-0000-0000-000000000011'::uuid,
                         '43000000-0000-0000-0000-000000000012'::uuid,
                         '43000000-0000-0000-0000-000000000013'::uuid]) then
    raise exception 'NG: はじめたばかりの人が出ていない（%）', v_ids;
  end if;
  -- 枠が1つも無い人は出さない（押しても予約できない）
  if v_ids @> array['43000000-0000-0000-0000-000000000014'::uuid] then
    raise exception 'NG: 枠が無い人が新人枠に出ている';
  end if;
  -- 本人確認が済んでいない人は掲載しない（public_host_cards と同じ条件）
  if v_ids @> array['43000000-0000-0000-0000-000000000015'::uuid] then
    raise exception 'NG: 未確認の人が新人枠に出ている';
  end if;
  -- 窓の外
  if v_ids @> array['43000000-0000-0000-0000-000000000016'::uuid] then
    raise exception 'NG: 90日前に始めた人が新人枠に出ている';
  end if;
  raise notice 'ok 新人枠は「最近・掲載中・枠あり」だけ（%人）', array_length(v_ids, 1);
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 閲覧の記録は最小限（1組1行・対象外は残さない） ==='
do $$
declare v_n int; v_at1 timestamptz; v_at2 timestamptz;
begin
  perform set_config('test.uid', '43000000-0000-0000-0000-000000000092', false);
  perform public.record_profile_view('43000000-0000-0000-0000-000000000011');
  select viewed_at into v_at1 from public.profile_views
    where viewer_id = '43000000-0000-0000-0000-000000000092';

  -- 2回見ても行は増えない（履歴ではなく「最後に見た日」）。
  -- ⚠️ now() はトランザクション開始時刻で固定なので、続けて呼んでも
  --    値は動かない。**一度古い日付に戻してから**呼んで、
  --    上書きの側（on conflict do update）が効いていることを見る
  update public.profile_views set viewed_at = now() - interval '10 days'
    where viewer_id = '43000000-0000-0000-0000-000000000092';
  perform public.record_profile_view('43000000-0000-0000-0000-000000000011');
  select count(*), max(viewed_at) into v_n, v_at2 from public.profile_views
    where viewer_id = '43000000-0000-0000-0000-000000000092';
  if v_n <> 1 then raise exception 'NG: 同じ相手で行が増えた（%件）', v_n; end if;
  if v_at2 <> v_at1 then raise exception 'NG: 最後に見た日が更新されていない（%）', v_at2; end if;

  -- 自分自身は記録しない
  perform set_config('test.uid', '43000000-0000-0000-0000-000000000011', false);
  perform public.record_profile_view('43000000-0000-0000-0000-000000000011');
  select count(*) into v_n from public.profile_views
    where viewer_id = '43000000-0000-0000-0000-000000000011';
  if v_n <> 0 then raise exception 'NG: 自分を見たことが記録された'; end if;

  -- 掲載中のピタメイト以外は記録しない（残す情報を増やさない）
  perform set_config('test.uid', '43000000-0000-0000-0000-000000000092', false);
  perform public.record_profile_view('43000000-0000-0000-0000-000000000093');
  select count(*) into v_n from public.profile_views
    where viewer_id = '43000000-0000-0000-0000-000000000092'
      and host_id = '43000000-0000-0000-0000-000000000093';
  if v_n <> 0 then raise exception 'NG: ピタメイト以外の閲覧が記録された'; end if;
  raise notice 'ok 閲覧の記録は1組1行・ピタメイトを見たときだけ';
end $$;

-- ------------------------------------------------------------
\echo '=== ★6. 見られた側から閲覧者は読めない ==='
set test.uid = '43000000-0000-0000-0000-000000000011';
set role authenticated;
do $$
declare v_n int;
begin
  -- 自分（ホスト）を見た人の行が読めてしまわないこと
  select count(*) into v_n from public.profile_views
    where host_id = '43000000-0000-0000-0000-000000000011';
  if v_n <> 0 then
    raise exception 'NG: ホストから閲覧者が % 件見えている（0053の方針違反）', v_n;
  end if;
  raise notice 'ok 見られた側からは誰が見たか読めない';
end $$;
reset role;

-- ------------------------------------------------------------
\echo '=== ★7. 枠を開けた通知は、同意した人にだけ広がる ==='
-- ゲストA: お気に入り / ゲストD: お気に入り かつ 閲覧
insert into public.favorites (user_id, host_id) values
  ('43000000-0000-0000-0000-000000000091','43000000-0000-0000-0000-000000000012'),
  ('43000000-0000-0000-0000-000000000094','43000000-0000-0000-0000-000000000012')
on conflict do nothing;

-- ゲストB・C・D・E が新人2を見た
do $$
declare g uuid;
begin
  foreach g in array array[
    '43000000-0000-0000-0000-000000000092'::uuid,
    '43000000-0000-0000-0000-000000000093'::uuid,
    '43000000-0000-0000-0000-000000000094'::uuid,
    '43000000-0000-0000-0000-000000000095'::uuid]
  loop
    perform set_config('test.uid', g::text, false);
    perform public.record_profile_view('43000000-0000-0000-0000-000000000012');
  end loop;
end $$;

-- B・D・E は「おすすめマッチ」on、C は off のまま（既定）
update public.notification_prefs set notify_recommendations = true
  where user_id in ('43000000-0000-0000-0000-000000000092',
                    '43000000-0000-0000-0000-000000000094',
                    '43000000-0000-0000-0000-000000000095');

-- E は新人2をブロックしている
insert into public.blocks (blocker_id, blocked_id)
  values ('43000000-0000-0000-0000-000000000095','43000000-0000-0000-0000-000000000012')
on conflict do nothing;

do $$
declare v_n int; v_title text;
begin
  perform set_config('test.uid', '43000000-0000-0000-0000-000000000012', false);
  -- 枠を増やす（もとは 水20時 の1つだけ）
  perform public.set_host_availability(
    '[{"weekday":3,"hour":20},{"weekday":5,"hour":21},{"weekday":6,"hour":22}]'::jsonb);

  -- お気に入り（従来どおり）
  select count(*) into v_n from public.notifications
    where user_id = '43000000-0000-0000-0000-000000000091' and type = 'host_slots_opened';
  if v_n <> 1 then raise exception 'NG: お気に入りに届いていない（%件）', v_n; end if;

  -- ★見ていただけ・同意あり → 届く。理由が分かる書き方になっている
  select count(*), max(title) into v_n, v_title from public.notifications
    where user_id = '43000000-0000-0000-0000-000000000092' and type = 'host_slots_opened';
  if v_n <> 1 then raise exception 'NG: 見ていた人に届いていない（%件）', v_n; end if;
  if v_title not like '前に見ていた%' then
    raise exception 'NG: なぜ届いたのか分からない文面（%）', v_title;
  end if;

  -- ★見ていただけ・同意なし → 届かない（既定は off）
  select count(*) into v_n from public.notifications
    where user_id = '43000000-0000-0000-0000-000000000093' and type = 'host_slots_opened';
  if v_n <> 0 then raise exception 'NG: 同意していない人に届いた（%件）', v_n; end if;

  -- ★お気に入り かつ 閲覧 → **1通だけ**。文面はお気に入り側
  select count(*), max(title) into v_n, v_title from public.notifications
    where user_id = '43000000-0000-0000-0000-000000000094' and type = 'host_slots_opened';
  if v_n <> 1 then raise exception 'NG: 二重に届いた（%件）', v_n; end if;
  if v_title like '前に見ていた%' then
    raise exception 'NG: お気に入りに入れている人に「前に見ていた」と出た（%）', v_title;
  end if;

  -- ブロックしている相手からは届かない
  select count(*) into v_n from public.notifications
    where user_id = '43000000-0000-0000-0000-000000000095' and type = 'host_slots_opened';
  if v_n <> 0 then raise exception 'NG: ブロックした相手から届いた（%件）', v_n; end if;

  raise notice 'ok 通知はお気に入り＋同意した閲覧者にだけ・重複なし';
end $$;

\echo '=== 43: すべて ok ==='
