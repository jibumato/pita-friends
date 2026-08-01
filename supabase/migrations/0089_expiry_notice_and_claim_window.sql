-- ============================================================
-- 0089: 失効の事前通知・残高と期限の表示(G7)と、申出の期間制限(G9)
--
-- ■ G7 — 規約 第7条5の3:
--   「当社は、有効期限が近いコインがある場合、本サービス上での表示
--     その他の方法によりその旨を**事前に通知**します。ユーザーは、
--     本サービス上でコインの**残高および有効期限を確認**できます。」
--
--   有効期限を6か月未満にしているのは資金決済法の適用除外を採るため
--   (第7条5項)。**利用者から見れば「気づかないうちに消える」制度**
--   なので、事前の通知と期限の可視化はセットでないと成り立たない。
--
-- ■ G9 — 規約 第9条4項:
--   「相談は、当該予約のプレイ完了が**確定した日から14日以内**に
--     行うものとします。」
--
--   期限が無いと、報酬が確定して振込まで済んだ後から申出が来る。
--   **控除できるのは未払の報酬だけ**(第8条の6第4項2号と同じ発想)なので、
--   期限を切らないと救済のしようがない場面が生まれる。
--
--   期間の起算点は「プレイ完了が確定した日」＝報酬コインが確定した日。
--   確定前の申出は従来どおりいつでも受ける(**大半はここ**)。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 数値(運営が後から変えられる場所に置く)
-- ------------------------------------------------------------
alter table public.platform_pricing
  add column if not exists expiry_notice_days int not null default 14,
  add column if not exists claim_window_days int not null default 14;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'platform_pricing_notice_window_check') then
    alter table public.platform_pricing
      add constraint platform_pricing_notice_window_check
      check (expiry_notice_days between 1 and 90
         and claim_window_days between 1 and 90);
  end if;
end $$;

comment on column public.platform_pricing.expiry_notice_days is
  '規約第7条5の3。有効期限のこの日数前に事前通知する。';
comment on column public.platform_pricing.claim_window_days is
  '規約第9条4項。プレイ完了の確定からこの日数以内に限り申出を受ける(既定14日)。';

-- ------------------------------------------------------------
-- 2. 同じロットを何度も通知しない
-- ------------------------------------------------------------
alter table public.coin_lots
  add column if not exists expiry_notified_at timestamptz;

comment on column public.coin_lots.expiry_notified_at is
  '失効の事前通知を送った日時(規約第7条5の3)。二重に通知しないための印。';

-- ------------------------------------------------------------
-- 3. 残高と有効期限を画面に出す(第7条5の3 後段)
--
-- **合計だけでは足りない。** 「いつ、何枚消えるか」が分からないと、
-- 使い切る判断ができない。期限ごとにまとめて返す。
-- ------------------------------------------------------------
create or replace function public.my_coin_expiry()
returns table (
  expires_at timestamptz,
  kind text,
  coins int,
  days_left int
)
language sql
stable
security invoker
set search_path = public
as $$
  select l.expires_at,
         l.kind,
         sum(l.remaining)::int as coins,
         greatest(0, extract(day from (l.expires_at - now()))::int) as days_left
  from public.coin_lots l
  where l.user_id = auth.uid() and l.remaining > 0
  group by l.expires_at, l.kind
  order by l.expires_at
$$;

comment on function public.my_coin_expiry() is
  '自分のコインを有効期限ごとにまとめて返す(規約第7条5の3の「残高および有効期限を確認できる」)。';

revoke all on function public.my_coin_expiry() from public, anon;
grant execute on function public.my_coin_expiry() to authenticated;

-- ------------------------------------------------------------
-- 4. 期限が近いコインを事前に通知する
--
-- **失効そのものは expire_coins() が行う。** ここは通知だけで、
-- 残高を1枚も動かさない。動かす処理と知らせる処理を分けておくと、
-- 通知が失敗しても失効が止まらず、逆も起きない。
-- ------------------------------------------------------------
create or replace function public.notify_expiring_coins()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int;
  v_rec record;
  v_count int := 0;
begin
  select expiry_notice_days into v_days from public.platform_pricing where id = 1;

  for v_rec in
    select l.user_id,
           l.expires_at,
           sum(l.remaining)::int as coins,
           array_agg(l.id) as lot_ids
    from public.coin_lots l
    join public.profiles p on p.id = l.user_id
    where l.remaining > 0
      and l.expiry_notified_at is null
      and l.expires_at > now()
      and l.expires_at <= now() + make_interval(days => v_days)
      -- 退会済みには送らない(コインは退会時に消滅している)
      and p.withdrawn_at is null
    group by l.user_id, l.expires_at
  loop
    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system',
      'コイン' || v_rec.coins || '枚の有効期限が近づいています',
      to_char(v_rec.expires_at, 'YYYY年MM月DD日') || 'に'
        || v_rec.coins || 'コインの有効期限が切れます。'
        || '期限を過ぎたコインは消滅し、払い戻しはできません(利用規約 第7条)。'
        || 'コインウォレットで残高と有効期限をご確認いただけます。');

    update public.coin_lots
      set expiry_notified_at = now()
      where id = any (v_rec.lot_ids);

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.notify_expiring_coins() is
  '有効期限が近いコインの事前通知(規約第7条5の3)。残高は動かさない。';

revoke all on function public.notify_expiring_coins() from public, anon;

select cron.schedule('notify-expiring-coins', '9 9 * * *',
  $$select public.notify_expiring_coins()$$);

