-- ピタメイトの「ひとこと」(0056)の検証。
--
-- 重点は**古いひとことを出さないこと**。「今日は21時から!」が2か月前の
-- ものだと、何も無いより悪い(来ないと分かっている枠を待たせる)。
-- あわせて、掲載していない人のひとことが公開の場に出ないことも確かめる。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f7000000-0000-0000-0000-000000000001'::uuid),  -- 見る人
  ('f7000000-0000-0000-0000-000000000009'::uuid),  -- 掲載中のピタメイト
  ('f7000000-0000-0000-0000-00000000000d'::uuid)   -- 掲載していない人
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('f7000000-0000-0000-0000-000000000001'::uuid, '見る人'),
  ('f7000000-0000-0000-0000-000000000009'::uuid, 'ひとことメイト'),
  ('f7000000-0000-0000-0000-00000000000d'::uuid, '未掲載')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('f7000000-0000-0000-0000-000000000009'::uuid,
                    'f7000000-0000-0000-0000-00000000000d'::uuid);
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('f7000000-0000-0000-0000-000000000009'::uuid, true, 1200),
  ('f7000000-0000-0000-0000-00000000000d'::uuid, false, 1200)
  on conflict (user_id) do update set is_host = excluded.is_host;

\echo '=== 1. 書ける / 時刻が入る ==='
set test.uid = 'f7000000-0000-0000-0000-000000000009';
do $$
declare v timestamptz;
begin
  v := public.set_host_status('今夜21時から遊べます');
  if v is null then raise exception 'FAIL: 書けたのに時刻が返らない'; end if;
  if (select status_text from public.host_settings
      where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid) <> '今夜21時から遊べます' then
    raise exception 'FAIL: 保存されていない';
  end if;
end $$;

\echo '=== 2. 改行と余分な空白は1つにまとめる ==='
do $$
begin
  perform public.set_host_status('  今夜は' || chr(10) || chr(10) || '  21時から  ');
  if (select status_text from public.host_settings
      where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid) <> '今夜は 21時から' then
    raise exception 'FAIL: 整形されていない: %',
      (select status_text from public.host_settings
       where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid);
  end if;
end $$;

\echo '=== 3. 60字を超えると弾く ==='
do $$
begin
  begin
    perform public.set_host_status(repeat('あ', 61));
    raise exception 'FAIL: 61字が通ってしまった';
  exception when others then
    if sqlerrm not like '%STATUS_TOO_LONG%' then raise; end if;
  end;
  -- ちょうど60字は通る
  perform public.set_host_status(repeat('い', 60));
end $$;

\echo '=== 4. 消すと時刻も消える ==='
do $$
begin
  if public.set_host_status('') is not null then
    raise exception 'FAIL: 空を渡したのに時刻が返った';
  end if;
  if (select status_updated_at from public.host_settings
      where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid) is not null then
    raise exception 'FAIL: 消したのに時刻が残っている';
  end if;
end $$;

\echo '=== 5. 掲載カードとお気に入り一覧にひとことが載る ==='
select public.set_host_status('今週末はランク回します');
set test.uid = 'f7000000-0000-0000-0000-000000000001';
select public.set_favorite('f7000000-0000-0000-0000-000000000009'::uuid, true);
do $$
begin
  if (select status_text from public.public_host_cards(60)
      where host_id = 'f7000000-0000-0000-0000-000000000009'::uuid) <> '今週末はランク回します' then
    raise exception 'FAIL: 掲載カードにひとことが出ない';
  end if;
  if (select status_text from public.my_favorites()
      where host_id = 'f7000000-0000-0000-0000-000000000009'::uuid) <> '今週末はランク回します' then
    raise exception 'FAIL: お気に入り一覧にひとことが出ない';
  end if;
end $$;

\echo '=== 6. 14日を過ぎたひとことは出ない(消えはしない) ==='
update public.host_settings set status_updated_at = now() - interval '15 days'
  where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid;
do $$
begin
  if (select status_text from public.public_host_cards(60)
      where host_id = 'f7000000-0000-0000-0000-000000000009'::uuid) is not null then
    raise exception 'FAIL: 15日前のひとことが掲載カードに出ている';
  end if;
  if (select status_updated_at from public.my_favorites()
      where host_id = 'f7000000-0000-0000-0000-000000000009'::uuid) is not null then
    raise exception 'FAIL: 隠しているのに時刻だけ出ている';
  end if;
  -- 本人の行には残っていること(書き直せばまた出る)
  if (select status_text from public.host_settings
      where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid) is null then
    raise exception 'FAIL: 古いだけで本人の行から消えた';
  end if;
end $$;
-- 13日前ならまだ出る(境目の確認)
update public.host_settings set status_updated_at = now() - interval '13 days'
  where user_id = 'f7000000-0000-0000-0000-000000000009'::uuid;
do $$
begin
  if (select status_text from public.public_host_cards(60)
      where host_id = 'f7000000-0000-0000-0000-000000000009'::uuid) is null then
    raise exception 'FAIL: 13日前なのに隠された';
  end if;
end $$;

\echo '=== 7. 掲載していない人のひとことは公開の場に出ない ==='
set test.uid = 'f7000000-0000-0000-0000-00000000000d';
select public.set_host_status('見えてはいけない');
set test.uid = 'f7000000-0000-0000-0000-000000000001';
do $$
begin
  if exists (select 1 from public.public_host_cards(60)
             where host_id = 'f7000000-0000-0000-0000-00000000000d'::uuid) then
    raise exception 'FAIL: 掲載していない人が掲載カードに出ている';
  end if;
end $$;

\echo '=== 8. 未ログインは書けない / カードは読める ==='
do $$
begin
  if has_function_privilege('anon', 'public.set_host_status(text)', 'execute') then
    raise exception 'FAIL: anonが書ける';
  end if;
  if not has_function_privilege('anon', 'public.public_host_cards(integer)', 'execute') then
    raise exception 'FAIL: anonが掲載カードを読めない(0052の意図から外れた)';
  end if;
  if has_function_privilege('anon', 'public.my_favorites()', 'execute') then
    raise exception 'FAIL: anonがお気に入り一覧を引ける';
  end if;
end $$;

reset test.uid;
delete from public.favorites where user_id::text like 'f7000000-%';
delete from public.host_settings where user_id::text like 'f7000000-%';
delete from public.profiles where id::text like 'f7000000-%';
delete from auth.users where id::text like 'f7000000-%';

\echo '=== 87_host_status: 全項目OK ==='
