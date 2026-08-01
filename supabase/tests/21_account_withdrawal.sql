-- ============================================================
-- 21: 退会(0086・G6)
-- ------------------------------------------------------------
-- 規約 第6条の2。弁護士(総評3)が
-- 「**換金できない残高を人質に離脱を妨げる外形は、優越的地位の濫用の
--   評価において最も分の悪い事実になる**」と指摘した箇所。
--
-- したがってここで守るのは「退会できること」より、
-- **「辞めた後も、稼いだ分を回収できること」**のほう。
--
-- 固定するのは7つ:
--   ・消滅するコインの数を、退会**前**に出せること(第3項の約束)
--   ・成立済みの予約があるうちは退会できないこと(第2項)
--   ・有償・無償は消え、**報酬コインは消えない**こと(第4項)
--   ・退会後もサービスは使えないこと
--   ・退会後90日以内は換金を申請できること
--   ・90日を過ぎたら申請できず、報酬コインが消えること
--   ・**申請中の換金があるうちは消さない**こと
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('e1000000-0000-0000-0000-000000000001'),
  ('e1000000-0000-0000-0000-000000000002');
insert into public.profiles (id, nickname) values
  ('e1000000-0000-0000-0000-000000000001','退会する人'),
  ('e1000000-0000-0000-0000-000000000002','相手')
  on conflict (id) do update set nickname = excluded.nickname;
update public.profile_trust_stats set is_verified = true
  where user_id in ('e1000000-0000-0000-0000-000000000001',
                    'e1000000-0000-0000-0000-000000000002');
insert into public.host_settings (user_id, is_host, hourly_rate) values
  ('e1000000-0000-0000-0000-000000000001', true, 1000),
  ('e1000000-0000-0000-0000-000000000002', true, 1000)
  on conflict (user_id) do update set is_host = true, hourly_rate = 1000;

-- 有償2000・無償0・報酬6000 の状態を作る
insert into public.coin_lots (user_id, kind, remaining, expires_at)
values ('e1000000-0000-0000-0000-000000000001','paid', 2000, now() + interval '3 months');
update public.coin_wallets set balance = 2000, earned_balance = 6000
  where user_id = 'e1000000-0000-0000-0000-000000000001';

set test.uid = 'e1000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
\echo '=== 1. 退会の前に、消えるコインの数を出せること(第6条の2第3項) ==='
-- **数を出せないと条文違反になる。** 表示の材料は実装の一部
do $$
declare v jsonb;
begin
  v := public.withdrawal_preview();
  if (v->>'expiring_paid')::int <> 2000 then
    raise exception 'FAIL: 消えるコイン数が出ない(%)', v;
  end if;
  if (v->>'earned_balance')::int <> 6000 then
    raise exception 'FAIL: 報酬コインが出ない(%)', v;
  end if;
  if (v->>'payout_days')::int <> 90 then
    raise exception 'FAIL: 換金できる期間が90日でない(%)', v;
  end if;
  if (v->>'can_withdraw')::boolean is not true then
    raise exception 'FAIL: 退会できる状態のはずが can_withdraw=false(%)', v;
  end if;
  raise notice 'OK: 消滅%枚 / 報酬%枚 / 期限%',
    (v->>'expiring_paid')::int, (v->>'earned_balance')::int, v->>'payout_deadline';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 成立済みの予約があるうちは退会できないこと(第2項) ==='
-- **相手のあることなので、片方が黙って消えると相手が救済されない**
select public.create_booking('e1000000-0000-0000-0000-000000000002', 60) as bk \gset

do $$
declare v jsonb;
begin
  v := public.withdrawal_preview();
  if (v->>'blocking_bookings')::int < 1 then
    raise exception 'FAIL: 進行中の予約を数えていない(%)', v;
  end if;
  if (v->>'can_withdraw')::boolean is not false then
    raise exception 'FAIL: 予約があるのに退会できることになっている';
  end if;

  begin
    perform public.withdraw_account(null);
    raise exception 'FAIL: 予約を残したまま退会できてしまった';
  exception when others then
    if sqlerrm <> 'HAS_ACTIVE_BOOKINGS' then raise; end if;
  end;
  raise notice 'OK: HAS_ACTIVE_BOOKINGS で止まる';
end $$;

-- 予約を片付ける(相手が辞退)
set test.uid = 'e1000000-0000-0000-0000-000000000002';
select public.decline_booking(:'bk');
set test.uid = 'e1000000-0000-0000-0000-000000000001';

