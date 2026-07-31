-- ============================================================
-- 0088: 相殺の対象特定・通知・実行と、新規ユーザー原資の換金保留(G11後半)
--
-- 規約 第8条の6第3項・第4項・第5項2号。
--
-- ■ 条文がやってよいと言っている範囲は、かなり狭い
--   3項  控除できるのは「**当該コインから充当された部分に限り**」、
--        かつ「**未払の**報酬コイン」から
--   4項1号 対象は「当該失効した購入から**現に充当された**予約およびギフト」
--   4項2号 **振込済みの金銭は請求しない**
--   4項3号 **控除の前に通知し、異議を述べる機会を与える**
--   4項4号 本人認証が成立し当社が損失を負担しない取引は対象外
--
--   弁護士の言葉:「**この構成で説明できない類型——役務の品質への不満を
--   理由とするもの等——にまで及ぼせば、片面的なリスク転嫁条項となり
--   許容性は急落する**」。だから実装も、広く取れる作りにしない。
--
-- ■ 4項4号は「異議が成立した購入だけを対象にする」ことで満たす
--   3DSの認証結果を持っていなくても、**当社が現に損失を負担した
--   (dispute が lost になった)購入だけ**を起点にすれば、
--   「損失を負担しないこととなった取引」は自然に外れる。
--   持っていない情報で判定するより、確実で説明しやすい。
--
-- ■ 自動で引かない
--   通知 → 異議の機会(7日) → 運営が実行、の3段。
--   **控除は他人の報酬を減らす操作なので、cron で走らせない。**
-- ============================================================

-- ------------------------------------------------------------
-- 1. ギフトも出所をたどれるようにする
--
-- 条文は控除の対象に**ギフトを含めている**が、send_gift は追跡しない
-- ほうの消費関数を呼んでいたため、ギフト → ロット → 購入 がたどれなかった。
-- ------------------------------------------------------------
alter table public.coin_lot_consumptions
  add column if not exists gift_id uuid references public.gifts (id);

create index if not exists coin_lot_consumptions_gift_idx
  on public.coin_lot_consumptions (gift_id) where gift_id is not null;

comment on column public.coin_lot_consumptions.gift_id is
  'ギフトで消費した場合の相手。規約第8条の6第4項1号がギフトも対象にしているため要る。';

create or replace function public._record_gift_lot_consumptions(
  p_user_id uuid,
  p_gift_id uuid,
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
  if p_breakdown is null then return; end if;
  for v_row in select * from jsonb_array_elements(p_breakdown)
  loop
    insert into public.coin_lot_consumptions
      (user_id, booking_id, gift_id, kind, expires_at, coins, lot_id)
    values (
      p_user_id, null, p_gift_id, 'paid',
      (v_row ->> 'expires_at')::timestamptz,
      (v_row ->> 'coins')::int,
      (v_row ->> 'lot_id')::uuid
    );
  end loop;
end;
$$;

revoke all on function public._record_gift_lot_consumptions(uuid, uuid, jsonb) from public, anon;

-- ------------------------------------------------------------
-- 1-b. 取引の種別に 'chargeback_offset' を足す
--
-- **既存の種別に寄せない。** 相殺は返金でも失効でもなく、
-- 会計上も別の仕訳(預り金の取り崩し)になる。
-- ------------------------------------------------------------
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus', 'booking_earned',
    'payout', 'expire', 'gift_sent', 'gift_received', 'platform_fee',
    'withdrawal', 'chargeback_offset'));

-- ------------------------------------------------------------
-- 2. 相殺の台帳
-- ------------------------------------------------------------
create table if not exists public.chargeback_offsets (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.coin_purchases (id),
  -- 控除を受けるピタメイト
  host_id uuid not null references auth.users (id) on delete cascade,
  booking_id uuid references public.bookings (id),
  gift_id uuid references public.gifts (id),
  -- 当該取引のうち、失効した購入から充当された報酬コイン
  coins int not null check (coins > 0),
  status text not null default 'notified'
    check (status in ('notified', 'executed', 'cancelled')),
  notified_at timestamptz not null default now(),
  -- 異議を述べる機会(第8条の6第4項3号)
  objection_deadline timestamptz not null,
  objected_at timestamptz,
  objection_note text,
  executed_at timestamptz,
  executed_coins int,
  note text,
  -- 同じ取引を二重に控除しない
  constraint chargeback_offsets_once
    unique (purchase_id, booking_id, gift_id)
);

