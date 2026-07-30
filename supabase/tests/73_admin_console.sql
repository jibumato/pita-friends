-- 運営コンソール(0066)の検証。
--
-- 重点は2つ。
--   ・**運営以外には一切見えないこと。** 通報の中身・口座情報・保留中の予約は、
--     RLSが利用者本人に絞っているものを SECURITY DEFINER で開けている。
--     判定が1本抜けると全部漏れる。
--   ・**操作が記録に残ること。** 返金の承認・振込の消し込み・通報の処分は
--     後から「誰の判断か」を説明できる必要がある。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('ca000000-0000-0000-0000-00000000000a'::uuid),  -- 運営
  ('ca000000-0000-0000-0000-000000000001'::uuid),  -- ゲスト
  ('ca000000-0000-0000-0000-000000000009'::uuid)   -- ピタメイト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('ca000000-0000-0000-0000-00000000000a'::uuid, '運営の人'),
  ('ca000000-0000-0000-0000-000000000001'::uuid, '申し出ゲスト'),
  ('ca000000-0000-0000-0000-000000000009'::uuid, '保留メイト')
on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('ca000000-0000-0000-0000-00000000000a'::uuid)
  on conflict do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id = 'ca000000-0000-0000-0000-000000000009'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate)
  values ('ca000000-0000-0000-0000-000000000009'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true;
insert into public.coin_wallets (user_id, balance, earned_balance) values
  ('ca000000-0000-0000-0000-000000000009'::uuid, 0, 20000)
  on conflict (user_id) do update set earned_balance = 20000;

-- 保留中の予約(ピタメイトの報酬が凍結されている状態)
set app.ledger_override = 'on';
insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, status,
                             scheduled_at, confirmed_at, held_at, hold_reason)
values ('ca000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000009'::uuid,
        60, 2000, 2000, 'confirmed',
        now() - interval '20 days', now() - interval '20 days',
        now() - interval '18 days', 'claim');
reset app.ledger_override;

-- 通報(重いものが上に来るか見るため2件)
insert into public.reports (reporter_id, reported_id, category, severity, message_snapshot, status)
values ('ca000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000009'::uuid,
        'other', 'low', '["軽い通報"]'::jsonb, 'open'),
       ('ca000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000009'::uuid,
        'external_invite', 'high', '["外部誘導された"]'::jsonb, 'open');

-- 換金申請(口座情報つき)
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana)
values ('ca000000-0000-0000-0000-000000000009'::uuid, 'ピタ銀行', '0001', '本店', '001',
        '普通', '1234567', 'ホリユウメイト')
on conflict (user_id) do update set bank_name = excluded.bank_name;

set test.uid = 'ca000000-0000-0000-0000-000000000009';
select public.request_bank_payout(10000);
reset test.uid;

\echo '=== 1. 運営以外には一切見えない ==='
set test.uid = 'ca000000-0000-0000-0000-000000000001';
do $$
declare f text;
begin
  foreach f in array array[
    'select public.admin_console_summary()',
    'select * from public.admin_reports()',
    'select * from public.admin_held_bookings()',
    'select * from public.admin_pending_payouts()',
    'select * from public.admin_account_requests()',
    'select public.admin_health()',
    'select * from public.admin_recent_actions()'
  ] loop
    begin
      execute f;
      raise exception 'FAIL: 運営でないのに通った: %', f;
    exception when others then
      if sqlerrm not like '%NOT_ADMIN%' then
        raise exception 'FAIL: NOT_ADMIN以外で落ちた(% / %)', f, sqlerrm;
      end if;
    end;
  end loop;
end $$;

\echo '=== 2. 運営でない人は書き込みもできない ==='
do $$
declare v_id uuid;
begin
  select id into v_id from public.reports where severity = 'high';
  begin
    perform public.admin_resolve_report(v_id, '勝手に処分');
    raise exception 'FAIL: 運営でないのに通報を処分できた';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;

  select id into v_id from public.payouts where status = 'pending';
  begin
    perform public.admin_mark_payout_paid(v_id);
    raise exception 'FAIL: 運営でないのに振込済みにできた';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
end $$;

\echo '=== 3. 生の関数は利用者に開いていない(包みだけが開いている) ==='
do $$
begin
  -- resolve_report / mark_payout_* は中に管理者判定を持たないので、
  -- 直接開いていると誰でも他人の処分を書けてしまう
  if has_function_privilege('authenticated', 'public.resolve_report(uuid, text, text, numeric)', 'execute') then
    raise exception 'FAIL: resolve_report が利用者に開いている(管理者判定が中に無い)';
  end if;
  if has_function_privilege('authenticated', 'public.mark_payout_paid(uuid)', 'execute') then
    raise exception 'FAIL: mark_payout_paid が利用者に開いている';
  end if;
  if has_function_privilege('authenticated', 'public.mark_payout_failed(uuid, text)', 'execute') then
    raise exception 'FAIL: mark_payout_failed が利用者に開いている';
  end if;
  if has_function_privilege('authenticated', 'public._log_admin_action(text, uuid, text)', 'execute') then
    raise exception 'FAIL: 記録の書き込み関数が利用者に開いている(履歴を捏造できる)';
  end if;
  if has_function_privilege('anon', 'public.admin_console_summary()', 'execute') then
    raise exception 'FAIL: 未ログインが運営の口を叩ける';
  end if;
