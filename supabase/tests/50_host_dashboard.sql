\set ON_ERROR_STOP on
\i supabase/tests/_fixture_host.sql

set test.uid = 'b2222222-2222-2222-2222-222222222222';
\echo '=== ダッシュボード集計 ==='
select jsonb_pretty(public.host_dashboard());
