-- ============================================================
-- 0103: 利用料は「実際に受け取った額」から引く(保留解除の過大控除を直す)
-- ------------------------------------------------------------
-- ■ 見つかった穴(0102 の逆向き)
--   完了時の利用料トリガー(0033/0091)は **new.coins = 予約の全額** を
--   基準に控除する。ところが、申し出の保留を一部返還で解除する
--   `release_hold_and_refund`(0042/0085)も status を 'completed' に
--   するので同じトリガーが走り、**ホストが受け取っていない分にまで
--   利用料がかかっていた。**
--
--   実測(2,000コインの予約・20%ティア):
--     50%返還  → ホストの受取 1,000。控除 400(2,000×20%)。**実効40%**
--     100%返還 → ホストの受取 **0**。それでも 340 が控除され、
--                **別の予約で稼いだ残高 5,000 が 4,660 に減った**
--
--   0102 が「運営の取り漏れ」だったのに対し、こちらは**運営の取りすぎ**。
--   規約 第8条の2第2項は「ピタメイトが受け取った対価から控除する」と
--   定めているので、受け取っていない額からの控除は**規約違反そのもの**。
--   個人のピタメイト相手なので、優越的地位の濫用の評価でも最も分が悪い。
--   platform_fees の明細も net 1,600 と記録され、実際の受取 600 と
--   食い違っていた(会計の突合も狂う)。
--
-- ■ 直し方: 基準額を「予約の全額」ではなく「この予約でホストに
--   実際に付与された額」にする
--
--   付与は必ず coin_transactions に type='booking_earned' で記録される
--   (complete_booking / auto_complete_bookings / release_hold_and_*)。
--   トリガーは deferrable initially deferred なので、**同じ
--   トランザクションで挿入された付与の行が必ず見える**。
--
--     通常の完了・自動確定・保留解除(全額) → 付与 = 予約額。挙動は従来どおり
--     保留解除(一部返還)                   → 付与 = ホストへ渡る分だけ
--     保留解除(全額返還)                   → 付与 = 0。**控除も明細も作らない**
--
--   関数を1本ずつ直すのではなくトリガー側で吸収するのは、
--   付与する関数が今後増えても取りこぼさないため(0033 が手数料を
--   トリガーにした理由と同じ)。
--
-- ■ 直さないことにしたもの(意図的)
--   `host_monthly_ticket_gmv`(料率ティアの当月累計)は、一部返還があっても
--   予約の全額を数える。累計が実受取より少し大きく出て、**以後の限界料率が
--   下がりやすくなる = ピタメイト有利**の側にしか働かないので、複雑にして
--   まで直さない。ティアは「その月に取り扱った規模」への割引であり、
--   予約の全額が一度は流通しているという説明も立つ。
-- ============================================================

create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r jsonb;
  v_fee int;
  v_base int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  -- 0103: この予約でホストに実際に付与された額。
  -- 一部返還つきの保留解除では予約額より小さく、全額返還では0になる
  select coalesce(sum(t.amount), 0) into v_base
    from public.coin_transactions t
    where t.related_booking_id = new.id
      and t.user_id = new.host_id
      and t.type = 'booking_earned';

  -- 受け取っていないものからは引かない(規約 第8条の2第2項)。
  -- 明細も作らない(gross 0 の行は applied_rate が計算できない)
  if v_base <= 0 then
    return new;
  end if;

  v_r := public._booking_fee_coins(
    new.host_id, new.guest_id, new.id, v_base, new.scheduled_at,
    coalesce(new.confirmed_at, new.created_at, now()));
  v_fee := (v_r ->> 'fee')::int;

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (new.host_id, -v_fee, 'platform_fee', new.id, 'booking_fee');
  end if;

  insert into public.platform_fees (
    host_id, kind, booking_id, gross_coins, fee_coins, net_coins, applied_rate, repeat_discounted)
  values (
    new.host_id, 'booking', new.id, v_base, v_fee, v_base - v_fee,
    round(v_fee::numeric / v_base, 4), (v_r ->> 'repeat')::boolean);

  return new;
end;
$$;

comment on function public._apply_booking_fee() is
  '予約が completed になったときに利用料を引く。0103で基準額を「予約の全額」から'
  '「この予約でホストに実際に付与された額(booking_earned の合計)」に改めた。'
  '一部返還つきの保留解除で、受け取っていない分にまで課金していたため(規約 第8条の2第2項)。';

revoke all on function public._apply_booking_fee() from public, anon, authenticated;
