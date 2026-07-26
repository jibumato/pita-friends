-- ============================================================
-- 0047_ledger_export_heartbeat.sql
-- 外部へのエクスポートが止まったことを検知する
-- ------------------------------------------------------------
-- `workers/ledger-export` が Cloudflare R2 へ取引データを写し取る。
-- ただし**止まったことに気づけないバックアップは無いのと同じ**なので、
-- 実行結果をここに書き戻させ、途絶えたら整合性チェックで鳴らす。
--
-- あわせて integrity_latest の定義を直す。これまでは
--   ran_at = (select max(ran_at) from integrity_checks)
-- で「最後の実行」の行だけを出していたが、これだと
--   ・実行の周期が違うチェックを足せない
--   ・あるチェックだけ落ちて行が書かれなかったとき、静かに消える
-- という問題がある。チェック名ごとの最新を出す形に変える。
-- ============================================================

-- ------------------------------------------------------------
-- ledger_exports: エクスポートの実行記録(Workerがservice_roleで書く)
-- ------------------------------------------------------------
create table if not exists public.ledger_exports (
  id uuid primary key default gen_random_uuid(),
  ran_at timestamptz not null default now(),
  kind text not null check (kind in ('incremental', 'snapshot')),
  ok boolean not null default true,
  row_count int not null default 0,
  detail jsonb not null default '{}'::jsonb,
  error text
);

comment on table public.ledger_exports is
  'R2への取引データ書き出しの実行記録。途絶えると整合性チェックの ledger_export_freshness が鳴る。';

alter table public.ledger_exports enable row level security;

-- 閲覧は管理者のみ。書き込みポリシーは作らない(Workerのservice_roleのみ)。
drop policy if exists "ledger_exports_select_admin" on public.ledger_exports;
create policy "ledger_exports_select_admin"
  on public.ledger_exports for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create index if not exists ledger_exports_recent_idx
  on public.ledger_exports (kind, ran_at desc) where ok;

-- ------------------------------------------------------------
-- integrity_latest: チェック名ごとの最新を出す
-- ------------------------------------------------------------
drop view if exists public.integrity_latest;

create view public.integrity_latest
with (security_invoker = true) as
select *
from (
  select distinct on (check_name) *
  from public.integrity_checks
  order by check_name, ran_at desc
) t
order by
  case severity when 'error' then 0 when 'warn' then 1 else 2 end,
  check_name;

comment on view public.integrity_latest is
  '各チェックの最新の結果。severityの重い順に並ぶ。実行周期の違うチェックが混ざっても正しく出る。';

-- ------------------------------------------------------------
-- check_ledger_export: エクスポートの鮮度を見る
--   差分は毎時、全量は毎日の想定。取りこぼしを許す幅を持たせている。
--   結果は integrity_checks に同じ形で積むので、運用の見方は変わらない。
-- ------------------------------------------------------------
create or replace function public.check_ledger_export()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inc timestamptz;
  v_snap timestamptz;
  v_inc_age numeric;
  v_snap_age numeric;
  v_severity text;
  v_failures int;
begin
  if auth.uid() is not null
     and not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select max(ran_at) into v_inc from public.ledger_exports
    where kind = 'incremental' and ok;
  select max(ran_at) into v_snap from public.ledger_exports
    where kind = 'snapshot' and ok;

  v_inc_age := extract(epoch from (now() - v_inc)) / 3600.0;
  v_snap_age := extract(epoch from (now() - v_snap)) / 3600.0;

  -- 直近24時間の失敗回数(成功していても、失敗が続いているなら知りたい)
  select count(*) into v_failures from public.ledger_exports
    where not ok and ran_at > now() - interval '24 hours';

  -- 毎時実行なので3時間(2回分の取りこぼし)まで許す。
  -- 全量は毎日なので26時間まで許す。
  v_severity := case
    when v_inc is null or v_snap is null then 'error'
    when v_inc_age > 3 or v_snap_age > 26 then 'error'
    when v_failures > 0 then 'warn'
    else 'ok'
  end;

  insert into public.integrity_checks
    (check_name, severity, affected_count, total_gap, detail)
  values (
    'ledger_export_freshness',
    v_severity,
    v_failures,
    coalesce(round(greatest(coalesce(v_inc_age, 999), 0))::bigint, 999),
    jsonb_build_object(
      'last_incremental', v_inc,
      'last_snapshot', v_snap,
      'incremental_age_hours', round(coalesce(v_inc_age, 0), 1),
      'snapshot_age_hours', round(coalesce(v_snap_age, 0), 1),
      'failures_24h', v_failures,
      'note', 'R2への書き出しが止まっていないか。止まったバックアップは無いのと同じ。'
    ));

  if v_severity = 'error' then
    insert into public.notifications (user_id, type, title, body)
    select a.user_id, 'integrity_alert',
           '取引データの外部バックアップが止まっています',
           coalesce(
             '最後の書き出しは差分=' || coalesce(v_inc::text, 'なし') ||
             ' / 全量=' || coalesce(v_snap::text, 'なし') || ' です。',
             'まだ一度も実行されていません。')
    from public.admins a;
    return 1;
  end if;

  return 0;
end;
$$;

comment on function public.check_ledger_export() is
  'R2へのエクスポートが止まっていないかを確認し、integrity_checks に記録する。errorなら管理者に通知。';

revoke all on function public.check_ledger_export() from public;
grant execute on function public.check_ledger_export() to authenticated;

-- ------------------------------------------------------------
-- 古い実行記録の掃除(90日)。integrity_checks と同じ扱い。
-- ------------------------------------------------------------
create or replace function public.prune_ledger_exports()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_deleted int;
begin
  delete from public.ledger_exports where ran_at < now() - interval '90 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.prune_ledger_exports() from public;

-- ------------------------------------------------------------
-- cronに登録。整合性チェック(04:07)の直後に見る。
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('check-ledger-export', '17 4 * * *', 'select public.check_ledger_export()');
    perform cron.schedule('prune-ledger-exports', '47 4 * * 0', 'select public.prune_ledger_exports()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end;
$$;
