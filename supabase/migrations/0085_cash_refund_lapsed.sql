-- ============================================================
-- 0085: ゲストに帰責の無い返還で消滅した分を、金銭で返金する(G8)
--
-- 規約 第9条5の3(2026-07-31 新設):
--   「前項にかかわらず、ゲストの責めに帰すべき事由によらずに返還が
--     生じた場合(ピタメイト都合のキャンセル、無断欠席、大幅な遅刻、
--     システム障害により役務が提供されなかった場合その他これらに
--     準ずる場合をいいます)において、前項により返還されるコインが
--     消滅するときは、当社は、消滅した数に相当する額を金銭により
--     返金します。」
--
-- ■ なぜ要るか
--   コインの返還は**当初の取得日**を基準に期限を引き継ぐ(第9条5の2・0030)。
--   これは資金決済法の適用除外(6か月未満)を崩さないための設計だが、
--   その結果**返還の時点で期限が過ぎていると、コインは戻らない。**
--
--   ゲスト都合ならそれでよい。だが**ピタメイトがドタキャンした場合まで
--   「役務を受けられず、対価も戻らない」**のは、弁護士の言葉で
--   「消費者契約法10条無効の典型的な標的であり、事案として世に出れば
--   最も批判を浴びる類型」(総評4・論点7)。
--
-- ■ どこで捕まえるか
--   消滅した数を知っているのは `_refund_coin_lots_for_booking` **だけ**。
--   呼び出し側は「何枚戻すか」しか渡しておらず、そのうち何枚が期限切れで
--   消えたかは中でしか分からない。**だから記録もここで行う。**
--
--   引数に「誰の責めか」を足し、**呼び出し側が必ず明示する**形にした。
--   既定は 'guest_fault'(＝返金しない)。**判断を書き忘れたときに
--   お金が出ていく側に倒れない**ようにするため。
--
-- ■ 1コイン = 1円
--   全パックで coins = price_yen(0016)。上乗せ(ボーナス)も廃止済み(0083)。
--   したがって消滅した**有償**コインの数が、そのまま円になる。
--   **無償コインは対価を受け取っていないので0円**。返金しない。
--   この前提が崩れたらテスト 13_cash_refund_lapsed.sql が落ちる。
--
-- ■ 自動で振り込まない
--   記録するところまでを自動にし、**支払は運営が実行する。**
--   金銭の払い出しは、コインの付け替えと違って取り消せない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 返金債務の台帳
-- ------------------------------------------------------------
create table if not exists public.cash_refunds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  booking_id uuid references public.bookings (id),
  -- 消滅したコインの数と、それに相当する円
  coins int not null check (coins > 0),
  amount_yen int not null check (amount_yen > 0),
  -- 'host_fault'(ピタメイト都合) / 'host_no_show'(無断欠席) /
  -- 'support'(申出対応で当社が返還を認めた) / 'system'(システム障害)
  cause text not null,
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  note text
);

create index if not exists cash_refunds_pending_idx
  on public.cash_refunds (created_at) where status = 'pending';
create index if not exists cash_refunds_user_idx
  on public.cash_refunds (user_id, created_at desc);

comment on table public.cash_refunds is
  '規約第9条5の3。ゲスト無帰責の返還で期限切れにより消滅したコインの、金銭返金の債務。支払は運営が手動で実行する。';

alter table public.cash_refunds enable row level security;

-- 本人は自分の分だけ読める。書き込みは SECURITY DEFINER 関数だけ
create policy "cash_refunds_select_own"
  on public.cash_refunds for select
  to authenticated
  using (user_id = auth.uid());

create policy "cash_refunds_select_admin"
  on public.cash_refunds for select
  to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- ------------------------------------------------------------
-- 2. 返還の中身を知っている場所に、記録を足す
--
-- ⚠️ 既存の3引数版は**落としてから**作り直す。
--    引数に既定値を付けて増やすと、3引数の呼び出しが
--    (uuid,int,int) と (uuid,int,int,text default) の両方に一致して
--    「function is not unique」になる。
-- ------------------------------------------------------------
drop function if exists public._refund_coin_lots_for_booking(uuid, int, int);

