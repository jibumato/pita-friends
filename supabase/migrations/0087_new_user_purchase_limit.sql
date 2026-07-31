-- ============================================================
-- 0087: 新規ユーザーの購入上限と、コインの出所の記録(G11の前半)
--
-- 規約 第8条の6第5項1号:
--   「登録から一定期間内のユーザーについて、1回あたりまたは一定期間
--     あたりの購入額に上限を設けること」
--
-- ■ この上限が守っているのは1類型だけ
--   ①不正利用型 … **3DS2の責任移転**が主防御(第8条の6第4項4号で
--     控除対象からも外している)。上限はほぼ不要
--   ②品質不満型 … 本条の対象外。申出対応(第9条4項)で扱う
--   ③**自作自演型** … 本人が3DSを通すので責任移転が効かない。
--     **ここだけが上限の守備範囲**
--
-- ■ 数値の根拠
--   1アカウントあたりの最大損失 = 期間累計の上限 + チャージバック手数料
--   開業時は取引実績がゼロで「正常な利用者の分布」から決められないため、
--   保守的に始めてデータが溜まってから緩める。
--
--     対象   登録30日以内、または本人確認未完了、または係争中の異議あり
--     1回    10,000円   (最大パック50,000円の1/5)
--     30日   30,000円   (1件あたり最大損失 約31,500円)
--
--   **数値は規約に書いていない。** 第8条の6第5項が
--   「措置の具体的な数値は、不正防止の目的の範囲で変更することがあります」
--   としてあるので、platform_pricing で後から変えても規約改定にならない。
--
-- ■ 上限は「購入の入口」で見る
--   決済が終わってから弾くと、**代金を受け取ったのにコインを付けない**
--   事故になる。判定は Checkout セッションを作る前に行う。
--
-- ■ コインの出所を記録する(第8条の6第4項1号の前提)
--   条文は控除の対象を「**当該失効した購入から現に充当された**予約および
--   ギフトに係る報酬コイン」に限っている。ところが現在の台帳は
--   ロットが**どの購入で生まれたか**を持たず、消費記録も**どのロットから
--   引いたか**を持っていない。**このままでは条文どおりの特定ができない。**
--   弁護士が「本条項の許容性を支える最大の資産」と呼んだのは
--   ロット単位の追跡なので、その前提をここで満たす。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 数値(運営が後から変えられる場所に置く)
-- ------------------------------------------------------------
alter table public.platform_pricing
  add column if not exists new_user_days int not null default 30,
  add column if not exists new_user_purchase_max_yen int not null default 10000,
  add column if not exists new_user_period_purchase_max_yen int not null default 30000,
  -- 5項2号の換金保留。**列だけ先に置く**(使うのは次の migration)
  add column if not exists new_user_payout_hold_days int not null default 30;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'platform_pricing_new_user_limits_check') then
    alter table public.platform_pricing
      add constraint platform_pricing_new_user_limits_check
      check (new_user_days >= 0
         and new_user_purchase_max_yen > 0
         and new_user_period_purchase_max_yen >= new_user_purchase_max_yen
         -- 条文が「最長30日間」と画しているので、超える値を入れられなくする
         and new_user_payout_hold_days between 0 and 30);
  end if;
end $$;

comment on column public.platform_pricing.new_user_purchase_max_yen is
  '規約第8条の6第5項1号。新規ユーザーの1回あたりの購入上限(円)。';
comment on column public.platform_pricing.new_user_period_purchase_max_yen is
  '規約第8条の6第5項1号。新規ユーザーの一定期間(new_user_days)あたりの購入上限(円)。';
comment on column public.platform_pricing.new_user_payout_hold_days is
  '規約第8条の6第5項2号。条文が最長30日と画しているため、31日以上は入れられない。';

-- ------------------------------------------------------------
-- 2. コインの出所を記録できるようにする
--
-- 既存の行は null のまま(未公開で実データが無い)。
-- **追記専用の台帳(0044)なので、列を足すだけで過去を書き換えない。**
-- ------------------------------------------------------------
alter table public.coin_lots
  add column if not exists purchase_id uuid references public.coin_purchases (id);
alter table public.coin_lot_consumptions
  add column if not exists lot_id uuid references public.coin_lots (id);

create index if not exists coin_lots_purchase_idx
  on public.coin_lots (purchase_id) where purchase_id is not null;
