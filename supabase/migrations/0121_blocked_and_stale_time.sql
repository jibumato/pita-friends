-- ============================================================
-- 0121: 想定外の順序で操作したときに、黙って間違う3つを塞ぐ
--
-- `supabase/tests/41_unexpected_order.sql` を書いて見つけたもの。
-- **どれも例外が出ずに、頼んでいない結果が確定していた。**
--
-- ------------------------------------------------------------
-- ① ブロックしても予約できた（既存の穴・いちばん広い）
--
--   `0116` は「ブロック(0008) → 相手への影響: 予約もトークも不可」と
--   表で明記している。**ところが実装に検査が無かった。**
--     ・`create_booking` … ブロックを一切見ていない
--     ・`messages` の RLS … 約束の当事者かどうかだけ。ブロックを見ていない
--   ブロックを見ていたのは `create_booking_from_board`(0113) だけで、
--   板を経由しない経路（さがす・お気に入り・再予約・リクエスト）は素通り。
--
--   RLS で見えないので**ふつうには起きない**が、
--     ・一緒に遊んだ相手をブロックしても、既存のトークからは送れる
--     ・リクエストに応じてもらったあとにブロックされても、予約が通る
--   の2つは実際に到達する。**41 のテスト7で、通ることを確認した。**
--
--   ここでは判定を**予約とメッセージの入口そのもの**に置く。
--   画面側で隠すのは補助で、守っているのはここ。
--
-- ------------------------------------------------------------
-- ② 応じる時刻を変えられると、ゲストは画面と違う時刻で成立した
--
--   ホストが 20:00 で応じる → ゲストの画面に 20:00 が出る
--   → ホストが 22:00 に変える → ゲストが「予約する」を押す
--   → **22:00 で成立する。**
--
--   `create_booking_from_request` が時刻を引数で受け取らず、
--   応答の行をその場で読み直していたため。エラーは出ないので、
--   ゲストは 20:00 のつもりで 22:00 の約束を買うことになる。
--   **金銭を伴う約束が、見ていた内容と違う条件で確定する。**
--
--   見ていた時刻を引数で受け取り、食い違ったら止める。
--   （楽観ロック。**時刻の権威はサーバのまま**で、
--     「画面が古い」ことだけを検出する）
--
-- ------------------------------------------------------------
-- ③ ブロックの解除は、予約を復活させない
--   ブロックを外せば、また予約できる。ここでは状態を持たない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. create_booking にブロック検査を足す
--
--    ⚠️ **本体は適用済みDBから取り出したものをそのまま使い、
--       ブロック検査の分だけを足している。** 記憶で書き直すと、
--       有効期限順の充当(0082)や安全手数料の扱いを落とす
--       （0119 で実際にやって、テスト28 が拾った）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_booking(p_host_id uuid, p_duration_minutes integer, p_policy_version text, p_scheduled_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_verified boolean;
  v_coins int;
  v_list_coins int;
  v_discount int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_lead int;
  v_start timestamptz;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  -- 0121: ブロック関係があれば予約させない。
  -- **0116 が「ブロック＝予約もトークも不可」と書いているのに、
  --   ここには検査が無かった。** create_booking_from_board(0113)だけが
  --   独自に見ていたので、板を経由しない経路は全部素通りだった。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_guest_id and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_guest_id)
  ) then
    raise exception 'BLOCKED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_lead) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hs.hourly_rate, hs.is_host into v_hourly_rate, v_is_host
  from public.host_settings hs where hs.user_id = p_host_id for share;
  if not coalesce(v_is_host, false) or v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  select pts.is_verified into v_verified
  from public.profile_trust_stats pts where pts.user_id = p_host_id;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  v_start := coalesce(p_scheduled_at, now());

  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 常連への先行予約(0057)。開始まで遠い枠は、一緒に遊んだことのある人だけ。
  if not public.slot_open_to(p_host_id, v_guest_id, v_start) then
    raise exception 'REGULARS_FIRST';
  end if;

  perform public._lock_booking_slots(v_guest_id, p_host_id);

  if public._booking_slot_conflict(p_host_id, v_start, p_duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(v_guest_id, v_start, p_duration_minutes) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;
  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 有償を先に使い切るのではなく、**有効期限の早いロットから**充当する。
  -- 同一期限内では有償が先。詳細は 0082 の冒頭を参照。
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_guest_id, v_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, policy_version, policy_agreed_at,
    list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
  )
  returning id into v_booking_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$function$;
comment on function public.create_booking(uuid, integer, text, timestamptz) is
  'ピタメイトの予約を申し込み、コインを確保する。0121でブロック検査を追加'
  '（0116 が「ブロック＝予約もトークも不可」と書いているのに、検査が無かった）。';

