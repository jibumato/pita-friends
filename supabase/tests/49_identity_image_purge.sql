-- ============================================================
-- 49: 本人確認の画像の削除を、サーバー側へ移したこと(0129)
-- ------------------------------------------------------------
-- ファイルそのものの削除は Edge Function identity-images-purge が行う
-- (そちらの動作は supabase/functions/identity-images-purge/purge.test.ts)。
-- ここでは DB 側を固定する:
--   ・消したかどうかを記録する列があること
--   ・anonymize_user が storage.objects を SQL で消さなくなったこと
--     (0008 で、同じやり方が本番では権限エラーになり承認ごと失敗した。
--      ローカルの postgres は特権ユーザーなので、ここでは失敗を再現できない。
--      だから「消そうとしていない」ことを本体の文面と結果の両方で確かめる)
--   ・匿名化した利用者が「まだファイルを消していない」として残ること
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('49000000-0000-0000-0000-000000000001'),   -- 退会する人
  ('49000000-0000-0000-0000-0000000000ad');   -- 運営
insert into public.profiles (id, nickname) values
  ('49000000-0000-0000-0000-000000000001', '退会する人'),
  ('49000000-0000-0000-0000-0000000000ad', '運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('49000000-0000-0000-0000-0000000000ad');

-- 本人確認の申請には居住地の申告が先に要る(0081)
set test.uid = '49000000-0000-0000-0000-000000000001';
select public.declare_residency(true);
reset test.uid;

insert into public.identity_verifications (user_id, status, document_path, selfie_path)
values ('49000000-0000-0000-0000-000000000001', 'verified',
        '49000000-0000-0000-0000-000000000001/document-1.jpg',
        '49000000-0000-0000-0000-000000000001/selfie-1.jpg');
insert into storage.objects (bucket_id, name, owner) values
  ('identity-documents', '49000000-0000-0000-0000-000000000001/document-1.jpg',
   '49000000-0000-0000-0000-000000000001');

\echo '=== 1. 記録用の列がある ==='
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'identity_verifications'
                   and column_name = 'images_deleted_at') then
    raise exception 'FAIL: identity_verifications.images_deleted_at が無い';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'account_anonymizations'
                   and column_name = 'storage_purged_at') then
    raise exception 'FAIL: account_anonymizations.storage_purged_at が無い';
  end if;
  raise notice 'OK: images_deleted_at / storage_purged_at がある';
end $$;

\echo '=== 2. anonymize_user は storage.objects を SQL で消さない ==='
do $$
begin
  if pg_get_functiondef('public.anonymize_user'::regproc) ~* 'delete\s+from\s+storage\.objects' then
    raise exception 'FAIL: anonymize_user がまだ storage.objects を SQL で消している(本番では権限エラー)';
  end if;
  raise notice 'OK: 本体に storage.objects の削除が無い';
end $$;

set test.uid = '49000000-0000-0000-0000-0000000000ad';
select public.anonymize_user('49000000-0000-0000-0000-000000000001');
reset test.uid;

do $$
begin
  -- ファイルは残っている(消すのは identity-images-purge の毎日の掃除)
  if not exists (select 1 from storage.objects
                 where name = '49000000-0000-0000-0000-000000000001/document-1.jpg') then
    raise exception 'FAIL: anonymize_user が storage.objects を消した';
  end if;
  -- 「まだ消していない」印として残る
  if not exists (select 1 from public.account_anonymizations
                 where user_id = '49000000-0000-0000-0000-000000000001'
                   and storage_purged_at is null) then
    raise exception 'FAIL: 匿名化した利用者が「未削除」として残っていない';
  end if;
  -- 参照は外れている(掃除からは「申請に紐づかない画像」としても見える)
  if exists (select 1 from public.identity_verifications
             where user_id = '49000000-0000-0000-0000-000000000001'
               and (document_path is not null or selfie_path is not null)) then
    raise exception 'FAIL: 本人確認書類の参照が外れていない';
  end if;
  raise notice 'OK: 匿名化は成功し、ファイルの削除は掃除に回る';
end $$;
