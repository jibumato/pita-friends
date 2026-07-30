-- ============================================================
-- 89: ギフトの「法的な防壁」が壊れていないことを固定する
-- ------------------------------------------------------------
-- なぜこのテストが要るか。
--
-- 弁護士から、ギフトの相手限定について
--   「実際に一緒に遊んだ(予約が完了した)相手にのみ贈れる、という限定は、
--     ギフトを役務に付随する謝礼と性格づけ、汎用送金(=為替取引・
--     資金移動業該当)との距離を保つ**最重要の防壁**であり、絶対に緩めないこと」
-- という指摘を受けている。
--
-- つまりこの条件は「機能」ではなく**事業の適法性を支える前提**で、
-- うっかり緩めた場合の被害が大きい。だからテストで固定する。
-- あわせて、同じく法務上の意味を持つ次の2つも固定する:
--   ・受領ギフトの**7日換金保留**(マネロン対策として弁護士に説明済み)
--   ・**報酬コインは失効しない**こと(失効すると労働対価の没収になり、
--     消費者契約法10条・公序の問題が正面から生じる)
--
-- 実装は 0020(付随謝礼の限定・保留)・0018(失効の対象)にある。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('c9000000-0000-0000-0000-000000000001'),  -- 贈る人(ゲスト)
  ('c9000000-0000-0000-0000-000000000002'),  -- 受け取る人(ピタメイト)
  ('c9000000-0000-0000-0000-000000000003');  -- 遊んだことのない相手
