-- ============================================================
-- 48: 予約時のゲスト側の本人確認(0128)の検証
-- ------------------------------------------------------------
-- 規約 第3条1項「本サービスの利用には……本人確認……の完了が必要」は
-- ホストとゲストを区別していない。ところが create_booking はホストの
-- is_verified しか見ておらず、RPCを直接叩けば未確認のゲストでも予約が
-- 通ってしまっていた(アプリの通常導線では起こらないが、規約と実装が
-- 食い違っている状態)。
--
-- 固定するのは2つ:
--   ・未確認のゲストは GUEST_NOT_VERIFIED で弾かれること
--   ・確認済みになれば通常どおり予約できること(過剰に塞いでいないこと)
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('48000000-0000-0000-0000-000000000001'),  -- 未確認のゲスト
  ('48000000-0000-0000-0000-000000000002')   -- ピタメイト
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('48000000-0000-0000-0000-000000000001','未確認ゲスト'),
  ('48000000-0000-0000-0000-000000000002','ピタメイト')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '48000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('48000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('48000000-0000-0000-0000-000000000001','paid', 50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id = '48000000-0000-0000-0000-000000000001';

\echo '=== 1. 未確認のゲストは GUEST_NOT_VERIFIED で弾かれる ==='
set test.uid = '48000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.create_booking(
      '48000000-0000-0000-0000-000000000002'::uuid, 60, 'v1', null);
    raise exception 'FAIL 未確認のゲストで予約できてしまった';
  exception when others then
    if sqlerrm not like '%GUEST_NOT_VERIFIED%' then raise; end if;
  end;
  raise notice 'OK 未確認のゲストは弾かれる';
end $$;

\echo '=== 2. 確認済みになれば通常どおり予約できる ==='
update public.profile_trust_stats set is_verified = true
  where user_id = '48000000-0000-0000-0000-000000000001';
do $$
declare v_booking uuid;
begin
  v_booking := public.create_booking(
    '48000000-0000-0000-0000-000000000002'::uuid, 60, 'v1', null);
  if v_booking is null then raise exception 'FAIL 確認済みなのに予約できない'; end if;
  raise notice 'OK 確認済みなら通常どおり予約できる';
end $$;
