\set ON_ERROR_STOP on
insert into auth.users (id) values ('33333333-3333-3333-3333-333333333333');

set test.uid = '33333333-3333-3333-3333-333333333333';

\echo '--- 同意を記録 ---'
select public.record_monitoring_consent('2026-07-26');
select version, agreed_at is not null as recorded, revoked_at
from public.monitoring_consents where user_id = '33333333-3333-3333-3333-333333333333';

\echo '--- 同じ版で再実行しても増えないか(再ログイン等の重複防止) ---'
select public.record_monitoring_consent('2026-07-26');
select public.record_monitoring_consent('2026-07-26');
select count(*) as rows_for_same_version from public.monitoring_consents
where user_id = '33333333-3333-3333-3333-333333333333' and version = '2026-07-26';

\echo '--- 文言を改定したら新しい行が積まれるか ---'
select public.record_monitoring_consent('2026-09-01');
select version, revoked_at from public.monitoring_consents
where user_id = '33333333-3333-3333-3333-333333333333' order by agreed_at;

\echo '--- 撤回すると全部に revoked_at が入るか ---'
select public.revoke_monitoring_consent();
select version, revoked_at is not null as revoked from public.monitoring_consents
where user_id = '33333333-3333-3333-3333-333333333333' order by version;

\echo '--- 撤回後に再同意できるか(新しい行になる) ---'
select public.record_monitoring_consent('2026-09-01');
select count(*) as total_rows from public.monitoring_consents
where user_id = '33333333-3333-3333-3333-333333333333';

\echo '--- 未ログインでは何も起きないか ---'
set test.uid = '';
select public.record_monitoring_consent('2026-09-01');
select count(*) as unchanged from public.monitoring_consents;
