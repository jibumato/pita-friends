-- ============================================================
-- 0086: 退会(G6)
--
-- 規約 第6条の2(2026-07-31 新設):
--   1. ユーザーは、いつでも当社所定の方法により退会することができる
--   2. **成立済みの予約は、履行またはキャンセルを完了させてから**退会する
--   3. 退会の時点で保有するコインは消滅し、返金しない。
--      **当社は、退会の手続を行う画面において、消滅するコインの数を
--      事前に表示する**
--   4. **退会後も、退会日から90日間に限り、報酬コインの換金を申請できる。**
--      本人確認および振込先口座の状態は退会時のものによる。
--      当該期間の経過後、報酬コインは消滅する
--   5. 退会後も、法令に基づく記録の保存その他必要な範囲で記録を保持する
--
-- ■ なぜこれが要るか
--   退会条項そのものが規約に無かった。弁護士(総評3・論点3(c))の指摘:
--   「**換金できない残高を人質に離脱を妨げる外形は、優越的地位の濫用の
--   評価において最も分の悪い事実になる**」。
--
--   したがってこの実装の核心は「退会できること」ではなく、
--   **「辞めた後も、稼いだ分を回収できること」**にある。
--
-- ■ 退会 ≠ アカウント削除
--   90日間は換金を申請できなければならないので、**ログインは残す。**
--   削除の請求は従来どおり account_requests で別に受ける。
--
-- ■ 消すもの / 残すもの
--   消す: 有償・無償コイン(第7条3項により返金しない)、掲載
--   残す: 報酬コイン(90日)、取引の記録、プロフィール(記録保持のため)
-- ============================================================

-- ------------------------------------------------------------
-- 1. 退会の状態
-- ------------------------------------------------------------
alter table public.profiles
  add column if not exists withdrawn_at timestamptz;

create index if not exists profiles_withdrawn_idx
  on public.profiles (withdrawn_at) where withdrawn_at is not null;

comment on column public.profiles.withdrawn_at is
  '規約第6条の2の退会日時。null は在籍中。退会後90日は換金のみ可能。';

-- 退会の記録。**あとから「何が消えたか」を説明できるようにする**
create table if not exists public.account_withdrawals (
  user_id uuid primary key references auth.users (id) on delete cascade,
  withdrawn_at timestamptz not null default now(),
  -- 退会時に消滅させたコイン
  expired_paid_coins int not null default 0,
  expired_bonus_coins int not null default 0,
  -- 退会時に残した報酬コインと、換金できる期限
  earned_balance int not null default 0,
  payout_deadline timestamptz not null,
  -- 期限到来で報酬コインを消滅させた日時
  earned_expired_at timestamptz,
  reason text
);

comment on table public.account_withdrawals is
  '規約第6条の2の退会記録。消滅させたコインの数と、換金できる期限(退会日+90日)。';

alter table public.account_withdrawals enable row level security;

create policy "account_withdrawals_select_own"
  on public.account_withdrawals for select
  to authenticated
  using (user_id = auth.uid());

create policy "account_withdrawals_select_admin"
  on public.account_withdrawals for select
  to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- ------------------------------------------------------------
-- 1-b. 通知の種別に 'system' を足す
--
-- 退会の完了と換金期限の到来は、既存のどの種別にも当てはまらない。
-- **既存の種別に無理に寄せると、通知一覧の見出しが実態と食い違う。**
-- ------------------------------------------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed', 'booking_requested',
    'booking_approved', 'gift_received', 'booking_extended',
    'board_cancelled', 'integrity_alert', 'booking_no_show',
    'host_slots_opened', 'system'));

