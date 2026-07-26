-- キャンセルポリシーの記録(E-1)と立証材料ビュー(E-2)の検証。
--
-- もともとは E-10(「開始1時間前まで全額」と表示しながら、承諾の瞬間から
-- 全額没収されていた問題)を**再現する**テストでした。0040 でこれを直したので、
-- 現在は「直っていること」を確かめる内容になっています。
-- 段階制そのものの網羅は 95_scheduled_cancel.sql が担当します。

\set ON_ERROR_STOP on
insert into auth.users (id) values
  ('44444444-4444-4444-4444-444444444444'),
  ('55555555-5555-5555-5555-555555555555')
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('44444444-4444-4444-4444-444444444444','ゲスト'),
  ('55555555-5555-5555-5555-555555555555','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '55555555-5555-5555-5555-555555555555';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('55555555-5555-5555-5555-555555555555', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('44444444-4444-4444-4444-444444444444','paid', 5000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 5000
  where user_id = '44444444-4444-4444-4444-444444444444';

set test.uid = '44444444-4444-4444-4444-444444444444';
select public.create_booking('55555555-5555-5555-5555-555555555555', 60, '2026-07-26') as bid \gset

\echo '=== 1. E-1: 同意したポリシー版が予約に記録される ==='
do $$
declare v_ver text; v_at timestamptz;
begin
  select policy_version, policy_agreed_at into v_ver, v_at
    from public.bookings where guest_id = '44444444-4444-4444-4444-444444444444'::uuid;
  if v_ver is null or v_at is null then
    raise exception 'FAIL ポリシー版が記録されていない(版=% 時刻=%)', v_ver, v_at;
  end if;
  raise notice 'OK 同意したポリシー版(%)と同意時刻が予約に残っている', v_ver;
end $$;

\echo '=== 2. 承諾直後のキャンセルは全額戻る(E-10の修正) ==='
set test.uid = '55555555-5555-5555-5555-555555555555';
select public.approve_booking(:'bid');
set test.uid = '44444444-4444-4444-4444-444444444444';
select public.cancel_booking(:'bid', 'test');

do $$
declare v_balance int; v_status text;
begin
  select balance into v_balance from public.coin_wallets
    where user_id = '44444444-4444-4444-4444-444444444444'::uuid;
  select status into v_status from public.bookings
    where guest_id = '44444444-4444-4444-4444-444444444444'::uuid;
  if v_balance <> 5000 then
    raise exception 'FAIL 承諾直後なのに没収された(残高% / 5000のはず)', v_balance;
  end if;
  if v_status <> 'cancelled_by_guest' then
    raise exception 'FAIL ステータスが想定と違う: %', v_status;
  end if;
  raise notice 'OK 承諾から5分以内のキャンセルは全額戻る(残高%)', v_balance;
end $$;

\echo '=== 3. E-2: 立証材料ビューが承諾時刻ベースで出る ==='
do $$
declare v_row public.guest_cancellation_evidence;
begin
  select * into v_row from public.guest_cancellation_evidence
    where guest_id = '44444444-4444-4444-4444-444444444444'::uuid;
  if v_row.booking_id is null then raise exception 'FAIL 立証材料の行が出ていない'; end if;
  if v_row.approved_at is null then raise exception 'FAIL 承諾時刻が入っていない'; end if;
  if v_row.seconds_after_approval is null or v_row.seconds_after_approval < 0 then
    raise exception 'FAIL 承諾からの経過秒が異常: %', v_row.seconds_after_approval;
  end if;
  if v_row.refund_percent_at_cancel <> 100 then
    raise exception 'FAIL 適用された返還率が100%%でない: %', v_row.refund_percent_at_cancel;
  end if;
  raise notice 'OK 承諾から%秒後のキャンセル・返還率%パーセント・ポリシー版%が残る',
    v_row.seconds_after_approval, v_row.refund_percent_at_cancel, v_row.policy_version;
end $$;

\echo '=== 完了 ==='