create function public._refund_coin_lots_for_booking(
  p_booking_id uuid,
  p_paid int default null,
  p_bonus int default null,
  -- **呼び出し側が必ず書くこと。** 既定は返金しない側
  p_cause text default 'guest_fault'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_rec record;
  v_found boolean := false;
  v_lapsed_paid int := 0;
  v_lapsed_bonus int := 0;
  v_left_paid int;
  v_left_bonus int;
  v_take int;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null then
    return;
  end if;

  v_left_paid := coalesce(p_paid, v_booking.paid_coins);
  v_left_bonus := coalesce(p_bonus, v_booking.bonus_coins);

  -- 期限の近いものから戻す(消費したときと同じ順序)
  for v_rec in
    select id, kind, expires_at, coins
    from public.coin_lot_consumptions
    where booking_id = p_booking_id and restored_at is null
    order by expires_at
    for update
  loop
    v_found := true;

    if v_rec.kind = 'paid' then
      v_take := least(v_left_paid, v_rec.coins);
      v_left_paid := v_left_paid - v_take;
    else
      v_take := least(v_left_bonus, v_rec.coins);
      v_left_bonus := v_left_bonus - v_take;
    end if;

    if v_take > 0 then
      if v_rec.expires_at > now() then
        insert into public.coin_lots (user_id, kind, remaining, expires_at)
          values (v_booking.guest_id, v_rec.kind, v_take, v_rec.expires_at);
      elsif v_rec.kind = 'paid' then
        v_lapsed_paid := v_lapsed_paid + v_take;
      else
        v_lapsed_bonus := v_lapsed_bonus + v_take;
      end if;
    end if;

    update public.coin_lot_consumptions set restored_at = now() where id = v_rec.id;
  end loop;

  -- 0030 より前の予約(消費記録なし)。予約作成時刻を基準に引き直す。
  if not v_found then
    if v_left_paid > 0 then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, 'paid', v_left_paid, public.coin_expiry_from(v_booking.created_at));
    end if;
    if v_left_bonus > 0 then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, 'bonus', v_left_bonus, public.coin_expiry_from(v_booking.created_at));
    end if;
  end if;

  -- 当初の期限をすでに過ぎていた分は戻さない。呼び出し側が足したキャッシュ残高から引く。
  if v_lapsed_paid > 0 or v_lapsed_bonus > 0 then
    update public.coin_wallets
      set balance = greatest(0, balance - v_lapsed_paid),
          bonus_balance = greatest(0, bonus_balance - v_lapsed_bonus)
      where user_id = v_booking.guest_id;
    -- **有償と無償を1行にまとめない(0085で変更)。**
    -- 会計は有償だけ前受金を取り崩す(無償は前受金を立てていない)。
    -- 合算した1行だと、仕訳側で内訳を復元できない
    if v_lapsed_paid > 0 then
      insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
        values (v_booking.guest_id, -v_lapsed_paid, 'expire', p_booking_id,
                'refund_lapsed_paid');
    end if;
    if v_lapsed_bonus > 0 then
      insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
        values (v_booking.guest_id, -v_lapsed_bonus, 'expire', p_booking_id,
                'refund_lapsed_bonus');
    end if;
  end if;

  -- ----------------------------------------------------------
  -- 規約 第9条5の3: ゲスト無帰責なら、消滅した分を金銭で返す
  --
  -- **無償コインは対象外。** 対価を受け取っていないので、
  -- 「消滅した数に相当する額」は0円になる。
  -- ----------------------------------------------------------
  if v_lapsed_paid > 0
     and p_cause in ('host_fault', 'host_no_show', 'support', 'system') then
    insert into public.cash_refunds (user_id, booking_id, coins, amount_yen, cause)
      values (v_booking.guest_id, p_booking_id, v_lapsed_paid, v_lapsed_paid, p_cause);

    insert into public.notifications (user_id, type, title, body, related_id)
      values (v_booking.guest_id, 'booking_cancelled',
        '有効期限切れのコイン' || v_lapsed_paid || '枚を返金します',
        'お客様に落ち度のないキャンセルのため、お戻しできなかった'
          || v_lapsed_paid || 'コインに相当する' || v_lapsed_paid
          || '円を、ご登録の方法で返金します。手続の完了までお時間をいただきます。',
        p_booking_id);
  end if;