-- ------------------------------------------------------------
-- 2. 退会できるか / 何が消えるか(**画面に出すための材料**)
--
-- 規約第6条の2第3項は「消滅するコインの数を事前に表示する」と
-- **約束している。** 表示できなければ条文違反になるので、
-- 数を返すのは実装の一部であって付け足しではない。
-- ------------------------------------------------------------
create or replace function public.withdrawal_preview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_verified boolean;
  v_has_bank boolean;
  v_withdrawn timestamptz;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  select p.withdrawn_at into v_withdrawn from public.profiles p where p.id = v_uid;

  -- 履行もキャンセルも済んでいない予約(第6条の2第2項)
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');

  select coalesce(w.balance, 0), coalesce(w.bonus_balance, 0), coalesce(w.earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets w where w.user_id = v_uid;

  select coalesce(s.is_verified, false) into v_verified
  from public.profile_trust_stats s where s.user_id = v_uid;

  select exists (select 1 from public.host_bank_accounts a where a.user_id = v_uid)
    into v_has_bank;

  return jsonb_build_object(
    'withdrawn_at', v_withdrawn,
    'blocking_bookings', coalesce(v_blocking, 0),
    'can_withdraw', v_withdrawn is null and coalesce(v_blocking, 0) = 0,
    -- 消滅するコイン(第7条3項により返金しない)
    'expiring_paid', coalesce(v_paid, 0),
    'expiring_bonus', coalesce(v_bonus, 0),
    -- 退会後も90日間は換金できる報酬コイン
    'earned_balance', coalesce(v_earned, 0),
    'payout_days', 90,
    'payout_deadline', coalesce(v_withdrawn, now()) + interval '90 days',
    -- 換金の条件が退会時に揃っているか。**退会後は本人確認をやり直せない**
    'verified', coalesce(v_verified, false),
    'has_bank_account', coalesce(v_has_bank, false)
  );
end;
$$;

comment on function public.withdrawal_preview() is
  '退会の画面に出す材料。消滅するコインの数と、退会後に換金できる期限(規約第6条の2第3項・第4項)。';

revoke all on function public.withdrawal_preview() from public, anon;
grant execute on function public.withdrawal_preview() to authenticated;

-- ------------------------------------------------------------
-- 3. 退会の実行
-- ------------------------------------------------------------
create or replace function public.withdraw_account(p_reason text default null)
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
  update public.profiles
    set withdrawn_at = now(), presence_status = 'busy'
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
             || '期限を過ぎると消滅します。'
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
  '規約第6条の2の退会。有償・無償コインを消滅させ、報酬コインは90日間だけ換金できる状態で残す。';

revoke all on function public.withdraw_account(text) from public, anon;
grant execute on function public.withdraw_account(text) to authenticated;

-- ------------------------------------------------------------
-- 4. 退会したアカウントを、サービスから締め出す
--
-- 0074 が既にメッセージ・誘い・予約・募集の4経路にトリガを張っており、
-- そのすべてが `_require_monitoring_consent` を通る。
-- **同じ入口に退会の判定を足すのが、漏れが最も少ない。**
-- トリガを5本作り直すより、通る場所を1つにしておくほうが安全。
-- ------------------------------------------------------------
create or replace function public._is_withdrawn(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = p_user and p.withdrawn_at is not null)
$$;

revoke all on function public._is_withdrawn(uuid) from public, anon;

create or replace function public._require_monitoring_consent(p_self uuid, p_other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 0086: 退会したアカウントは、みまもり同意の有無以前に利用できない
  if public._is_withdrawn(p_self) then
    raise exception 'ACCOUNT_WITHDRAWN';
  end if;
  if public._is_withdrawn(p_other) then
    raise exception 'PARTNER_ACCOUNT_WITHDRAWN';
  end if;

  if public._monitoring_consent_revoked(p_self) then
    raise exception 'MONITORING_CONSENT_REVOKED';
  end if;
  if public._monitoring_consent_revoked(p_other) then
    raise exception 'PARTNER_MONITORING_CONSENT_REVOKED';
  end if;
end;
$$;

comment on function public._require_monitoring_consent(uuid, uuid) is
  '利用できる状態かをまとめて確かめる。①退会していないこと(0086・第6条の2)②みまもり同意が撤回されていないこと(0074・Q19)。メッセージは双方の通信なので相手側も見る。';

revoke all on function public._require_monitoring_consent(uuid, uuid) from public, anon;

-- ------------------------------------------------------------
-- 5. 換金は退会後90日まで(第6条の2第4項)
--
-- request_bank_payout 本体は触らない。**入口の payouts に条件を張る**
-- ほうが、条件の置き場所が1か所で済み、将来の経路追加にも効く。
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
  -- **期限は account_withdrawals.payout_deadline が唯一の権威。**
  -- profiles.withdrawn_at から都度計算すると、記録側と判定側で
  -- 二重の真実になり、片方だけ直したときに食い違う
  select aw.payout_deadline into v_deadline
  from public.account_withdrawals aw where aw.user_id = new.user_id;

  if v_deadline is not null and now() > v_deadline then
    raise exception 'PAYOUT_WINDOW_CLOSED';
  end if;
  return new;
end;
$$;

revoke all on function public._payouts_check_withdrawal() from public, anon;

drop trigger if exists payouts_check_withdrawal on public.payouts;
create trigger payouts_check_withdrawal
  before insert on public.payouts
  for each row execute function public._payouts_check_withdrawal();

-- ------------------------------------------------------------
-- 6. 90日を過ぎた報酬コインを消滅させる(第6条の2第4項の後段)
--
-- **申請中(pending)の換金があるうちは消さない。** 申請したのに
-- 振込前に消えるのは、条文のどこにも書いていない。
-- ------------------------------------------------------------
create or replace function public.expire_withdrawn_earned()
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
    where aw.earned_expired_at is null
      and aw.payout_deadline < now()
      and coalesce(w.earned_balance, 0) > 0
      and not exists (
        select 1 from public.payouts p
        where p.user_id = aw.user_id and p.status = 'pending')
    for update of aw skip locked
  loop
    update public.coin_wallets set earned_balance = 0 where user_id = v_rec.user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (v_rec.user_id, -v_rec.earned, 'expire', 'withdraw_earned_expired');
    update public.account_withdrawals
      set earned_expired_at = now() where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system', '報酬コインの換金期限が過ぎました',
      '退会から90日が経過したため、報酬コイン' || v_rec.earned || '枚は消滅しました。');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.expire_withdrawn_earned() is
  '退会から90日を過ぎた報酬コインを消滅させる(規約第6条の2第4項)。申請中の換金があるうちは消さない。';

revoke all on function public.expire_withdrawn_earned() from public, anon;

select cron.schedule('expire-withdrawn-earned', '31 3 * * *',
  $$select public.expire_withdrawn_earned()$$);

-- ------------------------------------------------------------
-- 7. 会計仕訳: 退会で消滅したコイン
--
-- **J16 は expire_coins() が付ける note='lot:...' しか拾わない。**
-- 退会による消滅は別の note なので、足さないと前受金が過大に残る
-- (0085 の J18 と同じ形の取りこぼし)。
-- ------------------------------------------------------------
-- accounting_journal は 0085 で J18〜J21 まで足してある。
-- ここでは退会分(J22)を足すために作り直す。
-- ------------------------------------------------------------
create or replace function public.accounting_journal(p_from date, p_to date)
returns table (
  日付 date,
  区分 text,
  借方科目 text,
  借方補助 text,
  貸方科目 text,
  貸方補助 text,
  金額円 bigint,
  税区分 text,
  摘要 text,
  伝票id text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return query

  -- ------------------------------------------------------------
  -- J1 コイン購入(コイン代金)
  --   Stripe の入金は数日後なので、いったん未収入金で受ける。
  --   実際の着金と決済手数料は Stripe の明細から別途起票する
  --   (ここでは出せない。DB に Stripe の入金データが無いため)。
  -- ------------------------------------------------------------
  select cp.created_at::date, 'コイン購入'::text,
         '未収入金'::text, 'Stripe'::text,
         '前受金'::text, 'コイン'::text,
         cp.price_yen::bigint, '対象外'::text,
         ('コイン購入 ' || coalesce(cp.pack_id, '-') || ' ' || cp.coins_credited || 'コイン')::text,
         cp.id::text
  from public.coin_purchases cp
  where cp.price_yen > 0
    and cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J2 あんしんサポート料(購入時に売上計上・税理士 §1-4)
  -- ------------------------------------------------------------
  select cp.created_at::date, 'コイン購入'::text,
         '未収入金'::text, 'Stripe'::text,
         '売上高'::text, 'あんしんサポート料'::text,
         cp.safety_fee_yen::bigint, '課対売上込10%'::text,
         ('あんしんサポート料 ' || coalesce(cp.pack_id, '-'))::text,
         cp.id::text
  from public.coin_purchases cp
  where coalesce(cp.safety_fee_yen, 0) > 0
    and cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J4 予約成立(有償コイン分) — 前受金がエスクローへ移る
  --   coin_lot_consumptions から引く。bookings.paid_coins は
  --   **延長で積み上がる累計**なので、1件の予約に複数回の消費が
  --   ありうる。消費記録なら1回ずつ正確に取れる。
  -- ------------------------------------------------------------
  select c.created_at::date, '予約成立'::text,
         '前受金'::text, 'コイン'::text,
         '前受金'::text, '予約エスクロー'::text,
         sum(c.coins)::bigint, '対象外'::text,
         ('予約 ' || left(c.booking_id::text, 8) || ' 有償コイン充当')::text,
         c.booking_id::text
  from public.coin_lot_consumptions c
  where c.booking_id is not null and c.kind = 'paid'
    and c.created_at >= p_from and c.created_at < (p_to + 1)
  group by c.created_at::date, c.booking_id

  union all

  -- ------------------------------------------------------------
  -- J5 予約成立(無償コイン分) — ★科目は税理士へ確認中
  --   無償コインには前受金を立てていない(現金を受け取っていない)。
  --   それでもピタメイトへの支払は発生するので、**消費した時点で
  --   費用**にしないと、エスクローの貸方に相手科目が無くなる。
  -- ------------------------------------------------------------
  select c.created_at::date, '予約成立'::text,
         '販売促進費'::text, '無償コイン'::text,
         '前受金'::text, '予約エスクロー'::text,
         sum(c.coins)::bigint, '対象外'::text,
         ('予約 ' || left(c.booking_id::text, 8) || ' 無償コイン充当')::text,
         c.booking_id::text
  from public.coin_lot_consumptions c
  where c.booking_id is not null and c.kind = 'bonus'
    and c.created_at >= p_from and c.created_at < (p_to + 1)
  group by c.created_at::date, c.booking_id

  union all

  -- ------------------------------------------------------------
  -- J6 返金(有償コイン分) — キャンセル・辞退・期限切れ・保留解除
  --   返す枚数の内訳は、どの経路も
  --     有償 = least(bookings.paid_coins, 返還総額)
  --   で決まる(cancel_booking / release_hold_and_refund が同じ式)。
  --   ここで同じ式を引き直しているのは、返還時の内訳が
  --   coin_transactions に残らないため。
  -- ------------------------------------------------------------
  select t.created_at::date, '返金'::text,
         '前受金'::text, '予約エスクロー'::text,
         '前受金'::text, 'コイン'::text,
         least(b.paid_coins, t.amount)::bigint, '対象外'::text,
         ('返金 ' || coalesce(t.note, '') || ' 予約 ' || left(b.id::text, 8))::text,
         t.id::text
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  where t.type = 'refund' and t.amount > 0
    and least(b.paid_coins, t.amount) > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- J7 返金(無償コイン分) — J5 で立てた費用の戻し
  select t.created_at::date, '返金'::text,
         '前受金'::text, '予約エスクロー'::text,
         '販売促進費'::text, '無償コイン'::text,
         (t.amount - least(b.paid_coins, t.amount))::bigint, '対象外'::text,
         ('返金(無償分) ' || coalesce(t.note, '') || ' 予約 ' || left(b.id::text, 8))::text,
         t.id::text
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  where t.type = 'refund' and t.amount > 0
    and (t.amount - least(b.paid_coins, t.amount)) > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J8 報酬確定 — エスクローがピタメイトへの預り金に変わる
  --   完了時とキャンセル没収時の両方がここに入る(どちらも
  --   booking_earned)。**総額で入る**(利用料の控除は J10 で別行)。
  -- ------------------------------------------------------------
  select t.created_at::date, '報酬確定'::text,
         '前受金'::text, '予約エスクロー'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         t.amount::bigint, '対象外'::text,
         ('報酬確定 ' || coalesce(t.note, '') || ' 予約 ' || left(coalesce(t.related_booking_id::text, '-'), 8))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'booking_earned' and t.amount > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J9 ギフト受領
  --   ギフトは**有償コインのみ**で送れる(send_gift が
  --   _consume_coin_lots(..., 'paid', ...) しか呼ばない)ので、
  --   相手科目は前受金(コイン)で確定する。
  -- ------------------------------------------------------------
  select t.created_at::date, 'ギフト'::text,
         '前受金'::text, 'コイン'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         t.amount::bigint, '対象外'::text,
         'ギフト受領'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'gift_received' and t.amount > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J10 プラットフォーム利用料 — ここが売上
  --   note が 'gift_fee:%' ならギフト、それ以外は予約。
  -- ------------------------------------------------------------
  select t.created_at::date, 'PF利用料'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '売上高'::text,
         case when coalesce(t.note, '') like 'gift_fee:%' then 'PF利用料(ギフト)'
              else 'PF利用料(予約)' end,
         (-t.amount)::bigint, '課対売上込10%'::text,
         ('利用料 ' || coalesce(t.note, ''))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'platform_fee' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J11 換金申請(振込予定額) — 預り金の中で区分が変わるだけ
  -- ------------------------------------------------------------
  select p.created_at::date, '換金申請'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '預り金'::text, '換金申請中'::text,
         p.amount_yen::bigint, '対象外'::text,
         ('換金申請 ' || left(p.id::text, 8) || ' ' || p.coins || 'コイン')::text,
         p.id::text
  from public.payouts p
  where p.status in ('pending', 'paid')
    and p.created_at >= p_from and p.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J12 換金申請(事務手数料) — **振込が終わるまで売上にしない**
  --   Q7-b。ここを飛ばすと、申請から振込までの間だけ
  --   負債合計が300コイン足りなくなる。
  -- ------------------------------------------------------------
  select p.created_at::date, '換金申請'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '仮受金'::text, '換金手数料'::text,
         p.fee_yen::bigint, '対象外'::text,
         ('換金事務手数料(未実現) ' || left(p.id::text, 8))::text,
         p.id::text
  from public.payouts p
  where p.status in ('pending', 'paid') and coalesce(p.fee_yen, 0) > 0
    and p.created_at >= p_from and p.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J13 振込完了 — ここで初めて現金が出る
  -- ------------------------------------------------------------
  select p.paid_at::date, '振込'::text,
         '預り金'::text, '換金申請中'::text,
         '普通預金'::text, '支払口座'::text,
         p.amount_yen::bigint, '対象外'::text,
         ('振込 ' || left(p.id::text, 8) || ' ' || coalesce(p.bank_name, '') || ' ' || coalesce(p.account_holder_kana, ''))::text,
         p.id::text
  from public.payouts p
  where p.status = 'paid' and p.paid_at is not null
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all

  -- J14 換金事務手数料の売上振替(振込完了時)
  select p.paid_at::date, '振込'::text,
         '仮受金'::text, '換金手数料'::text,
         '売上高'::text, '換金事務手数料'::text,
         p.fee_yen::bigint, '課対売上込10%'::text,
         ('換金事務手数料 ' || left(p.id::text, 8))::text,
         p.id::text
  from public.payouts p
  where p.status = 'paid' and p.paid_at is not null and coalesce(p.fee_yen, 0) > 0
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J15 振込失敗の戻し
  --   mark_payout_failed は手数料も含めて全額 earned_balance へ返す。
  --   related_booking_id が無いので、J6/J7 とは自然に分かれる。
  -- ------------------------------------------------------------
  select t.created_at::date, '振込失敗'::text,
         '預り金'::text, '換金申請中'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         p.amount_yen::bigint, '対象外'::text,
         ('振込失敗の戻し ' || coalesce(p.failure_reason, ''))::text,
         t.id::text
  from public.coin_transactions t
  join public.payouts p on p.id = nullif(replace(t.note, 'mark_payout_failed:', ''), '')::uuid
  where t.type = 'refund' and t.related_booking_id is null
    and t.note like 'mark_payout_failed:%'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  select t.created_at::date, '振込失敗'::text,
         '仮受金'::text, '換金手数料'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         p.fee_yen::bigint, '対象外'::text,
         ('振込失敗の戻し(手数料) ' || coalesce(p.failure_reason, ''))::text,
         t.id::text
  from public.coin_transactions t
  join public.payouts p on p.id = nullif(replace(t.note, 'mark_payout_failed:', ''), '')::uuid
  where t.type = 'refund' and t.related_booking_id is null
    and t.note like 'mark_payout_failed:%' and coalesce(p.fee_yen, 0) > 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J16 コイン失効(有償分のみ) — 雑収入
  --   無償コインの失効は**仕訳なし**。前受金を立てていないので
  --   取り崩すものが無い(J5 で費用にするのは消費した分だけ)。
  --   消費税は不課税。会計ソフト上は「対象外」で入力する。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         'コイン失効(有償・不課税)'::text,
         t.id::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J17 純額処理への調整(**選択制**)
  --   無償コインで成立した予約から生じた利用料は、上の J10 でいったん
  --   売上に立っている。税理士の推奨する純額処理を採る場合は、
  --   ここでその分を売上から落とす。
  --   **両建てのままだと課税売上高が水増しされ、1,000万円の判定が
  --   実態より早く来る**(第4回回答)。
  --   純額処理を採らないなら、区分「純額調整」を除いて出力する。
  --   按分式は 0078 の内数と同じ(fee × bonus_coins / coins)。
  -- ------------------------------------------------------------
  select f.created_at::date, '純額調整'::text,
         '売上高'::text, 'PF利用料(予約)'::text,
         '販売促進費'::text, '無償コイン'::text,
         round(f.fee_coins::numeric * b.bonus_coins / nullif(b.coins, 0))::bigint,
         '課対売上込10%'::text,
         ('純額処理: 無償コイン起因の利用料を売上から控除 予約 ' || left(b.id::text, 8))::text,
         f.id::text
  from public.platform_fees f
  join public.bookings b on b.id = f.booking_id
  where f.kind = 'booking' and coalesce(b.bonus_coins, 0) > 0
    and round(f.fee_coins::numeric * b.bonus_coins / nullif(b.coins, 0)) > 0
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J18 返還時の失効(有償分) — **0085で追加**
  --   返還されるコインは当初の期限を引き継ぐ(第9条5の2)ため、
  --   返還の時点で期限を過ぎていると戻らずに消える。
  --   J6 で前受金(コイン)へ戻した分を、ここで取り崩す。
  --   **これが無いと前受金が過大に残り、突合が合わない。**
  --   無償分(refund_lapsed_bonus)は前受金を立てていないので仕訳なし。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         ('返還時の失効(有償・不課税) 予約 ' || left(coalesce(t.related_booking_id::text, '-'), 8))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'refund_lapsed_paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J19 金銭返金の債務計上(規約第9条5の3・0085)
  --   ゲストに落ち度が無い返還で消えた分は、現金で返す約束をしている。
  --   **J18 で立った失効益を、同額打ち消す。** 手元に残らないので
  --   利益にはならない、というのが経済実態。
  -- ------------------------------------------------------------
  select r.created_at::date, '返金債務'::text,
         '雑収入'::text, 'コイン失効益'::text,
         '未払金'::text, '返金(第9条5の3)'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('無帰責返還の金銭返金 ' || r.cause || ' ' || left(r.id::text, 8))::text,
         r.id::text
  from public.cash_refunds r
  where r.status in ('pending', 'paid')
    and r.created_at >= p_from and r.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J20 返金の支払 — ここで初めて現金が出る
  -- ------------------------------------------------------------
  select r.resolved_at::date, '返金'::text,
         '未払金'::text, '返金(第9条5の3)'::text,
         '普通預金'::text, '支払口座'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('返金の支払 ' || left(r.id::text, 8) || ' ' || coalesce(r.note, ''))::text,
         r.id::text
  from public.cash_refunds r
  where r.status = 'paid' and r.resolved_at is not null
    and r.resolved_at >= p_from and r.resolved_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J21 返金債務の取消(却下)
  --   運営が理由を付けて却下した場合。**理由は摘要に残す。**
  -- ------------------------------------------------------------
  select r.resolved_at::date, '返金取消'::text,
         '未払金'::text, '返金(第9条5の3)'::text,
         '雑収入'::text, 'コイン失効益'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('返金債務の取消 ' || left(r.id::text, 8) || ' ' || coalesce(r.note, ''))::text,
         r.id::text
  from public.cash_refunds r
  where r.status = 'rejected' and r.resolved_at is not null
    and r.resolved_at >= p_from and r.resolved_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J22 退会によるコイン消滅(有償分) — 0086
  --   第6条の2第3項。返金しないので前受金を取り崩して雑収入にする。
  --   無償分(withdraw_bonus)は前受金を立てていないので仕訳なし。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         '退会によるコイン消滅(有償・不課税)'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'withdraw_paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J23 退会後90日を過ぎた報酬コインの消滅 — 0086
  --   ピタメイトへの**預り金**が、支払わなくてよくなる。
  --   第6条の2第4項。90日という猶予を置いたうえでの消滅なので、
  --   債務免除益として雑収入に振り替える。
  -- ------------------------------------------------------------
  select t.created_at::date, '報酬失効'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '雑収入'::text, '報酬コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         '退会から90日経過による報酬コインの消滅(不課税)'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'withdraw_earned_expired' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  order by 1, 2, 10;
end;
$$;

comment on function public.accounting_journal(date, date) is
  '期間内の取引を会計ソフト取込用の単純仕訳(1行=借方1・貸方1)にして返す(運営のみ)。1コイン=1円。読み取りのみ。Stripeの着金・決済手数料と、経費・按分はここには出ない(明細から別途起票する)。';

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;
