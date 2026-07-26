-- 開始時刻の指定と段階制キャンセル(0040)の検証。
-- E-10(「開始1時間前まで全額」が構造上ずっと成立しなかった件)の修正確認。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('e0000000-0000-0000-0000-0000000000a1'::uuid),
  ('e0000000-0000-0000-0000-0000000000b1'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('e0000000-0000-0000-0000-0000000000a1'::uuid, '時間メイト'),
  ('e0000000-0000-0000-0000-0000000000b1'::uuid, '時間ゲスト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'e0000000-0000-0000-0000-0000000000a1'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('e0000000-0000-0000-0000-0000000000a1'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000, trial_discount_percent = 0;
-- 何度流しても同じ状態から始まるようにする(残ったロットは消す)
delete from public.coin_lots where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('e0000000-0000-0000-0000-0000000000b1'::uuid, 'paid', 90000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 90000
  where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid;

\echo '=== 1. 受付範囲の外は弾かれる(最短30分先・最長14日先) ==='
set test.uid = 'e0000000-0000-0000-0000-0000000000b1';
do $$
begin
  begin
    perform public.create_booking('e0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2', now() + interval '5 minutes');
    raise exception 'FAIL 30分以内の指定が通ってしまった';
  exception when others then
    if sqlerrm <> 'START_TOO_SOON' then raise; end if;
    raise notice 'OK 直前すぎる指定は START_TOO_SOON';
  end;
  begin
    perform public.create_booking('e0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2', now() + interval '20 days');
    raise exception 'FAIL 上限より先の指定が通ってしまった';
  exception when others then
    if sqlerrm <> 'START_TOO_FAR' then raise; end if;
    raise notice 'OK 先すぎる指定は START_TOO_FAR';
  end;
end $$;

\echo '=== 2. 承諾しても希望開始時刻が上書きされない(E-10の本体) ==='
select public.create_booking('e0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2',
       date_trunc('minute', now()) + interval '3 hours') as s1 \gset
set test.uid = 'e0000000-0000-0000-0000-0000000000a1';
select public.approve_booking(:'s1');

do $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = (select id from public.bookings
    where guest_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid order by created_at desc limit 1);
  if b.scheduled_at <> b.requested_start_at then
    raise exception 'FAIL 承諾で開始時刻が上書きされた(希望% / 実際%)', b.requested_start_at, b.scheduled_at;
  end if;
  if b.confirmed_at is null then raise exception 'FAIL 承諾時刻が記録されていない'; end if;
  if b.scheduled_at <= b.confirmed_at then
    raise exception 'FAIL 開始時刻が承諾時刻より後になっていない';
  end if;
  raise notice 'OK 開始は3時間後のまま・承諾時刻は別に記録された';
end $$;

\echo '=== 3. 開始3時間前なら全額戻る(いままで構造上ありえなかった状態) ==='
do $$
declare v_pct int;
begin
  select public.my_booking_refund_percent((select id from public.bookings
    where guest_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid order by created_at desc limit 1))
    into v_pct;
  if v_pct <> 100 then raise exception 'FAIL 開始3時間前の返還率が100でない: %', v_pct; end if;
  raise notice 'OK 開始3時間前は100%% 返還';
end $$;

set test.uid = 'e0000000-0000-0000-0000-0000000000b1';
select public.cancel_booking(:'s1', '用事ができた');
do $$
declare v_bal int;
begin
  select balance into v_bal from public.coin_wallets
    where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid;
  if v_bal <> 90000 then raise exception 'FAIL 全額戻っていない(残高%)', v_bal; end if;
  raise notice 'OK 残高が元に戻った(90000)';
end $$;

\echo '=== 4. 開始30分前のキャンセルは一部返還(既定50%%) ==='
select public.create_booking('e0000000-0000-0000-0000-0000000000a1'::uuid, 60, 'v2',
       now() + interval '40 minutes') as s2 \gset
set test.uid = 'e0000000-0000-0000-0000-0000000000a1';
select public.approve_booking(:'s2');
-- 承諾の猶予を抜けた状態を作る(承諾時刻を過去へずらす)
update public.bookings set confirmed_at = now() - interval '30 minutes' where id = :'s2';
set test.uid = 'e0000000-0000-0000-0000-0000000000b1';

do $$
declare v_pct int; v_bal_before int; v_bal_after int; v_earned int;
begin
  select public.my_booking_refund_percent((select id from public.bookings
    where guest_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid order by created_at desc limit 1))
    into v_pct;
  if v_pct <> 50 then raise exception 'FAIL 開始40分前の返還率が50でない: %', v_pct; end if;

  select balance into v_bal_before from public.coin_wallets
    where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid;
  perform public.cancel_booking((select id from public.bookings
    where guest_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid order by created_at desc limit 1), null);
  select balance into v_bal_after from public.coin_wallets
    where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid;
  select earned_balance into v_earned from public.coin_wallets
    where user_id = 'e0000000-0000-0000-0000-0000000000a1'::uuid;

  -- 2000コインの予約 → 1000戻り・1000がピタメイトへ
  if v_bal_after - v_bal_before <> 1000 then
    raise exception 'FAIL 返還が1000でない: %', v_bal_after - v_bal_before;
  end if;
  if v_earned <> 1000 then raise exception 'FAIL ピタメイト取り分が1000でない: %', v_earned; end if;
  raise notice 'OK 2000のうち1000が返還・1000がピタメイトへ';
end $$;

\echo '=== 5. 一部返還でも、戻したコインの合計とロットの合計が一致する ==='
do $$
declare v_wallet int; v_lots int;
begin
  select balance into v_wallet from public.coin_wallets
    where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid;
  select coalesce(sum(remaining), 0) into v_lots from public.coin_lots
    where user_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid and kind = 'paid'
      and expires_at > now();
  if v_wallet <> v_lots then
    raise exception 'FAIL 残高%とロット合計%がずれている(有効期限の管理が壊れる)', v_wallet, v_lots;
  end if;
  raise notice 'OK 残高とロット合計が一致(%)', v_wallet;
end $$;

\echo '=== 6. 「今すぐ」でも承諾から5分は全額戻る(承諾直後100%%没収の解消) ==='
select public.create_booking('e0000000-0000-0000-0000-0000000000a1'::uuid, 30, 'v2', null) as s3 \gset
set test.uid = 'e0000000-0000-0000-0000-0000000000a1';
select public.approve_booking(:'s3');
set test.uid = 'e0000000-0000-0000-0000-0000000000b1';
do $$
declare v_pct int;
begin
  select public.my_booking_refund_percent((select id from public.bookings
    where guest_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid order by created_at desc limit 1))
    into v_pct;
  if v_pct <> 100 then
    raise exception 'FAIL 承諾直後の返還率が100でない(猶予が効いていない): %', v_pct;
  end if;
  raise notice 'OK 承諾直後は猶予が効いて100%% 返還';
end $$;

\echo '=== 7. 猶予を過ぎた「今すぐ」予約は返還なし ==='
update public.bookings set confirmed_at = now() - interval '30 minutes',
                           scheduled_at = now() - interval '30 minutes' where id = :'s3';
do $$
declare v_pct int;
begin
  select public.my_booking_refund_percent((select id from public.bookings
    where guest_id = 'e0000000-0000-0000-0000-0000000000b1'::uuid order by created_at desc limit 1))
    into v_pct;
  if v_pct <> 0 then raise exception 'FAIL 開始後の返還率が0でない: %', v_pct; end if;
  raise notice 'OK 開始後は0%% 返還';
end $$;

\echo '=== 8. 返還率は platform_pricing で変えられる(弁護士回答で数値が変わっても改修不要) ==='
update public.platform_pricing set late_cancel_refund_percent = 30 where id = 1;
do $$
declare v_pct int;
begin
  v_pct := public.booking_refund_percent('confirmed', now() - interval '1 hour', now() + interval '30 minutes', now());
  if v_pct <> 30 then raise exception 'FAIL 設定が反映されていない: %', v_pct; end if;
  raise notice 'OK 返還率を30%%に変更できた(コード改修なし)';
end $$;
update public.platform_pricing set late_cancel_refund_percent = 50 where id = 1;
