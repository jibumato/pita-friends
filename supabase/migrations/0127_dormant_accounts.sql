-- ============================================================
-- 0127: 長期間ご利用のないアカウント（規約 第6条の4）
--
-- ■ 何が抜けていたか
--   規約 第6条の4 は「最終ログインから2年以上→30日前通知→利用停止/削除。
--   購入コインは消滅するが、**報酬コインの金銭債権は消滅させない**」と
--   約束している。ところが実装は1行も存在しなかった——`0086`(退会後90日)
--   と同じ形で、**条文だけが先に走っていた。**
--
-- ■ 「最終ログイン」はどこから取るか
--   `profiles.last_seen_at` は使えない。0026 の設計で、オンライン表示を
--   オフにした瞬間に **null に戻る**（プライバシー設定であって、ログイン
--   記録ではない）。本番の Supabase Auth が実際に持つ
--   `auth.users.last_sign_in_at`（GoTrue がログインのたびに更新する）を使う。
--   一度もログイン記録が無い場合は `profiles.created_at` に落とす。
--
-- ■ 設計：既存の「最終換金」の仕組みにそのまま乗せる
--   第6条の4第4項は「換金については、第6条の2第4項を準用する」と定めている。
--   実装でも同じ道を通す。`request_bank_payout` の最低申請額の除外判定は
--   既に `withdrawn_at is not null or suspended_at is not null` の1行に
--   集約されている(0100)。ここに `dormant_closed_at is not null` を足すだけで、
--   **最終換金(全額一括・最低額なし)の仕組みをまるごと再利用できる。**
--
--   `withdrawn_at`(退会・本人の意思)や `suspended_at`(第6条・違反による停止)
--   と**同じ列を使い回さない**。理由の異なる3つの停止を1つの列に混ぜると、
--   運営コンソールで「違反により停止」の一覧に、何もしていない休眠者が
--   混ざってしまう。
--
-- ■ 通知→30日待つ→再確認、の流れ
--   `dormant_account_notices` に1人1行。
--     1. 検知した日に通知を送り、実行日(30日後)を記録する
--     2. 実行日になったら**もう一度**最終ログインを見る。通知後にログインが
--        あれば(第6条の4第2項)、行を削除して終わり——措置は取らない
--     3. まだ休眠のままなら、そのときだけ実行する
--   こうすれば「30日以内にログインがあれば措置をしない」を、判定のやり直し
--   だけで満たせる。ログイン済みかどうかのフラグを別に持つ必要がない。
-- ============================================================

alter table public.profiles
  add column if not exists dormant_closed_at timestamptz;

comment on column public.profiles.dormant_closed_at is
  '0127: 規約第6条の4により、長期間未ログインを理由に利用停止/削除した時刻。'
  '**報酬コインの金銭債権は消滅させない**(第6条の4第4項)。'
  'withdrawn_at(退会)・suspended_at(違反による停止)とは別の列にしてある——'
  '理由が異なる停止を1つの列に混ぜると、運営コンソールの一覧が混同する。';

create index if not exists profiles_dormant_closed_at_idx
  on public.profiles (dormant_closed_at) where dormant_closed_at is not null;

-- ------------------------------------------------------------
-- 1. 最終ログインを引く
-- ------------------------------------------------------------
create or replace function public._effective_last_login(p_user_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select u.last_sign_in_at from auth.users u where u.id = p_user_id),
    (select p.created_at from public.profiles p where p.id = p_user_id)
  );
$$;

comment on function public._effective_last_login(uuid) is
  '0127: 最終ログイン時刻。auth.users.last_sign_in_at を使う'
  '(profiles.last_seen_at はオンライン表示のプライバシー設定でnullに戻るため不可)。'
  '記録が無ければ登録日に落とす。';

