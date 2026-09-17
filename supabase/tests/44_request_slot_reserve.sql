-- ============================================================
-- 44: リクエストの応答枠が、はじめたばかりの人に残るか（0124）
--
-- ■ なぜ要るか
--   リクエスト(0120)は、実績のない人にも平等に届く**唯一の経路**。
--   ところが応じられるのは5人までで先着なので、通知をよく見ている
--   実績のある人から埋まる。唯一平等な経路でも席が取れなかった。
--
--   5枠のうち2つを、最初の30分だけ実績ゼロの人に残す。
--
-- ■ このファイルが見ているもの
--     ① 実績のある人は、最初の30分は3枠までしか取れない
--     ② そのとき実績ゼロの人は入れる
--     ③ 30分を過ぎたら取り置きは消え、誰でも5枠まで
--     ④ 一覧(guest_requests_for_host)の答えと、応じたときの結果が一致する
--        （押してから断られない）
--     ⑤ 実績の判定は 0122 と同じ——返金や没収では「実績あり」にならない
-- ============================================================
\set ON_ERROR_STOP on

-- ホスト: …001〜005 が実績あり、…011〜013 が実績ゼロ
insert into auth.users (id)
select ('44000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid
from unnest(array[1,2,3,4,5,11,12,13,91,92]) n
on conflict do nothing;

insert into public.profiles (id, nickname)
select ('44000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'u' || n
from unnest(array[1,2,3,4,5,11,12,13,91,92]) n
on conflict (id) do update set nickname = excluded.nickname;

update public.profile_trust_stats set is_verified = true;

insert into public.host_settings (user_id, is_host, hourly_rate, games)
select ('44000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       true, 1000, array['Apex']
from unnest(array[1,2,3,4,5,11,12,13]) n
on conflict (user_id) do update
  set is_host = true, hourly_rate = 1000, games = array['Apex'];

-- ゲスト（リクエストを出す人）
insert into public.coin_lots (user_id, kind, remaining, expires_at) values
  ('44000000-0000-0000-0000-000000000091','paid', 500000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 500000
  where user_id = '44000000-0000-0000-0000-000000000091';

-- ★実績を作る。**platform_fees の明細があること**が「実績あり」の条件(0122)。
--   完了した予約を1件ずつ通して、明細を自然に作る
do $$
declare h uuid; v_b uuid;
begin
  foreach h in array array[
    '44000000-0000-0000-0000-000000000001'::uuid,
    '44000000-0000-0000-0000-000000000002'::uuid,
    '44000000-0000-0000-0000-000000000003'::uuid,
    '44000000-0000-0000-0000-000000000004'::uuid,
    -- …005 は実績ありだが**一度も応じない**（テスト6で使う）
    '44000000-0000-0000-0000-000000000005'::uuid]
  loop
    perform set_config('test.uid', '44000000-0000-0000-0000-000000000091', false);
    v_b := public.create_booking(h, 60, 'v1', now() + interval '2 days');
    perform set_config('test.uid', h::text, false);
    perform public.approve_booking(v_b);
    perform set_config('test.uid', '44000000-0000-0000-0000-000000000091', false);
    perform public.complete_booking(v_b);
  end loop;
end $$;

do $$
declare v_n int;
begin
  select count(*) into v_n from public.platform_fees
   where kind = 'booking'
     and host_id = '44000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'NG: 前提が崩れた（実績の明細が作られていない）'; end if;
  select count(*) into v_n from public.platform_fees
   where kind = 'booking'
     and host_id = '44000000-0000-0000-0000-000000000011';
  if v_n <> 0 then raise exception 'NG: 前提が崩れた（新人に明細がある）'; end if;
end $$;

-- リクエストを1件出す（Apex・4〜6日後の窓）
-- ⚠️ psql の変数(v_req)は **dollar-quote の中では展開されない。**
--    GUC に入れて do ブロックから current_setting で読む（39 と同じやり方）
set test.uid = '44000000-0000-0000-0000-000000000091';
select set_config('test.req',
  public.create_guest_request(
    'Apex', now() + interval '4 days', now() + interval '6 days', 60, '')::text,
  false);

-- ------------------------------------------------------------
\echo '=== ★1. 実績のある人は、最初の30分は3枠まで ==='
do $$
declare v_req uuid; v_at timestamptz := date_trunc('hour', now() + interval '5 days');
        v_block text; v_msg text;
begin
  v_req := current_setting('test.req')::uuid;
  -- 実績のある3人までは通る
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000001', false);
  perform public.respond_to_guest_request(v_req, v_at);
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000002', false);
  perform public.respond_to_guest_request(v_req, v_at + interval '1 hour');
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000003', false);
  perform public.respond_to_guest_request(v_req, v_at + interval '2 hours');

  -- ★4人目（実績あり）は取り置きに当たる
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000004', false);
  v_block := public._request_response_block(v_req, '44000000-0000-0000-0000-000000000004');
  if v_block <> 'reserved_for_new' then
    raise exception 'NG: 一覧が「応じられる」と言っている（%）', coalesce(v_block, 'null');
  end if;

  begin
    perform public.respond_to_guest_request(v_req, v_at + interval '3 hours');
    raise exception 'NG: 実績のある4人目が入れてしまった';
  exception when others then
    v_msg := sqlerrm;
    if v_msg not like '%RESERVED_FOR_NEW_HOSTS%' then raise; end if;
  end;
  raise notice 'ok 実績のある人は最初の30分は3枠まで';
end $$;

-- ------------------------------------------------------------
\echo '=== ★2. そのとき、実績ゼロの人は入れる ==='
do $$
declare v_req uuid; v_at timestamptz := date_trunc('hour', now() + interval '5 days');
        v_block text;
begin
  v_req := current_setting('test.req')::uuid;
  v_block := public._request_response_block(v_req, '44000000-0000-0000-0000-000000000011');
  if v_block is not null then
    raise exception 'NG: 実績ゼロの人が弾かれている（%）', v_block;
  end if;

  perform set_config('test.uid', '44000000-0000-0000-0000-000000000011', false);
  perform public.respond_to_guest_request(v_req, v_at + interval '4 hours');
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000012', false);
  perform public.respond_to_guest_request(v_req, v_at + interval '5 hours');

  -- ここで5人埋まった。**新人でもこれ以上は入れない**
  v_block := public._request_response_block(v_req, '44000000-0000-0000-0000-000000000013');
  if v_block <> 'enough' then
    raise exception 'NG: 5人埋まったのに enough でない（%）', coalesce(v_block, 'null');
  end if;
  raise notice 'ok 取り置きの2枠に新人が入り、5人で打ち止め';
end $$;

-- ------------------------------------------------------------
\echo '=== ★3. 30分を過ぎたら取り置きは消える ==='
do $$
declare v_req uuid; v_at timestamptz := date_trunc('hour', now() + interval '5 days');
        v_block text;
begin
  v_req := current_setting('test.req')::uuid;
  -- 新人2人の応答を取り下げて、3枠埋まりの状態に戻す
  delete from public.guest_request_responses
   where request_id = v_req
     and host_id in ('44000000-0000-0000-0000-000000000011',
                     '44000000-0000-0000-0000-000000000012');

  -- リクエストを31分前に出したことにする
  update public.guest_requests set created_at = now() - interval '31 minutes'
   where id = v_req;

  -- ★実績のある4人目が入れるようになる
  v_block := public._request_response_block(v_req, '44000000-0000-0000-0000-000000000004');
  if v_block is not null then
    raise exception 'NG: 30分を過ぎても取り置きが残っている（%）', v_block;
  end if;
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000004', false);
  perform public.respond_to_guest_request(v_req, v_at + interval '3 hours');
  raise notice 'ok 30分後は誰でも5枠まで';
end $$;

-- ------------------------------------------------------------
\echo '=== ★4. 言い直し（2度目に応じる）は上限で弾かれない ==='
do $$
declare v_req uuid; v_at timestamptz := date_trunc('hour', now() + interval '5 days');
        v_starts timestamptz;
begin
  v_req := current_setting('test.req')::uuid;
  -- ⚠️ **取り置きが効いている時間に戻して見る。** ここを戻さないと、
  --    「すでに応じた人は上限で弾かれない」という肝心の部分を通らない
  --    （実際、最初はこの規則が無く、応じたあと他に3人集まると
  --      画面に「時刻を変える」が出ているのに直せなくなっていた）
  update public.guest_requests set created_at = now() where id = v_req;
  if public._request_response_block(v_req, '44000000-0000-0000-0000-000000000001') is not null then
    raise exception 'NG: すでに応じた人が上限で弾かれている';
  end if;

  -- いま4人。うち…001 が時刻を言い直す
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000001', false);
  perform public.respond_to_guest_request(v_req, v_at + interval '10 hours');
  select starts_at into v_starts from public.guest_request_responses
    where request_id = v_req and host_id = '44000000-0000-0000-0000-000000000001';
  if v_starts <> v_at + interval '10 hours' then
    raise exception 'NG: 言い直しが反映されていない（%）', v_starts;
  end if;
  if (select count(*) from public.guest_request_responses where request_id = v_req) <> 4 then
    raise exception 'NG: 言い直しで行が増えた';
  end if;
  raise notice 'ok 言い直しは上限に数えない';
end $$;

-- ------------------------------------------------------------
\echo '=== ★5. 返金・没収では「実績あり」にならない（0122と同じ基準） ==='
do $$
declare v_req uuid; v_b uuid; v_block text; v_new uuid := '44000000-0000-0000-0000-000000000013';
begin
  v_req := current_setting('test.req')::uuid;
  -- …013 に「無断欠席の没収」を1件作る。報酬は出るが遊んでいないので
  -- platform_fees の明細は作られない（0122）
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000091', false);
  v_b := public.create_booking(v_new, 60, 'v1', now() + interval '3 days');
  perform set_config('test.uid', v_new::text, false);
  perform public.approve_booking(v_b);
  update public.bookings
     set scheduled_at = now() - interval '10 minutes',
         requested_start_at = now() - interval '10 minutes',
         confirmed_at = now() - interval '2 hours'
   where id = v_b;
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000091', false);
  perform public.cancel_booking(v_b);

  if (select coalesce(sum(amount),0) from public.coin_transactions
        where related_booking_id = v_b and type = 'booking_earned') <= 0 then
    raise exception 'NG: 前提が崩れた（没収が起きていない）';
  end if;
  if exists (select 1 from public.platform_fees where booking_id = v_b) then
    raise exception 'NG: 前提が崩れた（遊んでいないのに明細ができた）';
  end if;

  -- ★没収でコインは入ったが、実績ゼロのままなので取り置きを使える。
  --   いま4人埋まっているので、実績ありなら reserved_for_new になる場面
  v_block := public._request_response_block(v_req, v_new);
  if v_block is not null then
    raise exception 'NG: 没収で「実績あり」になった（%）', v_block;
  end if;
  raise notice 'ok 没収では実績ありにならない（0122と同じ基準）';
end $$;

-- ------------------------------------------------------------
\echo '=== ★6. 一覧の答えと、応じた結果が食い違わない ==='
do $$
declare v_req uuid; r record; v_block text; v_ok boolean;
begin
  v_req := current_setting('test.req')::uuid;
  -- ⚠️ **「応じられる」で一致しても検証にならない。** 取り置きに当たった
  --    状態で一致することを見たいので、**まだ応じていない実績ありの人**で見る。
  --    いま4人応じているので、…005 から見ると4人＝実績ありの上限(3)を超えている
  update public.guest_requests set created_at = now() where id = v_req;

  -- 一覧が返す cannot_respond と、ヘルパーの答えが一致すること。
  -- **画面で数え直していないことの確認**（数え直すと必ずずれる）
  perform set_config('test.uid', '44000000-0000-0000-0000-000000000005', false);
  select * into r from public.guest_requests_for_host(30) where id = v_req;
  if r.id is null then
    raise exception 'NG: 一覧にリクエストが出ていない';
  end if;
  v_block := public._request_response_block(v_req, '44000000-0000-0000-0000-000000000005');
  if r.cannot_respond is distinct from v_block then
    raise exception 'NG: 一覧(%) とヘルパー(%) が食い違う',
      coalesce(r.cannot_respond, 'null'), coalesce(v_block, 'null');
  end if;
  -- 一致しているだけでなく、**塞がっている状態で**一致していること
  if r.cannot_respond is null then
    raise exception 'NG: 前提が崩れた（取り置きに当たっていない）';
  end if;
  raise notice 'ok 一覧の答えは応じる側と同じ規則（%）',
    coalesce(r.cannot_respond, 'null(応じられる)');
end $$;

\echo '=== 44: すべて ok ==='
