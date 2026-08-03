-- ============================================================
-- 0095_close_server_only_functions.sql
-- Edge Function だけが呼ぶ関数を、利用者から閉じる
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   `docs/check-cron.sql` が、0094 適用後の本番で1件を赤にした。
--
--     public.credit_coins_for_purchase(...)  ❌ authenticated に開いている
--
--   **これはコインを付与する関数で、security definer なのに中に権限チェックが
--   無い。** 引数で「誰に」「何コインを」渡せるため、ログインさえしていれば
--   自分に無制限にコインを付与できた。
--   本来 stripe-webhook が service_role で呼ぶだけのもの。
--
--   0094 は「`_` 始まり・トリガー関数・テストが名指しした運営用」を閉じたが、
--   **この関数はどれにも当てはまらなかった。** 名前で見分ける方式の穴。
--
-- ■ 方針
--   **Edge Function だけが呼ぶ関数**を明示して閉じる。
--   `supabase/functions/` の中で呼ばれ、かつ `src/` からは呼ばれないもの
--   （フロントの87本の RPC と突き合わせて確認済み）。
--   `service_role` は触らないので、Edge Function からは今までどおり動く。
--
--   再発防止として `supabase/tests/74_anon_surface.sql` に固定した。
-- ============================================================

do $$
declare
  -- Edge Function(service_role)だけが呼ぶもの。
  --   credit_coins_for_purchase … コインの付与(stripe-webhook)★最重要
  --   check_purchase_allowed    … 購入上限の判定(create-checkout-session)
  --   safety_fee_for            … あんしんサポート料の計算(同上)
  --   record_ip                 … IPの記録(record-ip)
  -- 送信側・カード/異議の記録は 0094 で閉じ済み。
  c_server_only constant text[] := array[
    'credit_coins_for_purchase',
    'check_purchase_allowed',
    'safety_fee_for',
    'record_ip'
  ];
  r record;
  n int := 0;
  v_left text;
begin
  for r in
    select p.oid, p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prokind = 'f'
       and p.proname = any (c_server_only)
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    n := n + 1;
  end loop;

  raise notice '0095: % 本の関数を利用者から閉じました', n;

  if n = 0 then
    raise exception '0095: 対象の関数が1つも見つかりません。関数名を確認してください';
  end if;

  -- 結果で確かめる。SQL Editor は NOTICE も WARNING も表示しないため
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_left
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = any (c_server_only)
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('anon', p.oid, 'execute'));

  if v_left is not null then
    raise exception '0095: まだ利用者に開いています: %', v_left;
  end if;

  -- **閉じすぎていないか。** service_role が失うと決済が丸ごと止まる
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_left
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = any (c_server_only)
     and not has_function_privilege('service_role', p.oid, 'execute');

  if v_left is not null then
    raise exception '0095: service_role が実行できなくなっています(決済が止まります): %', v_left;
  end if;

  raise notice '0095: service_role からは今までどおり呼べます';
end $$;