revoke all on function public._effective_last_login(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. 通知の記録
-- ------------------------------------------------------------
create table if not exists public.dormant_account_notices (
  user_id uuid primary key references auth.users (id) on delete cascade,
  notified_at timestamptz not null default now(),
  execute_at timestamptz not null,
  executed_at timestamptz
);

comment on table public.dormant_account_notices is
  '0127: 長期未ログイン(規約第6条の4)の通知記録。1人1行。'
  'execute_at より前にログインがあれば行ごと削除する(措置を取らない)。'
  'executed_at が付いた行は履歴として残す。';

alter table public.dormant_account_notices enable row level security;

-- 見えるのは本人だけ。運営は _is_admin() 経由の関数で扱う
create policy "dormant_account_notices_select_own"
  on public.dormant_account_notices for select
  to authenticated
  using (user_id = auth.uid());

-- insert/update/delete のポリシーは置かない。**cronの内部関数だけが操作する**

-- ------------------------------------------------------------
-- 3. 検知して通知する(日次cron)
-- ------------------------------------------------------------
create or replace function public.flag_dormant_accounts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_threshold constant interval := interval '2 years';
  c_notice_days constant int := 30;
  v_rec record;
  v_count int := 0;
begin
  for v_rec in
    select p.id
    from public.profiles p
    where p.withdrawn_at is null
      and p.suspended_at is null
      and p.dormant_closed_at is null
      and public._effective_last_login(p.id) < now() - c_threshold
      and not exists (
        select 1 from public.dormant_account_notices n
        where n.user_id = p.id and n.executed_at is null
      )
  loop
    insert into public.dormant_account_notices (user_id, notified_at, execute_at)
    values (v_rec.id, now(), now() + make_interval(days => c_notice_days))
    on conflict (user_id) do nothing;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.id, 'system',
      '長期間ご利用が無いため、まもなく利用を停止します',
      '最終のご利用から2年以上が経過しました。このまま' || c_notice_days
        || '日間ログインが無い場合、規約第6条の4に基づき、利用を停止いたします。'
        || 'ログインいただければ、この措置は取りません。'
        || '報酬コインをお持ちの場合、停止後も換金の権利は消滅しません。');

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.flag_dormant_accounts() is
  '0127: 最終ログインから2年以上のアカウントに、30日前通知を送る(規約第6条の4第1・2項)。'
  '日次cron(flag-dormant-accounts)から呼ぶ。運営が手動で呼ぶ経路は用意しない'
  '(対象の選定に個別判断が要らないため、自動処理で十分)。';

revoke all on function public.flag_dormant_accounts() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. 実行する(日次cron。通知の30日後)
-- ------------------------------------------------------------
create or replace function public.execute_dormant_accounts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_final_deadline constant interval := interval '90 days';
  v_rec record;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_blocking int;
  v_count int := 0;
begin
  for v_rec in
    select n.user_id, n.notified_at
    from public.dormant_account_notices n
    where n.executed_at is null
      and n.execute_at <= now()
    for update of n skip locked
  loop
    -- 第6条の4第2項: **通知後にログインがあれば、措置を取らない。**
    -- 判定をやり直すだけで満たせる(別にフラグを持たない)
    if public._effective_last_login(v_rec.user_id) > v_rec.notified_at then
      delete from public.dormant_account_notices where user_id = v_rec.user_id;
      continue;
    end if;

    -- 成立済みの予約を残したまま止めない。相手のあることなので、
    -- 片方が消えると相手が救済されない(0086と同じ考え方)。
    -- **実行を見送るだけ**——次の日次実行で再判定する
    select count(*) into v_blocking
    from public.bookings b
    where (b.guest_id = v_rec.user_id or b.host_id = v_rec.user_id)
      and b.status in ('requested', 'confirmed');
    if coalesce(v_blocking, 0) > 0 then
      continue;
    end if;

    select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
      into v_paid, v_bonus, v_earned
    from public.coin_wallets where user_id = v_rec.user_id for update;

    -- 第6条の4第3項: 購入コインは消滅する。
    -- ⚠️ **通常はここより先に第7条5項の6か月失効で既に0になっている。**
    -- 2年ログインが無い間、期限切れの日次cron(expire-coins)は動き続けるため。
    -- ここでの没収は、その取りこぼしに対する保険。
    if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
      update public.coin_lots set remaining = 0
        where user_id = v_rec.user_id and remaining > 0;
      update public.coin_wallets set balance = 0, bonus_balance = 0
        where user_id = v_rec.user_id;
      if v_paid > 0 then
        insert into public.coin_transactions (user_id, amount, type, note)
          values (v_rec.user_id, -v_paid, 'expire', 'dormant_paid');
      end if;
      if v_bonus > 0 then
        insert into public.coin_transactions (user_id, amount, type, note)
          values (v_rec.user_id, -v_bonus, 'expire', 'dormant_bonus');
      end if;
    end if;

    -- 第6条の4第4項: **報酬コインの金銭債権は消滅させない。**
    -- 換金は第6条の2第4項を準用する(最低額なし・全額一括)。
    -- payout_claim_deadline は表示用(request_bank_payoutの実行そのものは
    -- 期限で縛らない。0098のsuspended_atと同じ扱い)。
    update public.profiles
      set dormant_closed_at = now(),
          payout_claim_deadline = case when v_earned > 0 then now() + c_final_deadline else null end
      where id = v_rec.user_id;

    -- 掲載を止める。検索・ランキング・「いま遊べる」は is_host を見ている
    update public.host_settings set is_host = false where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system',
      '長期間ご利用が無いため、利用を停止しました',
      case when v_earned > 0
        then '規約第6条の4に基づく措置です。報酬コイン' || v_earned || '枚は消滅せず、'
               || '最低申請額の制限なく全額を一括で申請できます。'
        else '規約第6条の4に基づく措置です。' end);

    update public.dormant_account_notices
      set executed_at = now()
      where user_id = v_rec.user_id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.execute_dormant_accounts() is
  '0127: 通知から30日後、まだ休眠のままなら利用を停止する(規約第6条の4)。'
  '成立済みの予約がある間は見送る(次回に再判定)。'
  '購入コインは消滅させるが、報酬コインの金銭債権は消滅させない。';