end;
$$;

comment on function public._refund_coin_lots_for_booking(uuid, int, int, text) is
  '予約の消費ロットを戻す。当初の期限を過ぎた分は戻さず、ゲスト無帰責(p_cause)なら cash_refunds に金銭返金の債務を立てる(規約第9条5の3)。';

revoke all on function public._refund_coin_lots_for_booking(uuid, int, int, text) from public, anon;

-- ------------------------------------------------------------
-- 3. 呼び出し側に「誰の責めか」を書かせる
--
-- 本文は 0048 / 0042 / 0050 のままで、_refund_coin_lots_for_booking の
-- 呼び出しに p_cause を足しただけ。**他は1文字も変えていない。**
-- ------------------------------------------------------------

create or replace function public.cancel_booking(p_booking_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_new_status text;
  v_other uuid;
  v_name text;
  v_pct int;
  v_refund_total int;
  v_refund_paid int;
  v_refund_bonus int;
  v_to_host int;
  -- 0085: 誰の責めによる返還か。ゲスト無帰責なら期限切れ分を金銭で返す
  v_cause text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  -- **取り消したのがどちらかで決まる。** ピタメイト側の取消し・辞退は
  -- 承諾の前後を問わずゲストに落ち度が無い
  v_cause := case when v_uid = v_booking.host_id then 'host_fault' else 'guest_fault' end;

  -- 承諾前の取り消しは、どちらからでも全額返還(従来どおり)
  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id, null, null, v_cause);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');
    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額戻りました', p_booking_id);
    return;
  end if;

  if v_booking.status <> 'confirmed' then raise exception 'BOOKING_NOT_CANCELLABLE'; end if;

  if v_uid = v_booking.host_id then
    -- ピタメイト都合はいつでも全額
    v_pct := 100;
    v_new_status := 'cancelled_by_host';
    update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_pct := public.booking_refund_percent(
      v_booking.status, v_booking.confirmed_at, v_booking.scheduled_at, now());
    -- 全額戻らなかった場合だけドタキャンとして記録する
    if v_pct < 100 then
      update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  -- 返す枚数。没収の上限(0048)を効かせてから、購入コインを先に返す
  v_refund_total := public.booking_refund_coins(
    v_booking.coins, v_booking.duration_minutes, v_pct, v_booking.scheduled_at, now());
  v_refund_paid := least(v_booking.paid_coins, v_refund_total);
  v_refund_bonus := v_refund_total - v_refund_paid;
  v_to_host := v_booking.coins - v_refund_total;

  update public.bookings set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund_total > 0 then
    update public.coin_wallets
      set balance = balance + v_refund_paid, bonus_balance = bonus_balance + v_refund_bonus
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(
      p_booking_id, v_refund_paid, v_refund_bonus, v_cause);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_refund_total, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 一部も戻らない場合でも、消費記録は閉じておく(期限管理のため)
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0, v_cause);
  end if;

  if v_to_host > 0 then
    update public.coin_wallets set earned_balance = earned_balance + v_to_host
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_to_host, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case when v_refund_total >= v_booking.coins then 'コインは全額戻りました'
         when v_refund_total = 0 then 'コインは報酬として確定しました'
         else v_refund_total || 'コインが戻り、' || v_to_host || 'コインが報酬として確定しました' end,
    p_booking_id);
end;
$$;

