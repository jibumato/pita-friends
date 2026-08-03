-- ============================================================
-- 0094_close_anon_function_grants.sql
-- 未ログイン(anon)に開いていた関数を、一覧で決めた5本だけに絞る
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   0065 も 0093 も `revoke all on function ... from public` で閉じていた。
--   素の PostgreSQL ではこれで十分だが、**Supabase は public スキーマに
--   作られた関数を anon / authenticated / service_role へ「直接」GRANT する
--   既定権限を設定している。** 直接の付与は PUBLIC からの revoke では外れない。
--
--   その結果、本番では **163本の関数が「PUBLIC からは閉じているのに
--   anon からは呼べる」** 状態だった（2026-08-03 に計測）。
--   0065 が塞いだつもりだった2件も開いたままだった。
--
--     ・_booking_slot_conflict … 掲載中のピタメイト全員の稼働予定が復元できる
--     ・_ledger_record_bypass  … 追記専用の台帳に嘘の記録を積める
--
--   手元の検証環境がこの既定権限を再現していなかったため、
--   `74_anon_surface` が通ってしまい、気づけなかった。
--   シム(`supabase/tests/00_supabase_shim.sql`)に既定権限を足して
--   本番と同じ形にしたところ、同テストは落ちるようになった。
--
-- ■ 方針
--   **列挙ではなく、除外にする。** 未ログインに見せてよいものだけを
--   一覧で持ち、それ以外の public スキーマの関数からは anon の EXECUTE を
--   すべて取り上げる。関数を足し忘れても穴が開かない。
--
--   一覧は `supabase/tests/74_anon_surface.sql` と同じ5本。
--   増やすときは、**個人情報を返さないこと**と**登録前に見える必要があること**
--   の2つを説明できるものだけにする。
--
--   あわせて既定権限そのものを止める。以後、新しく作った関数が
--   自動で anon に開くことはない。
--
--   `authenticated` は**内部用のものだけ**閉じる。予約や購入は authenticated が
--   呼ぶので、同じやり方で全部閉じるとアプリが止まる。内部用の判定は
--   「名前が `_` で始まる」か「トリガー関数」。フロントが呼ぶ87本の RPC に
--   `_` 始まりは1つも無く、トリガー関数も呼んでいないことを確認した。
--   `service_role` は触らない（Edge Function が使う）。
-- ============================================================

-- ------------------------------------------------------------
-- (1) 以後に作る関数を、自動で anon に開かない
-- ------------------------------------------------------------
alter default privileges in schema public revoke execute on functions from anon;

-- ------------------------------------------------------------
-- (2) いま開いているものを、一覧の5本だけに絞る
-- ------------------------------------------------------------
do $$
declare
  -- 未ログインに見せてよいもの。74_anon_surface.sql と同じ内容。
  --   fee_rates          … 手数料の率。規約 第8条の2第3項で表示を約束している
  --   host_ranking       … 掲載一覧(0052)の材料
  --   host_repeat_guests … 同上
  --   host_repeat_stats  … 同上
  --   public_host_cards  … 同上。閉じるとトップが空になる
  c_allowed constant text[] := array[
    'fee_rates()',
    'host_ranking(p_period text, p_limit integer)',
    'host_repeat_guests(p_host_id uuid)',
    'host_repeat_stats(p_host_ids uuid[])',
    'public_host_cards(p_limit integer)'
  ];
  -- 運営(SQL/コンソール)か Edge Function だけが呼ぶもの。
  -- **利用者に開いていてはいけない**とテストが固定している一覧
  -- (73_admin_console / 75_web_push / 77_fast_release /
  --  93_payment_dispute_freeze / 96_card_and_residency)。
  -- `_` 始まりとトリガー関数は別途まとめて閉じるので、ここには書かない。
  c_backend constant text[] := array[
    'mark_payout_paid',            -- 振込の消込(運営)
    'mark_payout_failed',          -- 同上
    'resolve_report',              -- 通報の処理(運営)
    'auto_complete_bookings',      -- 自動確定(定期ジョブ)
    'claim_push_batch',            -- 送信待ちの取り出し(送信側)
    'mark_push_result',            -- 送信結果の記録(送信側)
    'disable_push_subscription',   -- 無効な購読の停止(送信側)
    'prune_push',                  -- 送信済みの片付け(定期ジョブ)
    'record_payment_card',         -- カード指紋の記録(Edge Function)
    'record_payment_dispute'       -- 異議の記録(同上)
  ];
  r record;
  n int := 0;
  m int := 0;
  v_left text;
  v_missing text;