-- ------------------------------------------------------------
\echo '=== 3. 退会で有償は消え、報酬コインは残ること(第3項・第4項) ==='
do $$
declare v jsonb; v_bal int; v_earned int; v_lots int; v_host boolean;
begin
  v := public.withdraw_account('テスト');

  select balance, earned_balance into v_bal, v_earned
  from public.coin_wallets where user_id = 'e1000000-0000-0000-0000-000000000001';
  select coalesce(sum(remaining), 0) into v_lots from public.coin_lots
   where user_id = 'e1000000-0000-0000-0000-000000000001';
  select is_host into v_host from public.host_settings
   where user_id = 'e1000000-0000-0000-0000-000000000001';

  if v_bal <> 0 or v_lots <> 0 then
    raise exception 'FAIL: 有償コインが残っている(残高% / ロット%)', v_bal, v_lots;
  end if;
  if v_earned <> 6000 then
    raise exception
      'FAIL: **報酬コインを消してしまった(%)。** これが「人質」の指摘そのもの', v_earned;
  end if;
  if v_host is not false then
    raise exception 'FAIL: 掲載が止まっていない(検索やランキングに残る)';
  end if;
  if (v->>'payout_deadline') is null then
    raise exception 'FAIL: 換金の期限を返していない';
  end if;

  -- 何が消えたかの記録が残っているか
  if not exists (select 1 from public.account_withdrawals
                  where user_id = 'e1000000-0000-0000-0000-000000000001'
                    and expired_paid_coins = 2000 and earned_balance = 6000) then
    raise exception 'FAIL: 退会の記録が残っていない';
  end if;
  raise notice 'OK: 有償2000は消滅 / 報酬6000は残る / 掲載は停止';
end $$;

\echo '--- 投稿等の表示が止まっていること(規約 第10条の2第4項・0092) ---'
-- **条文で「退会後は将来に向かって終了する」と約束した以上、
--   自己紹介・音声・アバターへの参照は落ちていなければならない。**
-- ニックネームとレビューは残す(第10条の2第4項1号の例外)
do $$
declare v_bio text; v_voice text; v_avatar text; v_nick text; v_games text[];
begin
  select bio, voice_path, avatar_path, nickname, favorite_games
    into v_bio, v_voice, v_avatar, v_nick, v_games
  from public.profiles where id = 'e1000000-0000-0000-0000-000000000001';

  if coalesce(v_bio, '') <> '' or v_voice is not null or v_avatar is not null then
    raise exception
      'FAIL: 退会後も投稿物が残っている(bio=% / voice=% / avatar=%)', v_bio, v_voice, v_avatar;
  end if;
  if coalesce(array_length(v_games, 1), 0) <> 0 then
    raise exception 'FAIL: 好きなゲームが残っている(%)', v_games;
  end if;
  -- **ニックネームは消さない。**消すと相手側の取引履歴が読めなくなる
  if coalesce(v_nick, '') = '' then
    raise exception 'FAIL: ニックネームまで消した(相手の履歴が読めなくなる)';
  end if;
  raise notice 'OK: 自己紹介・音声・アバターは参照ごと落ち、名前は残る';
end $$;

\echo '--- 期限を本人に伝えているか ---'
do $$
begin
  if not exists (
    select 1 from public.notifications
     where user_id = 'e1000000-0000-0000-0000-000000000001'
       and title like '%退会%' and body like '%まで申請できます%') then
    raise exception 'FAIL: 換金期限の通知が無い';
  end if;
  raise notice 'OK: 期限を通知に残している';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 二重に退会できないこと ==='
do $$
begin
  perform public.withdraw_account(null);
  raise exception 'FAIL: 二度目の退会が通った';
exception when others then
  if sqlerrm <> 'ALREADY_WITHDRAWN' then raise; end if;
  raise notice 'OK: ALREADY_WITHDRAWN で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. 退会後はサービスを使えないこと ==='
-- 0074 のトリガが通る入口(誘い・予約・メッセージ・募集)を1つで確かめる
do $$
begin
  begin
    insert into public.invites (from_user, to_user, game, when_text, message)
    values ('e1000000-0000-0000-0000-000000000001',
            'e1000000-0000-0000-0000-000000000002', 'テスト', 'いつでも', '');
    raise exception 'FAIL: 退会後に誘いを送れてしまった';
  exception when others then
    if sqlerrm <> 'ACCOUNT_WITHDRAWN' then raise; end if;
  end;

  -- 相手側から見ても止まること(退会した人を誘えない)
  begin
    insert into public.invites (from_user, to_user, game, when_text, message)
    values ('e1000000-0000-0000-0000-000000000002',
            'e1000000-0000-0000-0000-000000000001', 'テスト', 'いつでも', '');
    raise exception 'FAIL: 退会した人を誘えてしまった';
  exception when others then
    if sqlerrm <> 'PARTNER_ACCOUNT_WITHDRAWN' then raise; end if;
  end;
  raise notice 'OK: 双方向で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 退会後90日以内は換金を申請できること(第4項) ==='