revoke all on function public.cancel_booking(uuid, text) from public;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- ------------------------------------------------------------
create or replace function public.release_hold_and_refund(
  p_booking_id uuid,
  p_refund_percent int,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
  v_refund_total int;
  v_refund_paid int;
  v_refund_bonus int;
  v_to_host int;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_refund_percent is null or p_refund_percent not between 0 and 100 then
    raise exception 'INVALID_PERCENT';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_b.held_at is null then raise exception 'NOT_HELD'; end if;
  if v_b.status <> 'confirmed' then raise exception 'BOOKING_NOT_HELDABLE'; end if;

  -- 返す枚数。購入コインから先に返す(キャンセルと同じ順序)
  v_refund_total := round(v_b.coins * p_refund_percent / 100.0);
  v_refund_paid := least(v_b.paid_coins, v_refund_total);
  v_refund_bonus := v_refund_total - v_refund_paid;
  v_to_host := v_b.coins - v_refund_total;

  update public.bookings
    set status = 'completed', held_at = null, hold_reason = null,
        cancel_reason = coalesce(p_note, cancel_reason)
    where id = p_booking_id;

  if v_refund_total > 0 then
    update public.coin_wallets
      set balance = balance + v_refund_paid, bonus_balance = bonus_balance + v_refund_bonus
      where user_id = v_b.guest_id;
    -- 申出を認めて返還する場面。**運営が「返す」と判断した以上、
    -- ゲストの落ち度による返還ではない**(規約第9条4項・4の2)
    perform public._refund_coin_lots_for_booking(
      p_booking_id, v_refund_paid, v_refund_bonus, 'support');
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_b.guest_id, v_refund_total, 'refund', p_booking_id, 'release_hold_and_refund');
  else
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0, 'guest_fault');
  end if;

  if v_to_host > 0 then
    update public.coin_wallets set earned_balance = earned_balance + v_to_host
      where user_id = v_b.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_b.host_id, v_to_host, 'booking_earned', p_booking_id, 'release_hold_and_refund');
  end if;

  update public.promises set status = 'completed' where booking_id = p_booking_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values
    (v_b.guest_id, 'booking_completed', 'お申し出の対応が完了しました',
     case when v_refund_total > 0 then v_refund_total || 'コインを返還しました'
          else '確認の結果、返還は行いませんでした' end, p_booking_id),
    (v_b.host_id, 'booking_completed', '保留の対応が完了しました',
     case when v_to_host > 0 then v_to_host || 'コインが報酬として確定しました'
          else 'お申し出を認めたため、この予約の報酬は確定しませんでした' end, p_booking_id);
end;
$$;

revoke all on function public.release_hold_and_refund(uuid, int, text) from public;
grant execute on function public.release_hold_and_refund(uuid, int, text) to authenticated;

-- ------------------------------------------------------------
create or replace function public.auto_resolve_no_show_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
  v_hours int;
  v_count int := 0;
begin
  select no_show_resolve_hours into v_hours from public.platform_pricing where id = 1;

  for v_b in
    select id, guest_id, host_id, coins, paid_coins, bonus_coins
    from public.bookings
    where status = 'confirmed'
      and hold_reason = 'no_show'
      and held_at is not null
      and host_checked_in_at is null
      and held_at < now() - make_interval(hours => v_hours)
    for update skip locked
  loop
    update public.bookings
      set status = 'no_show_host', cancelled_at = now(),
          cancel_reason = 'auto_no_show', held_at = null, hold_reason = null
      where id = v_b.id;

    -- 全額返還。ロットの当初期限を引き継ぐ(0030)
    update public.coin_wallets
      set balance = balance + v_b.paid_coins,
          bonus_balance = bonus_balance + v_b.bonus_coins
      where user_id = v_b.guest_id;
    -- **無断欠席はゲストに落ち度が無い。**期限切れ分は金銭で返す(0085)
    perform public._refund_coin_lots_for_booking(v_b.id, null, null, 'host_no_show');
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_b.guest_id, v_b.coins, 'refund', v_b.id, 'auto_no_show');

    update public.profile_trust_stats
      set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_b.host_id;

    update public.promises set status = 'cancelled' where booking_id = v_b.id;

    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.guest_id, 'booking_no_show',
      '無断欠席として処理しました',
      v_b.coins || 'コインを全額お戻ししました。', v_b.id);

    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.host_id, 'booking_no_show',
      '無断欠席として処理されました',
      '開始の確認ができないまま時間が経過したため、コインはゲストへ返還されました。'
        || 'ドタキャン記録に反映されます。',
      v_b.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.auto_resolve_no_show_bookings() from public;

-- ------------------------------------------------------------
-- 承諾前にピタメイトが辞退した場合。**ゲストは何もしていない**
-- ------------------------------------------------------------
create or replace function public.decline_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_host_name text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid <> v_booking.host_id then raise exception 'ONLY_HOST_CAN_DECLINE'; end if;
  if v_booking.status <> 'requested' then raise exception 'BOOKING_NOT_REQUESTED'; end if;

  update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = p_booking_id;
  update public.coin_wallets
    set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
    where user_id = v_booking.guest_id;
  perform public._refund_coin_lots_for_booking(p_booking_id, null, null, 'host_fault');
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'decline_booking');

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.guest_id, 'booking_cancelled',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を辞退しました',
    'コインは全額返却されました', p_booking_id);
