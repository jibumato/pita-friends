-- ============================================================
-- 0044_ledger_immutable.sql
-- 取引台帳を追記専用にし、誤操作による破壊を防ぐ
-- ------------------------------------------------------------
-- 背景: 実務でDBが壊れる原因は、ハードウェア故障よりも運用中の人為ミスが
-- 圧倒的に多いです。Supabaseの管理画面から行を選んで消す、SQL Editorで
-- where を付け忘れた UPDATE を流す、といったものです。
-- RLSは効きません。管理画面もEdge Functionも service_role で動くため、
-- RLSを迂回できるからです。テーブル側で拒否する必要があります。
--
-- ただし「絶対に変更できない」のは運用として無理があります。いつか正当な
-- 訂正(誤った付与の取り消しなど)が必要になり、そのときトリガーごと外されて
-- 二度と戻らない、というのが最悪の結末です。
-- そこで「明示的に宣言すれば通るが、宣言は必ず記録される」形にします。
--
--   set local app.ledger_override = 'on';   -- 同一トランザクション内でのみ有効
--
-- これで防げるのは「うっかり」です。狙いはそこで十分で、意図的な操作は
-- ledger_audit に旧値ごと残るため、後から必ず追えます。
--
-- どこを守るか:
--   coin_transactions / coin_purchases … 変更も削除も禁止(純粋な履歴)
--   payouts                            … 削除禁止。金額・宛先の変更も禁止
--                                        (status/振込結果の更新は通常運用)
--   coin_lots                          … 削除禁止(remainingの更新は消費・失効で必要)
--   coin_lot_consumptions              … 削除禁止(restored_atの更新のみ許可)
--   bookings                           … 削除禁止(預かり中のコインが宙に浮く)
-- ============================================================

-- ------------------------------------------------------------
-- ledger_audit: 保護を明示的に解除して行った変更の記録
-- ------------------------------------------------------------
create table if not exists public.ledger_audit (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(),
  table_name text not null,
  op text not null check (op in ('UPDATE', 'DELETE')),
  actor uuid,
  old_row jsonb,
  new_row jsonb
);

comment on table public.ledger_audit is
  '追記専用の保護を app.ledger_override で解除して行った台帳の変更履歴。旧値を含むので、誤った訂正はここから復元できる。';

alter table public.ledger_audit enable row level security;

drop policy if exists "ledger_audit_select_admin" on public.ledger_audit;
create policy "ledger_audit_select_admin"
  on public.ledger_audit for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create index if not exists ledger_audit_at_idx on public.ledger_audit (at desc);

-- ------------------------------------------------------------
-- _ledger_override_on: 保護の解除が宣言されているか
-- ------------------------------------------------------------
create or replace function public._ledger_override_on()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('app.ledger_override', true), '') = 'on';
$$;

