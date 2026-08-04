-- ============================================================
-- 26: 遊んだあとのキャンセルは、完了と同じ扱いになる(0102)
-- ------------------------------------------------------------
-- プレイ中の画面には「✓ プレイ完了」と「キャンセルする」が両方出ていて、
-- 開始後は返還0%なので**ゲストの支払額はどちらでも同じ**だった。
-- 違うのはピタメイトの手取り(20%)と、ゲストのドタキャン記録だけ。
--
-- つまり「完了じゃなくてキャンセル押しといて」で手取りが増える。
-- 利用料の取りこぼしより重いのは、**条文が事実と食い違うこと**:
-- キャンセル分に利用料を課さない根拠(規約 第8条の2第7項)は
-- 「役務の対価ではなく機会損失の補償」だが、2時間遊んだあとの
-- 「キャンセル」は完全に役務の対価。
--
-- 固定するのは4つ:
--   ・遊んだあと(両方チェックイン済み)のキャンセルは、完了と同じ手取り
--   ・そのときゲストにドタキャン記録がつかない
--   ・**遊んでいないキャンセルは従来どおり**(満額・記録あり)
--   ・チェックインが片方だけなら「遊んだ」ことにしない
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('26000000-0000-0000-0000-000000000001'),  -- ゲスト
  ('26000000-0000-0000-0000-000000000002'),  -- ピタメイト
  ('26000000-0000-0000-0000-000000000003');  -- ゲスト2(遊ばない側の検証用)
insert into public.profiles (id, nickname) values
  ('26000000-0000-0000-0000-000000000001','ゲスト'),
  ('26000000-0000-0000-0000-000000000002','ピタメイト'),
  ('26000000-0000-0000-0000-000000000003','ゲスト2')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '26000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('26000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('26000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now())),
  ('26000000-0000-0000-0000-000000000003','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 100000
  where user_id in ('26000000-0000-0000-0000-000000000001',
                    '26000000-0000-0000-0000-000000000003');

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 遊ばずにキャンセル: 従来どおり満額＋ドタキャン記録 ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '26000000-0000-0000-0000-000000000003';
select public.create_booking('26000000-0000-0000-0000-000000000002', 60, 'v1') as b0 \gset
set test.uid = '26000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b0');

-- 開始時刻を過ぎさせる(チェックインはしない = 誰も現れなかった)
-- 承諾から5分の猶予(0040)を抜けさせないと全額返還になり、検証にならない
update public.bookings set scheduled_at = now() - interval '10 minutes',
  confirmed_at = now() - interval '1 hour' where id = :'b0';

set test.uid = '26000000-0000-0000-0000-000000000003';
select public.cancel_booking(:'b0', 'テスト');

do $$
declare v_earned int; v_fee int; v_dota int;
begin
  select earned_balance into v_earned from public.coin_wallets
    where user_id = '26000000-0000-0000-0000-000000000002';
  if v_earned <> 2000 then
    raise exception 'FAIL 遊んでいないのに控除された: %(2000のはず)', v_earned;
  end if;
  select count(*) into v_fee from public.platform_fees
    where host_id = '26000000-0000-0000-0000-000000000002';
  if v_fee <> 0 then
    raise exception 'FAIL 遊んでいないのに利用料の明細ができた: %件', v_fee;
  end if;
  select dotakyan_count into v_dota from public.profile_trust_stats
    where user_id = '26000000-0000-0000-0000-000000000003';
  if coalesce(v_dota, 0) <> 1 then
    raise exception 'FAIL ドタキャン記録がついていない: %', v_dota;
  end if;
  raise notice 'OK 満額2,000が報酬になり、利用料なし、ゲストにドタキャン記録';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 遊んだあとのキャンセル: 完了と同じ控除・記録なし ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '26000000-0000-0000-0000-000000000001';
select public.create_booking('26000000-0000-0000-0000-000000000002', 60, 'v1') as b1 \gset
set test.uid = '26000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b1');

update public.bookings set scheduled_at = now() - interval '30 minutes',
  confirmed_at = now() - interval '1 hour' where id = :'b1';

-- 両方チェックイン(実際に遊んだ)
set test.uid = '26000000-0000-0000-0000-000000000001';
select public.check_in_booking(:'b1');
set test.uid = '26000000-0000-0000-0000-000000000002';
select public.check_in_booking(:'b1');

-- 「眠いから早めに終わろう、コインはそのままでいい」でキャンセルを押した
set test.uid = '26000000-0000-0000-0000-000000000001';
select public.cancel_booking(:'b1', '早めに終了');

do $$
declare
  v_gross int; v_fee int; v_net int; v_repeat boolean;
  v_earned int; v_dota int;
