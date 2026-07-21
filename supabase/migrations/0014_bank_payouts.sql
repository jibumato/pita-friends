-- ============================================================
-- 換金方式の変更: Stripe Connect → 自社銀行振込(GameRoom型)
-- ------------------------------------------------------------
-- 方針(2026-07-21 決定):
--   ・コイン購入は引き続き Stripe Checkout(0009)。
--   ・ホストへの報酬振込は、Stripe Connect をやめて自社の総合振込
--     (ネットバンキングへのCSV一括アップロード)で行う。
--     理由: Stripe Connect の日本料金(入金ごと0.25%+¥250、
--     有効アカウントごと月額¥200)では、少額ホストを多数抱える
--     本サービスのモデルでは自社振込のほうが大幅に安いため。
--   ・エスクロー設計(0013)はそのまま:
--     purchase balance と earned_balance は別会計、
--     ゲストの complete_booking でのみ報酬が確定する。
--   ・換金の流れ:
--       ホスト: 口座登録(host_bank_accounts) → 換金申請(request_bank_payout)
--       運営:   月次で締め → 振込リストをSQLで出力(docs/payouts-bank-operations.md)
--               → 総合振込を実行 → mark_payout_paid / mark_payout_failed で消し込み
--   ・手数料: 申請1件につき 300コイン(=¥300)をコイン側で控除する
--     (GameRoomと同方式)。振込額 = 申請コイン − 300。
--   ・最低申請額: 1,000コイン。手数料負けと少額振込の事務コストを防ぐ。
--
--   ⚠️ 自社振込は「資金移動の実行主体が当社になる」ため、
--   資金移動業/収納代行の法的整理が Stripe Connect 利用時より
--   シビアになる。本番投入前に必ず弁護士レビューを受けること
--   (docs/legal/coin-economy-legal-review.md §7.2)。
-- ============================================================

-- ------------------------------------------------------------
-- Stripe Connect 用のオブジェクトを撤去
-- (create-connect-account / request-payout Edge Function も削除済み)
-- ------------------------------------------------------------
drop function if exists public.reserve_payout(uuid, int);
drop function if exists public.finalize_payout(uuid, text);
drop function if exists public.fail_payout(uuid, text);
drop table if exists public.host_payout_accounts;

alter table public.payouts drop column if exists stripe_transfer_id;

-- ------------------------------------------------------------
-- host_bank_accounts: ホストの振込先口座
-- 本人のみ登録・閲覧・更新できる。運営はservice_role(SQL Editor)で参照。
-- カナ名義は全銀フォーマットに合わせてカタカナ+英数+記号のみ許可
-- (ひらがな→カタカナ等の正規化はクライアント側で行う)。
-- ------------------------------------------------------------
create table public.host_bank_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  bank_name text not null check (char_length(bank_name) between 1 and 30),
  bank_code text not null check (bank_code ~ '^[0-9]{4}$'),
  branch_name text not null check (char_length(branch_name) between 1 and 30),
  branch_code text not null check (branch_code ~ '^[0-9]{3}$'),
  account_type text not null check (account_type in ('普通', '当座')),
  account_number text not null check (account_number ~ '^[0-9]{7}$'),
  account_holder_kana text not null
    check (account_holder_kana ~ '^[ァ-ヶー0-9A-Z()（）./\- 　]+$'
           and char_length(account_holder_kana) between 1 and 48),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.host_bank_accounts is
  'ホストの報酬振込先口座。運営が総合振込(全銀CSV)を作成する際にservice_roleで参照する。';

alter table public.host_bank_accounts enable row level security;

create policy "host_bank_accounts_select_own"
  on public.host_bank_accounts for select
  to authenticated
  using (user_id = auth.uid());

create policy "host_bank_accounts_insert_own"
  on public.host_bank_accounts for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "host_bank_accounts_update_own"
  on public.host_bank_accounts for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create trigger host_bank_accounts_set_updated_at
  before update on public.host_bank_accounts
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- payouts: 自社振込用の列を追加
-- ・fee_yen: 申請時に控除した振込手数料(コイン=円)
-- ・振込先スナップショット: 申請後にホストが口座を変更しても
--   振込リストが変わらないよう、申請時点の口座情報を写し取る
-- ------------------------------------------------------------
alter table public.payouts
  add column fee_yen int not null default 0 check (fee_yen >= 0),
  add column bank_name text,
  add column bank_code text,
  add column branch_name text,
  add column branch_code text,
  add column account_type text,
  add column account_number text,
  add column account_holder_kana text,
  add column paid_at timestamptz;

comment on column public.payouts.amount_yen is
  '実際に振り込む金額(円)。申請コイン − 手数料(fee_yen)。';

-- ------------------------------------------------------------
-- request_bank_payout: ホスト本人が換金を申請する。
-- earned_balance から申請コインを引き落とし、payouts(pending)を作る。
-- 実際の振込は運営の総合振込で行い、mark_payout_paid で確定する。
-- ------------------------------------------------------------
create function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;       -- 振込手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 1000; -- 最低申請コイン
  v_uid uuid := auth.uid();
  v_balance int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
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
  if v_balance is null or v_balance < p_coins then
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
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

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;

-- ------------------------------------------------------------
-- mark_payout_paid / mark_payout_failed: 運営の消し込み用。
-- service_role(SQL Editor / 管理スクリプト)専用。クライアントには
-- 意図的にgrantしない(振込せずに残高だけ確定できてしまうため)。
-- ------------------------------------------------------------
create function public.mark_payout_paid(p_payout_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.payouts
    set status = 'paid', paid_at = now()
    where id = p_payout_id and status = 'pending';
end;
$$;

revoke all on function public.mark_payout_paid(uuid) from public;

create function public.mark_payout_failed(p_payout_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payout public.payouts;
begin
  select * into v_payout from public.payouts where id = p_payout_id and status = 'pending' for update;
  if v_payout.id is null then
    return;
  end if;

  update public.payouts set status = 'failed', failure_reason = p_reason where id = p_payout_id;

  -- 振込できなかったので、手数料も含め申請コイン全額を払い戻す
  update public.coin_wallets set earned_balance = earned_balance + v_payout.coins where user_id = v_payout.user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_payout.user_id, v_payout.coins, 'refund', 'mark_payout_failed:' || p_payout_id);
end;
$$;

revoke all on function public.mark_payout_failed(uuid, text) from public;
