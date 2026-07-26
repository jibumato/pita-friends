-- ============================================================
-- 自動確定の保留(E-12)
-- ------------------------------------------------------------
-- プレイ完了は開始時刻+72時間で自動確定し(0015)、確定した瞬間に対価は
-- ピタメイトの earned_balance(換金可能)に入る。**確定後に「相手が来なかった」と
-- 言われても、原資をピタメイトから回収する手段が無い**。
--
-- 申し出の期限を自動確定より内側に置くこと(48時間)は必要だが十分ではない。
-- 47時間目に来た申し出に25時間以内で必ず着手できる保証は無く、期限の短縮は
-- 構造的な問題を対応速度の問題に変えるだけ。**受け付けた事実だけで自動確定を
-- 止める**必要がある(判断まで待たない)。
--
-- ■ 保留の引き金を「申し出」だけにしない
--   最大の穴。ピタメイトが来なかったゲストは、がっかりしてアプリを開かなく
--   なり、申し出もしない。放っておくと**無断欠席した側が満額受け取る**。
--   泣き寝入りが最も起きやすく、しかも一番悪質なケースで起きる。
--   そこで**通報も引き金にする**。申し出(メール)より心理的ハードルが低く、
--   導線は既にある。reports には予約IDが無いので、通報した相手との間に
--   ある未確定の予約をまとめて保留する。
--
--   「合流の形跡が無い」の自動保留は採らない。Discord等で合流してアプリでは
--   喋らないケースが普通にあり、誤検知でピタメイトを不当に待たせる。
--   代わりに事後集計(held_bookings_overview)で偏りを見て掲載停止を検討する。
--
-- ■ 保留したままにしない
--   保留はピタメイトの資金を凍結する。黙って凍結すると不信を招くので、
--   保留時に通知し、保留自体にも期限(既定14日)を設けて督促できるようにする。
-- ============================================================

alter table public.bookings
  add column if not exists held_at timestamptz;
alter table public.bookings
  add column if not exists hold_reason text;

alter table public.bookings
  drop constraint if exists bookings_hold_reason_check;
alter table public.bookings
  add constraint bookings_hold_reason_check
  check (hold_reason is null or hold_reason in ('claim', 'report', 'manual'));

comment on column public.bookings.held_at is
  '自動確定を保留した時刻。null なら保留していない。'
  '保留中は auto_complete_bookings の対象から外れる(E-12)。';
comment on column public.bookings.hold_reason is
  '保留の理由。claim=返還の申し出 / report=通報 / manual=運営の判断。';

create index if not exists bookings_held_idx on public.bookings (held_at)
  where held_at is not null;

-- 保留の期限(過ぎたら督促する)。返還率などと同じく運用で変えられるようにする。
alter table public.platform_pricing
  add column if not exists hold_expiry_days int not null default 14;

comment on column public.platform_pricing.hold_expiry_days is
  '保留してから何日で「判断が滞っている」とみなすか。'
  'ピタメイトの資金を凍結し続けないための督促の基準。';

