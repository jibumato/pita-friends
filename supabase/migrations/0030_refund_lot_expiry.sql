-- ============================================================
-- 返金コインの有効期限を「当初の発行日」基準に改める
-- 論点: docs/legal/lawyer-review-round2-request.md Q18
-- 記録: docs/legal/lawyer-review-answers-round2-draft.md 「未対応の実装課題」
-- ------------------------------------------------------------
-- 【適用しないこと】このマイグレーションは弁護士Q18の回答を待って適用する。
--   回答前に適用してはいけない(修正方法の妥当性が未確認のため)。
-- ------------------------------------------------------------
-- 何が問題だったか:
--   0018 の _refund_coin_lots() は、キャンセル返金を coin_expiry_from(now())
--   の「新しい6か月ロット」として戻していた。関数コメントは「各ロットが6か月
--   未満だから適用除外の趣旨に反しない」と整理していたが、これは誤り。
--   資金決済法4条2号の基準は「発行の日から6月内に限り使用できる」ことなので、
--   購入から5か月後に予約・キャンセルすると、当初の発行日からの通算で
--   約11か月使えるコインが生まれ、除外要件を正面から割ってしまう。
--
-- どう直すか:
--   消費したロットの当初の有効期限を coin_lot_consumptions に記録しておき、
--   返金時は「新しい期限」ではなく「記録した当初の期限」でロットを戻す。
--   これにより、返金を経ても1枚のコインの寿命は発行日から6か月未満に収まる。
--
--   返金時点で当初の期限を過ぎていた分は、戻さずに失効させる(戻すと結局
--   6か月を超えて使えてしまうため)。呼び出し側は返金額の全額をキャッシュ残高に
--   足しているので、失効分は本関数側で差し引き、'expire' の取引履歴を残す。
--
-- ギフト(send_gift)を対象に含めない理由:
--   ギフトは規約第7条の2 3項で取消し・返金ができないため、戻す経路が無い。
--   また受領側は earned_balance(換金専用の別勘定)への加算で coin_lots を
--   作らないため、そもそも期限の起算が発生しない。
-- ============================================================

-- ------------------------------------------------------------
-- coin_lot_consumptions: どのロット(=どの期限)を何コイン消費したかの記録
-- ------------------------------------------------------------
create table public.coin_lot_consumptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  booking_id uuid references public.bookings (id) on delete cascade,
  kind text not null check (kind in ('paid', 'bonus')),
  -- 消費したロットが本来もっていた有効期限。返金時はこの値で戻す
  expires_at timestamptz not null,
  coins int not null check (coins > 0),
  -- 返金で戻した時刻。二重返金の防止に使う
  restored_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table public.coin_lot_consumptions is
  '予約で消費したコインロットの内訳(当初の有効期限つき)。キャンセル返金時に、新しい期限ではなく当初の期限で戻すために使う。資金決済法の適用除外(発行日から6月内)を維持するための記録。';

alter table public.coin_lot_consumptions enable row level security;

create policy "coin_lot_consumptions_select_own"
  on public.coin_lot_consumptions for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは SECURITY DEFINER 関数経由のみ(INSERT/UPDATEポリシーは作らない)。

create index coin_lot_consumptions_refund_idx
  on public.coin_lot_consumptions (booking_id)
  where restored_at is null;

-- ------------------------------------------------------------
-- _consume_coin_lots_tracked: 消費しつつ、消費した内訳を返す。
-- 返り値: [{"expires_at": "...", "coins": n}, ...] (期限が近い順)
-- 0018 の _consume_coin_lots と消費の挙動は同一。内訳を返す点だけが違う。
-- ------------------------------------------------------------
create function public._consume_coin_lots_tracked(p_user_id uuid, p_kind text, p_amount int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_left int := p_amount;
  v_lot record;
  v_take int;
  v_out jsonb := '[]'::jsonb;
begin
  if p_amount <= 0 then
    return v_out;
  end if;
  for v_lot in
    select id, remaining, expires_at from public.coin_lots
    where user_id = p_user_id and kind = p_kind and remaining > 0
    order by expires_at asc
    for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.remaining, v_left);
    update public.coin_lots set remaining = remaining - v_take where id = v_lot.id;
    v_out := v_out || jsonb_build_object('expires_at', v_lot.expires_at, 'coins', v_take);
    v_left := v_left - v_take;
  end loop;
  return v_out;
end;
$$;

revoke all on function public._consume_coin_lots_tracked(uuid, text, int) from public;