begin
  select gross_coins, fee_coins, net_coins, repeat_discounted
    into v_gross, v_fee, v_net, v_repeat
    from public.platform_fees
    where host_id = '26000000-0000-0000-0000-000000000002' and gross_coins = 2000;
  if v_gross is null then
    raise exception 'FAIL 遊んだのに利用料の明細ができていない';
  end if;
  -- 当月GMVはまだ0(完了した予約が無い)なので20%ティア。1件目のゲストなので割引なし
  if v_fee <> 400 then
    raise exception 'FAIL 利用料が完了時と違う: %(2000×20%%=400のはず)', v_fee;
  end if;
  if v_net <> 1600 then
    raise exception 'FAIL 手取りがおかしい: %', v_net;
  end if;
  if v_repeat then
    raise exception 'FAIL 初回なのにリピート割引が効いている';
  end if;

  -- 1で入った2,000 + 今回の1,600
  select earned_balance into v_earned from public.coin_wallets
    where user_id = '26000000-0000-0000-0000-000000000002';
  if v_earned <> 3600 then
    raise exception 'FAIL 報酬残高が合わない: %(2000+1600=3600のはず)', v_earned;
  end if;

  -- **遊んだのだから、ドタキャンではない**
  select dotakyan_count into v_dota from public.profile_trust_stats
    where user_id = '26000000-0000-0000-0000-000000000001';
  if coalesce(v_dota, 0) <> 0 then
    raise exception 'FAIL 遊んだのにドタキャン記録がついた: %', v_dota;
  end if;
  raise notice 'OK 2,000から利用料400を引いて1,600。ドタキャン記録なし';
end $$;

-- 取引履歴に「満額」と「控除」の2行が残ること(完了時と同じ読み方ができる)
do $$
declare v_earn int; v_fee int;
begin
  select count(*) into v_earn from public.coin_transactions
    where user_id = '26000000-0000-0000-0000-000000000002'
      and type = 'booking_earned' and note = 'cancel_booking_late';
  select count(*) into v_fee from public.coin_transactions
    where user_id = '26000000-0000-0000-0000-000000000002'
      and type = 'platform_fee' and note = 'cancel_played_fee';
  if v_earn < 1 or v_fee <> 1 then
    raise exception 'FAIL 履歴が2行になっていない: earned=% fee=%', v_earn, v_fee;
  end if;
  raise notice 'OK 履歴は booking_earned(満額) + platform_fee(控除) の2行';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 「完了」と「遊んだあとのキャンセル」で手取りが同じ ==='; end $$;
-- ------------------------------------------------------------
-- **これが本題。** 差があるかぎり、押すボタンで得をする人が出る。
--
-- ⚠️ 完了時の控除は **deferrable initially deferred のトリガー**(0033)なので、
-- 同じトランザクションの中では走らない。**do ブロックに閉じ込めると
-- 控除前の残高を読んでしまう**ので、文を分けて確かめる
-- 同じ条件でもう1件、今度は「完了」で閉じる
set test.uid = '26000000-0000-0000-0000-000000000003';
select public.create_booking('26000000-0000-0000-0000-000000000002', 60, 'v1') as b4 \gset
set test.uid = '26000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b4');
set test.uid = '26000000-0000-0000-0000-000000000003';
select public.complete_booking(:'b4');

-- 2つの経路の控除額を、履歴の note で引き当てて突き合わせる
-- (予約IDは \gset の変数で、$$ の中では展開されないため)
do $$
declare v_cancel int; v_complete int;
begin
  select -amount into v_cancel from public.coin_transactions
    where user_id = '26000000-0000-0000-0000-000000000002'
      and type = 'platform_fee' and note = 'cancel_played_fee';
  select -amount into v_complete from public.coin_transactions
    where user_id = '26000000-0000-0000-0000-000000000002'
      and type = 'platform_fee' and note = 'booking_fee';
  if v_cancel is null then
    raise exception 'FAIL 遊んだあとのキャンセルで控除されていない';
  end if;
  if v_complete is null then
    raise exception 'FAIL 完了で控除されていない';
  end if;
  if v_cancel <> v_complete then
    raise exception 'FAIL 完了とキャンセルで控除額が違う: 完了=% / キャンセル=%',
      v_complete, v_cancel;
  end if;
  raise notice 'OK どちらのボタンでも控除は%コイン。押し分ける動機が消えた', v_cancel;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. チェックインが片方だけなら「遊んだ」ことにしない ==='; end $$;
-- ------------------------------------------------------------
-- ゲストが開始時刻に一言つぶやいた一方で、ピタメイトが現れなかった場合まで
-- 「遊んだ」ことにすると、無断欠席の側の救済(0050)と食い違う
set test.uid = '26000000-0000-0000-0000-000000000001';
select public.create_booking('26000000-0000-0000-0000-000000000002', 60, 'v1') as b3 \gset
set test.uid = '26000000-0000-0000-0000-000000000002';
select public.approve_booking(:'b3');
update public.bookings set scheduled_at = now() - interval '20 minutes',
  confirmed_at = now() - interval '1 hour' where id = :'b3';

-- ゲストだけチェックイン
set test.uid = '26000000-0000-0000-0000-000000000001';
select public.check_in_booking(:'b3');
select public.cancel_booking(:'b3', 'ピタメイトが来ない');

do $$
declare v_n int;
begin
  select count(*) into v_n from public.platform_fees
    where booking_id = (select id from public.bookings
                        where guest_id = '26000000-0000-0000-0000-000000000001'
                          and status = 'cancelled_by_guest'
                        order by created_at desc limit 1);
  if v_n <> 0 then
    raise exception 'FAIL 片方だけのチェックインで「遊んだ」扱いになった';
  end if;
  raise notice 'OK 片方だけなら従来どおり(利用料を引かない)';
end $$;

do $$ begin raise notice '==== 26: すべて通過 ===='; end $$;
