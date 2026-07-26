-- ============================================================
-- 0043_integrity_checks.sql
-- 取引データの整合性を毎日自動で照合し、ズレを検知する
-- ------------------------------------------------------------
-- 背景: お金を扱う以上、いちばん怖いのは「壊れたことに気づかないまま
-- 時間が経つ」ことです。バックアップを持っていても、破損に3か月気づかなければ
-- どの時点まで巻き戻すのが正しいのか判断できず、復元しても意味がありません。
-- 予防(0044の追記専用化)や復旧(PITR)より先に、まず**検知**を置きます。
--
-- 幸い、この設計にはもともと冗長性があります。
--   ・coin_wallets.balance / bonus_balance は coin_lots の集計キャッシュ
--   ・coin_transactions は全ての残高変動の履歴(0003〜0042で67か所から記録)
--   ・coin_purchases は Stripe 側にも同じ記録が残る
-- つまり「同じ事実を別の形で持っている」ため、突き合わせれば破損が分かります。
--
-- いちばん効く不変条件はこれです:
--   Σ coin_transactions.amount == balance + bonus_balance + earned_balance
-- 残高の変動は必ず1行の履歴を伴うので、どのバケット(有償/ボーナス/報酬)に
-- 入ったかを分類しなくても、合計だけで全てのズレを捕まえられます。
--
-- 特に危ないのは greatest(0, balance - X) 形式の更新です(0018のexpire_coins、
-- 0030/0040の失効差し引き、0033の手数料控除)。既にズレていると更新側だけが
-- 0で止まり、履歴には満額が残るため、ズレが静かに拡大します。C3がこれを捕まえます。
-- ============================================================

-- ------------------------------------------------------------
-- integrity_checks: 照合結果の記録
-- ------------------------------------------------------------
create table if not exists public.integrity_checks (
  id uuid primary key default gen_random_uuid(),
  ran_at timestamptz not null default now(),
  check_name text not null,
  severity text not null check (severity in ('ok', 'warn', 'error')),
  -- ズレていた対象の件数(ok のときは 0、情報系は対象数)
  affected_count int not null default 0,
  -- ズレの合計(コイン単位)。情報系の指標値もここに入れる
  total_gap bigint not null default 0,
  -- 対象の内訳(先頭20件まで)。運営が個別に追える形で残す
  detail jsonb not null default '{}'::jsonb
);

comment on table public.integrity_checks is
  '取引データの日次整合性チェックの結果。severity=error の行が出たら、その日のうちに原因を特定すること。';

alter table public.integrity_checks enable row level security;

-- 閲覧は管理者のみ。書き込みポリシーは作らない(関数経由のみ)。
drop policy if exists "integrity_checks_select_admin" on public.integrity_checks;
create policy "integrity_checks_select_admin"
  on public.integrity_checks for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create index if not exists integrity_checks_ran_idx
  on public.integrity_checks (ran_at desc, check_name);

-- 通知タイプに整合性アラートを追加
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled',
    'integrity_alert'
  ));

-- ------------------------------------------------------------
-- run_integrity_checks: 全チェックを実行して結果を記録する
--   ・cron(service_role)からの実行と、管理者による手動実行の両方を許可
--   ・error が1件でもあれば管理者全員に通知する
--   ・戻り値は error だったチェックの数(0なら健全)
-- ------------------------------------------------------------
create or replace function public.run_integrity_checks()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run_at timestamptz := now();
  v_errors int := 0;
  v_count int;
  v_gap bigint;
  v_detail jsonb;
