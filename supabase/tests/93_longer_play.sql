-- あそぶ時間の長時間化(0048 / 上限は0049で10時間)の検証。
--
-- 上限を上げること自体より、上げたときに壊れる3点が直っているかが本題です。
--   ① 自動確定が「終了時刻+72時間」になっているか(開始基準だとプレイ中に確定する)
--   ② 没収額の上限が効いているか(消費者契約法9条)
--   ③ 刻みの規則がサーバでも同じか
--
-- 特に②は、**4時間以下の予約の挙動を変えていないこと**まで確かめます。
-- 変えてしまうと、既に説明済みのポリシーと食い違います。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a1000000-0000-0000-0000-00000000ab01'::uuid),
  ('a1000000-0000-0000-0000-00000000ab11'::uuid)
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('a1000000-0000-0000-0000-00000000ab01'::uuid, '長時間メイト'),
  ('a1000000-0000-0000-0000-00000000ab11'::uuid, '長時間ゲスト')
on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = 'a1000000-0000-0000-0000-00000000ab01'::uuid;
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('a1000000-0000-0000-0000-00000000ab01'::uuid, true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000, trial_discount_percent = 0;
set app.ledger_override = 'on';
delete from public.coin_lots where user_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid;
reset app.ledger_override;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('a1000000-0000-0000-0000-00000000ab11'::uuid, 'paid', 500000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 500000
  where user_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid;

\echo '=== 1. 刻みの規則(4時間までは30分・それ以降は1時間) ==='
do $$
begin
  -- 通る
  if not public.is_valid_booking_duration(30) then raise exception 'FAIL 30分が通らない'; end if;
  if not public.is_valid_booking_duration(90) then raise exception 'FAIL 90分が通らない'; end if;
  if not public.is_valid_booking_duration(240) then raise exception 'FAIL 240分が通らない'; end if;
  if not public.is_valid_booking_duration(300) then raise exception 'FAIL 300分が通らない'; end if;
  if not public.is_valid_booking_duration(600) then raise exception 'FAIL 600分(10時間)が通らない'; end if;
  -- 弾く
  if public.is_valid_booking_duration(270) then raise exception 'FAIL 4時間超の30分刻みを通した'; end if;
  if public.is_valid_booking_duration(660) then raise exception 'FAIL 上限超えを通した'; end if;
  if public.is_valid_booking_duration(0) then raise exception 'FAIL 0分を通した'; end if;
  if public.is_valid_booking_duration(null) then raise exception 'FAIL nullを通した'; end if;
  raise notice 'OK 4時間までは30分刻み・それ以降は1時間刻み・上限600分';
end $$;

\echo '=== 2. 10時間の予約が取れて、料金が正しい ==='
set test.uid = 'a1000000-0000-0000-0000-00000000ab11';
select public.create_booking('a1000000-0000-0000-0000-00000000ab01'::uuid, 600, 'v3', null) as b12 \gset
set test.b12 = :'b12';
do $$
declare v_c int;
begin
  select coins into v_c from public.bookings
    where guest_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid
    order by created_at desc limit 1;
  -- 時給2000 × 10時間 = 20000
  if v_c <> 20000 then raise exception 'FAIL 10時間の料金が合わない: %', v_c; end if;
  raise notice 'OK 10時間 = %コイン(時給2000)', v_c;
end $$;

\echo '=== 3. 4時間超の30分刻みはサーバでも弾かれる ==='
do $$
begin
  perform public.create_booking('a1000000-0000-0000-0000-00000000ab01'::uuid, 270, 'v3', null);
  raise exception 'FAIL 270分が通ってしまった';
exception when others then
  if sqlerrm <> 'INVALID_DURATION' then raise; end if;
  raise notice 'OK 270分は INVALID_DURATION';
end $$;

\echo '=== 4. ★没収の上限: 10時間予約を開始直前にキャンセル ==='
-- 従来なら50%=10000コイン没収。上限(3時間分=6000)が効いて6000になるはず。
do $$
declare v_refund int;
begin
  -- 20000コイン / 600分 → 1分あたり33.33コイン。3時間(180分)分 = 6000
  v_refund := public.booking_refund_coins(
    20000, 600, 50, now() + interval '10 minutes', now());
  if v_refund <> 14000 then
    raise exception 'FAIL 返還額が想定と違う(期待14000 / 実際%)', v_refund;
  end if;
  raise notice 'OK 10時間予約の開始直前キャンセル: 没収6000・返還%(従来は没収10000)', v_refund;
end $$;

\echo '=== 5. ★4時間以下の予約は挙動が変わらない ==='
do $$
declare v_refund int;
begin
  -- 4時間(240分)・8000コイン・開始直前(50%)
  -- 従来: 没収4000・返還4000。上限は3時間分=6000なので効かない
  v_refund := public.booking_refund_coins(
    8000, 240, 50, now() + interval '10 minutes', now());
  if v_refund <> 4000 then
    raise exception 'FAIL 4時間予約の挙動が変わった(期待4000 / 実際%)', v_refund;
  end if;

  -- 1時間・2000コイン・開始前(100%)
  v_refund := public.booking_refund_coins(2000, 60, 100, now() + interval '3 hours', now());
  if v_refund <> 2000 then raise exception 'FAIL 全額返還が崩れた: %', v_refund; end if;

  raise notice 'OK 4時間以下の予約では上限が効かず、従来どおりの額になる';
end $$;

\echo '=== 6. 開始後は「経過分」がピタメイトのものになる ==='
do $$
declare v_refund int;
begin
  -- 10時間予約の開始1時間後にキャンセル(率は0%)
  -- 没収 = 経過1時間分(2000) + 上限3時間分(6000) = 8000 → 返還12000
  v_refund := public.booking_refund_coins(
    20000, 600, 0, now() - interval '1 hour', now());
  if v_refund <> 12000 then
    raise exception 'FAIL 経過分の計算が合わない(期待12000 / 実際%)', v_refund;
  end if;
  raise notice 'OK 開始1時間後: 経過1時間分+3時間分=8000を没収し、%を返す', v_refund;

  -- 同じ10時間予約を9時間後にキャンセル → 経過分だけで予約額に達するので全額没収
  v_refund := public.booking_refund_coins(
    20000, 600, 0, now() - interval '9 hours', now());
  if v_refund <> 0 then
    raise exception 'FAIL 終盤のキャンセルで返してしまった: %', v_refund;
  end if;
  raise notice 'OK 開始9時間後は全額がピタメイトの報酬(経過分だけで予約額に達する)';
end $$;

\echo '=== 7. 実際の cancel_booking でも同じ額になる ==='
set test.uid = 'a1000000-0000-0000-0000-00000000ab01';
select public.approve_booking(:'b12');
-- 開始を10分後に寄せて「開始1時間前を過ぎた」状態を作る(承諾から5分の猶予も外す)
update public.bookings set scheduled_at = now() + interval '10 minutes',
                           confirmed_at = now() - interval '30 minutes'
  where id = :'b12';
set test.uid = 'a1000000-0000-0000-0000-00000000ab11';
do $$
declare v_before int; v_after int; v_host int;
begin
  select balance into v_before from public.coin_wallets
    where user_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid;
  perform public.cancel_booking(current_setting('test.b12', true)::uuid, 'test');
  select balance into v_after from public.coin_wallets
    where user_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid;
  select earned_balance into v_host from public.coin_wallets
    where user_id = 'a1000000-0000-0000-0000-00000000ab01'::uuid;
  if v_after - v_before <> 14000 then
    raise exception 'FAIL 実際の返還額が違う(期待14000 / 実際%)', v_after - v_before;
  end if;
  if v_host <> 6000 then
    raise exception 'FAIL ピタメイトへの確定額が違う(期待6000 / 実際%)', v_host;
  end if;
  raise notice 'OK 実処理でも 返還14000 / 確定6000 で一致した';
end $$;

\echo '=== 8. ★自動確定は「終了時刻+72時間」を基準にする ==='
set test.uid = 'a1000000-0000-0000-0000-00000000ab11';
select public.create_booking('a1000000-0000-0000-0000-00000000ab01'::uuid, 600, 'v3', null) as b2 \gset
set test.b2 = :'b2';
set test.uid = 'a1000000-0000-0000-0000-00000000ab01';
select public.approve_booking(:'b2');
do $$
declare v_st text; v_n int;
begin
  -- 開始から73時間経過(=まだ終了+72時間には届いていない)
  update public.bookings set scheduled_at = now() - interval '73 hours'
    where id = current_setting('test.b2', true)::uuid;
  v_n := public.auto_complete_bookings();
  select status into v_st from public.bookings
    where id = current_setting('test.b2', true)::uuid;
  if v_st = 'completed' then
    raise exception 'FAIL 開始基準のままで、終了前に確定してしまった';
  end if;
  raise notice 'OK 開始+73時間ではまだ確定しない(終了+72時間が基準)';

  -- 終了から73時間(= 開始から 10+73 = 83時間)
  update public.bookings set scheduled_at = now() - interval '83 hours'
    where id = current_setting('test.b2', true)::uuid;
  v_n := public.auto_complete_bookings();
  select status into v_st from public.bookings
    where id = current_setting('test.b2', true)::uuid;
  if v_st <> 'completed' then
    raise exception 'FAIL 終了+72時間を過ぎても確定しない: %', v_st;
  end if;
  raise notice 'OK 終了+72時間を過ぎたら確定する';
end $$;

\echo '=== 9. 延長は合計が上限を超えたら拒否される ==='
set test.uid = 'a1000000-0000-0000-0000-00000000ab11';
select public.create_booking('a1000000-0000-0000-0000-00000000ab01'::uuid, 540, 'v3', null) as b3 \gset
set test.b3 = :'b3';
set test.uid = 'a1000000-0000-0000-0000-00000000ab01';
select public.approve_booking(:'b3');
set test.uid = 'a1000000-0000-0000-0000-00000000ab11';
do $$
declare v_d int;
begin
  -- 540 + 60 = 600 はちょうど上限なので通る
  perform public.extend_booking(current_setting('test.b3', true)::uuid, 60);
  select duration_minutes into v_d from public.bookings
    where id = current_setting('test.b3', true)::uuid;
  if v_d <> 600 then raise exception 'FAIL 上限ちょうどの延長が通らない: %', v_d; end if;

  -- さらに30分は上限超え
  begin
    perform public.extend_booking(current_setting('test.b3', true)::uuid, 30);
    raise exception 'FAIL 上限を超えて延長できてしまった';
  exception when others then
    if sqlerrm <> 'DURATION_LIMIT_EXCEEDED' then raise; end if;
  end;
  raise notice 'OK 上限ちょうど(600分)までは延長でき、超えると DURATION_LIMIT_EXCEEDED';
end $$;

\echo '=== 10. 画面表示用の見積りが実処理と一致する ==='
do $$
declare v_q jsonb; v_b uuid;
begin
  select id into v_b from public.bookings
    where guest_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid and status = 'confirmed'
    order by created_at desc limit 1;
  update public.bookings set scheduled_at = now() + interval '10 minutes',
                             confirmed_at = now() - interval '30 minutes'
    where id = v_b;
  v_q := public.my_booking_refund_quote(v_b);
  if (v_q->>'refund_coins')::int + (v_q->>'forfeit_coins')::int <> (v_q->>'coins')::int then
    raise exception 'FAIL 見積りの内訳が合わない: %', v_q;
  end if;
  if (v_q->>'capped')::boolean is not true then
    raise exception 'FAIL 10時間予約なのに上限が効いていない: %', v_q;
  end if;
  raise notice 'OK 見積り: 返還% / 没収% (率%%%は上限で緩和されている)',
    v_q->>'refund_coins', v_q->>'forfeit_coins', v_q->>'base_percent';
end $$;

\echo '=== 11. 通報による保留の窓も終了時刻ベースになっている ==='
do $$
declare v_b uuid; v_held timestamptz;
begin
  select id into v_b from public.bookings
    where guest_id = 'a1000000-0000-0000-0000-00000000ab11'::uuid and status = 'confirmed'
    order by created_at desc limit 1;
  -- 開始から73時間(旧基準なら窓の外・新基準なら窓の内)
  update public.bookings set scheduled_at = now() - interval '73 hours', held_at = null
    where id = v_b;
  insert into public.reports (reporter_id, reported_id, category, severity)
    values ('a1000000-0000-0000-0000-00000000ab11'::uuid,
            'a1000000-0000-0000-0000-00000000ab01'::uuid, 'no_show', 'high');
  select held_at into v_held from public.bookings where id = v_b;
  if v_held is null then
    raise exception 'FAIL 終了前の予約が通報で保留されなかった(窓が開始基準のまま)';
  end if;
  raise notice 'OK 開始+73時間でもまだ終了前なので、通報で保留された';
end $$;

\echo '=== 完了 ==='