create index if not exists coin_lot_consumptions_lot_idx
  on public.coin_lot_consumptions (lot_id) where lot_id is not null;

comment on column public.coin_lots.purchase_id is
  'このロットを生んだ購入。規約第8条の6第4項1号の「当該失効した購入から現に充当された」を特定するために要る。';
comment on column public.coin_lot_consumptions.lot_id is
  '引いた元のロット。購入→ロット→消費→予約 の鎖をつなぐ。';

-- ------------------------------------------------------------
-- 3. 新規ユーザーかどうかと、残りいくら買えるか
--
-- 「新規」は3つのどれかに当たること。**どれも解除に人手が要らない**
--   ①登録から new_user_days 以内
--   ②本人確認が未完了
--   ③係争中または成立したチャージバックがある
--
-- ③を入れているのは、一度でも異議を出したカードの持ち主に
-- 上限なしで買わせる理由が無いため。②は自作自演の入口を塞ぐ。
-- ------------------------------------------------------------
create or replace function public.purchase_limit_status(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days int;
  v_per int;
  v_period int;
  v_signup timestamptz;
  v_verified boolean;
  v_disputed boolean;
  v_is_new boolean;
  v_spent bigint;
begin
  select new_user_days, new_user_purchase_max_yen, new_user_period_purchase_max_yen
    into v_days, v_per, v_period
  from public.platform_pricing where id = 1;

  -- **登録日時は profiles.created_at を見る。** auth.users は Supabase の
  -- 管理領域で、スキーマがこちらの都合で変わらない保証が無い
  select pr.created_at into v_signup from public.profiles pr where pr.id = p_user_id;
  select coalesce(s.is_verified, false) into v_verified
    from public.profile_trust_stats s where s.user_id = p_user_id;
  select exists (
    select 1 from public.payment_disputes d
    where d.user_id = p_user_id and d.status in ('open', 'lost')
  ) into v_disputed;

  v_is_new :=
       v_signup is null
    or v_signup > now() - make_interval(days => v_days)
    or not coalesce(v_verified, false)
    or coalesce(v_disputed, false);

  -- 期間内の購入額。**サポート料は含めない**(上限はコイン代金にかける)
  select coalesce(sum(p.price_yen), 0) into v_spent
  from public.coin_purchases p
  where p.user_id = p_user_id
    and p.created_at > now() - make_interval(days => v_days);

  return jsonb_build_object(
    'is_new_user', v_is_new,
    'period_days', v_days,
    'per_purchase_max_yen', case when v_is_new then v_per else null end,
    'period_max_yen', case when v_is_new then v_period else null end,
    'spent_yen', v_spent,
    'remaining_yen', case when v_is_new then greatest(0, v_period - v_spent) else null end,
    -- **なぜ上限が付いているかを画面で説明できるようにする。**
    -- 「理由が分からない上限」は問い合わせを生むだけでなく、
    -- 優越的地位の濫用の評価でも説明できない措置になる
    'reason_new_account', v_signup is null or v_signup > now() - make_interval(days => v_days),
    'reason_unverified', not coalesce(v_verified, false),
    'reason_disputed', coalesce(v_disputed, false)
  );
end;
$$;

comment on function public.purchase_limit_status(uuid) is
  '規約第8条の6第5項1号の購入上限の状態。新規ユーザーかどうかと、残りいくら買えるか。';

revoke all on function public.purchase_limit_status(uuid) from public, anon, authenticated;
grant execute on function public.purchase_limit_status(uuid) to service_role;

-- 画面に出すための自分専用の窓口
create or replace function public.my_purchase_limit()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  return public.purchase_limit_status(auth.uid());
end;
$$;

revoke all on function public.my_purchase_limit() from public, anon;
grant execute on function public.my_purchase_limit() to authenticated;

-- ------------------------------------------------------------
-- 4. 買ってよいかの判定(Checkout セッションを作る前に呼ぶ)
--
-- **決済の後で弾かない。** 代金を受け取ってからコインを付けないのは、
-- 上限で防ごうとしている損失より重い事故になる。
-- ------------------------------------------------------------
create or replace function public.check_purchase_allowed(p_user_id uuid, p_price_yen int)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := public.purchase_limit_status(p_user_id);
  v_per int;
  v_remaining bigint;
begin
  if not (v->>'is_new_user')::boolean then
    return jsonb_build_object('allowed', true);
  end if;

  v_per := (v->>'per_purchase_max_yen')::int;
  v_remaining := (v->>'remaining_yen')::bigint;

  if p_price_yen > v_per then
    return jsonb_build_object(
      'allowed', false, 'code', 'PURCHASE_LIMIT_PER',
      'limit_yen', v_per, 'remaining_yen', v_remaining,
      'period_days', (v->>'period_days')::int);
  end if;

  if p_price_yen > v_remaining then
    return jsonb_build_object(
      'allowed', false, 'code', 'PURCHASE_LIMIT_PERIOD',
      'limit_yen', (v->>'period_max_yen')::int, 'remaining_yen', v_remaining,
      'period_days', (v->>'period_days')::int);
  end if;

  return jsonb_build_object('allowed', true, 'remaining_yen', v_remaining);
end;
$$;

comment on function public.check_purchase_allowed(uuid, int) is
  '購入上限に触れないか(規約第8条の6第5項1号)。Checkoutセッションを作る前にEdge Functionから呼ぶ。';

revoke all on function public.check_purchase_allowed(uuid, int) from public, anon, authenticated;
grant execute on function public.check_purchase_allowed(uuid, int) to service_role;

-- ------------------------------------------------------------
-- 5. 付与の側で、ロットに購入を紐づける
--
-- 本文は 0083 のままで、coin_lots の insert に purchase_id を足しただけ。
-- ------------------------------------------------------------
create or replace function public.credit_coins_for_purchase(
  p_user_id uuid,
  p_pack_id text,
  p_coins int,
  p_bonus_coins int,
  p_price_yen int,
  p_session_id text,
  p_payment_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
  v_purchase_id uuid;
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 冪等性: 同じ session を二度処理しない
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  -- 0083: 購入ボーナスは廃止した。**引数は無視する。**
  -- 廃止をまたいだ決済(メタデータに古い値が残っているもの)が届いても、
  -- 有償分だけを付与して処理を続ける。
  if coalesce(p_bonus_coins, 0) <> 0 then
    raise notice '0083: 購入ボーナスは廃止済みのため無視しました(session=%, bonus=%)',
      p_session_id, p_bonus_coins;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent)
    returning id into v_purchase_id;

  update public.coin_wallets
    set balance = balance + p_coins
    where user_id = p_user_id;

  -- 0087: **どの購入で生まれたロットか**を残す。
  -- 規約第8条の6第4項1号の「当該失効した購入から現に充当された」の特定に要る
  insert into public.coin_lots (user_id, kind, remaining, expires_at, purchase_id)
    values (p_user_id, 'paid', p_coins, v_expires, v_purchase_id);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$fn$;

comment on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) is
  'Webhook から呼ぶ冪等なコイン付与(service_role専用)。0083で購入ボーナスを廃止したため、p_bonus_coins は無視する(引数は互換のために残している)。0087でロットに購入を紐づける。';

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- 6. 消費の側で、引いたロットを残す
--
-- 本文は 0030 のままで、内訳に lot_id を1つ足しただけ。
-- **これで 購入 → ロット → 消費 → 予約 の鎖がつながる。**
-- ------------------------------------------------------------
create or replace function public._consume_coin_lots_tracked(p_user_id uuid, p_kind text, p_amount int)
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
    v_out := v_out || jsonb_build_object(
      'expires_at', v_lot.expires_at, 'coins', v_take, 'lot_id', v_lot.id);
    v_left := v_left - v_take;
  end loop;
  return v_out;
end;
$$;

revoke all on function public._consume_coin_lots_tracked(uuid, text, int) from public, anon;

create or replace function public._record_lot_consumptions(
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
    insert into public.coin_lot_consumptions
      (user_id, booking_id, kind, expires_at, coins, lot_id)
    values (
      p_user_id,
      p_booking_id,
      p_kind,
      (v_row ->> 'expires_at')::timestamptz,
      (v_row ->> 'coins')::int,
      -- 0030 に作られた古い内訳には lot_id が無い
      (v_row ->> 'lot_id')::uuid
    );
  end loop;
end;
$$;

revoke all on function public._record_lot_consumptions(uuid, uuid, text, jsonb) from public, anon;
