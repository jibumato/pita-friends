-- ============================================================
-- 0075: 決済の異議申立て(チャージバック)を受けたら残高を凍結する
-- ------------------------------------------------------------
-- ■ なぜ最優先か
--   税理士の第2回回答(Q14)より:
--
--     「Stripeの異議申立てイベント(charge.dispute.created)を受け取って、
--       当該ユーザーのコイン残高を凍結する仕組みを、**リリース前に**
--       実装してください。これがないと、**チャージバックを申し立てながら、
--       その間にコインを使い切る**という極めて単純な不正が通ります。
--       会計処理をどう決めても、この穴が開いていれば損失は防げません。
--       **優先度は、本Q14の他のすべての論点より上です。**」
--
--   実際、異議申立てから決着まで数週間かかる。その間に使い切られると、
--   ①Stripeからの入金は取り消され ②PF利用料は売上に立ち
--   ③ホストへの預り金も発生している、という状態だけが残る。
--   **回収先が無い。**
--
-- ■ 何を止め、何を止めないか
--   止める(= コインを減らす操作):
--     ・新しい予約の成立(create_booking / create_booking_series)
--     ・ありがとうギフトの送信
--     ・プレイ時間の延長
--   止めない:
--     ・**既に成立した予約の履行**(チェックイン・完了・キャンセル・返還)
--       … 相手のピタメイトには何の落ち度も無い。ここを止めると
--         善意の第三者を巻き込む
--     ・トーク・通報・退会など、お金に関係しない操作
--     ・**ホストとしての換金**(凍結の理由はゲストとしての決済であり、
--       ピタメイトとして稼いだ報酬とは別。**ただし運営が個別に判断して
--       止める余地は admin 側に残す**)
--
-- ■ 誰を凍結するか
--   **決済を行った本人のみ。** 異議申立ては決済の当事者の申立てなので、
--   相手(ピタメイトやギフトの受領者)は凍結しない。
--
-- ■ 解除
--   Stripe の charge.dispute.closed で、
--     ・won(当社の主張が通った)  → 自動で解除する
--     ・lost(返金が確定した)     → **自動では解除しない。**
--       返金が確定した以上、残高の調整(取消)が必要で、その判断は運営が行う。
--       運営コンソールから解除する(admin_resolve_dispute)。
--
-- ■ 設計上の注意
--   凍結は**購入単位ではなく利用者単位**にする。異議申立てを受けた購入の
--   コインだけを特定して止める、という設計は一見きれいだが、コインは
--   ロットをまたいで混ざるため、**「どのコインが争われている購入由来か」を
--   後から追うのは実務上不可能**。利用者単位で止めるほうが確実で、
--   誤爆したときも解除できる。
-- ============================================================

-- ------------------------------------------------------------
-- payment_disputes: 異議申立ての記録
-- ------------------------------------------------------------
create table if not exists public.payment_disputes (
  id uuid primary key default gen_random_uuid(),
  -- 決済者が特定できない申立て(当社の購入と紐づかないもの)もあり得るので null 可。
  -- **握りつぶさずに残す** ため。null の行は誰も凍結しない。
  user_id uuid references auth.users (id) on delete cascade,
  -- Stripe の dispute id。同じ申立ての再送で二重に積まないための鍵
  stripe_dispute_id text not null unique,
  stripe_charge_id text,
  stripe_payment_intent text,
  -- 争われている金額(円)。Stripe の amount をそのまま入れる
  amount_yen int,
  reason text,
  -- open  … 申立て中(凍結の根拠)
  -- won   … 当社の主張が通った(自動解除)
  -- lost  … 返金が確定した(運営が残高を調整してから手動で解除)
  -- closed… その他の終了(warning_closed 等)
  status text not null default 'open'
    check (status in ('open', 'won', 'lost', 'closed')),
  -- 凍結を解除した時刻。**null の間は凍結中**(status ではなくこの列で判定する)
  resolved_at timestamptz,
  resolved_note text,
  created_at timestamptz not null default now()
);

comment on table public.payment_disputes is
  '決済の異議申立て(チャージバック)の記録。resolved_at が null の行があるユーザーはコインの消費を止める。税理士の第2回回答Q14(リリース前の必須実装)。';

alter table public.payment_disputes enable row level security;

-- 本人にも見せない。異議申立ての存否は運営とStripeの間の情報で、
-- 画面に出す必要が無い(出すと、凍結の回避方法を探る材料になる)。
-- select ポリシーを置かないことで既定の拒否になる。運営は service_role で見る。

create index if not exists payment_disputes_open_idx
  on public.payment_disputes (user_id)
  where resolved_at is null;

