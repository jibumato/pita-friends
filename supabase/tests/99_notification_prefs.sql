-- ============================================================
-- 99: 通知設定の自己修復(0084)の検証
-- ------------------------------------------------------------
-- 直した不具合は「設定画面の通知トグルが押しても無反応」。
-- 原因は notification_prefs の**行が無い**こと(0012のトリガより前に
-- 登録したユーザー)。読み取りは .single() で落ち、書き込みは
-- update … where user_id = … が**0行更新で成功扱い**になっていた。
--
-- ここで固定するのは4つ:
--   ・行が無くても取得できること(既定値で作られる)
--   ・行が無くても保存できること(**静かに0行更新にならない**)
--   ・null の項目は変更しないこと(他の端末の設定を巻き戻さない)
--   ・未ログインからは呼べないこと(SECURITY DEFINER なので)
--
-- 注意: テストは superuser で走るので RLS と GRANT は素通りする。
--       権限は has_function_privilege で見る。
-- ============================================================
\set ON_ERROR_STOP on

-- 0084 の救済INSERTは migration 適用時点のユーザーにしか効かない。
-- **後から「行の無いユーザー」を作って、関数側が自力で直せることを見る**
insert into auth.users (id) values ('c1000000-0000-0000-0000-000000000001');
insert into public.profiles (id, nickname) values
  ('c1000000-0000-0000-0000-000000000001','通知テスト') on conflict (id) do nothing;
delete from public.notification_prefs
 where user_id = 'c1000000-0000-0000-0000-000000000001';

set test.uid = 'c1000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
\echo '=== 1. 行が無くても取得でき、既定値が返ること ==='
do $$
declare v jsonb; v_n int;
begin
  v := public.get_notification_prefs();
  if v is null then
    raise exception 'FAIL: 行が無いと取得できない(不具合が再発している)';
  end if;
  if (v->>'notify_invites')::boolean is not true
     or (v->>'notify_online_friends')::boolean is not true
     or (v->>'notify_recommendations')::boolean is not false then
    raise exception 'FAIL: 既定値が表のdefaultと食い違う(%)', v;
  end if;

  select count(*) into v_n from public.notification_prefs
   where user_id = 'c1000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'FAIL: 行が作られていない(%)', v_n; end if;
  raise notice 'OK: 無ければ既定値で作ってから返す %', v;
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 保存できること(0行更新で静かに消えないこと) ==='
do $$
declare v jsonb; v_saved boolean;
begin
  v := public.set_notification_prefs(p_recommendations => true);
  if (v->>'notify_recommendations')::boolean is not true then
    raise exception 'FAIL: 戻り値に保存後の値が入っていない(%)', v;
  end if;
  -- **戻り値だけを見ない。** 表に本当に書けたかを確かめる
  select notify_recommendations into v_saved from public.notification_prefs
   where user_id = 'c1000000-0000-0000-0000-000000000001';
  if v_saved is not true then
    raise exception 'FAIL: 表に保存されていない(0行更新になっている)';
  end if;
  raise notice 'OK: おすすめマッチをONにでき、表にも入っている';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 行が無い状態でいきなり保存しても通ること ==='
-- 画面を開かずにトグルだけ押される経路(取得が失敗しても押せる)
delete from public.notification_prefs
 where user_id = 'c1000000-0000-0000-0000-000000000001';
do $$
declare v jsonb;
begin
  v := public.set_notification_prefs(p_invites => false);
  if (v->>'notify_invites')::boolean is not false then
    raise exception 'FAIL: 行が無いと保存できない(%)', v;
  end if;
  raise notice 'OK: 行が無い状態からでも保存できる';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. null の項目は変更しないこと ==='
-- 3つまとめて送る作りだと、別の端末で先に変えた設定を上書きしてしまう。
-- ここが崩れると「片方を触ったらもう片方が戻る」という直しにくい不具合になる
do $$
declare v jsonb;
begin
  perform public.set_notification_prefs(
    p_invites => false, p_online_friends => false, p_recommendations => true);
  -- 1つだけ触る
  v := public.set_notification_prefs(p_online_friends => true);
  if (v->>'notify_invites')::boolean is not false then
    raise exception 'FAIL: 触っていない notify_invites が変わった(%)', v;
  end if;
  if (v->>'notify_recommendations')::boolean is not true then
    raise exception 'FAIL: 触っていない notify_recommendations が変わった(%)', v;
  end if;
  if (v->>'notify_online_friends')::boolean is not true then
    raise exception 'FAIL: 指定した項目が変わっていない(%)', v;
  end if;
  raise notice 'OK: 指定した項目だけが変わる';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 未ログインからは呼べないこと ==='
-- SECURITY DEFINER は RLS を飛び越えるので、権限を剥がし忘れると
-- 他人の行を作れてしまう(user_id は auth.uid() 固定だが、それでも開けない)
do $$
begin
  if has_function_privilege('anon', 'public.get_notification_prefs()', 'execute') then
    raise exception 'FAIL: 未ログインが get_notification_prefs を実行できる';
  end if;
  if has_function_privilege('anon',
       'public.set_notification_prefs(boolean, boolean, boolean)', 'execute') then
    raise exception 'FAIL: 未ログインが set_notification_prefs を実行できる';
  end if;
  if not has_function_privilege('authenticated', 'public.get_notification_prefs()', 'execute') then
    raise exception 'FAIL: ログイン済みが get_notification_prefs を実行できない';
  end if;
  if not has_function_privilege('authenticated',
       'public.set_notification_prefs(boolean, boolean, boolean)', 'execute') then
    raise exception 'FAIL: ログイン済みが set_notification_prefs を実行できない';
  end if;
  raise notice 'OK: anon は不可 / authenticated は可';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 未ログイン(auth.uid()がnull)では例外になること ==='
reset test.uid;
do $$
begin
  perform public.get_notification_prefs();
  raise exception 'FAIL: 未ログインで取得できてしまった';
exception when others then
  if sqlerrm <> 'AUTH_REQUIRED' then raise; end if;
  raise notice 'OK: AUTH_REQUIRED で止まる';
end $$;

\echo '=== 99: 通知設定の自己修復 すべて通過 ==='
