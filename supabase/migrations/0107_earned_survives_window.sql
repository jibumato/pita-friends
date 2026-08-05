-- ============================================================
-- 0107: 退会後90日で報酬コインを「消滅させる」のをやめる
--
-- 2026-08-05の弁護士回答（論点A-1）による。**今回の回答で最も重い指摘。**
--
--   「報酬コインは、購入コインと法的性質が根本的に異なります。これは役務提供の
--    対価としてユーザーが既に取得した金銭債権……の計数的表示です。90日の経過に
--    より債権そのものを消滅させる条項は、法定の消滅時効（民法166条1項・5年）を
--    約款で90日に短縮するに等しく、消費者契約法10条により無効と判断される
--    リスクが高い類型です。」
--
-- 直すのは条文だけではない。`expire_withdrawn_earned()` が cron で毎日走り、
-- **実際に earned_balance = 0 にしていた**（0086）。条文を直しても実装が
-- 消していれば、約束と動作が食い違う。
--
-- ■ 新しい建付け（弁護士が示した方向。論点F(b)と同じ整理に揃える）
--
--   債権は消滅しない。閉じるのは**セルフサービスの換金申請の窓口だけ**。
--   期間の経過後は、運営の窓口への個別の申出により換金する。
--
--   | | 従前 | 0107 |
--   |---|---|---|
--   | 90日経過時 | 残高を0にする | **窓口を閉じるだけ。残高は残る** |
--   | 経過後の換金 | 不可能（残高が無い） | 個別の申出 → 運営コンソールから起票 |
--   | 通知の文面 | 「消滅しました」 | 「受付を終了しました。**残高は残っています**」 |
--
-- ■ 期限の判定は増やさない
--   0086 が `payouts` の INSERT トリガー（`_payouts_check_withdrawal`）で
--   止めている。**「条件の置き場所が1か所で済む」というのが 0086 の設計判断**
--   なので、request_bank_payout 側に同じ判定を足さない。
--   運営の起票だけを通すために、0044 の ledger_override と同じ形の
--   セッション変数を1つ用意する。
--
-- ■ 会計への影響
--   J23（退会から90日経過した報酬コインの消滅）は note='withdraw_earned_expired'
--   を拾うが、**この note は今後発生しない**。購入コインの失効（退会時・0092）は
--   別の経路なので J22 はそのまま。預り金（ホスト報酬）が消えずに残るのが
--   正しい姿になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 窓口を閉じた時刻を持つ
--
-- earned_expired_at（消滅した時刻）は**残すが、もう書かない**。
-- 0044 の追記専用台帳と同じ考え方で、過去の記録を壊さないため。
-- ------------------------------------------------------------
alter table public.account_withdrawals
  add column if not exists payout_window_closed_at timestamptz;

comment on column public.account_withdrawals.payout_window_closed_at is
  'セルフサービスの換金申請の受付を終了した時刻(0107)。**報酬コインは消えていない。**個別の申出があれば admin_payout_on_request() で換金する。';

comment on column public.account_withdrawals.earned_expired_at is
  '【廃止】退会後90日で報酬コインを消滅させていた時刻(0086)。0107で消滅をやめたため、今後は書き込まれない。過去の記録のために列は残す。';

-- ------------------------------------------------------------
-- 2. 消す処理を、窓口を閉じる処理に置き換える
-- ------------------------------------------------------------
create or replace function public.close_withdrawn_payout_window()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_count int := 0;
begin
  for v_rec in
    select aw.user_id, coalesce(w.earned_balance, 0) as earned
    from public.account_withdrawals aw
    join public.coin_wallets w on w.user_id = aw.user_id
    where aw.payout_window_closed_at is null
      and aw.payout_deadline < now()
      and coalesce(w.earned_balance, 0) > 0
      and not exists (
        select 1 from public.payouts p
        where p.user_id = aw.user_id and p.status = 'pending')
    for update of aw skip locked
  loop
    -- ⚠️ **残高には触れない。** ここで earned_balance を動かすと、
    -- 0107 が直そうとしたものをそのまま作り直すことになる。
    update public.account_withdrawals
      set payout_window_closed_at = now() where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system', '換金申請の受付期間が終了しました',
      '退会から90日が経過したため、アプリからの換金申請の受付を終了しました。'
      || 'なお報酬コイン' || v_rec.earned || '枚は消えていません。'
      || 'お問い合わせいただければ、個別に換金の手続を行います。');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.close_withdrawn_payout_window() is
  '退会から90日を過ぎたアカウントの、セルフサービスの換金申請の受付を終了する(規約 第6条の2第4項・0107)。**報酬コインは消さない。**個別の申出は admin_payout_on_request() で処理する。';

revoke all on function public.close_withdrawn_payout_window() from public, anon;

-- cron から外してから落とす。順序を逆にするとジョブが毎日失敗し続ける。
select cron.unschedule('expire-withdrawn-earned')
  where exists (select 1 from cron.job where jobname = 'expire-withdrawn-earned');

drop function if exists public.expire_withdrawn_earned();

select cron.schedule('close-withdrawn-payout-window', '31 3 * * *',
  $$select public.close_withdrawn_payout_window()$$);

