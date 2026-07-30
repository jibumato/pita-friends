-- 未ログイン(anon)から届く範囲を固定する。
--
-- PostgreSQL は**関数を作ると既定で PUBLIC に EXECUTE を与える。**
-- `revoke all ... from public` を書き忘れた関数は、そのぶん未ログインからも
-- 呼べる状態になる。そして **SECURITY DEFINER 関数は RLS を飛び越える**ので、
-- 内部用の補助関数が1本漏れるだけで、テーブルの権限をいくら正しく張っても
-- 迂回されてしまう(0065 で実際に2件見つかった)。
--
-- そこで**一覧を丸ごとここに書き写して固定する。** 関数を足して revoke を
-- 忘れると、このテストが落ちる。
--
-- ⚠️ このテストが落ちたときに、期待値の側を安易に書き換えないこと。
--    まず「その関数を未ログインに見せてよいか」を考える。見せてよい理由が
--    説明できるものだけ、下の一覧に足す。

\set ON_ERROR_STOP on

\echo '=== 1. 未ログインが実行できる SECURITY DEFINER 関数は、この一覧だけ ==='
do $$
declare
  -- 未ログインに開いていてよいもの。掲載一覧(0052)を未ログインでも
  -- 見せる設計なので、その材料だけが並ぶ。
  c_allowed constant text[] := array[
    'host_ranking(p_period text, p_limit integer)',
    'host_repeat_guests(p_host_id uuid)',
    'host_repeat_stats(p_host_ids uuid[])',
    'public_host_cards(p_limit integer)'
  ];
  v_actual text[];
  v_extra text[];
  v_missing text[];
begin
  select coalesce(array_agg(f order by f), array[]::text[]) into v_actual
  from (
    select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as f
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and has_function_privilege('anon', p.oid, 'execute')
  ) t;

  select coalesce(array_agg(x), array[]::text[]) into v_extra
  from unnest(v_actual) x where x <> all (c_allowed);
  select coalesce(array_agg(x), array[]::text[]) into v_missing
  from unnest(c_allowed) x where x <> all (v_actual);

  if array_length(v_extra, 1) > 0 then
    raise exception e'FAIL: 未ログインに開いているSECURITY DEFINER関数が増えています。\n'
      '  → %\n'
      '  RLSを飛び越えるので、まず revoke all ... from public を書いてください。\n'
      '  未ログインに見せてよい理由が説明できるものだけ、このテストの一覧に足すこと。',
      array_to_string(v_extra, e'\n  → ');
  end if;
  if array_length(v_missing, 1) > 0 then
    raise exception e'FAIL: 未ログインに見せる前提の関数が閉じています(トップページが空になります)。\n  → %',
      array_to_string(v_missing, e'\n  → ');
  end if;
end $$;

\echo '=== 2. 未ログインはどのテーブルも直接読めない ==='
do $$
declare v text;
begin
  select string_agg(distinct table_name, ', ' order by table_name) into v
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public';
  if v is not null then
    raise exception 'FAIL: anonにテーブル権限がある: %', v;
  end if;
end $$;

\echo '=== 3. 内部用の補助関数は誰にも開いていない ==='
-- 0065 で閉じた3本。開くと「他人の予定が読める」「台帳に嘘が書ける」に戻る
do $$
declare
  v record;
  c_internal constant text[] := array[
    'public._booking_slot_conflict(uuid, timestamptz, int, uuid, text[])',
    'public._ledger_record_bypass(text, text, jsonb, jsonb)',
    'public._lock_booking_slots(uuid, uuid)',
    'public._played_together_count(uuid, uuid)'
  ];
  f text;
begin
  foreach f in array c_internal loop
    if has_function_privilege('anon', f, 'execute') then
      raise exception 'FAIL: 未ログインが % を呼べます', f;
    end if;
    if has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL: 利用者が % を呼べます(内部用のはず)', f;
    end if;
  end loop;
end $$;

