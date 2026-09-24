-- ============================================================
-- 47: 長期間ご利用のないアカウント（規約 第6条の4・0127）
--
-- 見ているもの:
--   ① 最終ログインが2年未満なら対象にならない
--   ② 2年以上ログインが無いと通知される(30日後の実行日が記録される)
--   ③ 通知は重複して作られない(2回流しても1行のまま)
--   ④ 実行日までにログインがあれば、措置を取らずに通知を消す
--   ⑤ まだ休眠のままなら実行する:
--        ・購入コインは消える／報酬コインは残る
--        ・is_hostが下りる
--        ・最終換金(最低額なし・全額一括)が使えるようになる
--   ⑥ 成立済みの予約がある間は実行を見送る
--   ⑦ 実行は再実行しても二重に処理しない
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id, last_sign_in_at) values
  ('47000000-0000-0000-0000-000000000001', now() - interval '1 year'),   -- 最近ログイン
  ('47000000-0000-0000-0000-000000000002', now() - interval '3 years'),  -- 休眠(通知対象)
  ('47000000-0000-0000-0000-000000000003', now() - interval '3 years'),  -- 休眠→実行前にログインし直す
  ('47000000-0000-0000-0000-000000000004', now() - interval '3 years'),  -- 休眠→そのまま実行される
  ('47000000-0000-0000-0000-000000000005', now() - interval '3 years'),  -- 休眠だが成立済みの予約がある
  ('47000000-0000-0000-0000-000000000091', now())                        -- ホスト(相手役)
on conflict (id) do update set last_sign_in_at = excluded.last_sign_in_at;

insert into public.profiles (id, nickname) values
  ('47000000-0000-0000-0000-000000000001','u1'),
  ('47000000-0000-0000-0000-000000000002','u2'),
  ('47000000-0000-0000-0000-000000000003','u3'),
  ('47000000-0000-0000-0000-000000000004','u4'),
  ('47000000-0000-0000-0000-000000000005','u5'),
  ('47000000-0000-0000-0000-000000000091','ホスト(相手役)')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id = '47000000-0000-0000-0000-000000000091';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('47000000-0000-0000-0000-000000000091', true, 1000)
on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- u4・u5に、購入コイン(残っている想定)と報酬コインを持たせる
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('47000000-0000-0000-0000-000000000004','paid', 2000, now() + interval '10 years'),
  ('47000000-0000-0000-0000-000000000005','paid', 2000, now() + interval '10 years');
update public.coin_wallets set balance = 2000, earned_balance = 3000
  where user_id in ('47000000-0000-0000-0000-000000000004',
                    '47000000-0000-0000-0000-000000000005');

-- u5は「成立済みの予約」を残す(直接insertで作る。片方が消えると相手が
-- 救済されない、を再現するだけなので詳細な予約フローは要らない)
insert into public.bookings (guest_id, host_id, coins, duration_minutes, status, scheduled_at)
values ('47000000-0000-0000-0000-000000000005', '47000000-0000-0000-0000-000000000091',
        1000, 60, 'confirmed', now() + interval '3 days');

-- ------------------------------------------------------------
\echo '=== ★1. 最終ログインが2年未満なら対象にならない ==='
do $$
declare v_n int;
begin
  perform public.flag_dormant_accounts();
  select count(*) into v_n from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000001';
  if v_n <> 0 then raise exception 'NG: 2年未満なのに通知が作られた'; end if;
  raise notice 'ok 2年未満は対象にならない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★2. 2年以上ログインが無いと通知される ==='
do $$
declare v_notified timestamptz; v_execute timestamptz; v_n int;
begin
  select notified_at, execute_at into v_notified, v_execute
    from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000002';
  if v_notified is null then raise exception 'NG: 通知の行が無い'; end if;
  if v_execute - v_notified <> interval '30 days' then
    raise exception 'NG: 実行日が30日後になっていない（%）', v_execute - v_notified;
  end if;

  select count(*) into v_n from public.notifications
    where user_id = '47000000-0000-0000-0000-000000000002'
      and title like '%まもなく利用を停止%';
  if v_n <> 1 then raise exception 'NG: 通知メッセージが届いていない'; end if;
  raise notice 'ok 2年以上で通知され、実行日が30日後に記録される';
end $$;

-- ------------------------------------------------------------
\echo '=== ★3. 通知は重複して作られない ==='
do $$
declare v_n int;
begin
  perform public.flag_dormant_accounts();
  perform public.flag_dormant_accounts();
  select count(*) into v_n from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000002';
  if v_n <> 1 then raise exception 'NG: 通知が重複した（%件）', v_n; end if;
  raise notice 'ok 通知は重複しない';
end $$;

-- u3・u4・u5にも通知を作り、実行日を「過去」にずらす(30日待たずに検証する)
do $$
begin
  perform public.flag_dormant_accounts();
  update public.dormant_account_notices
     set execute_at = now() - interval '1 hour'
   where user_id in ('47000000-0000-0000-0000-000000000003',
                     '47000000-0000-0000-0000-000000000004',
                     '47000000-0000-0000-0000-000000000005');