-- ------------------------------------------------------------
-- _ledger_record_bypass: 解除して行った操作を記録する
-- ------------------------------------------------------------
create or replace function public._ledger_record_bypass(
  p_table text, p_op text, p_old jsonb, p_new jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.ledger_audit (table_name, op, actor, old_row, new_row)
  values (p_table, p_op, auth.uid(), p_old, p_new);
$$;

-- ------------------------------------------------------------
-- _ledger_immutable: 変更も削除も禁止(coin_transactions / coin_purchases)
-- ------------------------------------------------------------
create or replace function public._ledger_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._ledger_override_on() then
    raise exception 'LEDGER_IMMUTABLE: % は追記専用です(% は禁止)。訂正が必要な場合は打ち消しの行を追加してください。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。',
      TG_TABLE_NAME, TG_OP;
  end if;

  perform public._ledger_record_bypass(
    TG_TABLE_NAME, TG_OP,
    to_jsonb(OLD),
    case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);

  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- _ledger_no_delete: 削除のみ禁止(coin_lots / bookings)
-- ------------------------------------------------------------
create or replace function public._ledger_no_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._ledger_override_on() then
    raise exception 'LEDGER_IMMUTABLE: % の行は削除できません。やむを得ない場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。',
      TG_TABLE_NAME;
  end if;

  perform public._ledger_record_bypass(TG_TABLE_NAME, 'DELETE', to_jsonb(OLD), null);
  return OLD;
end;
$$;

-- ------------------------------------------------------------
-- _payout_amount_immutable: 換金の金額・宛先の変更を禁止
--   status / stripe_transfer_id / failure_reason の更新は通常運用なので通す。
-- ------------------------------------------------------------
create or replace function public._payout_amount_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.user_id is distinct from NEW.user_id
     or OLD.coins is distinct from NEW.coins
     or OLD.amount_yen is distinct from NEW.amount_yen
     or OLD.created_at is distinct from NEW.created_at then
    if not public._ledger_override_on() then
      raise exception 'LEDGER_IMMUTABLE: 換金の金額・宛先は変更できません。取り消す場合は mark_payout_failed() で失敗にして戻してください。';
    end if;
    perform public._ledger_record_bypass('payouts', 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
  end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- _consumption_restore_only: 消費記録は restored_at の更新のみ許可
--   (0030の返金で「当初の有効期限」を引き継ぐための記録。ここが書き換わると
--    返金コインの期限が延び、資金決済法の適用除外の前提が崩れる)
-- ------------------------------------------------------------
create or replace function public._consumption_restore_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.user_id is distinct from NEW.user_id
     or OLD.booking_id is distinct from NEW.booking_id
     or OLD.kind is distinct from NEW.kind
     or OLD.expires_at is distinct from NEW.expires_at
     or OLD.coins is distinct from NEW.coins
     or OLD.created_at is distinct from NEW.created_at then
    if not public._ledger_override_on() then
      raise exception 'LEDGER_IMMUTABLE: coin_lot_consumptions は restored_at 以外を変更できません。';
    end if;
    perform public._ledger_record_bypass('coin_lot_consumptions', 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
  end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- トリガーの設置
-- ------------------------------------------------------------
drop trigger if exists coin_transactions_immutable on public.coin_transactions;
create trigger coin_transactions_immutable
  before update or delete on public.coin_transactions
  for each row execute function public._ledger_immutable();

drop trigger if exists coin_purchases_immutable on public.coin_purchases;
create trigger coin_purchases_immutable
  before update or delete on public.coin_purchases
  for each row execute function public._ledger_immutable();

drop trigger if exists payouts_no_delete on public.payouts;
create trigger payouts_no_delete
  before delete on public.payouts
  for each row execute function public._ledger_no_delete();

drop trigger if exists payouts_amount_immutable on public.payouts;
create trigger payouts_amount_immutable
  before update on public.payouts
  for each row execute function public._payout_amount_immutable();

drop trigger if exists coin_lots_no_delete on public.coin_lots;
create trigger coin_lots_no_delete
  before delete on public.coin_lots
  for each row execute function public._ledger_no_delete();

drop trigger if exists coin_lot_consumptions_no_delete on public.coin_lot_consumptions;
create trigger coin_lot_consumptions_no_delete
  before delete on public.coin_lot_consumptions
  for each row execute function public._ledger_no_delete();

drop trigger if exists coin_lot_consumptions_restore_only on public.coin_lot_consumptions;
create trigger coin_lot_consumptions_restore_only
  before update on public.coin_lot_consumptions
  for each row execute function public._consumption_restore_only();

drop trigger if exists bookings_no_delete on public.bookings;
create trigger bookings_no_delete
  before delete on public.bookings
  for each row execute function public._ledger_no_delete();

-- ------------------------------------------------------------
-- 補足: この時点で auth.users の削除は失敗するようになります。
-- 上記テーブルは全て auth.users に on delete cascade でぶら下がっているため、
-- ユーザーを物理削除しようとすると台帳の削除が走り、ここで止まります。
-- 「入金記録も換金記録も黙って消える」よりは、止まって気づけるほうが安全です。
-- 退会そのものは 0045 の匿名化で行います。
-- ------------------------------------------------------------
