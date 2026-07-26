-- Supabase 相当の最小シム(ローカル検証用)
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists cron;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text
);

-- テスト中に切り替える現在ユーザー
create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function auth.role() returns text
language sql stable as $$ select coalesce(nullif(current_setting('test.role', true), ''), 'authenticated') $$;

-- pg_cron のダミー(0018 が cron.schedule を呼ぶため)
create or replace function cron.schedule(text, text, text) returns bigint
language sql as $$ select 1::bigint $$;
create or replace function cron.unschedule(text) returns boolean
language sql as $$ select true $$;
create table if not exists cron.job (jobid bigint, jobname text);
