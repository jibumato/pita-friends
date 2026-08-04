-- ============================================================
-- 30: 異議申立ての証跡が、束ねて取り出せる(0106)
-- ------------------------------------------------------------
-- 材料が全部あっても、Stripeの反論期限(7〜21日)の中で1枚にまとめられ
-- なければ争えない。**束ねる口があること**が本体なので、そこを固定する。
--
-- 固定するのは6つ:
--   ・運営以外は証跡を取り出せない
--   ・購入時点のIP・端末・UAが**その購入に**紐づいて出る
--   ・同意が**表示した文面ごと**出る(版番号だけでは証明にならない)
--   ・役務提供の記録(チェックイン・完了)が出る
--   ・**メッセージの本文は入らない**(第三者提供の判断を運営に残す)
--   ・0106より前の購入は available=false で**黙って隠さない**
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('30000000-0000-0000-0000-000000000001', 'guest30@example.com'),
  ('30000000-0000-0000-0000-000000000002', null),
  ('30000000-0000-0000-0000-0000000000ad', null);
insert into public.profiles (id, nickname) values
  ('30000000-0000-0000-0000-000000000001','買った人'),
  ('30000000-0000-0000-0000-000000000002','ピタメイト'),
  ('30000000-0000-0000-0000-0000000000ad','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('30000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;
update public.profile_trust_stats set is_verified = true
  where user_id in ('30000000-0000-0000-0000-000000000001',
                    '30000000-0000-0000-0000-000000000002');
-- 0081: 本人確認の前に居住地の申告が要る
insert into public.residency_declarations (user_id, declared_japan, version)
  values ('30000000-0000-0000-0000-000000000001', true, 'v1');
insert into public.identity_verifications (user_id, status, verified_at)
  values ('30000000-0000-0000-0000-000000000001', 'verified', now() - interval '40 days');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('30000000-0000-0000-0000-000000000002', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- 購入(webhook と同じ順序: 環境の記録 → 付与)
select public.record_purchase_evidence(
  'sess_30_1', '30000000-0000-0000-0000-000000000001',
  '203.0.113.9', 'dev-abcdefgh', 'Mozilla/5.0 (iPhone) Safari/605', 10000, 500);
select public.credit_coins_for_purchase(
  '30000000-0000-0000-0000-000000000001', 'pack_10000', 10000, 0, 10000,
  'sess_30_1', 'pi_30_1');

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 運営以外は取り出せない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '30000000-0000-0000-0000-000000000001';
do $$
declare v_id uuid;
begin
  select id into v_id from public.coin_purchases where stripe_session_id = 'sess_30_1';
  begin
    perform public.admin_purchase_evidence(v_id);
    raise exception 'FAIL 本人が自分の証跡一式を取り出せてしまった';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
    raise notice 'OK NOT_ADMIN';
  end;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 同意は「表示した文面ごと」残る ==='; end $$;
-- ------------------------------------------------------------
-- **版番号だけでは、その版が何と書いてあったかを示せない**
select public.record_policy_consent(
  'cancellation',
  E'【キャンセル・返金について】(版 2026-07-27)\n開始後・無断欠席は戻らず、コインは相手の報酬になります',
  null, 'dev-abcdefgh');

do $$
begin
  begin
    perform public.record_policy_consent('cancellation', '   ');
    raise exception 'FAIL 空の文面が記録できてしまった';
  exception when others then
    if sqlerrm not like '%TEXT_REQUIRED%' then raise; end if;
  end;
  begin
    perform public.record_policy_consent('unknown_kind', 'あああ');
    raise exception 'FAIL 知らない種別が記録できてしまった';
  exception when others then
    if sqlerrm not like '%INVALID_KIND%' then raise; end if;
  end;
  raise notice 'OK 空文面と未知の種別は弾かれる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 役務提供の記録(遊んだ事実)を作る ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '30000000-0000-0000-0000-000000000001';
select public.create_booking('30000000-0000-0000-0000-000000000002', 60, 'v1') as bk \gset
set test.uid = '30000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
update public.bookings set scheduled_at = now() - interval '30 minutes',
  confirmed_at = now() - interval '1 hour' where id = :'bk';
set test.uid = '30000000-0000-0000-0000-000000000001';
select public.check_in_booking(:'bk');
set test.uid = '30000000-0000-0000-0000-000000000002';
select public.check_in_booking(:'bk');
set test.uid = '30000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk');

-- アプリ起動の記録(購入の前後に使っていたこと)
select public.record_access_event(
  '30000000-0000-0000-0000-000000000001', '203.0.113.9', 'dev-abcdefgh', 'Mozilla/5.0');

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 束ねた証跡の中身 ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '30000000-0000-0000-0000-0000000000ad';
do $$
declare r jsonb; v_id uuid;
begin
  select id into v_id from public.coin_purchases where stripe_session_id = 'sess_30_1';
  r := public.admin_purchase_evidence(v_id);

  -- 購入時点の環境。**「最後に見たIP」ではなく、この購入のときのIP**
  if (r -> 'purchaseEnvironment' ->> 'available')::boolean is not true then
    raise exception 'FAIL 購入時点の環境が出ていない';
  end if;
  if (r -> 'purchaseEnvironment' ->> 'ip') <> '203.0.113.9' then
    raise exception 'FAIL 購入時のIPが違う: %', r -> 'purchaseEnvironment' ->> 'ip';
  end if;
  if (r -> 'purchaseEnvironment' ->> 'userAgent') not like 'Mozilla/5.0%' then
    raise exception 'FAIL User-Agentが出ていない';
  end if;

  -- 本人確認とメール(Stripeの Customer details 欄)
  if (r -> 'customer' ->> 'identityVerified')::boolean is not true
     or (r -> 'customer' ->> 'identityVerifiedAt') is null then
    raise exception 'FAIL 本人確認の結果が出ていない: %', r -> 'customer';
  end if;
  if (r -> 'customer' ->> 'email') <> 'guest30@example.com' then
    raise exception 'FAIL メールが出ていない';
  end if;

  -- 請求額(Receipt 欄)
  if (r -> 'purchase' ->> 'totalYen')::int <> 10000 then
    raise exception 'FAIL 請求総額が違う: %', r -> 'purchase' ->> 'totalYen';
  end if;

  -- 同意(Refund policy 欄)。**文面が入っていること**
  if jsonb_array_length(r -> 'consents') < 1 then
    raise exception 'FAIL 同意の記録が出ていない';
  end if;
  if (r -> 'consents' -> 0 ->> 'shownText') not like '%開始後・無断欠席は戻らず%' then
    raise exception 'FAIL 同意に文面が入っていない(版番号だけでは証明にならない)';
  end if;

  -- 役務提供(Service documentation / Service date 欄)
  if jsonb_array_length(r -> 'service' -> 'bookings') < 1 then
    raise exception 'FAIL 予約が出ていない';
  end if;
  if (r -> 'service' -> 'bookings' -> 0 ->> 'status') <> 'completed' then
    raise exception 'FAIL 完了の記録が出ていない';
  end if;
  if (r -> 'service' -> 'bookings' -> 0 ->> 'guestCheckedInAt') is null
     or (r -> 'service' -> 'bookings' -> 0 ->> 'hostCheckedInAt') is null then
    raise exception 'FAIL 双方のチェックインが出ていない(実際に遊んだ証拠の中心)';
  end if;

  -- アプリ起動(Activity log 欄)
  if jsonb_array_length(r -> 'accessLog') < 1 then
    raise exception 'FAIL アプリ起動の記録が出ていない';
  end if;

  raise notice 'OK IP・UA・本人確認・請求額・同意文面・チェックイン・起動記録がすべて出た';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. メッセージの本文は入らない ==='; end $$;
-- ------------------------------------------------------------
-- ⚠️ 本文には第三者(ピタメイト)の発言が混ざる。カード会社へ渡すかは
-- 個人情報の第三者提供として別に判断する。**束が勝手に持ち出さない。**
set test.uid = '30000000-0000-0000-0000-000000000002';
do $$
declare v_pid uuid;
begin
  select id into v_pid from public.promises
    where user_a = '30000000-0000-0000-0000-000000000001'
       or user_b = '30000000-0000-0000-0000-000000000001'
    order by created_at desc limit 1;
  insert into public.messages (promise_id, sender_id, body)
    values (v_pid, '30000000-0000-0000-0000-000000000002', 'ヒミツの合言葉ラムダ');
end $$;

set test.uid = '30000000-0000-0000-0000-0000000000ad';
do $$
declare r jsonb; v_id uuid;
begin
  select id into v_id from public.coin_purchases where stripe_session_id = 'sess_30_1';
  r := public.admin_purchase_evidence(v_id);

  if r::text like '%ヒミツの合言葉ラムダ%' then
    raise exception 'FAIL メッセージの本文が束に入ってしまった';
  end if;
  -- 「やりとりがあった事実」は入る
  if jsonb_array_length(r -> 'service' -> 'messageThreads') < 1 then
    raise exception 'FAIL やりとりの件数すら出ていない';
  end if;
  if (r -> 'service' -> 'messageThreads' -> 0 ->> 'messages')::int < 1 then
    raise exception 'FAIL 通数が数えられていない';
  end if;
  raise notice 'OK 本文は入らず、通数と時刻だけが出る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 環境の記録が無い購入は available=false ==='; end $$;
-- ------------------------------------------------------------
-- **黙って隠さない。** 0106より前の購入には環境が無く、
-- 「IPが空」と「記録していなかった」は別のこと
select public.credit_coins_for_purchase(
  '30000000-0000-0000-0000-000000000001', 'pack_1000', 1000, 0, 1000,
  'sess_30_old', 'pi_30_old');

do $$
declare r jsonb; v_id uuid;
begin
  select id into v_id from public.coin_purchases where stripe_session_id = 'sess_30_old';
  r := public.admin_purchase_evidence(v_id);
  if (r -> 'purchaseEnvironment' ->> 'available')::boolean is not false then
    raise exception 'FAIL 記録が無いのに available が false でない';
  end if;
  raise notice 'OK 記録が無いことが available=false で分かる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 7. 申立てから引ける／購入と紐づかない申立て ==='; end $$;
-- ------------------------------------------------------------
insert into public.payment_disputes
  (user_id, stripe_dispute_id, stripe_charge_id, stripe_payment_intent,
   amount_yen, reason, status)
values
  ('30000000-0000-0000-0000-000000000001','dp_30_1','ch_30_1','pi_30_1',
   10000, 'fraudulent', 'open'),
  ('30000000-0000-0000-0000-000000000001','dp_30_x','ch_30_x','pi_unknown',
   3000, 'fraudulent', 'open');

do $$
declare r jsonb; v_id uuid;
begin
  select id into v_id from public.payment_disputes where stripe_dispute_id = 'dp_30_1';
  r := public.admin_dispute_evidence(v_id);
  if (r ->> 'purchaseFound')::boolean is not true then
    raise exception 'FAIL 申立てから購入をたどれていない';
  end if;
  if (r -> 'evidence' -> 'purchaseEnvironment' ->> 'ip') <> '203.0.113.9' then
    raise exception 'FAIL 申立て経由だと証跡が欠ける';
  end if;

  -- 紐づかない申立ては**例外にせず**、その旨を返す(0075のコメントどおり)
  select id into v_id from public.payment_disputes where stripe_dispute_id = 'dp_30_x';
  r := public.admin_dispute_evidence(v_id);
  if (r ->> 'purchaseFound')::boolean is not false then
    raise exception 'FAIL 紐づかない申立てで purchaseFound が false でない';
  end if;
  raise notice 'OK 申立てから引け、紐づかない申立ては例外にせず知らせる';
end $$;

do $$ begin raise notice '==== 30: すべて通過 ===='; end $$;
