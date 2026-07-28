-- 未ログイン向けの掲載カード(0052)の検証。
--
-- ここは**インターネット全体に開く唯一の読み取り口**なので、
-- 「出したいものが出る」ことより「出してはいけないものが出ない」ことを重く見る。
--
-- 具体的には、次の3種類が混ざっていないことを確かめる。
--   ・掲載していない人(is_host = false)
--   ・本人確認が終わっていない人
--   ・「さがすに出さない」を選んでいる人

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('b6000000-0000-0000-0000-000000000001'::uuid),  -- 掲載中・確認済み・公開
  ('b6000000-0000-0000-0000-000000000002'::uuid),  -- 掲載中・確認済み・非公開希望
  ('b6000000-0000-0000-0000-000000000003'::uuid),  -- 掲載中だが未確認
  ('b6000000-0000-0000-0000-000000000004'::uuid)   -- 掲載していない一般利用者
on conflict do nothing;

insert into public.profiles (id, nickname, gender) values
  ('b6000000-0000-0000-0000-000000000001'::uuid, '公開メイト', 'female'),
  ('b6000000-0000-0000-0000-000000000002'::uuid, '非公開メイト', 'male'),
  ('b6000000-0000-0000-0000-000000000003'::uuid, '未確認メイト', 'na'),
  ('b6000000-0000-0000-0000-000000000004'::uuid, 'ただの利用者', 'na')
on conflict (id) do update set nickname = excluded.nickname;

-- 3人とも一度は確認済みにして掲載を有効にする(0003のトリガーが
-- 未確認からの is_host=true を弾くため)。
update public.profile_trust_stats set is_verified = true
  where user_id in ('b6000000-0000-0000-0000-000000000001'::uuid,
                    'b6000000-0000-0000-0000-000000000002'::uuid,
                    'b6000000-0000-0000-0000-000000000003'::uuid);

insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('b6000000-0000-0000-0000-000000000001'::uuid, true, 2000),
  ('b6000000-0000-0000-0000-000000000002'::uuid, true, 2000),
  ('b6000000-0000-0000-0000-000000000003'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- 3番は掲載を有効にしたあとで確認が取り消された人。掲載フラグは立ったままでも
-- 公開の場に出てはいけない(取り消し後も出続けるのが、いちばん怖い抜け道)。
update public.profile_trust_stats set is_verified = false
  where user_id = 'b6000000-0000-0000-0000-000000000003'::uuid;

-- 2番の人は「さがすに出さない」を選んでいる
update public.safety_prefs set discoverable = false
  where user_id = 'b6000000-0000-0000-0000-000000000002'::uuid;

\echo '=== 1. 掲載中・確認済み・公開の人だけが返る ==='
do $$
declare
  v_names text;
begin
  select string_agg(nickname, ', ' order by nickname)
    into v_names
  from public.public_host_cards(60)
  where host_id in (
    'b6000000-0000-0000-0000-000000000001'::uuid,
    'b6000000-0000-0000-0000-000000000002'::uuid,
    'b6000000-0000-0000-0000-000000000003'::uuid,
    'b6000000-0000-0000-0000-000000000004'::uuid);

  if v_names is distinct from '公開メイト' then
    raise exception 'FAIL: 返ってはいけない人が混ざっている: %', coalesce(v_names, '(なし)');
  end if;
end $$;

\echo '=== 2. 掲載を取り下げたら消える ==='
update public.host_settings set is_host = false
  where user_id = 'b6000000-0000-0000-0000-000000000001'::uuid;
do $$
begin
  if exists (select 1 from public.public_host_cards(60)
             where host_id = 'b6000000-0000-0000-0000-000000000001'::uuid) then
    raise exception 'FAIL: 掲載を止めたのに公開され続けている';
  end if;
end $$;
update public.host_settings set is_host = true
  where user_id = 'b6000000-0000-0000-0000-000000000001'::uuid;

\echo '=== 3. 「さがすに出さない」に切り替えたら消える ==='
update public.safety_prefs set discoverable = false
  where user_id = 'b6000000-0000-0000-0000-000000000001'::uuid;
do $$
begin
  if exists (select 1 from public.public_host_cards(60)
             where host_id = 'b6000000-0000-0000-0000-000000000001'::uuid) then
    raise exception 'FAIL: 非公開を選んだのに公開され続けている';
  end if;
end $$;
update public.safety_prefs set discoverable = true
  where user_id = 'b6000000-0000-0000-0000-000000000001'::uuid;

\echo '=== 4. 出してはいけない項目を返していない ==='
-- 戻り値の列を固定で確かめる。あとから「便利だから」と
-- 性別やオンライン状態を足してしまうのを、ここで止める。
--
-- **列を足したときは、ここも一緒に直すこと。** 直すときは「この列を未ログインの
-- 相手に見せてよいか」を一度考える。それがこの検査の目的で、通すためだけに
-- 機械的に書き足すと意味が無くなる。
--   0056: status_text / status_updated_at (ひとこと。本人が公開の場に書くもの)
--   0058: repeat_guests (2回以上遊んだ人の**数**。誰かは返らない・金額も含まない)
do $$
declare
  v_cols text;
begin
  select string_agg(a.attname, ',' order by a.attnum) into v_cols
  from pg_proc p
  join unnest(p.proallargtypes, p.proargmodes, p.proargnames)
    with ordinality as a(atttypid, attmode, attname, attnum) on true
  where p.oid = 'public.public_host_cards(int)'::regprocedure
    and a.attmode = 't';

  if v_cols is distinct from
     'host_id,nickname,avatar_initial,avatar_color,avatar_path,hourly_rate,games,bio,'
     || 'manner_score,review_count,is_verified,status_text,status_updated_at,repeat_guests'
  then
    raise exception 'FAIL: 公開する列が変わっている: %', v_cols;
  end if;
end $$;

\echo '=== 5. anon が実行できる(未ログインから見える) ==='
do $$
begin
  if not has_function_privilege('anon', 'public.public_host_cards(int)', 'execute') then
    raise exception 'FAIL: anonが実行できない';
  end if;
  if not has_function_privilege('anon', 'public.host_ranking(text, int)', 'execute') then
    raise exception 'FAIL: anonがランキングを取得できない';
  end if;
end $$;

\echo '=== 6. テーブルそのものは未ログインに開いていない ==='
-- 関数だけを開ける方針。テーブルに anon 向けのポリシーが増えていたら、
-- 掲載していない利用者まで読めるようになる。
do $$
declare
  t text;
begin
  foreach t in array array['profiles', 'host_settings', 'profile_trust_stats', 'safety_prefs']
  loop
    if exists (
      select 1 from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      where c.relname = t
        and 'anon' = any (select rolname from pg_roles where oid = any (pol.polroles))
    ) then
      raise exception 'FAIL: % に anon 向けポリシーがある', t;
    end if;
  end loop;
end $$;

delete from public.host_settings where user_id::text like 'b6000000-%';
delete from public.profiles where id::text like 'b6000000-%';
delete from auth.users where id::text like 'b6000000-%';

\echo '=== 86_public_host_listing: 全項目OK ==='