begin
  -- service_role/cron から呼ぶときは auth.uid() が null。
  -- ログイン中のユーザーが呼ぶ場合は管理者に限る。
  if auth.uid() is not null
     and not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  -- ============================================================
  -- C1/C2: 残高キャッシュ vs コインロットの残
  --   balance は「未失効ロットの合計」のキャッシュ。ここがズレると
  --   利用者から見える残高が実体と食い違う。
  --   失効済みロットは expire_coins() が remaining=0 にするため、
  --   期限で絞らず全ロットを合計してよい。
  -- ============================================================
  with agg as (
    select w.user_id,
           w.balance as cached,
           coalesce((select sum(l.remaining) from public.coin_lots l
                     where l.user_id = w.user_id and l.kind = 'paid'), 0) as lots
    from public.coin_wallets w
  ),
  bad as (select * from agg where cached <> lots)
  select count(*), coalesce(sum(abs(cached - lots)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'cached', cached, 'lots', lots)
         ) filter (where true), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(cached - lots) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'wallet_vs_lots_paid',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  with agg as (
    select w.user_id,
           w.bonus_balance as cached,
           coalesce((select sum(l.remaining) from public.coin_lots l
                     where l.user_id = w.user_id and l.kind = 'bonus'), 0) as lots
    from public.coin_wallets w
  ),
  bad as (select * from agg where cached <> lots)
  select count(*), coalesce(sum(abs(cached - lots)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'cached', cached, 'lots', lots)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(cached - lots) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'wallet_vs_lots_bonus',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C3: 残高の合計 vs 履歴の累計(いちばん強いチェック)
  --   残高変動は必ず coin_transactions に1行残るので、3つの残高の合計は
  --   履歴の累計と一致するはず。バケットの分類が要らないのが利点。
  -- ============================================================
  with agg as (
    select w.user_id,
           w.balance + w.bonus_balance + w.earned_balance as wallet_total,
           coalesce((select sum(t.amount) from public.coin_transactions t
                     where t.user_id = w.user_id), 0) as ledger_total
    from public.coin_wallets w
  ),
  bad as (select * from agg where wallet_total <> ledger_total)
  select count(*), coalesce(sum(abs(wallet_total - ledger_total)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'wallet_total', wallet_total, 'ledger_total', ledger_total)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(wallet_total - ledger_total) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'wallet_vs_ledger',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C4: 入金記録 vs 履歴(Stripe経由の付与)
  --   coin_purchases.coins_credited は「有償分+ボーナス分」の合計。
  --   Webhookの二重処理や付与漏れをここで捕まえる。
  --   Stripeのダッシュボード側とも突き合わせられる唯一の接点。
  -- ============================================================
  with agg as (
    select p.user_id,
           sum(p.coins_credited) as purchased,
           coalesce((select sum(t.amount) from public.coin_transactions t
                     where t.user_id = p.user_id
                       and t.type in ('purchase', 'bonus')
                       and t.note like 'stripe:%'), 0) as ledger
    from public.coin_purchases p
    group by p.user_id
  ),
  bad as (select * from agg where purchased <> ledger)
  select count(*), coalesce(sum(abs(purchased - ledger)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'purchased', purchased, 'ledger', ledger)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(purchased - ledger) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'purchase_vs_ledger',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C5: 換金申請 vs 履歴
  --   換金は申請時点(reserve)で earned_balance から引き、type='payout' を
  --   記録する。失敗時は 'refund' で戻すので、payoutの合計は申請の合計と一致する。
  --   ここがズレると「振り込んだのに残高が減っていない」等の直接の損失になる。
  -- ============================================================
  with agg as (
    select p.user_id,
           sum(p.coins) as requested,
           coalesce((select -sum(t.amount) from public.coin_transactions t
                     where t.user_id = p.user_id and t.type = 'payout'), 0) as ledger
    from public.payouts p
    group by p.user_id
  ),
  bad as (select * from agg where requested <> ledger)
  select count(*), coalesce(sum(abs(requested - ledger)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'requested', requested, 'ledger', ledger)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(requested - ledger) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'payout_vs_ledger',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C6: 預かり中の予約の内訳
  --   coins = paid_coins + bonus_coins が崩れていると、キャンセル返還で
  --   戻す量を誤る(返しすぎ/返し足りない)。
  -- ============================================================
  select count(*), coalesce(sum(abs(b.coins - (b.paid_coins + b.bonus_coins))), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'booking_id', b.id, 'coins', b.coins,
           'paid_coins', b.paid_coins, 'bonus_coins', b.bonus_coins)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (
    select * from public.bookings
    where status in ('requested', 'confirmed')
      and coins <> paid_coins + bonus_coins
    order by abs(coins - (paid_coins + bonus_coins)) desc
    limit 20
  ) b;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'escrow_split',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C7: 失効処理が動いているか
  --   期限切れなのに残っているロットが溜まっていたら、日次の
  --   expire_coins() が止まっている(=資金決済法の適用除外の前提が崩れる)。
  --   1日1回の実行なので、2日の猶予を見てから警告する。
  -- ============================================================
  select count(*), coalesce(sum(l.remaining), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'lot_id', l.id, 'user_id', l.user_id,
           'remaining', l.remaining, 'expires_at', l.expires_at)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (
    select * from public.coin_lots
    where remaining > 0 and expires_at < now() - interval '2 days'
    order by expires_at
    limit 20
  ) l;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'stale_expired_lots',
          case when v_count = 0 then 'ok' else 'warn' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));

  -- ============================================================
  -- C8(情報): 預かり中コインの総額
  --   ズレではないが、毎日記録して時系列で見られるようにする。
  --   前払式支払手段の残高監視(基準日3/31・9/30)の材料にもなる。
  -- ============================================================
  select count(*), coalesce(sum(coins), 0)
    into v_count, v_gap
  from public.bookings
  where status in ('requested', 'confirmed');

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'escrow_outstanding', 'ok', v_count, v_gap,
          jsonb_build_object('note', '預かり中(未完了)の予約とコイン総額'));

  -- ============================================================
  -- C9(情報): 未使用コインの総額(発行残高)
  -- ============================================================
  select count(*), coalesce(sum(balance + bonus_balance), 0)
    into v_count, v_gap
  from public.coin_wallets
  where balance + bonus_balance > 0;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'unused_coin_balance', 'ok', v_count, v_gap,
          jsonb_build_object('note', '未使用の前払式コイン(有償+ボーナス)の総額'));

  -- ============================================================
  -- error が出たら管理者に通知する
  -- ============================================================
  if v_errors > 0 then
    insert into public.notifications (user_id, type, title, body)
    select a.user_id, 'integrity_alert',
           '取引データの不整合を検知しました',
           v_errors::text || '件のチェックがエラーになりました。integrity_checks を確認してください。'
    from public.admins a;
  end if;

  return v_errors;