-- ------------------------------------------------------------
-- 1. 自動確定から保留中を外す
--    変更点は where 句の1行だけ。
-- ------------------------------------------------------------
create or replace function public.auto_complete_bookings()
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
    where status = 'confirmed'
      and scheduled_at + interval '72 hours' < now()
      -- 申し出・通報を受けた予約は確定させない(E-12)
      and held_at is null
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    insert into public.notifications (user_id, type, title, body, related_id)
    values
      (v_booking.host_id, 'booking_completed', 'プレイ完了が自動確定しました',
       v_booking.coins || 'コインが報酬として確定しました。ウォレットから換金申請できます', v_booking.id),
      (v_booking.guest_id, 'booking_completed', '予約が自動確定しました',
       '予約時刻から72時間が経過したため、プレイ完了として確定しました', v_booking.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  '72時間経過した予約を自動確定する。0042で、保留中(held_at is not null)のものを除外。';

-- ------------------------------------------------------------
-- 2. 保留する
--    確定前(confirmed)のものだけが対象。すでに確定していたら手遅れなので
--    黙って何もしない(呼び出し側が件数で判断できるよう戻り値を返す)。
-- ------------------------------------------------------------
create or replace function public._hold_booking(p_booking_id uuid, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  update public.bookings
    set held_at = now(), hold_reason = p_reason
    where id = p_booking_id and status = 'confirmed' and held_at is null
    returning * into v_b;

  if v_b.id is null then
    return false;
  end if;

  -- 黙って資金を凍結しない。何が起きているかをピタメイトに伝える。
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_b.host_id, 'booking_completed',
    'プレイ完了の確定を一時保留しています',
    'この予約についてお申し出があったため、確定を保留しました。'
      || '確認のうえご連絡します。内容によっては報酬が確定しないことがあります。',
    v_b.id);

  return true;
end;
$$;

revoke all on function public._hold_booking(uuid, text) from public;

-- 運営が申し出(メール)を受けて保留する。管理者専用。
create or replace function public.hold_booking(p_booking_id uuid, p_reason text default 'claim')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_reason not in ('claim', 'manual') then
    raise exception 'INVALID_REASON';
  end if;
  return public._hold_booking(p_booking_id, p_reason);
end;
$$;

revoke all on function public.hold_booking(uuid, text) from public;
grant execute on function public.hold_booking(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 3. 通報を引き金にする
--    reports に予約IDが無いため、通報した相手との間にある未確定の予約を
--    まとめて保留する。範囲を絞るため、自動確定の窓(72時間)の内側にある
--    ものだけを対象にする。
-- ------------------------------------------------------------
create or replace function public._hold_bookings_on_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  for v_id in
    select b.id from public.bookings b
    where b.status = 'confirmed'
      and b.held_at is null
      and (
        (b.guest_id = new.reporter_id and b.host_id = new.reported_id)
        or (b.host_id = new.reporter_id and b.guest_id = new.reported_id)
      )
      -- まだ自動確定していない(=止める意味がある)ものだけ
      and b.scheduled_at + interval '72 hours' >= now()
  loop
    perform public._hold_booking(v_id, 'report');
  end loop;
  return new;
end;
$$;

drop trigger if exists reports_hold_bookings on public.reports;
create trigger reports_hold_bookings
  after insert on public.reports
  for each row
  execute function public._hold_bookings_on_report();

-- ------------------------------------------------------------
-- 4. 保留を解く(管理者専用)
--    出口を2つ用意する。放置しないための入口でもある。
-- ------------------------------------------------------------

-- (a) 申し出を退けて、そのまま確定する
create or replace function public.release_hold_and_complete(p_booking_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_b.held_at is null then raise exception 'NOT_HELD'; end if;
  if v_b.status <> 'confirmed' then raise exception 'BOOKING_NOT_HELDABLE'; end if;

  update public.bookings
    set status = 'completed', held_at = null,
        hold_reason = null, cancel_reason = coalesce(p_note, cancel_reason)
    where id = p_booking_id;

  update public.coin_wallets
    set earned_balance = earned_balance + v_b.coins
    where user_id = v_b.host_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_b.host_id, v_b.coins, 'booking_earned', p_booking_id, 'release_hold_and_complete');

  update public.promises set status = 'completed' where booking_id = p_booking_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_b.host_id, 'booking_completed', '保留を解除し、報酬が確定しました',
    v_b.coins || 'コインが報酬として確定しました', p_booking_id);
end;
$$;

-- (b) 申し出を認めて、指定した割合を返還する
--     残りはピタメイトの報酬として確定する。0%なら全額返還。
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
    perform public._refund_coin_lots_for_booking(p_booking_id, v_refund_paid, v_refund_bonus);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_b.guest_id, v_refund_total, 'refund', p_booking_id, 'release_hold_and_refund');
  else
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0);
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

revoke all on function public.release_hold_and_complete(uuid, text) from public;
revoke all on function public.release_hold_and_refund(uuid, int, text) from public;
grant execute on function public.release_hold_and_complete(uuid, text) to authenticated;
grant execute on function public.release_hold_and_refund(uuid, int, text) to authenticated;

-- ------------------------------------------------------------
-- 5. 運営が見る一覧
--    保留中のものと、保留したまま期限を過ぎたもの(督促の対象)。
--    security_invoker なので、admins のRLS(管理者のみ全件可視)がそのまま効く。
-- ------------------------------------------------------------
create or replace view public.held_bookings_overview
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.coins,
  b.scheduled_at,
  b.held_at,
  b.hold_reason,
  extract(day from (now() - b.held_at))::int as held_days,
  b.held_at + make_interval(days => (select hold_expiry_days from public.platform_pricing where id = 1))
    < now() as is_overdue
from public.bookings b
where b.held_at is not null
order by b.held_at;

comment on view public.held_bookings_overview is
  '自動確定を保留している予約の一覧。is_overdue が true のものは判断が滞っている'
  '(ピタメイトの資金を凍結し続けている)ので優先して処理すること。';