insert into public.profiles (id, nickname) values
  ('c9000000-0000-0000-0000-000000000001','贈る人'),
  ('c9000000-0000-0000-0000-000000000002','ピタメイト'),
  ('c9000000-0000-0000-0000-000000000003','未プレイの相手')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('c9000000-0000-0000-0000-000000000002',
                    'c9000000-0000-0000-0000-000000000003');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('c9000000-0000-0000-0000-000000000002', true, 2000),
  ('c9000000-0000-0000-0000-000000000003', true, 2000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 2000;

-- 贈る人に有償コインを持たせる
insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('c9000000-0000-0000-0000-000000000001','paid', 100000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 100000
  where user_id = 'c9000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
\echo '=== 1. 【最重要】遊んだことのない相手には贈れない ==='
-- 「トークはつながっているが、予約は1件も完了していない」状態を作る。
-- 誘い(invite)由来のトークは、予約なしで成立する = 弁護士が懸念する
-- 「チャットさえ成立すれば誰にでも送金できる」状態そのもの。
insert into public.invites (id, from_user, to_user, game, when_text, status)
  values ('c9000000-0000-0000-0000-00000000aaaa',
          'c9000000-0000-0000-0000-000000000001',
          'c9000000-0000-0000-0000-000000000003',
          'Apex', '今夜', 'approved');
insert into public.promises (id, invite_id, user_a, user_b, status)
  values ('c9000000-0000-0000-0000-00000000bbbb',
          'c9000000-0000-0000-0000-00000000aaaa',
          'c9000000-0000-0000-0000-000000000001',
          'c9000000-0000-0000-0000-000000000003',
          'scheduled');

set test.uid = 'c9000000-0000-0000-0000-000000000001';
do $$
begin
  perform public.send_gift('c9000000-0000-0000-0000-00000000bbbb'::uuid, 1000, null, null);
  raise exception 'FAIL: 完了予約が無い相手にギフトを贈れてしまった(為替該当性の防壁が壊れている)';
exception
  when others then
    if sqlerrm not like '%NO_COMPLETED_PLAY%' then
      raise exception 'FAIL: 想定と違う理由で失敗した: %', sqlerrm;
    end if;
end $$;
\echo '(NO_COMPLETED_PLAY で弾かれれば OK)'

-- ------------------------------------------------------------
\echo '=== 2. 一緒に遊んだ相手には贈れる ==='
set test.uid = 'c9000000-0000-0000-0000-000000000001';
select public.create_booking('c9000000-0000-0000-0000-000000000002', 60, 'v1') as bk \gset
set test.uid = 'c9000000-0000-0000-0000-000000000002';
select public.approve_booking(:'bk');
set test.uid = 'c9000000-0000-0000-0000-000000000001';
select public.complete_booking(:'bk');

select id as pid from public.promises where booking_id = :'bk' \gset
set test.uid = 'c9000000-0000-0000-0000-000000000001';
select public.send_gift(:'pid', 1000, 'ありがとう', null) is not null as 贈れた;
\echo '(t なら OK。完了予約があるので贈れる)'

-- ------------------------------------------------------------
\echo '=== 3. 受け取ったギフトは7日間は換金できない(保留) ==='
-- 受領直後は earned_balance に入るが、換金可能額からは差し引かれる。
-- 「即時に換金可能」ではないことを固定する。
do $$
declare
  v_earned int;
  v_hold int;
begin
  select earned_balance into v_earned from public.coin_wallets
    where user_id = 'c9000000-0000-0000-0000-000000000002';
  select coalesce(sum(coins), 0) into v_hold from public.gifts
    where receiver_id = 'c9000000-0000-0000-0000-000000000002'
      and created_at > now() - interval '7 days';
  if v_hold <= 0 then
    raise exception 'FAIL: 直近7日の受領ギフトが保留として数えられていない';
  end if;
  raise notice '報酬残高=% / うち保留中=%(この分は換金申請できない)', v_earned, v_hold;
end $$;

-- 保留中は、その分を含む額の換金申請ができないこと。
--
-- **最低換金額(5,000)で落ちたのでは保留を検証したことにならない**ので、
-- 残高を最低額より十分大きくしてから、保留の境界をまたぐ2回の申請で確かめる:
--   ・残高ちょうど(保留分を含む)  → GIFT_ON_HOLD で弾かれる
--   ・残高 − 保留分(=換金可能額) → 通る
set test.uid = 'c9000000-0000-0000-0000-000000000002';
do $$
declare
  v_hold int;
  v_balance constant int := 12000;
  v_ok uuid;
begin
  -- 口座を登録しておく(未登録だと別の理由で落ちて検証にならない)
  insert into public.host_bank_accounts
    (user_id, bank_name, bank_code, branch_name, branch_code,
     account_type, account_number, account_holder_kana)
  values ('c9000000-0000-0000-0000-000000000002','テスト銀行','0001','本店','001',
          '普通','1234567','ピタメイト')
  on conflict (user_id) do nothing;

  -- 最低額の影響を排除するため、残高を十分に大きくする
  update public.coin_wallets set earned_balance = v_balance
    where user_id = 'c9000000-0000-0000-0000-000000000002';

  select coalesce(sum(coins), 0) into v_hold from public.gifts
    where receiver_id = 'c9000000-0000-0000-0000-000000000002'
      and created_at > now() - interval '7 days';
  if v_hold <= 0 then
    raise exception 'FAIL: 保留対象のギフトが無いので検証にならない';
  end if;

  -- (a) 残高ちょうど = 保留分を含む額 → 保留を理由に弾かれること
  begin
    perform public.request_bank_payout(v_balance);
    raise exception 'FAIL: 7日以内に受領したギフト分まで換金できてしまった';
  exception
    when others then
      if sqlerrm like '%FAIL:%' then
        raise;
      end if;
      -- 最低額や残高不足で落ちたのでは、保留を確かめたことにならない
      if sqlerrm not like '%GIFT_ON_HOLD%' then
        raise exception 'FAIL: 保留(GIFT_ON_HOLD)ではない理由で落ちた: %', sqlerrm;
      end if;
      raise notice 'OK: 保留分を含む申請は GIFT_ON_HOLD で弾かれた';
  end;

  -- (b) 保留分を除いた額 → 通ること(保留が「余計に止めていない」ことの確認)
  select public.request_bank_payout(v_balance - v_hold) into v_ok;
  if v_ok is null then
    raise exception 'FAIL: 換金可能額ちょうどの申請が通らなかった';
  end if;
  raise notice 'OK: 残高% − 保留% = %コインの申請は通った', v_balance, v_hold, v_balance - v_hold;
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 報酬コインは失効しない(労働対価の没収を作らない) ==='
-- 購入コインは6か月で失効する(前払式の適用除外を成立させるため)。
-- 一方、報酬コインは役務対価の未払金なので失効の対象外(0018)。
-- 最低換金額(5,000コイン)に届かないまま失効する、という事態が
-- 起きないことを固定する。
do $$
declare
  v_before int;
  v_after int;
  v_expired int;
begin
  select earned_balance into v_before from public.coin_wallets
    where user_id = 'c9000000-0000-0000-0000-000000000002';

  -- すべてのロットを期限切れにして失効処理を走らせる
  update public.coin_lots set expires_at = now() - interval '1 day';
  select public.expire_coins() into v_expired;

  select earned_balance into v_after from public.coin_wallets
    where user_id = 'c9000000-0000-0000-0000-000000000002';

  if v_after <> v_before then
    raise exception 'FAIL: 失効処理で報酬コインが減った(% → %)', v_before, v_after;
  end if;
  raise notice 'OK: ロット%件を失効させても報酬コインは % のまま', v_expired, v_after;
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 相互送金はできない(通謀による循環を防ぐ) ==='
-- 2で贈られた側から贈り主へは返せない。
set test.uid = 'c9000000-0000-0000-0000-000000000002';
insert into public.coin_lots (user_id, kind, remaining, expires_at)
  values ('c9000000-0000-0000-0000-000000000002','paid', 50000, public.coin_expiry_from(now()));
update public.coin_wallets set balance = 50000
  where user_id = 'c9000000-0000-0000-0000-000000000002';
do $$
begin
  perform public.send_gift(
    (select id from public.promises where user_a = 'c9000000-0000-0000-0000-000000000001'
       and user_b = 'c9000000-0000-0000-0000-000000000002' limit 1), 500, null, null);
  raise exception 'FAIL: 相互送金ができてしまった';
exception
  when others then
    if sqlerrm like '%FAIL:%' then
      raise;
    end if;
    raise notice 'OK: 相互送金は弾かれた(%)', sqlerrm;
end $$;

\echo '=== 89 すべて通過 ==='