end $$;

-- u3だけ、通知後にログインし直したことにする
update auth.users set last_sign_in_at = now()
  where id = '47000000-0000-0000-0000-000000000003';

-- ------------------------------------------------------------
\echo '=== ★4. 実行日までにログインがあれば、措置を取らない ==='
do $$
declare v_n int;
begin
  perform public.execute_dormant_accounts();

  select count(*) into v_n from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000003';
  if v_n <> 0 then raise exception 'NG: ログインしたのに通知の行が残っている'; end if;

  if exists (select 1 from public.profiles
              where id = '47000000-0000-0000-0000-000000000003'
                and dormant_closed_at is not null) then
    raise exception 'NG: ログインしたのに停止されている';
  end if;
  raise notice 'ok 実行前にログインがあれば措置を取らない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★6. 成立済みの予約がある間は実行を見送る ==='
do $$
declare v_n int;
begin
  perform public.execute_dormant_accounts();
  if exists (select 1 from public.profiles
              where id = '47000000-0000-0000-0000-000000000005'
                and dormant_closed_at is not null) then
    raise exception 'NG: 予約が残っているのに実行された';
  end if;
  select count(*) into v_n from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000005' and executed_at is null;
  if v_n <> 1 then raise exception 'NG: 通知が消えた（次回に再判定できない）'; end if;
  raise notice 'ok 成立済みの予約がある間は見送る（次回また判定される）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★5. まだ休眠のままなら実行する ==='
do $$
declare v_balance int; v_bonus int; v_earned int; v_closed timestamptz;
        v_is_host boolean; v_n int;
begin
  -- u4は実行されているはず(★4の一括実行で処理済み)
  select balance, bonus_balance, earned_balance into v_balance, v_bonus, v_earned
    from public.coin_wallets where user_id = '47000000-0000-0000-0000-000000000004';
  if v_balance <> 0 or v_bonus <> 0 then
    raise exception 'NG: 購入コインが残っている（% / %）', v_balance, v_bonus;
  end if;
  if v_earned <> 3000 then
    raise exception 'NG: 報酬コインが変わった（%）。金銭債権は消滅させないはず', v_earned;
  end if;

  select dormant_closed_at into v_closed from public.profiles
    where id = '47000000-0000-0000-0000-000000000004';
  if v_closed is null then raise exception 'NG: 停止されていない'; end if;

  select is_host into v_is_host from public.host_settings
    where user_id = '47000000-0000-0000-0000-000000000004';
  -- host_settingsの行自体が無い(ホスト登録していない)ケースもあるので null は許容
  if v_is_host is true then raise exception 'NG: is_hostが下りていない'; end if;

  select count(*) into v_n from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000004' and executed_at is not null;
  if v_n <> 1 then raise exception 'NG: 実行済みの記録が無い'; end if;

  raise notice 'ok 休眠のままなら実行される（購入コイン消滅・報酬コインは残る・掲載停止）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★5-2. 実行後は最終換金(最低額なし・全額一括)が使える ==='
do $$
declare v_msg text;
begin
  perform set_config('test.uid', '47000000-0000-0000-0000-000000000004', false);
  begin
    -- 本人確認・銀行口座は未登録なので、そこで止まるはず。
    -- **見たいのは「その手前(最低申請額)で止まらないこと」だけ**
    perform public.request_bank_payout(3000);
    raise exception 'NG: 口座未登録なのに通った（前提が崩れている）';
  exception when others then
    v_msg := sqlerrm;
    if v_msg like '%MIN_PAYOUT_COINS%' then
      raise exception 'NG: 長期未ログインによる停止なのに最低申請額で止まった';
    end if;
    -- NOT_VERIFIED か BANK_ACCOUNT_NOT_REGISTERED なら、最低額の関門は
    -- 通過できている証拠
    if v_msg not like '%NOT_VERIFIED%' and v_msg not like '%BANK_ACCOUNT_NOT_REGISTERED%' then
      raise;
    end if;
  end;
  raise notice 'ok 長期未ログインによる停止後は、最低申請額の制限を受けない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★7. 実行は再実行しても二重に処理しない ==='
do $$
declare v_earned_before int; v_earned_after int; v_n int;
begin
  select earned_balance into v_earned_before from public.coin_wallets
    where user_id = '47000000-0000-0000-0000-000000000004';

  perform public.execute_dormant_accounts();

  select earned_balance into v_earned_after from public.coin_wallets
    where user_id = '47000000-0000-0000-0000-000000000004';
  if v_earned_after <> v_earned_before then
    raise exception 'NG: 再実行で報酬コインが動いた（% → %）', v_earned_before, v_earned_after;
  end if;

  select count(*) into v_n from public.dormant_account_notices
    where user_id = '47000000-0000-0000-0000-000000000004';
  if v_n <> 1 then raise exception 'NG: 実行済みの行が増えた（%件）', v_n; end if;
  raise notice 'ok 実行は再実行しても二重に処理しない';
end $$;

\echo '=== 47: すべて ok ==='