revoke all on function public.execute_dormant_accounts() from public, anon, authenticated;

select cron.schedule('flag-dormant-accounts', '0 4 * * *',
  $$select public.flag_dormant_accounts()$$);
select cron.schedule('execute-dormant-accounts', '20 4 * * *',
  $$select public.execute_dormant_accounts()$$);

-- ------------------------------------------------------------
-- 5. request_bank_payout: 長期未ログインによる停止も最終換金として扱う
--
-- ⚠️ 本体は適用済みのDBから取り出したもの。差分は最終換金の判定に
--    dormant_closed_at を足した1行だけ。
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins integer)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 換金事務手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
  v_final boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 0098/0100: **退会または利用停止の後は「最終換金」として扱う。**
  -- 最低申請額を外す代わりに、換金可能な全額を1回で出してもらう
  -- (規約 第6条の2第4項・第6条の3第2項)。
  -- 0127: 長期未ログインによる停止(第6条の4)も最終換金として扱う。
  -- 準用元(第6条の2第4項)と同じく、最低申請額を外し全額一括にする。
  select (p.withdrawn_at is not null or p.suspended_at is not null
          or p.dormant_closed_at is not null)
    into v_final from public.profiles p where p.id = v_uid;
  v_final := coalesce(v_final, false);

  if p_coins is null or p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;
  if not v_final and p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;
  -- 手数料以下では振込が成り立たない(手取りが0以下になる)
  if p_coins <= c_fee then
    raise exception 'BELOW_PAYOUT_FEE';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';

  -- 0077: 係争中のチャージバックに紐づく予約の報酬も保留。
  -- **ホスト全体を止めるのではなく、紐づく額だけを差し引く。**
  v_dispute_hold := public._dispute_payout_hold(v_uid);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、**どちらの保留かを分けて伝える**。
    -- 利用者から見ると原因も待つべき期間も違う(ギフトは7日で明ける／
    -- 係争は決着するまで分からない)ので、同じ文言にしてはいけない。
    if p_coins <= coalesce(v_balance, 0) then
      if v_dispute_hold > 0 and p_coins > coalesce(v_balance, 0) - v_dispute_hold then
        raise exception 'DISPUTE_ON_HOLD';
      end if;
      if v_gift_hold > 0 then
        raise exception 'GIFT_ON_HOLD';
      end if;
    end if;
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  -- 0100: **最終換金は分割できない。** 額を全額に縛ると、1回目で残高が0に
  -- なるので2回目は自然に起きない。回数を数える必要がない。
  -- 保留がある場合に「換金可能な全額」で足りるのは、保留が明けてからの
  -- 申請は分割ではなく保留の仕組みが働いた結果だから。
  if v_final and p_coins <> v_available then
    raise exception 'FINAL_PAYOUT_MUST_BE_WHOLE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(integer) is
  '換金申請。退会(withdrawn_at)・利用停止(suspended_at)・長期未ログインによる停止'
  '(dormant_closed_at・0127)の後は最終換金として扱い、最低申請額を外す代わりに'
  '**換金可能な全額を一括**でのみ申請できる(規約 第6条の2第4項・第6条の3第2項・'
  '第6条の4第4項)。手数料は最終換金でも控除する。';

revoke all on function public.request_bank_payout(integer) from public, anon;
grant execute on function public.request_bank_payout(integer) to authenticated;

