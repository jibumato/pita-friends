-- ============================================================
-- 45: ペア相手の申請・承認（0125）
--
-- ゲストがまとめて予約できる(0126)のは、この関係が active の組だけ。
-- ここでは関係そのものの正しさだけを見る。
--
--   ① 両方の承認で成立する。片方の申請だけでは成立しない
--   ② 申請した本人は自分の申請を承認できない
--   ③ 相手からの申請が既にあるところに申請すると、その場で成立する
--   ④ ブロック関係があると申請できない
--   ⑤ ホストでない相手には申請できない
--   ⑥ 成立後はどちらからでも解消できる
--   ⑦ 順序に依らず同じ組は1つ（A→BもB→Aも同じ行に収束する）
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('45000000-0000-0000-0000-000000000001'),  -- ホストA
  ('45000000-0000-0000-0000-000000000002'),  -- ホストB
  ('45000000-0000-0000-0000-000000000003'),  -- ホストC(ブロック関係)
  ('45000000-0000-0000-0000-000000000004')   -- ゲスト(ホストでない)
on conflict do nothing;

insert into public.profiles (id, nickname) values
  ('45000000-0000-0000-0000-000000000001','ホストA'),
  ('45000000-0000-0000-0000-000000000002','ホストB'),
  ('45000000-0000-0000-0000-000000000003','ホストC'),
  ('45000000-0000-0000-0000-000000000004','ゲスト')
on conflict (id) do update set nickname = excluded.nickname;

-- ホストになるには本人確認が要る(HOST_REQUIRES_VERIFICATION)
update public.profile_trust_stats set is_verified = true
  where user_id in ('45000000-0000-0000-0000-000000000001',
                    '45000000-0000-0000-0000-000000000002',
                    '45000000-0000-0000-0000-000000000003');

insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('45000000-0000-0000-0000-000000000001', true, 1000),
  ('45000000-0000-0000-0000-000000000002', true, 1200),
  ('45000000-0000-0000-0000-000000000003', true, 900)
on conflict (user_id) do update set is_host = true, hourly_rate = excluded.hourly_rate;

insert into public.blocks (blocker_id, blocked_id) values
  ('45000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000003')
on conflict do nothing;

-- ------------------------------------------------------------
\echo '=== ★1. 片方の申請だけでは成立しない ==='
do $$
declare v_id uuid; v_status text;
begin
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000001', false);
  v_id := public.propose_pair_partner('45000000-0000-0000-0000-000000000002');
  perform set_config('test.pair', v_id::text, false);

  select status into v_status from public.host_pair_partners where id = v_id;
  if v_status <> 'pending' then
    raise exception 'NG: 片方の申請だけで % になった', v_status;
  end if;
  if public.are_pair_partners(
       '45000000-0000-0000-0000-000000000001',
       '45000000-0000-0000-0000-000000000002') then
    raise exception 'NG: pending なのに are_pair_partners が true';
  end if;
  raise notice 'ok 片方の申請だけでは成立しない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★2. 申請した本人は自分の申請を承認できない ==='
do $$
declare v_id uuid := current_setting('test.pair')::uuid; v_msg text;
begin
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000001', false);
  begin
    perform public.respond_pair_partner(v_id, true);
    raise exception 'NG: 申請者自身が承認できてしまった';
  exception when others then
    v_msg := sqlerrm;
    if v_msg not like '%CANNOT_RESPOND_OWN_REQUEST%' then raise; end if;
  end;
  raise notice 'ok 申請者は自分の申請を承認できない';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 承認すると active になり、are_pair_partners が true ==='
do $$
declare v_id uuid := current_setting('test.pair')::uuid; v_status text;
begin
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000002', false);
  perform public.respond_pair_partner(v_id, true);
  select status into v_status from public.host_pair_partners where id = v_id;
  if v_status <> 'active' then raise exception 'NG: 承認したのに %', v_status; end if;

  if not public.are_pair_partners(
       '45000000-0000-0000-0000-000000000001',
       '45000000-0000-0000-0000-000000000002') then
    raise exception 'NG: active なのに are_pair_partners が false';
  end if;
  -- 順序を入れ替えても同じ答え
  if not public.are_pair_partners(
       '45000000-0000-0000-0000-000000000002',
       '45000000-0000-0000-0000-000000000001') then
    raise exception 'NG: 順序を入れ替えると false になった';
  end if;
  raise notice 'ok 承認で成立。順序に依らず true';
end $$;

-- ------------------------------------------------------------
\echo '=== ★4. ブロック関係があると申請できない ==='
do $$
declare v_msg text;
begin
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000001', false);
  begin
    perform public.propose_pair_partner('45000000-0000-0000-0000-000000000003');
    raise exception 'NG: ブロック関係があるのに申請できた';
  exception when others then
    v_msg := sqlerrm;
    if v_msg not like '%BLOCKED%' then raise; end if;
  end;
  raise notice 'ok ブロック関係があると申請できない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★5. ホストでない相手には申請できない ==='
do $$
declare v_msg text;
begin
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000001', false);
  begin
    perform public.propose_pair_partner('45000000-0000-0000-0000-000000000004');
    raise exception 'NG: ホストでない相手に申請できた';
  exception when others then
    v_msg := sqlerrm;
    if v_msg not like '%PARTNER_NOT_HOST%' then raise; end if;
  end;
  raise notice 'ok ホストでない相手には申請できない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★6. 成立後はどちらからでも解消できる ==='
do $$
declare v_id uuid := current_setting('test.pair')::uuid;
begin
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000002', false);
  perform public.end_pair_partner(v_id);
  if exists (select 1 from public.host_pair_partners where id = v_id) then
    raise exception 'NG: 解消したのに行が残っている';
  end if;
  if public.are_pair_partners(
       '45000000-0000-0000-0000-000000000001',
       '45000000-0000-0000-0000-000000000002') then
    raise exception 'NG: 解消したのに are_pair_partners が true';
  end if;
  raise notice 'ok 解消できる（相手側からでも）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★7. 相手からの申請が既にあるところに申請すると、その場で成立する ==='
do $$
declare v_id1 uuid; v_id2 uuid; v_status text;
begin
  -- A → B に申請
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000001', false);
  v_id1 := public.propose_pair_partner('45000000-0000-0000-0000-000000000002');

  -- B → A に申請（逆向き）。**新しい行を作らず、同じ行がその場で成立する**
  perform set_config('test.uid', '45000000-0000-0000-0000-000000000002', false);
  v_id2 := public.propose_pair_partner('45000000-0000-0000-0000-000000000001');

  if v_id1 <> v_id2 then
    raise exception 'NG: 逆向きの申請で別の行ができた（% / %）', v_id1, v_id2;
  end if;
  select status into v_status from public.host_pair_partners where id = v_id1;
  if v_status <> 'active' then
    raise exception 'NG: 相互の申請なのに % のまま', v_status;
  end if;
  raise notice 'ok 相互の申請はその場で成立する（重複を作らない）';
end $$;

\echo '=== 45: すべて ok ==='