-- ------------------------------------------------------------
-- 5. 申出は完了確定から14日以内に限る(第9条4項・G9)
--
-- 起算点は「プレイ完了が確定した日」＝報酬コインが確定した日。
-- **確定前の申出はいつでも受ける。**(第9条6項末尾により通報・申出が
-- あれば自動確定は止まるので、実務上の大半はこちら)
-- ------------------------------------------------------------
create or replace function public.hold_booking(p_booking_id uuid, p_reason text default 'claim')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int;
  v_confirmed timestamptz;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_reason not in ('claim', 'manual') then
    raise exception 'INVALID_REASON';
  end if;

  -- 'manual'(運営の職権)は期間の制限を受けない。
  -- 制限されるのは**利用者からの申出**を受けての保留だけ
  if p_reason = 'claim' then
    select claim_window_days into v_days from public.platform_pricing where id = 1;

    select min(t.created_at) into v_confirmed
    from public.coin_transactions t
    where t.related_booking_id = p_booking_id and t.type = 'booking_earned';

    if v_confirmed is not null
       and now() > v_confirmed + make_interval(days => v_days) then
      raise exception 'CLAIM_WINDOW_CLOSED';
    end if;
  end if;

  return public._hold_booking(p_booking_id, p_reason);
end;
$$;

comment on function public.hold_booking(uuid, text) is
  '申出を受けて予約を保留する(運営のみ)。claim は完了確定から claim_window_days 以内に限る(規約第9条4項)。';

revoke all on function public.hold_booking(uuid, text) from public;
grant execute on function public.hold_booking(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 6. 申出を受け付けられるかを、運営コンソールで見えるようにする
--
-- **押してから断られるのは最悪。** 期限切れなら、押す前に分かるようにする。
-- ------------------------------------------------------------
create or replace function public.claim_window_status(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days int;
  v_confirmed timestamptz;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select claim_window_days into v_days from public.platform_pricing where id = 1;
  select min(t.created_at) into v_confirmed
  from public.coin_transactions t
  where t.related_booking_id = p_booking_id and t.type = 'booking_earned';

  return jsonb_build_object(
    'window_days', v_days,
    'confirmed_at', v_confirmed,
    'deadline', case when v_confirmed is null then null
                     else v_confirmed + make_interval(days => v_days) end,
    -- 確定前は期限が始まっていないので受けられる
    'can_accept', v_confirmed is null
                  or now() <= v_confirmed + make_interval(days => v_days)
  );
end;
$$;

revoke all on function public.claim_window_status(uuid) from public, anon;
grant execute on function public.claim_window_status(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. 運営コンソールから操作するための一覧
--
-- **SQL Editor を開かないと運用できない状態にしない。**
-- 0085(返金)と0088(相殺)は、ここまで関数しか無く、画面が無かった。
-- 運営作業は原則としてコンソールから完結させる。
-- ------------------------------------------------------------

-- 相殺を起こせる購入(異議が成立したもの)の一覧
create or replace function public.admin_offsetable_purchases()
returns table (
  purchase_id uuid,
  user_id uuid,
  nickname text,
  price_yen int,
  disputed_at timestamptz,
  candidate_count int,
  candidate_coins int,
  notified_count int
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
  select cp.id,
         cp.user_id,
         pr.nickname,
         cp.price_yen,
         d.created_at,
         coalesce(cand.n, 0)::int,
         coalesce(cand.coins, 0)::int,
         coalesce((select count(*)::int from public.chargeback_offsets o
                   where o.purchase_id = cp.id and o.status <> 'cancelled'), 0)
  from public.coin_purchases cp
  join public.payment_disputes d
    on d.stripe_payment_intent = cp.stripe_payment_intent and d.status = 'lost'
  left join public.profiles pr on pr.id = cp.user_id
  left join lateral (
    select count(*)::int as n, coalesce(sum(v.deductible_coins), 0)::int as coins
    from public.chargeback_offset_preview(cp.id) v
  ) cand on true
  order by d.created_at desc;
end;
$$;

revoke all on function public.admin_offsetable_purchases() from public, anon;
grant execute on function public.admin_offsetable_purchases() to authenticated;

-- 予告済み・実行済みの相殺の一覧
create or replace function public.admin_chargeback_offsets()
returns table (
  id uuid,
  host_id uuid,
  nickname text,
  booking_id uuid,
  gift_id uuid,
  coins int,
  status text,
  notified_at timestamptz,
  objection_deadline timestamptz,
  objected_at timestamptz,
  objection_note text,
  executed_coins int,
  unpaid_earned int
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
  select o.id, o.host_id, p.nickname, o.booking_id, o.gift_id, o.coins,
         o.status, o.notified_at, o.objection_deadline, o.objected_at,
         o.objection_note, o.executed_coins,
         -- **実際に引ける枚数を画面に出す。** 未払が足りなければ
         -- そこまでしか引けない(第8条の6第4項2号)
         greatest(0,
           coalesce(w.earned_balance, 0)
           - coalesce((select sum(py.coins)::int from public.payouts py
                       where py.user_id = o.host_id and py.status = 'pending'), 0)
         )::int
  from public.chargeback_offsets o
  left join public.profiles p on p.id = o.host_id
  left join public.coin_wallets w on w.user_id = o.host_id
  where o.status <> 'cancelled'
  order by (o.status = 'notified') desc, o.notified_at desc;
end;
$$;

revoke all on function public.admin_chargeback_offsets() from public, anon;
grant execute on function public.admin_chargeback_offsets() to authenticated;