end $$;

\echo '=== 4. ダッシュボードの件数 ==='
set test.uid = 'ca000000-0000-0000-0000-00000000000a';
do $$
declare v jsonb;
begin
  v := public.admin_console_summary();
  if (v->>'未対応の通報')::int <> 2 then
    raise exception 'FAIL: 通報の件数が合わない: %', v->>'未対応の通報';
  end if;
  if (v->>'保留中の予約')::int <> 1 then
    raise exception 'FAIL: 保留の件数が合わない: %', v->>'保留中の予約';
  end if;
  -- 18日前から保留 = 0042の督促(14日)を超えている
  if (v->>'保留の最長日数')::int < 17 then
    raise exception 'FAIL: 保留の日数が出ていない: %', v->>'保留の最長日数';
  end if;
  if (v->>'未処理の換金申請')::int <> 1 then
    raise exception 'FAIL: 換金申請の件数が合わない: %', v->>'未処理の換金申請';
  end if;
  if (v->>'換金申請の合計コイン')::int <> 10000 then
    raise exception 'FAIL: 換金申請の合計が合わない: %', v->>'換金申請の合計コイン';
  end if;
end $$;

\echo '=== 5. 通報は重い順・古い順に並ぶ ==='
do $$
declare v_first text;
begin
  select severity into v_first from public.admin_reports('open', 10) limit 1;
  if v_first <> 'high' then
    raise exception 'FAIL: 重い通報が先頭に来ていない: %', v_first;
  end if;
  -- 相手の通報累計が出る(常習かどうかの判断材料)
  if (select reported_report_count from public.admin_reports('open', 10) limit 1) <> 2 then
    raise exception 'FAIL: 通報の累計が出ていない';
  end if;
  -- 判断に必要なのでメッセージのスナップショットは返す
  if (select message_snapshot from public.admin_reports('open', 10) limit 1) is null then
    raise exception 'FAIL: メッセージのスナップショットが無い';
  end if;
end $$;

\echo '=== 6. 保留中の予約は日数つきで出る ==='
do $$
declare r record;
begin
  select * into r from public.admin_held_bookings(10) limit 1;
  if r.id is null then raise exception 'FAIL: 保留中の予約が出ない'; end if;
  if r.held_days < 17 then raise exception 'FAIL: 保留日数が出ていない: %', r.held_days; end if;
  if r.host_name <> '保留メイト' or r.guest_name <> '申し出ゲスト' then
    raise exception 'FAIL: 当事者の名前が出ていない';
  end if;
  if r.coins <> 2000 then raise exception 'FAIL: 凍結されている額が出ていない'; end if;
end $$;

\echo '=== 7. 換金申請は口座情報を返し、見たことが記録される ==='
do $$
declare r record; v_logs int;
begin
  select count(*) into v_logs from public.admin_actions where kind = 'view_pending_payouts';
  select * into r from public.admin_pending_payouts(10) limit 1;
  if r.account_number <> '1234567' then
    raise exception 'FAIL: 口座番号が出ていない(振込作業ができない)';
  end if;
  if r.amount_yen <> 9700 then  -- 10000 - 手数料300
    raise exception 'FAIL: 振込額が合わない: %', r.amount_yen;
  end if;
  if not r.is_verified then
    raise exception 'FAIL: 本人確認済みかどうかが出ていない';
  end if;
  -- **口座を見たこと自体が残る**
  if (select count(*) from public.admin_actions where kind = 'view_pending_payouts') <= v_logs then
    raise exception 'FAIL: 口座情報の閲覧が記録されていない';
  end if;
end $$;

\echo '=== 8. 処分には理由が必須。処分は記録に残る ==='
do $$
declare v_id uuid;
begin
  select id into v_id from public.reports where severity = 'high';
  begin
    perform public.admin_resolve_report(v_id, '   ');
    raise exception 'FAIL: 空白だけの理由で処分できた';
  exception when others then
    if sqlerrm not like '%RESOLUTION_REQUIRED%' then raise; end if;
  end;

  perform public.admin_resolve_report(v_id, '外部誘導を確認。警告のうえ減点', 'resolved', 5);
  if (select status from public.reports where id = v_id) <> 'resolved' then
    raise exception 'FAIL: 処分が反映されていない';
  end if;
  if not exists (select 1 from public.admin_actions
                 where kind = 'resolve_report' and target_id = v_id and note like '%外部誘導%') then
    raise exception 'FAIL: 処分が記録されていない';
  end if;
  -- 減点も入っている
  if not exists (select 1 from public.manner_penalties where report_id = v_id) then
    raise exception 'FAIL: 減点が入っていない';
  end if;
