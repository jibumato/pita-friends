-- ============================================================
-- 25: 制限値が「運営コンソールから動かせて、かつ天井を超えない」こと(0101)
-- ------------------------------------------------------------
-- 0101 の狙いは2つで、どちらが欠けても意味が無い。
--
--   ①動かせること   … 数値がハードコードだと、運営が SQL Editor を
--                       開くまで何も変えられない
--   ②天井があること … 無制限に動かせると、ギフトの「付随謝礼」という
--                       性格づけ(=為替取引該当性の否定)が数値の側から崩れる
--
-- 固定するのは:
--   ・運営以外は読むことも変えることもできない
--   ・理由が無ければ変えられない(admin_actions に残す前提)
--   ・知らないキーは黙って捨てず、その場で落とす
--   ・天井を超える値・順序が壊れる値は入らない
--   ・**変えた値に send_gift が実際に従う**(表に移しただけで
--     関数が定数を見ていたら、画面は嘘をつく)
--   ・前後の値が admin_actions に残る
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('25000000-0000-0000-0000-000000000001'),  -- 贈る人(ゲスト)
  ('25000000-0000-0000-0000-000000000002'),  -- 受け取る人(ピタメイト)
  ('25000000-0000-0000-0000-0000000000ad');  -- 運営
insert into public.profiles (id, nickname) values
  ('25000000-0000-0000-0000-000000000001','贈る人'),
  ('25000000-0000-0000-0000-000000000002','ピタメイト'),
  ('25000000-0000-0000-0000-0000000000ad','運営')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id = '25000000-0000-0000-0000-000000000002';
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('25000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;
insert into public.admins (user_id) values ('25000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;

insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('25000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 100000
  where user_id = '25000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 運営以外は触れない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '25000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.admin_platform_limits();
    raise exception 'FAIL 一般ユーザーが制限値を読めてしまった';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
  begin
    perform public.admin_update_platform_limits('理由', '{"giftMaxPerTx": 100}'::jsonb);
    raise exception 'FAIL 一般ユーザーが制限値を変えられてしまった';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
  raise notice 'OK 読み書きとも NOT_ADMIN';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 既定値は 0087/0097 のときと同じ ==='; end $$;
-- ------------------------------------------------------------
-- **0101 は挙動を変えない migration。** 既定値がずれていたら、
-- 「場所を移しただけ」ではなく実質的な緩和をしてしまっている
set test.uid = '25000000-0000-0000-0000-0000000000ad';
do $$
declare r jsonb;
begin
  r := public.admin_platform_limits();
  if (r -> 'newUser' ->> 'days')::int <> 30
     or (r -> 'newUser' ->> 'purchaseMaxYen')::int <> 10000
     or (r -> 'newUser' ->> 'periodPurchaseMaxYen')::int <> 30000
     or (r -> 'newUser' ->> 'payoutHoldDays')::int <> 30 then
    raise exception 'FAIL 新規ユーザー制限の既定値が変わっている: %', r -> 'newUser';
  end if;
  if (r -> 'gift' ->> 'maxPerTx')::int <> 50000
     or (r -> 'gift' ->> 'maxPerDay')::int <> 50000
     or (r -> 'gift' ->> 'maxPerMonth')::int <> 200000
     or (r -> 'gift' ->> 'maxRecvMonth')::int <> 1000000
     or (r -> 'gift' ->> 'maxPairMonth')::int <> 100000
     or (r -> 'gift' ->> 'windowDays')::int <> 30 then
    raise exception 'FAIL ギフト上限の既定値が変わっている: %', r -> 'gift';
  end if;
  raise notice 'OK 既定値は移設前と同じ';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 理由・空・知らないキー ==='; end $$;
-- ------------------------------------------------------------
do $$
begin
  begin
    perform public.admin_update_platform_limits('  ', '{"giftMaxPerTx": 1000}'::jsonb);
    raise exception 'FAIL 理由なしで変えられてしまった';
  exception when others then
    if sqlerrm not like '%REASON_REQUIRED%' then raise; end if;
    raise notice 'OK 理由が空なら REASON_REQUIRED';
  end;

  begin
    perform public.admin_update_platform_limits('理由', '{}'::jsonb);
    raise exception 'FAIL 空の変更が通ってしまった';
  exception when others then
    if sqlerrm not like '%NO_CHANGES%' then raise; end if;
    raise notice 'OK 空なら NO_CHANGES';
  end;

  -- **綴り間違いで「変えたつもり」になるのが一番まずい**
  begin
    perform public.admin_update_platform_limits('理由', '{"giftMaxPerTX": 1000}'::jsonb);
    raise exception 'FAIL 知らないキーが黙って捨てられた';
  exception when others then
    if sqlerrm not like '%UNKNOWN_KEY%' then raise; end if;
    raise notice 'OK 知らないキーは UNKNOWN_KEY で落ちる';
  end;

  -- 同じ値を入れても「変更なし」
  begin
    perform public.admin_update_platform_limits('理由', '{"giftMaxPerTx": 50000}'::jsonb);
    raise exception 'FAIL 同じ値なのに変更として通ってしまった';
  exception when others then
    if sqlerrm not like '%NO_CHANGES%' then raise; end if;
    raise notice 'OK 同じ値なら NO_CHANGES';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 天井を超える値は入らない ==='; end $$;
-- ------------------------------------------------------------
-- ⚠️ ここが通るようになったら、ギフトを「付随謝礼」と説明する根拠が
-- 数値の側から崩れる。**天井を上げる判断は弁護士に相談してから。**
do $$
declare
  v_case record;
begin
  for v_case in
    select * from (values
      ('giftMaxPerTx',            200000, 'ギフト1回の天井(100,000)'),
      ('giftMaxPerDay',           200000, '1日の天井(100,000)'),
      ('giftMaxPerMonth',        1000000, '30日の天井(500,000)'),
      ('giftMaxRecvMonth',       9000000, '受領側の天井(2,000,000)'),
      ('giftMaxPairMonth',        900000, '同一相手の天井(200,000)'),
      ('giftWindowDays',              365, '期間の天井(90日)'),
      ('newUserPayoutHoldDays',        60, '換金保留の天井(規約が「最長30日」と画している)')
    ) as t(k, v, label)
  loop
    begin
      perform public.admin_update_platform_limits(
        'テスト', jsonb_build_object(v_case.k, v_case.v));
      raise exception 'FAIL 天井を超えた: % = %', v_case.k, v_case.v;
    exception when check_violation then
      raise notice 'OK %', v_case.label;
    end;
  end loop;
end $$;

-- 順序の制約(内側の上限が意味を失わないこと)
do $$
begin
  begin
    -- 1回 > 1日 になる組み合わせ
    perform public.admin_update_platform_limits('テスト', '{"giftMaxPerTx": 60000}'::jsonb);
    raise exception 'FAIL 1回の上限が1日の上限を超えられてしまった';
  exception when check_violation then
    raise notice 'OK 1回 <= 1日 の順序が守られる';
  end;
  begin
    -- 同一相手 > 受領側 になる組み合わせ
    perform public.admin_update_platform_limits('テスト', '{"giftMaxPairMonth": 150000,
      "giftMaxRecvMonth": 120000}'::jsonb);
    raise exception 'FAIL 同一相手の上限が受領側の上限を超えられてしまった';
  exception when check_violation then
    raise notice 'OK 同一相手 <= 受領側 の順序が守られる';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 変えた値に send_gift が実際に従う ==='; end $$;
-- ------------------------------------------------------------
-- **ここが本題。** 表に移しただけで関数が定数を見ていたら、
-- 運営コンソールの数字は嘘になる
set test.uid = '25000000-0000-0000-0000-000000000001';
select public.create_booking('25000000-0000-0000-0000-000000000002', 60, 'v1') as bk \gset
set test.uid = '25000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
set test.uid = '25000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk');

set test.uid = '25000000-0000-0000-0000-0000000000ad';
select public.admin_update_platform_limits(
  '検証のため1回あたりを500に下げる',
  '{"giftMaxPerTx": 500}'::jsonb);

set test.uid = '25000000-0000-0000-0000-000000000001';
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
    where user_a = '25000000-0000-0000-0000-000000000001'
       or user_b = '25000000-0000-0000-0000-000000000001'
    order by created_at desc limit 1;

  begin
    perform public.send_gift(v_pid, 1000, null, null);
    raise exception 'FAIL 下げた上限(500)を超える1,000コインが通ってしまった';
  exception when others then
    if sqlerrm not like '%INVALID_AMOUNT%' then raise; end if;
    raise notice 'OK 下げた上限を超えると INVALID_AMOUNT';
  end;

  -- 上限内なら通る(下げすぎて全部止まっているのではないことの確認)
  if public.send_gift(v_pid, 400, 'ありがとう', null) is null then
    raise exception 'FAIL 上限内(400)なのに贈れなかった';
  end if;
  raise notice 'OK 上限内(400)は通る';
end $$;

-- 同一相手の上限も表から読んでいること
set test.uid = '25000000-0000-0000-0000-0000000000ad';
select public.admin_update_platform_limits(
  '検証のため同一相手の30日上限を500に下げる',
  '{"giftMaxPairMonth": 500}'::jsonb);

set test.uid = '25000000-0000-0000-0000-000000000001';
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
    where user_a = '25000000-0000-0000-0000-000000000001'
       or user_b = '25000000-0000-0000-0000-000000000001'
    order by created_at desc limit 1;
  -- すでに400贈っているので、+200 で 600 > 500
  begin
    perform public.send_gift(v_pid, 200, null, null);
    raise exception 'FAIL 同一相手の上限(500)を超えたのに通ってしまった';
  exception when others then
    if sqlerrm not like '%PAIR_MONTHLY_LIMIT%' then raise; end if;
    raise notice 'OK 同一相手の上限は PAIR_MONTHLY_LIMIT で効く';
  end;
end $$;

-- 期間(gift_window_days)も表から読んでいること
set test.uid = '25000000-0000-0000-0000-0000000000ad';
select public.admin_update_platform_limits(
  '検証のため期間を1日に縮める',
  '{"giftWindowDays": 1, "giftMaxPairMonth": 100000}'::jsonb);

-- 完了確定の記録を2日前にずらす(0044で台帳は追記専用なので明示的に解除する)
set app.ledger_override = 'on';
update public.coin_transactions set created_at = now() - interval '2 days'
  where type = 'booking_earned' and user_id = '25000000-0000-0000-0000-000000000002';
reset app.ledger_override;

set test.uid = '25000000-0000-0000-0000-000000000001';
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
    where user_a = '25000000-0000-0000-0000-000000000001'
       or user_b = '25000000-0000-0000-0000-000000000001'
    order by created_at desc limit 1;
  begin
    perform public.send_gift(v_pid, 100, null, null);
    raise exception 'FAIL 期間(1日)を過ぎているのに贈れてしまった';
  exception when others then
    if sqlerrm not like '%GIFT_WINDOW_CLOSED%' then raise; end if;
    raise notice 'OK 期間を過ぎると GIFT_WINDOW_CLOSED';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 前後の値が運営の操作記録に残る ==='; end $$;
-- ------------------------------------------------------------
-- **記録があっても、前後の値が無いと後から説明できない。**
-- 「理由なく上限を下げて換金させなかった」と言われたときの反証材料はこれしかない
do $$
declare v_note text; v_actor uuid;
begin
  select note, actor into v_note, v_actor from public.admin_actions
    where kind = 'update_platform_limits' order by at limit 1;
  if v_note is null then
    raise exception 'FAIL 制限値の変更が admin_actions に残っていない';
  end if;
  if v_note not like '%giftMaxPerTx: 50000→500%' then
    raise exception 'FAIL 前後の値が残っていない: %', v_note;
  end if;
  if v_note not like '%理由:%' then
    raise exception 'FAIL 理由が残っていない: %', v_note;
  end if;
  if v_actor <> '25000000-0000-0000-0000-0000000000ad' then
    raise exception 'FAIL 操作者が残っていない: %', v_actor;
  end if;
  raise notice 'OK %', v_note;
end $$;

do $$ begin raise notice '==== 25: すべて通過 ===='; end $$;