-- ------------------------------------------------------------
-- _coins_frozen: そのユーザーが凍結中か
-- ------------------------------------------------------------
create or replace function public._coins_frozen(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- **status ではなく resolved_at で判定する。**
  -- lost(返金が確定した)は自動解除してはいけない ── 残高の調整という
  -- 運営の作業が残っているため。status で見ると lost の瞬間に凍結が
  -- 解けてしまい、**最も止めたい場面で止まらない。**
  select p_user is not null and exists (
    select 1 from public.payment_disputes d
    where d.user_id = p_user and d.resolved_at is null
  );
$$;

comment on function public._coins_frozen(uuid) is
  '決済の異議申立て中でコインの消費を止めるべきユーザーか。';

revoke all on function public._coins_frozen(uuid) from public;

-- ------------------------------------------------------------
-- コインが減る操作を止める。
-- coin_wallets の UPDATE を直接見張るのではなく、**消費のたびに必ず通る
-- coin_transactions の INSERT** を見張る。返還(refund)や失効(expire)は
-- 止めない ── 止めると既存予約のキャンセルができなくなる。
-- ------------------------------------------------------------
create or replace function public._coin_tx_require_unfrozen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 減る向きの、利用者の意思による消費だけを見る。
  -- expire(失効)は当社側の処理、refund は返す向きなので対象外。
  if new.type in ('booking_spend', 'gift_sent')
     and public._coins_frozen(new.user_id) then
    raise exception 'COINS_FROZEN_DISPUTE';
  end if;
  return new;
end;
$$;

revoke all on function public._coin_tx_require_unfrozen() from public;

drop trigger if exists coin_transactions_require_unfrozen on public.coin_transactions;
create trigger coin_transactions_require_unfrozen
  before insert on public.coin_transactions
  for each row execute function public._coin_tx_require_unfrozen();

-- ------------------------------------------------------------
-- record_payment_dispute: Stripe webhook から呼ぶ(service_role のみ)
-- 同じ dispute の再送は状態を更新するだけで、二重に積まない。
-- ------------------------------------------------------------
create or replace function public.record_payment_dispute(
  p_stripe_dispute_id text,
  p_stripe_charge_id text,
  p_stripe_payment_intent text,
  p_amount_yen int,
  p_reason text,
  p_status text default 'open'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if p_stripe_dispute_id is null or p_status not in ('open','won','lost','closed') then
    raise exception 'INVALID_ARGS';
  end if;

  -- 決済者を購入履歴から引く(payment_intent が唯一の手掛かり)。
  select p.user_id into v_user
    from public.coin_purchases p
   where (p_stripe_payment_intent is not null
          and p.stripe_payment_intent = p_stripe_payment_intent)
   limit 1;

  -- 決済者が特定できない場合も user_id = null で記録する。
  -- **握りつぶさない。** 誰も凍結しないが、人が調べられる形で残す。
  insert into public.payment_disputes
    (user_id, stripe_dispute_id, stripe_charge_id, stripe_payment_intent,
     amount_yen, reason, status)
  values (v_user, p_stripe_dispute_id, p_stripe_charge_id, p_stripe_payment_intent,
          p_amount_yen, p_reason, p_status)
  on conflict (stripe_dispute_id) do update
    set status = excluded.status,
        amount_yen = coalesce(excluded.amount_yen, public.payment_disputes.amount_yen),
        reason = coalesce(excluded.reason, public.payment_disputes.reason);

  -- won は当社の主張が通った = 自動で解除してよい。
  -- lost は返金が確定した = **残高の調整が要る**ので自動解除しない
  -- (運営が admin_resolve_dispute で解除する)。
  if p_status = 'won' then
    update public.payment_disputes
       set resolved_at = now(),
           resolved_note = coalesce(resolved_note, 'Stripeで当社の主張が認められたため自動解除')
     where stripe_dispute_id = p_stripe_dispute_id and resolved_at is null;
  end if;
end;
$$;

revoke all on function public.record_payment_dispute(text, text, text, int, text, text) from public;
-- 呼ぶのは Stripe webhook(service_role)だけ。anon/authenticated には渡さない。

-- ------------------------------------------------------------
-- admin_open_disputes / admin_resolve_dispute: 運営コンソール用
-- ------------------------------------------------------------
create or replace function public.admin_open_disputes()
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  stripe_dispute_id text,
  amount_yen int,
  reason text,
  status text,
  created_at timestamptz,
  coin_balance int,
  earned_balance int
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  perform public._log_admin_action('view_disputes', null, null);
  return query
    select d.id, d.user_id, pr.nickname, d.stripe_dispute_id, d.amount_yen,
           d.reason, d.status, d.created_at,
           coalesce(w.balance, 0), coalesce(w.earned_balance, 0)
      from public.payment_disputes d
      left join public.profiles pr on pr.id = d.user_id
      left join public.coin_wallets w on w.user_id = d.user_id
     where d.resolved_at is null
     order by d.created_at desc;
end;
$$;

revoke all on function public.admin_open_disputes() from public;
grant execute on function public.admin_open_disputes() to authenticated;

create or replace function public.admin_resolve_dispute(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_note is null or char_length(btrim(p_note)) = 0 then
    -- 理由を必ず書かせる。凍結の解除は後から説明を求められる操作。
    raise exception 'NOTE_REQUIRED';
  end if;

  update public.payment_disputes
     set status = case when status = 'open' then 'closed' else status end,
         resolved_at = now(),
         resolved_note = p_note
   where id = p_id and resolved_at is null
  returning user_id into v_user;

  if v_user is null then
    raise exception 'DISPUTE_NOT_FOUND';
  end if;
  perform public._log_admin_action('resolve_dispute', v_user, p_note);
end;
$$;

revoke all on function public.admin_resolve_dispute(uuid, text) from public;
grant execute on function public.admin_resolve_dispute(uuid, text) to authenticated;
