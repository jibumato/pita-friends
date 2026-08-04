-- ============================================================
-- 0102: 遊んだあとのキャンセルは、完了と同じ扱いにする
-- ------------------------------------------------------------
-- ■ 見つかった穴
--   プレイ中(開始後)の画面には「✓ プレイ完了」と「キャンセルする」が
--   **両方出ている**。開始後は返還0%なので、**ゲストの支払額はどちらでも
--   同じ**。違うのは次の2点だけだった。
--
--     ✓ プレイ完了 … ピタメイトの手取り 予約額−20%(利用料) / 記録なし
--     キャンセル   … ピタメイトの手取り **予約額まるごと** / ゲストに
--                    **ドタキャン記録**
--
--   つまり「完了じゃなくてキャンセル押しといて」と言うだけで手取りが
--   20%増える。ゲストは支払額が同じなので断る理由がなく、
--   **運営だけが損をして、しかも記録上は「キャンセルされた予約」なので
--   気づけない。** ゲストには事実と違うドタキャン記録が残る。
--
-- ■ いちばんまずいのは、利用料の取りこぼしではない
--   キャンセル分に利用料を課さないのは、規約 第8条の2第7項が
--   「**役務の対価ではなく機会損失の補償**」と整理しているからだった。
--   2時間遊んだあとの「キャンセル」で満額を渡すなら、それは補償ではなく
--   **完全に役務の対価**。この取引が積み上がると、
--     ・消費者契約法9条の「平均的な損害」の主張
--     ・補償金を不課税として扱う整理
--   のどちらも、後から説明できなくなる。**条文が事実と食い違う。**
--
-- ■ 直し方
--   「実際に遊んだか」は既に記録がある。チェックイン(0050)は
--   ボタンだけでなく**メッセージを1通送るだけでも自動で立つ**ので、
--   本当に遊んだ組はほぼ確実に両方立っている。
--
--     両方チェックイン済み → 完了と同じ: 利用料を控除し、ドタキャン記録なし
--     片方だけ / 未チェックイン → 従来どおり(補償として満額・記録あり)
--
--   **片方だけでは足りない。** ゲストが開始時刻に一言つぶやいた一方で
--   ピタメイトが現れなかった場合まで「遊んだ」ことにすると、
--   無断欠席の側の救済(0050)と食い違う。
--
--   キャンセルのボタン自体は残す。プレイ中に気まずくなって途中で
--   切りたい場面の出口を塞がないため。
--
-- ■ 当月累計(GMV)には足さない
--   `host_monthly_ticket_gmv` は `status = 'completed'` だけを数えている。
--   ここは変えない。数えないと累計が小さいまま = **率が下がりにくい**ので、
--   ピタメイトに有利にはならず、抜け道にならない。
--   (逆に「キャンセルを積んで率を下げる」ことはできない)
-- ============================================================

-- ------------------------------------------------------------
-- 1. 手数料の計算を、トリガーの外から呼べる形にする
--
-- 0091 の `_apply_booking_fee()` の中身をそのまま関数にしただけ。
-- 違いは基準額を引数で受けること(キャンセルでは予約額ではなく
-- **実際にピタメイトへ渡る額**が基準になる)。
-- ------------------------------------------------------------
create or replace function public._booking_fee_coins(
  p_host_id uuid,
  p_guest_id uuid,
  p_booking_id uuid,
  p_gross_coins int,
  p_scheduled_at timestamptz,
  -- 0091: **予約が「成立」した時点。**確定した時点ではない(規約第8条の2第5項)
  p_agreed_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_repeat_discount constant numeric := 0.03;
  c_rate_floor constant numeric := 0.10;
  v_gmv_before int;
  v_gmv_after int;
  v_base_fee numeric;
  v_rate numeric;
  v_discount numeric := 0;
  v_is_repeat boolean := false;
  v_fee int;
begin
  if p_gross_coins is null or p_gross_coins <= 0 then
    return jsonb_build_object('fee', 0, 'repeat', false);
  end if;

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(p_host_id, p_scheduled_at, p_booking_id);
  v_gmv_after := v_gmv_before + p_gross_coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after, p_agreed_at)
              - public.host_progressive_fee(v_gmv_before, p_agreed_at);
  v_rate := v_base_fee / p_gross_coins;

  -- 指名リピート: 同じゲストと過去に完了した予約があるか
  select exists (
    select 1 from public.bookings b
    where b.host_id = p_host_id
      and b.guest_id = p_guest_id
      and b.status = 'completed'
      and b.id <> p_booking_id
      and b.scheduled_at < p_scheduled_at
  ) into v_is_repeat;

  if v_is_repeat then
    v_discount := least(c_repeat_discount, greatest(0, v_rate - c_rate_floor)) * p_gross_coins;
  end if;

  v_fee := least(greatest(0, round(v_base_fee - v_discount))::int, p_gross_coins);

  return jsonb_build_object('fee', v_fee, 'repeat', v_is_repeat);
end;
$$;

comment on function public._booking_fee_coins(uuid, uuid, uuid, int, timestamptz, timestamptz) is
  '予約の利用料(コイン)を計算する。基準額を引数で受けるので、完了(予約額)にも'
  '遊んだあとのキャンセル(実際に渡る額)にも同じ式を使える(0102)。';