-- **ここが通らないと、条文が守れていないことになる**
insert into public.host_bank_accounts
  (user_id, bank_name, bank_code, branch_name, branch_code,
   account_type, account_number, account_holder_kana)
values ('e1000000-0000-0000-0000-000000000001','テスト銀行','0001','本店','001',
        '普通','1234567','タイカイ タロウ')
on conflict (user_id) do nothing;

do $$
declare v_id uuid;
begin
  v_id := public.request_bank_payout(5000);
  if v_id is null then raise exception 'FAIL: 換金を申請できない'; end if;
  raise notice 'OK: 退会後でも換金を申請できる';
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 申請中があるうちは報酬コインを消さないこと ==='
-- 期限を過ぎた状態にしてから走らせる
update public.account_withdrawals
  set payout_deadline = now() - interval '1 day'
  where user_id = 'e1000000-0000-0000-0000-000000000001';

do $$
declare v_n int; v_earned int;
begin
  v_n := public.expire_withdrawn_earned();
  select earned_balance into v_earned from public.coin_wallets
   where user_id = 'e1000000-0000-0000-0000-000000000001';
  if v_n <> 0 then
    raise exception 'FAIL: 申請中なのに消滅させた(%件)', v_n;
  end if;
  if v_earned = 0 then
    raise exception 'FAIL: 申請中の報酬コインまで消えた';
  end if;
  raise notice 'OK: 申請中は消さない(残%枚)', v_earned;
end $$;

-- ------------------------------------------------------------
\echo '=== 8. 期限が過ぎたら申請できず、報酬コインが消えること ==='
-- 申請を振込済みにして、pending を無くす
update public.payouts set status = 'paid', paid_at = now()
  where user_id = 'e1000000-0000-0000-0000-000000000001' and status = 'pending';
-- 最低申請額(5000)以上にしておく。**MIN_PAYOUT_COINS で先に落ちると、
-- 期限の判定を通っていないのに「止まった」と誤読してしまう**
update public.coin_wallets set earned_balance = 5000
  where user_id = 'e1000000-0000-0000-0000-000000000001';

do $$
declare v_n int; v_earned int;
begin
  -- まず新規の申請が通らないこと
  begin
    perform public.request_bank_payout(5000);
    raise exception 'FAIL: 期限を過ぎても換金を申請できてしまった';
  exception when others then
    if sqlerrm <> 'PAYOUT_WINDOW_CLOSED' then raise; end if;
  end;

  v_n := public.expire_withdrawn_earned();
  select earned_balance into v_earned from public.coin_wallets
   where user_id = 'e1000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'FAIL: 消滅の処理が動いていない(%)', v_n; end if;
  if v_earned <> 0 then raise exception 'FAIL: 報酬コインが残っている(%)', v_earned; end if;

  if not exists (select 1 from public.account_withdrawals
                  where user_id = 'e1000000-0000-0000-0000-000000000001'
                    and earned_expired_at is not null) then
    raise exception 'FAIL: 消滅の記録が残っていない';
  end if;

  -- 二度目は何もしないこと
  v_n := public.expire_withdrawn_earned();
  if v_n <> 0 then raise exception 'FAIL: 同じ人を二度処理した(%)', v_n; end if;
  raise notice 'OK: 申請不可 / 消滅 / 記録あり / 二度は処理しない';
end $$;

-- ------------------------------------------------------------
\echo '=== 9. 会計仕訳に、退会で消えた分が出ること ==='
-- **仕訳に出ないと前受金・預り金が過大に残る**(0079のJ16が拾わない note)
insert into auth.users (id) values ('e1000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('e1000000-0000-0000-0000-000000000009','運営') on conflict (id) do nothing;
insert into public.admins (user_id) values ('e1000000-0000-0000-0000-000000000009');
set test.uid = 'e1000000-0000-0000-0000-000000000009';

do $$
declare v_paid bigint; v_earned bigint;
begin
  select 金額円 into v_paid from public.accounting_journal('2000-01-01','2100-01-01')
   where 摘要 like '退会によるコイン消滅%';
  if coalesce(v_paid, 0) <> 2000 then
    raise exception 'FAIL: 退会のコイン消滅が仕訳に出ない(%)', v_paid;
  end if;

  select 金額円 into v_earned from public.accounting_journal('2000-01-01','2100-01-01')
   where 摘要 like '退会から90日経過%';
  if coalesce(v_earned, 0) <= 0 then
    raise exception 'FAIL: 報酬コインの消滅が仕訳に出ない(%)', v_earned;
  end if;
  raise notice 'OK: J22 %円 / J23 %円', v_paid, v_earned;
end $$;

\echo '=== 21: 退会(第6条の2) すべて通過 ==='
