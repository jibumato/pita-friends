-- 外部エクスポートの鮮度チェック(0047)の検証。
--
-- バックアップの仕組みそのものより、「止まったことに気づけるか」のほうが
-- 大事です。ここでは止まり方ごとに鳴るかどうかを見ます。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('e1000000-0000-0000-0000-0000000000d9'::uuid),
  ('e1000000-0000-0000-0000-0000000000d1'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('e1000000-0000-0000-0000-0000000000d9'::uuid, 'エクスポート運営'),
  ('e1000000-0000-0000-0000-0000000000d1'::uuid, '一般')
on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('e1000000-0000-0000-0000-0000000000d9'::uuid)
  on conflict do nothing;

set test.uid = 'e1000000-0000-0000-0000-0000000000d9';

\echo '=== 1. 一度も実行されていなければ error ==='
do $$
declare v_err int; v_sev text;
begin
  v_err := public.check_ledger_export();
  select severity into v_sev from public.integrity_latest
    where check_name = 'ledger_export_freshness';
  if v_err <> 1 or v_sev <> 'error' then
    raise exception 'FAIL 未実行を検知できていない(err=% sev=%)', v_err, v_sev;
  end if;
  raise notice 'OK 一度も書き出していない状態を error として検知した';
end $$;

\echo '=== 2. エラー時に管理者へ通知が飛ぶ ==='
do $$
declare v_n int;
begin
  select count(*) into v_n from public.notifications
    where user_id = 'e1000000-0000-0000-0000-0000000000d9'::uuid
      and type = 'integrity_alert';
  if v_n < 1 then raise exception 'FAIL 通知が飛んでいない'; end if;
  raise notice 'OK 管理者に通知が届いている(% 件)', v_n;
end $$;

\echo '=== 3. 差分・全量とも直近に成功していれば ok ==='
insert into public.ledger_exports (ran_at, kind, ok, row_count) values
  (now() - interval '20 minutes', 'incremental', true, 12),
  (now() - interval '5 hours', 'snapshot', true, 340);
do $$
declare v_err int; v_sev text;
begin
  v_err := public.check_ledger_export();
  select severity into v_sev from public.integrity_latest
    where check_name = 'ledger_export_freshness';
  if v_err <> 0 or v_sev <> 'ok' then
    raise exception 'FAIL 正常なのに鳴っている(err=% sev=%)', v_err, v_sev;
  end if;
  raise notice 'OK 直近に成功していれば ok';
end $$;

\echo '=== 4. 差分が3時間以上止まっていれば error ==='
do $$
declare v_sev text; v_detail jsonb;
begin
  update public.ledger_exports set ran_at = now() - interval '5 hours'
    where kind = 'incremental';
  perform public.check_ledger_export();
  select severity, detail into v_sev, v_detail from public.integrity_latest
    where check_name = 'ledger_export_freshness';
  if v_sev <> 'error' then raise exception 'FAIL 差分の停止を検知できていない: %', v_sev; end if;
  raise notice 'OK 差分が%時間止まって error になった', v_detail->>'incremental_age_hours';
end $$;

\echo '=== 5. 全量が26時間以上止まっていれば error ==='
do $$
declare v_sev text;
begin
  update public.ledger_exports set ran_at = now() - interval '20 minutes'
    where kind = 'incremental';
  update public.ledger_exports set ran_at = now() - interval '30 hours'
    where kind = 'snapshot';
  perform public.check_ledger_export();
  select severity into v_sev from public.integrity_latest
    where check_name = 'ledger_export_freshness';
  if v_sev <> 'error' then raise exception 'FAIL 全量の停止を検知できていない: %', v_sev; end if;
  raise notice 'OK 全量が30時間止まって error になった';
end $$;

\echo '=== 6. 失敗した実行は「成功」として数えない ==='
do $$
declare v_sev text;
begin
  update public.ledger_exports set ran_at = now() - interval '20 minutes'
    where kind = 'snapshot';
  -- 直近の差分を失敗にすると、成功の最新は5時間前のまま → error
  update public.ledger_exports set ok = false, error = 'R2 put failed'
    where kind = 'incremental';
  perform public.check_ledger_export();
  select severity into v_sev from public.integrity_latest
    where check_name = 'ledger_export_freshness';
  if v_sev <> 'error' then raise exception 'FAIL 失敗を成功として扱っている: %', v_sev; end if;
  raise notice 'OK ok=false の実行は成功として数えない';
end $$;

\echo '=== 7. 成功していても直近に失敗があれば warn ==='
do $$
declare v_sev text; v_n int;
begin
  insert into public.ledger_exports (ran_at, kind, ok, row_count) values
    (now() - interval '10 minutes', 'incremental', true, 3);
  perform public.check_ledger_export();
  select severity, affected_count into v_sev, v_n from public.integrity_latest
    where check_name = 'ledger_export_freshness';
  if v_sev <> 'warn' then raise exception 'FAIL 直近の失敗を warn にできていない: %', v_sev; end if;
  if v_n < 1 then raise exception 'FAIL 失敗回数が出ていない'; end if;
  raise notice 'OK 復旧はしたが直近に%件失敗している状態を warn にした', v_n;
end $$;

\echo '=== 8. integrity_latest はチェック名ごとの最新を返す(0047の修正) ==='
do $$
declare v_n int; v_names int;
begin
  -- 実行周期の違うチェックを混ぜる
  perform public.run_integrity_checks();
  perform public.check_ledger_export();
  select count(*), count(distinct check_name) into v_n, v_names
    from public.integrity_latest;
  if v_n <> v_names then
    raise exception 'FAIL 同じチェックが重複して出ている(行=% 名=%)', v_n, v_names;
  end if;
  if not exists (select 1 from public.integrity_latest
                 where check_name = 'ledger_export_freshness') then
    raise exception 'FAIL 周期の違うチェックが消えている';
  end if;
  if not exists (select 1 from public.integrity_latest
                 where check_name = 'wallet_vs_ledger') then
    raise exception 'FAIL 本体のチェックが消えている';
  end if;
  raise notice 'OK 周期の違う% 種類のチェックが重複なく並ぶ', v_names;
end $$;

\echo '=== 9. 実行記録は管理者しか読めず、書き込みポリシーが無い ==='
do $$
begin
  if exists (select 1 from pg_policies
             where tablename = 'ledger_exports' and cmd <> 'SELECT') then
    raise exception 'FAIL 書き込みポリシーが存在する';
  end if;
  raise notice 'OK ledger_exports は管理者のSELECTのみ(書き込みはservice_roleのみ)';
end $$;

\echo '=== 10. 管理者以外は実行できない ==='
set test.uid = 'e1000000-0000-0000-0000-0000000000d1';
do $$
begin
  perform public.check_ledger_export();
  raise exception 'FAIL 一般ユーザーが実行できてしまった';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK 一般ユーザーの実行は NOT_ADMIN';
end $$;

\echo '=== 完了 ==='