\echo '=== 4. 予約表が外から復元できないこと(0065で塞いだ本体) ==='
insert into auth.users (id) values
  ('ba000000-0000-0000-0000-000000000001'::uuid),
  ('ba000000-0000-0000-0000-000000000009'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('ba000000-0000-0000-0000-000000000001'::uuid, '予定ゲスト'),
  ('ba000000-0000-0000-0000-000000000009'::uuid, '予定メイト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'ba000000-0000-0000-0000-000000000009'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate)
  values ('ba000000-0000-0000-0000-000000000009'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true;
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, status,
                             scheduled_at, requested_start_at)
values ('ba000000-0000-0000-0000-000000000001'::uuid,
        'ba000000-0000-0000-0000-000000000009'::uuid,
        60, 2000, 'confirmed',
        date_trunc('day', now()) + interval '1 day 21 hours',
        date_trunc('day', now()) + interval '1 day 21 hours');
reset app.ledger_override;

set role anon;
do $$
declare v_id uuid;
begin
  -- 未ログインで他人の予定を探ろうとすると、権限で弾かれる
  begin
    select public._booking_slot_conflict(
             'ba000000-0000-0000-0000-000000000009'::uuid,
             date_trunc('day', now()) + interval '1 day 21 hours', 60) into v_id;
    raise exception 'FAIL: 未ログインで他人の予定が引けました(予約ID %)', v_id;
  exception when insufficient_privilege then
    null; -- これが期待する結果
  end;
end $$;

\echo '=== 5. 未ログインで台帳に書き込めないこと ==='
do $$
begin
  begin
    perform public._ledger_record_bypass('payouts', 'UPDATE',
      '{"amount_yen": 1}'::jsonb, '{"amount_yen": 9999999}'::jsonb);
    raise exception 'FAIL: 未ログインで台帳に行を差し込めました';
  exception when insufficient_privilege then
    null; -- これが期待する結果
  end;
end $$;
reset role;

do $$
begin
  if exists (select 1 from public.ledger_audit where (new_row->>'amount_yen') = '9999999') then
    raise exception 'FAIL: 偽の台帳行が入っています';
  end if;
end $$;

\echo '=== 6. 掲載一覧は未ログインでも動く(閉じすぎていないこと) ==='
set role anon;
do $$
begin
  perform public.public_host_cards(10);
  perform public.host_ranking('week', 10);
  perform public.host_repeat_guests('ba000000-0000-0000-0000-000000000009'::uuid);
  perform public.host_repeat_stats(array['ba000000-0000-0000-0000-000000000009'::uuid]);
end $$;
reset role;

\echo '=== 7. 台帳は運営だけ、送信待ちは誰も読めない ==='
do $$
declare t text; v text;
begin
  foreach t in array array['ledger_audit', 'push_outbox'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'FAIL: % のRLSが無効です', t;
    end if;
  end loop;

  -- 台帳は運営(admins)だけが読める。利用者に開くと他人の入出金が見える
  select string_agg(polname || ':' || polcmd::text, ', ' order by polname) into v
  from pg_policy where polrelid = 'public.ledger_audit'::regclass;
  if v is distinct from 'ledger_audit_select_admin:r' then
    raise exception 'FAIL: 台帳のポリシーが想定外です: %', coalesce(v, '(なし)');
  end if;
  if (select pg_get_expr(polqual, polrelid) from pg_policy
      where polrelid = 'public.ledger_audit'::regclass) !~ 'admins' then
    raise exception 'FAIL: 台帳の読み取りが運営に限定されていません';
  end if;

  -- 送信待ちは誰にも見せない(自分の通知は notifications で見える)
  if exists (select 1 from pg_policy where polrelid = 'public.push_outbox'::regclass) then
    raise exception 'FAIL: push_outbox にポリシーがあります(利用者に見せる必要はない)';
  end if;
end $$;

set app.ledger_override = 'on';
delete from public.bookings where guest_id::text like 'ba000000-%';
reset app.ledger_override;
delete from public.host_settings where user_id::text like 'ba000000-%';
delete from public.profiles where id::text like 'ba000000-%';
delete from auth.users where id::text like 'ba000000-%';

\echo '=== 74_anon_surface: 全項目OK ==='