revoke all on function public.create_booking(uuid, integer, text, timestamptz) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 2. メッセージにもブロック検査を足す
--
--    RLS の with check ではなくトリガーにする。理由は 0113・0081 と同じで、
--    **エラー名で理由を返せる**ため。みまもり同意の検査(0074)と同じ場所に置く。
-- ------------------------------------------------------------
create or replace function public._messages_require_not_blocked()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
begin
  select case when pr.user_a = new.sender_id then pr.user_b else pr.user_a end
    into v_other
  from public.promises pr where pr.id = new.promise_id;

  if v_other is null then
    return new; -- 相手が特定できない行は、ここでは判断しない
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = new.sender_id and b.blocked_id = v_other)
       or (b.blocker_id = v_other and b.blocked_id = new.sender_id)
  ) then
    raise exception 'BLOCKED';
  end if;
  return new;
end;
$$;

comment on function public._messages_require_not_blocked() is
  'ブロック関係があればメッセージを送れない(0121)。'
  '**既存のトークでも止める**——一緒に遊んだあとにブロックした相手から'
  '送り続けられると、ブロックの意味が無くなる。';

revoke all on function public._messages_require_not_blocked() from public, anon;

drop trigger if exists messages_require_not_blocked on public.messages;
create trigger messages_require_not_blocked
  before insert on public.messages
  for each row execute function public._messages_require_not_blocked();

-- ------------------------------------------------------------
-- 3. リクエストからの予約に「見ていた時刻」を渡させる
--
--    引数を足すので、**古い3引数版は落とす。** 残すと画面側が
--    古いほうを呼び続けられてしまい、直したことにならない
--    （0119 で declare_residency の2引数版を落としたのと同じ理由）。
-- ------------------------------------------------------------
drop function if exists public.create_booking_from_request(uuid, uuid, text);

create or replace function public.create_booking_from_request(
  p_request_id uuid,
  p_host_id uuid,
  p_policy_version text,
  p_expected_starts_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_res public.guest_request_responses;
  v_booking_id uuid;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.guest_id <> v_uid then
    raise exception 'NOT_MY_REQUEST';
  end if;
  if v_req.status <> 'open' then
    raise exception 'REQUEST_NOT_OPEN';
  end if;

  select * into v_res from public.guest_request_responses
  where request_id = p_request_id and host_id = p_host_id;
  if v_res.id is null then
    raise exception 'RESPONSE_NOT_FOUND';
  end if;

  -- ★0121: 画面に出ていた時刻と、いまの応答の時刻が食い違っていたら止める。
  --   ホストは応じたあとに時刻を言い直せる(on conflict do update)。
  --   ここを見ないと、**ゲストは 20:00 のつもりで 22:00 の約束を買う。**
  --   null のときは検査しない（古い画面からの呼び出しを壊さないため。
  --   画面側は必ず渡す）
  if p_expected_starts_at is not null and v_res.starts_at <> p_expected_starts_at then
    raise exception 'RESPONSE_TIME_CHANGED';
  end if;

  -- ★create_booking を先に通す。ここで status を先に変えると、
  --   host_is_open_at が open のリクエストしか見ないので、
  --   自分で開けた枠を自分で閉じてから予約することになる
  v_booking_id := public.create_booking(
    p_host_id,
    v_req.duration_minutes,
    p_policy_version,
    v_res.starts_at
  );

  update public.bookings
    set from_guest_request_id = p_request_id
    where id = v_booking_id;

  update public.guest_requests
    set status = 'matched', closed_at = now()
    where id = p_request_id;

  -- 応じてくれた他の人に、決まったことを知らせる。
  -- **開けていた枠は同時に閉じている**ので、そのことも書く
  for v_other in
    select r.host_id from public.guest_request_responses r
    where r.request_id = p_request_id and r.host_id <> p_host_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストは他の方で決まりました',
      v_req.game || '・応じていただいた時間の枠は閉じました。ありがとうございました',
      p_request_id
    );
  end loop;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_request(uuid, uuid, text, timestamptz) is
  'リクエストに応じた相手を予約する(0120、0121で p_expected_starts_at を追加)。'
  '画面に出ていた時刻と食い違っていたら RESPONSE_TIME_CHANGED で止める'
  '——ホストは応じたあとに時刻を言い直せるので、見ていた時刻と違う約束が成立しうる。';

revoke all on function public.create_booking_from_request(uuid, uuid, text, timestamptz) from public, anon;
grant execute on function public.create_booking_from_request(uuid, uuid, text, timestamptz) to authenticated;