end $$;

\echo '=== 9. 保留の解除。割合が記録に残る ==='
do $$
declare v_id uuid; v_before int;
begin
  select id into v_id from public.bookings where held_at is not null;
  select earned_balance into v_before from public.coin_wallets
    where user_id = 'ca000000-0000-0000-0000-000000000009'::uuid;

  -- 50%返還で解除
  perform public.admin_release_hold_refund(v_id, 50, 'ログを確認。半額返還で合意');

  if (select held_at from public.bookings where id = v_id) is not null then
    raise exception 'FAIL: 保留が解けていない';
  end if;
  -- ピタメイトには残り半分が入る
  if (select earned_balance from public.coin_wallets
      where user_id = 'ca000000-0000-0000-0000-000000000009'::uuid) <> v_before + 1000 then
    raise exception 'FAIL: 解除後の報酬が合わない';
  end if;
  -- **割合が記録に残る**(後から「なぜ50%か」を説明できる)
  if not exists (select 1 from public.admin_actions
                 where kind = 'release_hold_refund' and target_id = v_id and note like '50%%') then
    raise exception 'FAIL: 返還の割合が記録されていない';
  end if;
end $$;

\echo '=== 10. 振込の消し込み。pending以外は弾く ==='
do $$
declare v_id uuid;
begin
  select id into v_id from public.payouts where status = 'pending';
  perform public.admin_mark_payout_paid(v_id, '週次振込 第1回');
  if (select status from public.payouts where id = v_id) <> 'paid' then
    raise exception 'FAIL: 振込済みになっていない';
  end if;
  if not exists (select 1 from public.admin_actions
                 where kind = 'mark_payout_paid' and target_id = v_id and note like '%9700円%') then
    raise exception 'FAIL: 振込の消し込みが記録されていない';
  end if;
  -- 二重に押しても通らない
  begin
    perform public.admin_mark_payout_paid(v_id);
    raise exception 'FAIL: 2回目が通った(二重振込の記録ができる)';
  exception when others then
    if sqlerrm not like '%PAYOUT_NOT_PENDING%' then raise; end if;
  end;

  -- 失敗には理由が必須
  begin
    perform public.admin_mark_payout_failed(v_id, '');
    raise exception 'FAIL: 理由なしで失敗にできた';
  exception when others then
    if sqlerrm not like '%REASON_REQUIRED%' then raise; end if;
  end;
end $$;

\echo '=== 11. 記録は運営だけが読め、後から書き換えられない ==='
do $$
declare v text;
begin
  select string_agg(polname || ':' || polcmd::text, ', ' order by polname) into v
  from pg_policy where polrelid = 'public.admin_actions'::regclass;
  if v is distinct from 'admin_actions_select_admin:r' then
    raise exception 'FAIL: 記録のポリシーが想定外(読み取り専用のはず): %', coalesce(v, '(なし)');
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.admin_actions'::regclass) then
    raise exception 'FAIL: 記録のRLSが無効';
  end if;
end $$;

\echo '=== 12. 健全性(整合性・台帳・プッシュ) ==='
do $$
declare v jsonb;
begin
  v := public.admin_health();
  if v->'integrity' is null then raise exception 'FAIL: integrityが無い'; end if;
  if v->'push' is null then raise exception 'FAIL: pushが無い'; end if;
  if (v->'push'->>'pending') is null then raise exception 'FAIL: プッシュの滞留が出ない'; end if;
end $$;

reset test.uid;
-- 片付け。profiles を消すと coin_lots まで cascade するので、
-- 追記専用の宣言は最後まで外さない(0044)
set app.ledger_override = 'on';
delete from public.admin_actions where actor::text like 'ca000000-%';
delete from public.manner_penalties where user_id::text like 'ca000000-%';
delete from public.reports where reporter_id::text like 'ca000000-%';
delete from public.coin_transactions where user_id::text like 'ca000000-%';
delete from public.payouts where user_id::text like 'ca000000-%';
delete from public.bookings where guest_id::text like 'ca000000-%' or host_id::text like 'ca000000-%';
delete from public.host_bank_accounts where user_id::text like 'ca000000-%';
delete from public.admins where user_id::text like 'ca000000-%';
delete from public.host_settings where user_id::text like 'ca000000-%';
delete from public.coin_wallets where user_id::text like 'ca000000-%';
delete from public.profiles where id::text like 'ca000000-%';
delete from auth.users where id::text like 'ca000000-%';
reset app.ledger_override;

\echo '=== 73_admin_console: 全項目OK ==='