end;
$$;

revoke all on function public.decline_booking(uuid) from public;
grant execute on function public.decline_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- 24時間응答が無くて流れた場合。**応答しなかったのはピタメイト側**
-- ------------------------------------------------------------
create or replace function public.expire_stale_booking_requests()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_count int := 0;
begin
  for v_booking in
    select * from public.bookings
    where status = 'requested' and created_at + interval '24 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = v_booking.id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(v_booking.id, null, null, 'host_fault');
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', v_booking.id, 'expire_request');
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_booking.guest_id, 'booking_cancelled', '予約リクエストが期限切れになりました',
      'ホストからの応答がなかったため、コインを全額返却しました', v_booking.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.expire_stale_booking_requests() from public;

-- ------------------------------------------------------------
-- 4. 運営コンソール: 未払いの返金と、支払済みの記録
-- ------------------------------------------------------------
create or replace function public.admin_pending_cash_refunds()
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  booking_id uuid,
  coins int,
  amount_yen int,
  cause text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  return query
  select r.id, r.user_id, p.nickname, r.booking_id,
         r.coins, r.amount_yen, r.cause, r.created_at
  from public.cash_refunds r
  left join public.profiles p on p.id = r.user_id
  where r.status = 'pending'
  order by r.created_at;
end;
$$;

revoke all on function public.admin_pending_cash_refunds() from public, anon;
grant execute on function public.admin_pending_cash_refunds() to authenticated;

create or replace function public.admin_resolve_cash_refund(
  p_id uuid,
  p_status text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_status not in ('paid', 'rejected') then
    raise exception 'INVALID_STATUS';
  end if;
  -- **理由なしに断らせない。** 返金しない判断は説明できる形で残す
  if p_status = 'rejected' and coalesce(btrim(p_note), '') = '' then
    raise exception 'NOTE_REQUIRED';
  end if;

  update public.cash_refunds
    set status = p_status, resolved_at = now(), note = p_note
    where id = p_id and status = 'pending';
  if not found then
    raise exception 'NOT_PENDING';
  end if;

  perform public._log_admin_action('resolve_cash_refund', p_id, p_status || ' ' || coalesce(p_note, ''));
end;
$$;

revoke all on function public.admin_resolve_cash_refund(uuid, text, text) from public, anon;
grant execute on function public.admin_resolve_cash_refund(uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- 5. 本人が自分の返金予定を見るための関数
-- ------------------------------------------------------------
create or replace function public.my_cash_refunds()
returns table (
  id uuid,
  coins int,
  amount_yen int,
  cause text,
  status text,
  created_at timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select r.id, r.coins, r.amount_yen, r.cause, r.status, r.created_at
  from public.cash_refunds r
  where r.user_id = auth.uid()
  order by r.created_at desc
$$;

revoke all on function public.my_cash_refunds() from public, anon;
grant execute on function public.my_cash_refunds() to authenticated;

-- ------------------------------------------------------------
-- 6. 会計仕訳に、失効の取り崩しと金銭返金を足す
--
-- **J18 は 0079 の取りこぼしの修正でもある。** 返還時に期限切れで
-- 消えた分は、これまでどの仕訳にも出ていなかった。J6 で前受金へ戻した
-- ままになるので、前受金が過大に残り、accounting_journal_check の
-- 突合が合わなくなる(取引が0件だったので顕在化していなかった)。
--
-- 本文は 0079 のままで、末尾に J18〜J21 を足しただけ。
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

  order by 1, 2, 10;
end;
$$;

comment on function public.accounting_journal(date, date) is
  '期間内の取引を会計ソフト取込用の単純仕訳(1行=借方1・貸方1)にして返す(運営のみ)。1コイン=1円。読み取りのみ。Stripeの着金・決済手数料と、経費・按分はここには出ない(明細から別途起票する)。';

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;