create index if not exists chargeback_offsets_host_idx
  on public.chargeback_offsets (host_id, status);

comment on table public.chargeback_offsets is
  '規約第8条の6第3項・第4項の相殺。購入の失効から現に充当された取引ごとに1行。通知→異議の機会→運営の実行、の3段。';

alter table public.chargeback_offsets enable row level security;

-- 控除される本人は見られる。**見えないまま減らされるのが最悪**
create policy "chargeback_offsets_select_own"
  on public.chargeback_offsets for select
  to authenticated
  using (host_id = auth.uid());

create policy "chargeback_offsets_select_admin"
  on public.chargeback_offsets for select
  to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- ------------------------------------------------------------
-- 3. 対象の特定(第8条の6第4項1号)
--
-- 「当該失効した購入から**現に充当された**予約およびギフト」を、
-- 購入 → ロット → 消費 → 予約/ギフト の鎖からそのまま引く。
--
-- **返してよいのは充当された分だけ。** 予約の報酬総額ではない。
-- 1つの予約が複数の購入から充当されることがあるため、
-- 消費記録の coins(そのロットから引いた枚数)を上限にする。
-- ------------------------------------------------------------
create or replace function public.chargeback_offset_preview(p_purchase_id uuid)
returns table (
  host_id uuid,
  nickname text,
  booking_id uuid,
  gift_id uuid,
  funded_coins int,
  host_earned_coins int,
  deductible_coins int,
  already_offset boolean
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
  with funded as (
    select c.booking_id, c.gift_id, sum(c.coins)::int as funded
    from public.coin_lot_consumptions c
    join public.coin_lots l on l.id = c.lot_id
    where l.purchase_id = p_purchase_id
      -- **返還済み(restored_at)は充当が巻き戻っているので対象外**
      and c.restored_at is null
    group by c.booking_id, c.gift_id
  ),
  rows as (
    -- 予約: 報酬として確定した分だけが控除の対象(3項)
    select b.host_id,
           f.booking_id,
           null::uuid as gift_id,
           f.funded,
           -- **利用料を引いた後の、実際に渡った枚数。**
           -- 報酬確定は総額で入り(J8)、利用料は別行で控除される(J10)。
           -- 総額で引くと、当社の取り分まで相手から取り返すことになる
           coalesce((
             select sum(t.amount)::int from public.coin_transactions t
             where t.related_booking_id = b.id and t.type = 'booking_earned'
           ), 0)
           - coalesce((
             select sum(pf.fee_coins)::int from public.platform_fees pf
             where pf.booking_id = b.id and pf.kind = 'booking'
           ), 0) as earned
    from funded f
    join public.bookings b on b.id = f.booking_id
    where f.booking_id is not null

    union all

    -- ギフト: 受領した枚数がそのまま報酬コインになる
    select g.receiver_id as host_id,
           null::uuid as booking_id,
           f.gift_id,
           f.funded,
           g.coins
           - coalesce((
             select sum(pf.fee_coins)::int from public.platform_fees pf
             where pf.gift_id = g.id and pf.kind = 'gift'
           ), 0) as earned
    from funded f
    join public.gifts g on g.id = f.gift_id
    where f.gift_id is not null
  )
  select r.host_id,
         p.nickname,
         r.booking_id,
         r.gift_id,
         r.funded,
         r.earned,
         -- **充当された分と、実際に報酬になった分の小さいほう。**
         -- 利用料を引いた後の報酬しか渡っていないので、
         -- 充当額をそのまま引くと当社の取り分まで相手から取ることになる
         least(r.funded, r.earned) as deductible,
         exists (
           select 1 from public.chargeback_offsets o
           where o.purchase_id = p_purchase_id
             and o.booking_id is not distinct from r.booking_id
             and o.gift_id is not distinct from r.gift_id
             and o.status <> 'cancelled'
         ) as already
  from rows r
  left join public.profiles p on p.id = r.host_id
  where least(r.funded, r.earned) > 0
  order by r.host_id;
end;
$$;

revoke all on function public.chargeback_offset_preview(uuid) from public, anon;
grant execute on function public.chargeback_offset_preview(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4. 通知して、異議の機会を与える(第8条の6第4項3号)
--
-- **ここでは1コインも引かない。** 引くのは異議期間が過ぎてから。
-- 起点は「異議が成立した購入」に限る(4項4号)。
-- ------------------------------------------------------------
create or replace function public.chargeback_offset_notify(
  p_purchase_id uuid,
  p_objection_days int default 7
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_deadline timestamptz;
  v_count int := 0;
  v_yen int;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_objection_days < 3 then
    -- 3日を切ると「機会を与えた」と言いにくい
    raise exception 'OBJECTION_PERIOD_TOO_SHORT';
  end if;

  -- 第8条の6第4項4号。**当社が現に損失を負担した購入だけ**を起点にする。
  -- 本人認証が成立して損失が移った取引は、そもそもここに来ない
  if not exists (
    select 1 from public.coin_purchases cp
    join public.payment_disputes d
      on d.stripe_payment_intent = cp.stripe_payment_intent
    where cp.id = p_purchase_id and d.status = 'lost'
  ) then
    raise exception 'PURCHASE_NOT_LOST';
  end if;

  v_deadline := now() + make_interval(days => p_objection_days);

  for v_rec in select * from public.chargeback_offset_preview(p_purchase_id)
  loop
    if v_rec.already_offset then
      continue;
    end if;

    insert into public.chargeback_offsets
      (purchase_id, host_id, booking_id, gift_id, coins, objection_deadline)
    values (p_purchase_id, v_rec.host_id, v_rec.booking_id, v_rec.gift_id,
            v_rec.deductible_coins, v_deadline);

    v_yen := v_rec.deductible_coins;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_rec.host_id, 'system',
      '報酬コインの控除についてのお知らせ',
      'お客様の決済が取り消されたため、その決済で支払われた'
        || v_rec.deductible_coins || 'コイン分について、未払の報酬コインからの'
        || '控除を予定しています(利用規約 第8条の6)。'
        || to_char(v_deadline, 'YYYY年MM月DD日')
        || 'までにお心当たりのない点があれば、お問い合わせ窓口までご連絡ください。'
        || '既にお振込みが完了した分を請求することはありません。',
      coalesce(v_rec.booking_id, v_rec.gift_id));

    v_count := v_count + 1;
  end loop;

  perform public._log_admin_action('chargeback_offset_notify', p_purchase_id,
    v_count || '件に控除を予告');
  return v_count;
end;
$$;

revoke all on function public.chargeback_offset_notify(uuid, int) from public, anon;
grant execute on function public.chargeback_offset_notify(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 5. 異議(本人が述べる)
-- ------------------------------------------------------------
create or replace function public.object_to_chargeback_offset(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'NOTE_REQUIRED';
  end if;
  update public.chargeback_offsets
    set objected_at = now(), objection_note = p_note
    where id = p_id and host_id = auth.uid() and status = 'notified';
  if not found then
    raise exception 'NOT_OBJECTABLE';
  end if;
end;
$$;

revoke all on function public.object_to_chargeback_offset(uuid, text) from public, anon;
grant execute on function public.object_to_chargeback_offset(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 6. 実行(運営)
--
-- ・異議期間が過ぎていること
-- ・異議が出ているなら、運営が個別に判断してから(強制はできない)
-- ・**未払の報酬コインからのみ**(第8条の6第3項・4項2号)
-- ------------------------------------------------------------
create or replace function public.chargeback_offset_execute(p_id uuid, p_note text default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_o public.chargeback_offsets;
  v_available int;
  v_take int;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_o from public.chargeback_offsets where id = p_id for update;
  if v_o.id is null then raise exception 'NOT_FOUND'; end if;
  if v_o.status <> 'notified' then raise exception 'NOT_PENDING'; end if;
  if now() < v_o.objection_deadline then
    raise exception 'OBJECTION_PERIOD_OPEN';
  end if;
  if v_o.objected_at is not null and coalesce(btrim(p_note), '') = '' then
    -- 異議が出ているのに理由なしで押し切らせない
    raise exception 'NOTE_REQUIRED_AFTER_OBJECTION';
  end if;

  -- **未払の報酬コイン。** 申請中(pending)の換金は既に手元を離れかけて
  -- いるので当てにしない。振込済みは4項2号により請求しない
  select coalesce(w.earned_balance, 0)
       - coalesce((select sum(p.coins) from public.payouts p
                   where p.user_id = v_o.host_id and p.status = 'pending'), 0)
    into v_available
  from public.coin_wallets w where w.user_id = v_o.host_id;

  v_take := least(v_o.coins, greatest(0, coalesce(v_available, 0)));

  if v_take > 0 then
    update public.coin_wallets
      set earned_balance = earned_balance - v_take
      where user_id = v_o.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_o.host_id, -v_take, 'chargeback_offset', v_o.booking_id,
              'chargeback_offset:' || v_o.id::text);
  end if;

  update public.chargeback_offsets
    set status = 'executed', executed_at = now(), executed_coins = v_take, note = p_note
    where id = p_id;

  insert into public.notifications (user_id, type, title, body)
  values (v_o.host_id, 'system', '報酬コインの控除を行いました',
    v_take || 'コインを未払の報酬コインから控除しました(利用規約 第8条の6)。'
      || case when v_take < v_o.coins
           then '未払残高が不足していたため、控除しきれなかった分の請求は行いません。'
           else '' end);

  perform public._log_admin_action('chargeback_offset_execute', p_id,
    v_take || 'コインを控除 ' || coalesce(p_note, ''));
  return v_take;
end;
$$;

revoke all on function public.chargeback_offset_execute(uuid, text) from public, anon;
grant execute on function public.chargeback_offset_execute(uuid, text) to authenticated;

create or replace function public.chargeback_offset_cancel(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'NOTE_REQUIRED';
  end if;
  update public.chargeback_offsets
    set status = 'cancelled', note = p_note
    where id = p_id and status = 'notified';
  if not found then raise exception 'NOT_PENDING'; end if;

  perform public._log_admin_action('chargeback_offset_cancel', p_id, p_note);
end;
$$;

revoke all on function public.chargeback_offset_cancel(uuid, text) from public, anon;
grant execute on function public.chargeback_offset_cancel(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 7. 新規ユーザーを原資とする報酬の換金保留(第8条の6第5項2号)
--
-- 条文:「登録から一定期間内のユーザーによる購入を原資とする報酬コインに
--       ついて、**換金の申請から最長30日間**、換金を保留すること」
--
-- **申請そのものは止めない。** 止めるのは振込。申請を拒むと
-- 「換金できない」外形になり、離脱の自由の議論に触れる。
-- ------------------------------------------------------------
alter table public.payouts
  add column if not exists hold_until timestamptz;

comment on column public.payouts.hold_until is
  '規約第8条の6第5項2号。新規ユーザーの購入を原資とする報酬が含まれる場合、この日時まで振込を保留する。';

create or replace function public._payouts_set_risk_hold()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int;
  v_hold_days int;
  v_risky boolean;
begin
  select new_user_days, new_user_payout_hold_days into v_days, v_hold_days
  from public.platform_pricing where id = 1;

  if coalesce(v_hold_days, 0) <= 0 then
    return new;
  end if;

  -- **この人の未払報酬に、新規ユーザーの購入を原資とする分が混ざっているか。**
  -- 混ざっていれば、その申請ごと保留する(枚数で切り分けると、
  -- どの枚が誰の原資かという答えの無い問いになる)
  select exists (
    select 1
    from public.coin_lot_consumptions c
    join public.coin_lots l on l.id = c.lot_id
    join public.coin_purchases cp on cp.id = l.purchase_id
    join public.profiles pr on pr.id = cp.user_id
    left join public.bookings b on b.id = c.booking_id
    left join public.gifts g on g.id = c.gift_id
    where c.restored_at is null
      and coalesce(b.host_id, g.receiver_id) = new.user_id
      -- 購入の時点で新規だったか
      and cp.created_at < pr.created_at + make_interval(days => v_days)
      -- 保留期間の中にある購入だけを見る(古い分は既に過ぎている)
      and cp.created_at > now() - make_interval(days => v_hold_days)
  ) into v_risky;

  if coalesce(v_risky, false) then
    new.hold_until := now() + make_interval(days => v_hold_days);
  end if;
  return new;
end;
$$;

revoke all on function public._payouts_set_risk_hold() from public, anon;

drop trigger if exists payouts_set_risk_hold on public.payouts;
create trigger payouts_set_risk_hold
  before insert on public.payouts
  for each row execute function public._payouts_set_risk_hold();

-- 保留中は振込済みにできない。**運用の手が滑っても止まるようにする**
create or replace function public._payouts_block_paid_while_held()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'paid' and old.status <> 'paid'
     and new.hold_until is not null and now() < new.hold_until then
    raise exception 'PAYOUT_ON_RISK_HOLD';
  end if;
  return new;
end;
$$;

revoke all on function public._payouts_block_paid_while_held() from public, anon;

drop trigger if exists payouts_block_paid_while_held on public.payouts;
create trigger payouts_block_paid_while_held
  before update on public.payouts
  for each row execute function public._payouts_block_paid_while_held();

-- ------------------------------------------------------------
-- 8. send_gift を追跡する消費に切り替える
--
-- 本文は 0022 のままで、消費の1行を追跡版に変え、
-- ギフトの行ができた直後に消費記録を書くようにしただけ。
-- ------------------------------------------------------------
create or replace function public.send_gift(
  p_promise_id uuid,
  p_coins int,
  p_message text default null,
  p_device_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gift_lots jsonb;
  c_max_per_tx    constant int := 50000;
  c_max_per_day   constant int := 50000;
  c_max_per_month constant int := 200000;
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_last_purchase timestamptz;
  v_sum_day int;
  v_sum_month int;
  v_ip_flag boolean;
  v_gift_id uuid;
  v_sender_name text;
  v_msg text;
  v_body text;
begin
  if v_sender is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < 10 or p_coins > c_max_per_tx then
    raise exception 'INVALID_AMOUNT';
  end if;

  select * into v_promise from public.promises where id = p_promise_id;
  if v_promise.id is null then
    raise exception 'THREAD_NOT_FOUND';
  end if;
  if v_sender not in (v_promise.user_a, v_promise.user_b) then
    raise exception 'FORBIDDEN';
  end if;

  v_receiver := case when v_sender = v_promise.user_a then v_promise.user_b else v_promise.user_a end;

  -- 送り主の端末を記録(以降の共有判定に使う)
  if p_device_id is not null and char_length(p_device_id) between 8 and 128 then
    insert into public.user_devices (user_id, device_id)
      values (v_sender, p_device_id)
    on conflict (user_id, device_id) do update
      set last_seen_at = now(), uses = public.user_devices.uses + 1;
  end if;

  -- ブロック関係では贈れない
  if exists (
    select 1 from public.blocks
    where (blocker_id = v_sender and blocked_id = v_receiver)
       or (blocker_id = v_receiver and blocked_id = v_sender)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 【同一端末の自己取引を遮断】(端末一致はほぼ同一人物なので拒否)
  if exists (
    select 1
    from public.user_devices d1
    join public.user_devices d2 on d1.device_id = d2.device_id
    where d1.user_id = v_sender and d2.user_id = v_receiver
  ) then
    raise exception 'SAME_DEVICE_FORBIDDEN';
  end if;

  -- 【付随謝礼】実際に一緒に遊んだ相手(=完了した予約が1回以上ある相手)にのみ贈れる
  if not exists (
    select 1 from public.bookings
    where status = 'completed'
      and ((guest_id = v_sender and host_id = v_receiver)
        or (guest_id = v_receiver and host_id = v_sender))
  ) then
    raise exception 'NO_COMPLETED_PLAY';
  end if;

  -- 【相互送金禁止】
  if exists (
    select 1 from public.gifts where sender_id = v_receiver and receiver_id = v_sender
  ) then
    raise exception 'MUTUAL_GIFT_FORBIDDEN';
  end if;

  -- 【チャージ直後禁止】最後のコイン購入から24時間は送金不可
  select max(created_at) into v_last_purchase from public.coin_purchases where user_id = v_sender;
  if v_last_purchase is not null and v_last_purchase > now() - interval '24 hours' then
    raise exception 'RECENT_PURCHASE_COOLDOWN';
  end if;

  -- 【上限】直近24時間・直近30日の送金合計
  select coalesce(sum(coins), 0) into v_sum_day
    from public.gifts where sender_id = v_sender and created_at > now() - interval '1 day';
  select coalesce(sum(coins), 0) into v_sum_month
    from public.gifts where sender_id = v_sender and created_at > now() - interval '30 days';
  if v_sum_day + p_coins > c_max_per_day then
    raise exception 'DAILY_LIMIT';
  end if;
  if v_sum_month + p_coins > c_max_per_month then
    raise exception 'MONTHLY_LIMIT';
  end if;

  -- 【IP共有の検知】遮断はしない。調査用フラグを立てるだけ。
  select exists (
    select 1
    from public.user_ips a
    join public.user_ips b on a.ip = b.ip
    where a.user_id = v_sender and b.user_id = v_receiver
  ) into v_ip_flag;

  -- 原資は有償の購入コイン(balance)のみ
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  -- 0088: **追跡する側で消費する。** ギフト → ロット → 購入 がたどれないと、
  -- 規約第8条の6第4項1号の「現に充当された…ギフト」を特定できない
  v_gift_lots := public._consume_coin_lots_tracked(v_sender, 'paid', p_coins);

  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message, sender_device_id, ip_flagged)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg, p_device_id, coalesce(v_ip_flag, false))
    returning id into v_gift_id;

  -- ギフトの行ができてから消費記録を書く(gift_id を入れるため)
  perform public._record_gift_lot_consumptions(v_sender, v_gift_id, v_gift_lots);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_sender, -p_coins, 'gift_sent', 'gift:' || v_gift_id);
  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_receiver, p_coins, 'gift_received', 'gift:' || v_gift_id);

  v_body := '🎁 ' || p_coins || 'コインのありがとうギフトを贈りました';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんからありがとうギフトが届きました',
    p_coins || 'コインを受け取りました(受領から7日間は換金できません)'
      || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

revoke all on function public.send_gift(uuid, int, text, text) from public;
grant execute on function public.send_gift(uuid, int, text, text) to authenticated;

-- ------------------------------------------------------------
-- 9. 会計仕訳に相殺(J24)を足す
--
-- **足さないと預り金が過大に残る。** 0079のJ16・0085のJ18と同じ形の
-- 取りこぼしを作らないため、台帳を動かしたら必ず仕訳も足す。
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

  union all

  -- ------------------------------------------------------------
  -- J22 退会によるコイン消滅(有償分) — 0086
  --   第6条の2第3項。返金しないので前受金を取り崩して雑収入にする。
  --   無償分(withdraw_bonus)は前受金を立てていないので仕訳なし。
  -- ------------------------------------------------------------
  select t.created_at::date, 'コイン失効'::text,
         '前受金'::text, 'コイン'::text,
         '雑収入'::text, 'コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         '退会によるコイン消滅(有償・不課税)'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'withdraw_paid' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J23 退会後90日を過ぎた報酬コインの消滅 — 0086
  --   ピタメイトへの**預り金**が、支払わなくてよくなる。
  --   第6条の2第4項。90日という猶予を置いたうえでの消滅なので、
  --   債務免除益として雑収入に振り替える。
  -- ------------------------------------------------------------
  select t.created_at::date, '報酬失効'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '雑収入'::text, '報酬コイン失効益'::text,
         (-t.amount)::bigint, '対象外'::text,
         '退会から90日経過による報酬コインの消滅(不課税)'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note = 'withdraw_earned_expired' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J24 チャージバック清算による相殺(規約第8条の6第3項・0088)
  --   ピタメイトへの**預り金が減る**。購入が遡って無効になった以上、
  --   その原資から生じた報酬の支払債務も基礎を失う、という整理。
  --   当社が負担した返金の一部が回収されるので、相手科目は雑収入。
  -- ------------------------------------------------------------
  select t.created_at::date, '相殺'::text,
         '預り金'::text, 'ピタメイト報酬'::text,
         '雑収入'::text, 'チャージバック清算'::text,
         (-t.amount)::bigint, '対象外'::text,
         ('購入の失効による相殺 ' || coalesce(t.note, ''))::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'chargeback_offset' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  order by 1, 2, 10;
end;
$$;

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;