revoke all on function public._booking_fee_coins(uuid, uuid, uuid, int, timestamptz, timestamptz)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. 完了時のトリガーは、計算だけを上の関数に委ねる
--    **挙動は 0091 と同じ。** `tests/40_host_fees` がそれを見ている
-- ------------------------------------------------------------
create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r jsonb;
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  v_r := public._booking_fee_coins(
    new.host_id, new.guest_id, new.id, new.coins, new.scheduled_at,
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
    new.host_id, 'booking', new.id, new.coins, v_fee, new.coins - v_fee,
    round(v_fee::numeric / new.coins, 4), (v_r ->> 'repeat')::boolean);

  return new;
end;
$$;

revoke all on function public._apply_booking_fee() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. cancel_booking
--
-- 0085 の定義を出発点にして、足したのは
--   ・v_played(両方チェックイン済みか)の判定
--   ・遊んでいたらドタキャン記録をつけない
--   ・遊んでいたら渡す額から利用料を引く
-- の3点だけ。**他は 0085 のまま。**
-- (関数を作り直すときは最新の定義から始めること)
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
  -- 0102: **実際に遊んだか。** 両方がチェックイン済みなら「遊んだ」と見る
  v_played boolean;
  v_fee_r jsonb;
  v_fee int := 0;
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

  -- 0102: チェックインはメッセージ1通でも自動で立つ(0050)ので、
  -- 本当に遊んだ組はほぼ確実に両方立っている
  v_played := v_booking.guest_checked_in_at is not null
          and v_booking.host_checked_in_at is not null;

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
    -- 全額戻らなかった場合だけドタキャンとして記録する。
    -- 0102: **ただし実際に遊んだあとなら、それはドタキャンではない。**
    -- 「早く終わろう」の合意でキャンセルを押した人に、事実と違う記録を残さない
    if v_pct < 100 and not v_played then
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

    -- 0102: **遊んだあとなら、これは機会損失の補償ではなく役務の対価。**
    -- 完了と同じように利用料を引く(規約 第8条の2第7項が適用されるのは
    -- 「遊んでいないのに渡る分」だけ)。
    -- 基準は予約額ではなく**実際に渡る額**。長い予約では没収の上限(0048)が
    -- 効いて、予約額より少ないことがある
    if v_played then
      v_fee_r := public._booking_fee_coins(
        v_booking.host_id, v_booking.guest_id, v_booking.id, v_to_host,
        v_booking.scheduled_at,
        coalesce(v_booking.confirmed_at, v_booking.created_at, now()));
      v_fee := (v_fee_r ->> 'fee')::int;

      if v_fee > 0 then
        update public.coin_wallets
          set earned_balance = greatest(0, earned_balance - v_fee)
          where user_id = v_booking.host_id;
        insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
          values (v_booking.host_id, -v_fee, 'platform_fee', p_booking_id, 'cancel_played_fee');
      end if;

      insert into public.platform_fees (
        host_id, kind, booking_id, gross_coins, fee_coins, net_coins,
        applied_rate, repeat_discounted)
      values (
        v_booking.host_id, 'booking', p_booking_id, v_to_host, v_fee, v_to_host - v_fee,
        round(v_fee::numeric / v_to_host, 4), (v_fee_r ->> 'repeat')::boolean);
    end if;
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約を'
      || case when v_played then '終了しました' else 'キャンセルしました' end,
    case when v_refund_total >= v_booking.coins then 'コインは全額戻りました'
         when v_refund_total = 0 then 'コインは報酬として確定しました'
         else v_refund_total || 'コインが戻り、' || v_to_host || 'コインが報酬として確定しました' end,
    p_booking_id);
end;
$$;

comment on function public.cancel_booking(uuid, text) is
  'キャンセル。0102で、両方がチェックイン済み(=実際に遊んだ)あとのキャンセルは'
  '完了と同じ扱いにした(利用料を控除し、ドタキャン記録をつけない)。'
  '規約 第8条の2第7項の「機会損失の補償」が当てはまるのは、遊んでいないのに渡る分だけ。';

revoke all on function public.cancel_booking(uuid, text) from public, anon;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 4. 画面の見積りに「遊んだあとか」を足す
--
-- 確認ダイアログは「ドタキャンとして記録されます」と書いていたが、
-- 0102 で遊んだあとは記録されなくなった。**判定を画面で作り直さない。**
-- サーバが1か所で持っている答えをそのまま渡す。
--
-- 0048 の定義に played を足しただけで、金額の計算には触っていない。
-- ------------------------------------------------------------
create or replace function public.my_booking_refund_quote(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
  v_pct int;
  v_refund int;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;

  v_pct := public.booking_refund_percent(v_b.status, v_b.confirmed_at, v_b.scheduled_at, now());
  v_refund := public.booking_refund_coins(
    v_b.coins, v_b.duration_minutes, v_pct, v_b.scheduled_at, now());

  return jsonb_build_object(
    'coins', v_b.coins,
    'refund_coins', v_refund,
    'forfeit_coins', v_b.coins - v_refund,
    'base_percent', v_pct,
    -- 上限が効いたか(効いていれば、率から期待される額より多く戻る)
    'capped', v_refund > round(v_b.coins * v_pct / 100.0),
    -- 0102: 両方チェックイン済み = 実際に遊んだ。
    -- このときキャンセルは完了と同じ扱いになる(ドタキャン記録がつかない)
    'played', v_b.guest_checked_in_at is not null and v_b.host_checked_in_at is not null
  );
end;
$$;

revoke all on function public.my_booking_refund_quote(uuid) from public, anon;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;