-- ------------------------------------------------------------
-- 3. 期限のトリガーに、運営の起票だけを通す抜け道を作る
--
-- 0086 の `_payouts_check_withdrawal` は payouts への INSERT を
-- 一律に止める。**残高を残す以上、運営が個別の申出を処理する経路が要る。**
--
-- 0044 の ledger_override と同じ形にした:
--   ・セッション変数（set local）でのみ開く
--   ・開けられるのは SECURITY DEFINER の運営関数の中だけ
--   ・admin_actions に必ず記録が残る（呼び出し側で perform している）
-- ------------------------------------------------------------
create or replace function public._payouts_check_withdrawal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deadline timestamptz;
begin
  -- 0107: 運営が個別の申出を処理するときだけ通す。
  -- **利用者からは開けられない**（set local を挟めるのは運営関数の中だけ）。
  if coalesce(current_setting('app.payout_window_override', true), 'off') = 'on' then
    return new;
  end if;

  -- **期限は account_withdrawals.payout_deadline が唯一の権威。**
  select aw.payout_deadline into v_deadline
  from public.account_withdrawals aw where aw.user_id = new.user_id;

  if v_deadline is not null and now() > v_deadline then
    raise exception 'PAYOUT_WINDOW_CLOSED';
  end if;
  return new;
end;
$$;

comment on function public._payouts_check_withdrawal() is
  '退会後90日(payout_deadline)を過ぎた換金の起票を止める(規約 第6条の2第4項・0086)。0107で、運営の個別処理(app.payout_window_override)だけ通すようにした。';

revoke all on function public._payouts_check_withdrawal() from public, anon;

-- ------------------------------------------------------------
-- 4. 運営コンソール: 窓口が閉じた後の個別の申出を処理する
-- ------------------------------------------------------------
create or replace function public.admin_closed_window_balances(p_limit int default 200)
returns table (
  user_id uuid,
  nickname text,
  withdrawn_at timestamptz,
  payout_deadline timestamptz,
  window_closed_at timestamptz,
  earned_balance int,
  has_bank_account boolean,
  is_verified boolean
)
language sql
security definer
set search_path = public
as $$
  select aw.user_id,
         p.nickname,
         p.withdrawn_at,
         aw.payout_deadline,
         aw.payout_window_closed_at,
         coalesce(w.earned_balance, 0)::int,
         (b.user_id is not null),
         coalesce(t.is_verified, false)
  from public.account_withdrawals aw
  join public.coin_wallets w on w.user_id = aw.user_id
  left join public.profiles p on p.id = aw.user_id
  left join public.host_bank_accounts b on b.user_id = aw.user_id
  left join public.profile_trust_stats t on t.user_id = aw.user_id
  where public._is_admin()
    and aw.payout_deadline < now()
    and coalesce(w.earned_balance, 0) > 0
  order by coalesce(w.earned_balance, 0) desc
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$$;

comment on function public.admin_closed_window_balances(int) is
  '換金申請の受付が終了した後も残っている報酬コインの一覧(0107)。**残高は消していない**ので、個別の申出があればここから admin_payout_on_request() で起票する。';

revoke all on function public.admin_closed_window_balances(int) from public, anon;
grant execute on function public.admin_closed_window_balances(int) to authenticated;

create or replace function public.admin_payout_on_request(
  p_user_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = p_user_id;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets
    where user_id = p_user_id for update;

  -- 保留は運営の起票でも外さない。**保留の理由は窓口の開閉と無関係**で、
  -- ギフトの様子見(7日)も係争中の凍結も、そのまま効いている必要がある。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = p_user_id and created_at > now() - interval '7 days';
  v_dispute_hold := public._dispute_payout_hold(p_user_id);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if v_available <= c_fee then
    -- 手取りが0以下。**勝手に手数料を引いて振り込まない**
    -- (サービス終了の手順書と同じ考え方。本人に確認してから決める)。
    raise exception 'BELOW_PAYOUT_FEE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - v_available
    where user_id = p_user_id;

  -- 期限を過ぎているので、0086 のトリガーをここだけ開ける
  set local app.payout_window_override = 'on';

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    p_user_id, v_available, v_available - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, -v_available, 'payout', 'admin_payout_on_request:' || v_payout_id);

  perform public._log_admin_action('payout_on_request', v_payout_id,
    v_available || 'コイン / ' || p_reason);

  insert into public.notifications (user_id, type, title, body)
  values (p_user_id, 'system', '換金の手続を行いました',
    'お申し出により、報酬コイン' || v_available || '枚の換金を受け付けました。'
    || '振込手数料を含む事務手数料' || c_fee || '円を差し引いた'
    || (v_available - c_fee) || '円をお振込みします。');

  return v_payout_id;
end;
$$;

comment on function public.admin_payout_on_request(uuid, text) is
  '換金申請の受付が終了した後の個別の申出を、運営が起票する(規約 第6条の2第4項・0107)。**換金可能な全額**を1回で出す(最終換金と同じ扱い)。ギフト・係争の保留はそのまま効く。';

revoke all on function public.admin_payout_on_request(uuid, text) from public, anon;
grant execute on function public.admin_payout_on_request(uuid, text) to authenticated;
