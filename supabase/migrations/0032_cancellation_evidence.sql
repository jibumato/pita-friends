-- ============================================================
-- キャンセルポリシーの同意記録と、キャンセル実態の集計
-- 論点: docs/legal/lawyer-review-round2-request.md Q14
--       (直前キャンセルの没収と消費者契約法9条)
-- 対応: open-issues.md の E-1 / E-2
-- ------------------------------------------------------------
-- Q14で示された条件のうち、①「予約確定前にキャンセルポリシーを明示し、
-- 同意の痕跡(ログ)を残す」③「争いになった際の『平均的な損害』の立証材料を
-- 蓄積する」に対応する。
--
-- ■ E-1: 同意の記録
--   予約時に、そのとき画面に表示していたポリシーのバージョンを予約行に残す。
--   別テーブルにせず bookings に持たせるのは、証跡が予約と1対1で、
--   予約を見れば「どの版のポリシーに同意して申し込んだか」が分かるため。
--
-- ■ E-2: 「平均的な損害」の立証材料
--   当初は「直前キャンセルされた枠がその後埋まったか(再販売率)」を記録する
--   想定だったが、本サービスに将来日時の予約は無く、ホストが承諾した時点で
--   役務が始まる(approve_booking が scheduled_at = now() を設定する)。
--   「空いた枠が後で売れたか」という概念が成立しないため、代わりに
--   **承諾からキャンセルまでの経過時間と没収額**を集計する。
--   これらは bookings の既存カラム(scheduled_at = 承諾時刻, cancelled_at)から
--   導出できるので、新しい列は増やさずビューだけを用意する。
-- ============================================================

-- ------------------------------------------------------------
-- E-1: 同意したポリシーのバージョンを予約に記録する
-- ------------------------------------------------------------
alter table public.bookings
  add column policy_version text,
  add column policy_agreed_at timestamptz;

comment on column public.bookings.policy_version is
  '予約申込時に画面へ表示していたキャンセルポリシーのバージョン(src/content/bookingPolicy.ts と対応)。消費者契約法9条の争いに備えた同意の痕跡。';
comment on column public.bookings.policy_agreed_at is
  '上記ポリシーに同意して申し込んだ時刻。';

-- create_booking に p_policy_version を足す。
--
-- 旧2引数版は「まだ残す」。main へのマージで自動デプロイされる構成のため、
-- マイグレーションの適用とフロントのデプロイの順序が前後しうる。
-- ここで2引数版を消すと、適用前にデプロイされた瞬間に予約が作れなくなる。
--
-- なお3引数版の p_policy_version に既定値を持たせると、2引数での呼び出しが
-- どちらの関数にも一致して "function is not unique" になるため、
-- **3引数版は必須引数**にしてある。
--
-- ⚠️ フロントのデプロイ完了後に、旧2引数版は削除すること(同意記録の無い予約が
--    作れる状態を残さないため)。削除は次のマイグレーションで行う。
drop function if exists public.create_booking(uuid, int, text);

create function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_guest_name text;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_duration_minutes not in (30, 60, 120) then
    raise exception 'INVALID_DURATION';
  end if;
  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings where user_id = p_host_id for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_coins := round(v_hourly_rate * p_duration_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end
  )
  returning id into v_booking_id;

  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id, 'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

-- 旧2引数版を、3引数版へ委譲する薄いラッパーに置き換える(経過措置)。
-- 同意バージョンは null になるので、記録の無い予約は「デプロイ前の申込み」と
-- 判別できる。
create or replace function public.create_booking(p_host_id uuid, p_duration_minutes int)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.create_booking(p_host_id, p_duration_minutes, null::text);
$$;

comment on function public.create_booking(uuid, int) is
  '経過措置。フロントのデプロイ完了後に削除すること(同意記録の無い予約が作れる状態を残さないため)。';

-- ------------------------------------------------------------
-- E-2: キャンセル実態の集計(「平均的な損害」の立証材料)
--
-- security_invoker により、通常のユーザーには bookings のRLSがそのまま効く
-- (自分が当事者の予約しか見えない)。運営はダッシュボード/service_roleで全件見る。
-- ------------------------------------------------------------
create view public.guest_cancellation_evidence
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.host_id,
  b.duration_minutes,
  b.coins as forfeited_coins,
  b.policy_version,
  b.scheduled_at as approved_at,
  b.cancelled_at,
  -- 承諾(=役務の開始)からキャンセルまでの経過秒数
  extract(epoch from (b.cancelled_at - b.scheduled_at))::int as seconds_after_approval,
  -- 経過時間が予約時間に占める割合(1.0 = 予定時間をすべて消化してからキャンセル)
  round(
    extract(epoch from (b.cancelled_at - b.scheduled_at))::numeric
      / nullif(b.duration_minutes * 60, 0),
    3
  ) as elapsed_ratio
from public.bookings b
where b.status = 'cancelled_by_guest'
  and b.cancelled_at is not null
  -- 承諾前(status='requested')の取消は全額返金なので対象外。
  -- 没収が起きたケースだけを見る。
  and b.scheduled_at is not null
  and b.cancelled_at >= b.scheduled_at;

comment on view public.guest_cancellation_evidence is
  'ゲスト都合キャンセルで没収が生じた予約の一覧。承諾からキャンセルまでの経過時間と没収額を出す。消費者契約法9条の「平均的な損害」を検討・立証するための材料(docs/legal/lawyer-review-round2-request.md Q14)。';