-- ------------------------------------------------------------
-- 6. withdraw_account: 期限後は「消滅する」と読める通知文を訂正
--
-- 0107(2026-08-05)で退会後90日の消滅そのものは撤去したが、退会**直後**に
-- 送るこの通知の文面は直し忘れていた。「期限を過ぎると消滅します」は
-- 現在の実装(消滅しない)と食い違ったまま残っていた——0086→0107と同じ
-- 種類の見落とし。本体は適用済みのDBから取り出したもので、差分は
-- 通知本文の1行だけ。
-- ------------------------------------------------------------
create or replace function public.withdraw_account(p_reason text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  if exists (select 1 from public.profiles p
              where p.id = v_uid and p.withdrawn_at is not null) then
    raise exception 'ALREADY_WITHDRAWN';
  end if;

  -- 第6条の2第2項。**成立済みの予約を残したまま辞めさせない。**
  -- 相手のあることなので、片方が黙って消えると相手が救済されない
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');
  if coalesce(v_blocking, 0) > 0 then
    raise exception 'HAS_ACTIVE_BOOKINGS';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = v_uid for update;

  -- ----------------------------------------------------------
  -- コインを消滅させる(第7条3項・第6条の2第3項)
  --
  -- **報酬コイン(earned_balance)には手を付けない。** 換金の対象であり、
  -- ここで消すと弁護士の指摘した「人質」そのものになる
  -- ----------------------------------------------------------
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots
      set remaining = 0
      where user_id = v_uid and remaining > 0;
    update public.coin_wallets
      set balance = 0, bonus_balance = 0
      where user_id = v_uid;
    if coalesce(v_paid, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_paid, 'expire', 'withdraw_paid');
    end if;
    if coalesce(v_bonus, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_bonus, 'expire', 'withdraw_bonus');
    end if;
  end if;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**ので、
  -- ここを落とすことで退会者が誰の目にも触れなくなる
  update public.host_settings set is_host = false where user_id = v_uid;

  -- 0092: 規約 第10条の2第4項。**投稿等の利用許諾は退会で将来に向かって終わる。**
  -- 条文でそう約束した以上、表示に使う投稿物への参照はここで落とす。
  -- 落とさないものは第10条の2第4項1号・2号の例外(レビューと、
  -- マナースコアの算定根拠、法令に基づく記録)だけ。
  --
  -- ⚠️ ストレージ上の実体(音声・アバターのファイル)はここでは消せない。
  --    参照を切ったうえで、運営が avatar-delete / voice-delete を回す。
  --    **参照だけ切って安心しないこと。**
  update public.profiles
    set withdrawn_at = now(),
        presence_status = 'busy',
        bio = '',
        voice_path = null,
        voice_seconds = null,
        avatar_path = null,
        favorite_games = '{}'
    where id = v_uid;

  insert into public.account_withdrawals
    (user_id, expired_paid_coins, expired_bonus_coins, earned_balance, payout_deadline, reason)
  values (v_uid, coalesce(v_paid, 0), coalesce(v_bonus, 0), coalesce(v_earned, 0),
          v_deadline, p_reason);

  -- 期限を本人に残す。画面を閉じても分かるように通知にも書く
  insert into public.notifications (user_id, type, title, body)
  values (v_uid, 'system', '退会の手続が完了しました',
    case when coalesce(v_earned, 0) > 0
      then '報酬コイン' || v_earned || '枚の換金は、'
             || to_char(v_deadline, 'YYYY年MM月DD日') || 'まで申請できます。'
             -- 0127: 「期限を過ぎると消滅します」は0107(2026-08-05)で誤りになった
             -- ままの文言だった。報酬コインの金銭債権はこの期限を過ぎても消えない
             -- (第6条の2第4項)。アプリからの申請受付が終わるだけで、それ以降は
             -- 個別の申出で換金できる、と正確に書く。**「まで申請できます」の
             -- 文言はテスト(21_account_withdrawal.sql)が固定して見ているので、
             -- そのまま残し、訂正は後ろに続ける形にする**
             || '期限を過ぎるとアプリからの申請受付は終了しますが、コインは消滅しません。'
             || 'お問い合わせいただければ個別に換金いたします。'
      else 'ご利用ありがとうございました。' end);

  return jsonb_build_object(
    'withdrawn_at', now(),
    'expired_paid', coalesce(v_paid, 0),
    'expired_bonus', coalesce(v_bonus, 0),
    'earned_balance', coalesce(v_earned, 0),
    'payout_deadline', v_deadline
  );
end;
$$;

comment on function public.withdraw_account(text) is
  '退会(規約 第6条の2)。報酬コインは消滅させない。90日間はアプリから換金申請できる'
  '(最低申請額なし・全額一括)。期限後の文言は0127で訂正——'
  '「消滅します」は0107で事実と食い違ったまま残っていた誤り。';

revoke all on function public.withdraw_account(text) from public, anon;
grant execute on function public.withdraw_account(text) to authenticated;
