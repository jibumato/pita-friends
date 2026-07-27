-- 公開前の事前登録(0052)の検証。
--
-- 名簿そのものより「名簿が外から読めないこと」の方が重要です。
-- 事前登録は未ログインから叩ける唯一の書き込み口なので、ここが緩いと
-- 集めたメールアドレスがそのまま漏れます。
--
-- あわせて「登録済みでも成功として返す」ことを確かめます。エラーを返すと、
-- 任意のアドレスを入れて反応の違いを見るだけで登録の有無が判ってしまいます。

\set ON_ERROR_STOP on

delete from public.pre_registrations where email like '%@pretest.example';

\echo '=== 1. 新規の登録が入る ==='
select public.pre_register('someone@pretest.example', 'x');
do $$
begin
  if (select count(*) from public.pre_registrations
      where email = 'someone@pretest.example') <> 1 then
    raise exception 'FAIL: 事前登録が入っていない';
  end if;
  if (select source from public.pre_registrations
      where email = 'someone@pretest.example') <> 'x' then
    raise exception 'FAIL: 流入元が記録されていない';
  end if;
end $$;

\echo '=== 2. 同じアドレスをもう一度でもエラーにならない(列挙対策) ==='
select public.pre_register('someone@pretest.example', 'landing');
do $$
begin
  if (select count(*) from public.pre_registrations
      where email = 'someone@pretest.example') <> 1 then
    raise exception 'FAIL: 二重登録された';
  end if;
  -- 後勝ちで source を書き換えない。最初にどこから来たかを残す
  if (select source from public.pre_registrations
      where email = 'someone@pretest.example') <> 'x' then
    raise exception 'FAIL: 最初の流入元が上書きされた';
  end if;
end $$;

\echo '=== 3. 大文字・前後の空白は正規化して同一視する ==='
select public.pre_register('  SomeOne@PreTest.Example  ');
do $$
begin
  if (select count(*) from public.pre_registrations
      where email like '%@pretest.example') <> 1 then
    raise exception 'FAIL: 大文字違いで別レコードが増えた';
  end if;
end $$;

\echo '=== 4. 形式が明らかにおかしいものは弾く ==='
do $$
declare
  v_bad text;
begin
  foreach v_bad in array array['', '   ', 'no-at-mark', 'a@b', 'a b@c.example', 'a@@b.example']
  loop
    begin
      perform public.pre_register(v_bad);
      raise exception 'FAIL: 不正なアドレスが通った: %', coalesce(nullif(v_bad, ''), '(空)');
    exception
      when sqlstate '22023' then null;  -- INVALID_EMAIL。想定どおり
    end;
  end loop;
end $$;

\echo '=== 5. 長すぎるアドレスを弾く ==='
do $$
begin
  begin
    perform public.pre_register(repeat('a', 250) || '@pretest.example');
    raise exception 'FAIL: 254文字超が通った';
  exception
    when sqlstate '22023' then null;
  end;
end $$;

\echo '=== 6. 名簿は未ログイン・一般利用者から読めない ==='
-- テーブルに select ポリシーが1本(管理者のみ)しか無いことを確かめる。
-- anon 向けのポリシーが足されたら、ここで気づける。
do $$
declare
  v_policies text;
begin
  select string_agg(polname, ', ' order by polname) into v_policies
  from pg_policy
  where polrelid = 'public.pre_registrations'::regclass;

  if v_policies is distinct from 'pre_registrations_select_admin, pre_registrations_update_admin' then
    raise exception 'FAIL: 想定外のポリシーがある: %', coalesce(v_policies, '(なし)');
  end if;

  if not (select relrowsecurity from pg_class
          where oid = 'public.pre_registrations'::regclass) then
    raise exception 'FAIL: RLSが無効';
  end if;
end $$;

\echo '=== 7. insert ポリシーが無い(直接の書き込み口を開けていない) ==='
do $$
begin
  if exists (
    select 1 from pg_policy
    where polrelid = 'public.pre_registrations'::regclass
      and polcmd = 'a'  -- INSERT
  ) then
    raise exception 'FAIL: insertポリシーがある。名簿への直接書き込み口ができている';
  end if;
end $$;

\echo '=== 8. 関数の実行権が anon にある(未ログインから登録できる) ==='
do $$
begin
  if not has_function_privilege('anon', 'public.pre_register(text, text)', 'execute') then
    raise exception 'FAIL: anonがpre_registerを実行できない';
  end if;
  if not (select prosecdef from pg_proc
          where oid = 'public.pre_register(text, text)'::regprocedure) then
    raise exception 'FAIL: pre_registerがSECURITY DEFINERでない';
  end if;
end $$;

delete from public.pre_registrations where email like '%@pretest.example';

\echo '=== 87_pre_registration: 全項目OK ==='