begin
  for r in
    select p.oid,
           p.oid::regprocedure as sig,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as ident,
           p.proname,
           (p.proname like '\_%' or p.prorettype = 'trigger'::regtype) as is_internal
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prokind = 'f'
       -- **拡張が入れた関数は触らない。** pgcrypto の digest / gen_random_uuid 等が
       -- public スキーマに入っており、所有者も違う。暗号の計算をするだけで
       -- 当方のデータには触れないので、閉じる対象ではない
       and not exists (
         select 1 from pg_depend d
          where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
  loop
    if r.ident <> all (c_allowed)
       and (has_function_privilege('anon', r.oid, 'execute')
            or has_function_privilege('public', r.oid, 'execute')) then
      -- **PUBLIC と anon の両方から取り上げる。**
      -- Supabase は anon へ直接 GRANT するので PUBLIC だけでは外れず、
      -- 逆に新しい関数は PUBLIC 経由でも開くため、両方が要る
      execute format('revoke all on function %s from public, anon', r.sig);
      n := n + 1;
    end if;

    -- 内部用の補助関数とトリガー関数は、ログイン済みの利用者からも閉じる。
    -- SECURITY DEFINER 関数の中から呼ばれるだけで、そのときは定義者の
    -- 権限で動くので、利用者側の EXECUTE は要らない
    if (r.is_internal or r.proname = any (c_backend))
       and has_function_privilege('authenticated', r.oid, 'execute') then
      execute format('revoke all on function %s from authenticated', r.sig);
      m := m + 1;
    end if;
  end loop;

  raise notice '0094: PUBLIC/anon から % 本、authenticated から % 本(内部用)を取り上げました', n, m;

  -- ------------------------------------------------------------
  -- 結果で確かめる。**Supabase の SQL Editor は NOTICE も WARNING も
  -- 表示しない**ので、「成功したのに効いていない」を作らせない。
  -- ------------------------------------------------------------
  select string_agg(x, ', ' order by x) into v_left
    from (
      select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as x
        from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.prokind = 'f'
         and not exists (
           select 1 from pg_depend d
            where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
         and has_function_privilege('anon', p.oid, 'execute')
    ) t
   where x <> all (c_allowed);

  if v_left is not null then
    raise exception E'0094: 未ログインに開いたままの関数があります。\n'
      '関数の所有者を確認してください（所有者でないと revoke は警告だけで何もしません）。\n'
      '残り: %', v_left;
  end if;

  -- 閉じすぎていないか。**トップページが空になるほうが気づきにくい。**
  select string_agg(x, ', ' order by x) into v_missing
    from unnest(c_allowed) x
   where not exists (
     select 1
       from pg_proc p
       join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public'
        and p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' = x
        and has_function_privilege('anon', p.oid, 'execute'));

  if v_missing is not null then
    raise exception '0094: 未ログインに見せる前提の関数が閉じています(トップが空になります): %', v_missing;
  end if;

  -- 内部用がログイン済みに開いたままなら止める
  select string_agg(x, ', ' order by x) into v_left
    from (
      select p.oid::regprocedure::text as x
        from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.prokind = 'f'
         and not exists (
           select 1 from pg_depend d
            where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
         and (p.proname like '\_%' or p.prorettype = 'trigger'::regtype
              or p.proname = any (c_backend))
         and has_function_privilege('authenticated', p.oid, 'execute')
    ) t;

  if v_left is not null then
    raise exception '0094: 内部用・運営用の関数がログイン済み利用者に開いたままです: %', v_left;
  end if;

  raise notice '0094: 未ログインに開いているのは一覧の5本だけになりました';
end $$;