-- ------------------------------------------------------------
-- _record_lot_consumptions: 内訳を予約に紐づけて保存する。
-- (消費はロット確保のため予約行の作成前に行うので、記録は作成後に呼ぶ)
-- ------------------------------------------------------------
create function public._record_lot_consumptions(
  p_user_id uuid,
  p_booking_id uuid,
  p_kind text,
  p_breakdown jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
begin
  if p_breakdown is null then
    return;
  end if;
  for v_row in select * from jsonb_array_elements(p_breakdown)
  loop
    insert into public.coin_lot_consumptions (user_id, booking_id, kind, expires_at, coins)
    values (
      p_user_id,
      p_booking_id,
      p_kind,
      (v_row ->> 'expires_at')::timestamptz,
      (v_row ->> 'coins')::int
    );
  end loop;
end;
$$;

revoke all on function public._record_lot_consumptions(uuid, uuid, text, jsonb) from public;

-- ------------------------------------------------------------
-- _refund_coin_lots_for_booking: 当初の期限でロットを戻す。
--
-- ・記録がある分  … 記録された当初の期限でロットを作る
-- ・期限切れの分  … 戻さず、呼び出し側が足したキャッシュ残高から差し引く
-- ・記録が無い場合 … 0030 より前に作られた予約向けのフォールバック。
--                    予約作成時刻を基準に期限を引き直す。
--                    (本サービスは未公開・コイン販売未開始のため、
--                     本番に該当データは存在しない想定)
-- ------------------------------------------------------------
create function public._refund_coin_lots_for_booking(p_booking_id uuid)
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
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null then
    return;
  end if;

  for v_rec in
    select id, kind, expires_at, coins
    from public.coin_lot_consumptions
    where booking_id = p_booking_id and restored_at is null
    for update
  loop
    v_found := true;
    if v_rec.expires_at > now() then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, v_rec.kind, v_rec.coins, v_rec.expires_at);
    elsif v_rec.kind = 'paid' then
      v_lapsed_paid := v_lapsed_paid + v_rec.coins;
    else
      v_lapsed_bonus := v_lapsed_bonus + v_rec.coins;
    end if;
    update public.coin_lot_consumptions set restored_at = now() where id = v_rec.id;
  end loop;

  -- 0030 より前の予約(記録なし)。予約作成時刻を基準に引き直す。
  if not v_found then
    if v_booking.paid_coins > 0 then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, 'paid', v_booking.paid_coins,
                public.coin_expiry_from(v_booking.created_at));
    end if;
    if v_booking.bonus_coins > 0 then
      insert into public.coin_lots (user_id, kind, remaining, expires_at)
        values (v_booking.guest_id, 'bonus', v_booking.bonus_coins,
                public.coin_expiry_from(v_booking.created_at));
    end if;
    return;
  end if;

  -- 返金までに当初の期限を過ぎていた分は戻さない。
  -- 呼び出し側は全額をキャッシュ残高に足しているのでここで差し引く。
  if v_lapsed_paid > 0 or v_lapsed_bonus > 0 then
    update public.coin_wallets
      set balance = greatest(0, balance - v_lapsed_paid),
          bonus_balance = greatest(0, bonus_balance - v_lapsed_bonus)
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, -(v_lapsed_paid + v_lapsed_bonus), 'expire',
              p_booking_id, 'refund_lapsed');
  end if;
end;
$$;

revoke all on function public._refund_coin_lots_for_booking(uuid) from public;

-- ------------------------------------------------------------
-- create_booking: 消費の内訳を記録するようにする(0018版がベース)
-- ------------------------------------------------------------
create or replace function public.create_booking(p_host_id uuid, p_duration_minutes int)
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

  -- 消費しつつ、どの期限のロットをいくつ使ったかを受け取る
  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested')
  returning id into v_booking_id;

  -- 予約行ができてから内訳を紐づける
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

-- ------------------------------------------------------------
-- 返金する3関数を、当初の期限で戻す版に差し替える(0018版がベース)。
-- 変更点は _refund_coin_lots(...) → _refund_coin_lots_for_booking(...) のみ。
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
  v_refund boolean;
  v_new_status text;
  v_other uuid;
  v_name text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');
    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額返却されました', p_booking_id);
    return;
  end if;

  if v_booking.status <> 'confirmed' then raise exception 'BOOKING_NOT_CANCELLABLE'; end if;

  if v_uid = v_booking.host_id then
    v_refund := true; v_new_status := 'cancelled_by_host';
    update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_refund := now() < (v_booking.scheduled_at - interval '1 hour');
    if not v_refund then
      update public.profile_trust_stats set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  update public.bookings set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund then
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins, bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_booking');
  else
    update public.coin_wallets set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case when v_refund then 'コインは全額再付与されました'
         else '開始1時間前以降のキャンセルのため、コインはホストの報酬として確定しました' end,
    p_booking_id);
end;
$$;

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
  perform public._refund_coin_lots_for_booking(p_booking_id);
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'decline_booking');

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.guest_id, 'booking_cancelled',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を辞退しました',
    'コインは全額返却されました', p_booking_id);
end;
$$;

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
    perform public._refund_coin_lots_for_booking(v_booking.id);
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

-- 旧ヘルパーは呼び出し元が無くなったため削除する(誤って使わないように)
drop function if exists public._refund_coin_lots(uuid, int, int);
