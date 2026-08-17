-- ============================================================
-- 35: 検索に出さない相手(0116)
--
-- 固定するのは「ブロックとの違い」。非表示は**相手に何の影響も与えない**。
-- ここが混ざると、好みの問題が安全の仕組みに流れ込む。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('35000000-0000-0000-0000-000000000001'),  -- ピタメイト
  ('35000000-0000-0000-0000-000000000009'),  -- 非表示にする人
  ('35000000-0000-0000-0000-000000000008')   -- 無関係な第三者
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('35000000-0000-0000-0000-000000000001','ピタメイト'),
  ('35000000-0000-0000-0000-000000000009','ゲスト'),
  ('35000000-0000-0000-0000-000000000008','第三者')
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true
  where user_id in ('35000000-0000-0000-0000-000000000001',
                    '35000000-0000-0000-0000-000000000009');
insert into public.host_settings (user_id, is_host, hourly_rate)
values ('35000000-0000-0000-0000-000000000001', true, 1000)
on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('35000000-0000-0000-0000-000000000009','paid', 50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id = '35000000-0000-0000-0000-000000000009';

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 付けたり外したりできる ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '35000000-0000-0000-0000-000000000009';
do $$
declare v_n int;
begin
  perform public.set_host_hidden('35000000-0000-0000-0000-000000000001', true);
  select count(*) into v_n from public.my_hidden_hosts();
  if v_n <> 1 then raise exception 'FAIL 非表示にできていない: %', v_n; end if;

  -- 連打しても増えない
  perform public.set_host_hidden('35000000-0000-0000-0000-000000000001', true);
  select count(*) into v_n from public.my_hidden_hosts();
  if v_n <> 1 then raise exception 'FAIL 二重に入った: %', v_n; end if;

  perform public.set_host_hidden('35000000-0000-0000-0000-000000000001', false);
  select count(*) into v_n from public.my_hidden_hosts();
  if v_n <> 0 then raise exception 'FAIL 解除できていない: %', v_n; end if;
  raise notice 'OK 付け外しできる・連打で増えない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 一覧に名前が出る(解除できるように) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare r record;
begin
  perform public.set_host_hidden('35000000-0000-0000-0000-000000000001', true);
  select * into r from public.my_hidden_hosts() limit 1;
  if r.nickname <> 'ピタメイト' then
    raise exception 'FAIL 名前が引けていない: %', r.nickname;
  end if;
  raise notice 'OK 誰を非表示にしたか分かる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. ★相手には何の影響も無い(ブロックとの違い) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_booking uuid;
begin
  -- 非表示にしたままでも予約できる。**弾いたらブロックと同じになる**
  v_booking := public.create_booking(
    '35000000-0000-0000-0000-000000000001', 60, 'v1', null);
  if v_booking is null then raise exception 'FAIL 非表示にすると予約できなくなった'; end if;

  -- 通知も操作記録も残さない(好みの問題を運営の判断材料にしない)
  if exists (select 1 from public.notifications
             where user_id = '35000000-0000-0000-0000-000000000001'
               and type like '%hidden%') then
    raise exception 'FAIL 相手に通知が飛んだ';
  end if;
  if exists (select 1 from public.admin_actions where kind like '%hidden%') then
    raise exception 'FAIL 運営の操作記録に残った';
  end if;
  raise notice 'OK 予約はできる・通知も記録も残らない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 他人の非表示は見えない・作れない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '35000000-0000-0000-0000-000000000008';
do $$
declare v_n int;
begin
  -- my_hidden_hosts は auth.uid() で絞るので、第三者には0件
  select count(*) into v_n from public.my_hidden_hosts();
  if v_n <> 0 then raise exception 'FAIL 他人の非表示が見えている: %', v_n; end if;
  raise notice 'OK 誰に非表示にされているかは分からない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 自分自身は非表示にできない ==='; end $$;
-- ------------------------------------------------------------
do $$
begin
  begin
    perform public.set_host_hidden('35000000-0000-0000-0000-000000000008', true);
    raise exception 'FAIL 自分を非表示にできてしまった';
  exception when others then
    if sqlerrm not like '%CANNOT_HIDE_SELF%' then raise; end if;
  end;
  raise notice 'OK CANNOT_HIDE_SELF で止まる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 未ログインでは呼べない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '';
do $$
begin
  begin
    perform public.set_host_hidden('35000000-0000-0000-0000-000000000001', true);
    raise exception 'FAIL 未ログインで呼べてしまった';
  exception when others then
    if sqlerrm not like '%NOT_AUTHENTICATED%' then raise; end if;
  end;
  raise notice 'OK NOT_AUTHENTICATED で止まる';
end $$;

\echo '==== 35: すべて通過 ===='