end;
$$;

comment on function public.run_integrity_checks() is
  '取引データの整合性を照合し integrity_checks に記録する。errorがあれば管理者に通知。cronから毎日実行。';

revoke all on function public.run_integrity_checks() from public;
grant execute on function public.run_integrity_checks() to authenticated;

-- ------------------------------------------------------------
-- integrity_latest: 直近の実行結果だけを見るビュー(運営用)
-- ------------------------------------------------------------
create or replace view public.integrity_latest
with (security_invoker = true) as
select c.*
from public.integrity_checks c
where c.ran_at = (select max(ran_at) from public.integrity_checks)
order by
  case c.severity when 'error' then 0 when 'warn' then 1 else 2 end,
  c.check_name;

comment on view public.integrity_latest is
  '最後に実行した整合性チェックの結果。severityの重い順に並ぶ。';

-- ------------------------------------------------------------
-- 古い記録の掃除(90日より前は消す。日次×9チェックなので放置しても
-- 大きくはならないが、無限に増やす理由もない)
-- ------------------------------------------------------------
create or replace function public.prune_integrity_checks()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted int;
begin
  delete from public.integrity_checks where ran_at < now() - interval '90 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.prune_integrity_checks() from public;

-- ------------------------------------------------------------
-- cronに登録(pg_cronが使える環境のみ)
--   毎日 04:07 に実行。expire_coins(03:11)の後になるよう時刻をずらしている
--   (失効処理の直後に照合したいため)。
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('run-integrity-checks', '7 4 * * *', 'select public.run_integrity_checks()');
    perform cron.schedule('prune-integrity-checks', '37 4 * * 0', 'select public.prune_integrity_checks()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end;
$$;
