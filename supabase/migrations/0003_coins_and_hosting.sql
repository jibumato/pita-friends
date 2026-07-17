-- コイン経済(GameRoom型マーケットプレイス)とホスト機能
-- 設計方針:
--   ・残高(coin_wallets.balance)はクライアントから直接書き換え不可。
--     purchase_coins / create_booking / cancel_booking の
--     SECURITY DEFINER関数経由でのみ増減する。
--   ・purchase_coins は実際の決済確認(未実装・決済代行事業者は未選定、
--     docs/legal/coin-economy-legal-review.md §2.1)が前提のため、
--     authenticated ロールへは EXECUTE を許可しない
--     (信頼できる決済Webhook/Edge Functionがservice_roleで呼ぶ)。

-- ============================================================
-- coin_wallets
-- ============================================================
create table public.coin_wallets (
  user_id uuid primary key references auth.users (id) on delete cascade,
  balance int not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

alter table public.coin_wallets enable row level security;

create policy "coin_wallets_select_own"
  on public.coin_wallets for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEポリシーは意図的に作成しない(残高操作は関数経由のみ)。

create trigger coin_wallets_set_updated_at
  before update on public.coin_wallets
  for each row execute function public.set_updated_at();

-- ============================================================
-- coin_transactions: 残高変動の履歴(監査用)
-- ============================================================
create table public.coin_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  amount int not null,
  type text not null check (type in ('purchase', 'booking_spend', 'refund', 'bonus')),
  related_booking_id uuid,
  note text,
  created_at timestamptz not null default now()
);

alter table public.coin_transactions enable row level security;

create policy "coin_transactions_select_own"
  on public.coin_transactions for select
  to authenticated
  using (user_id = auth.uid());

-- INSERTポリシーは意図的に作成しない(関数経由のみ)。

-- ============================================================
-- host_settings: ホスト掲載設定
-- ============================================================
create table public.host_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  is_host boolean not null default false,
  hourly_rate int not null default 400 check (hourly_rate between 50 and 2000),
  games text[] not null default '{}',
  bio text not null default '',
  updated_at timestamptz not null default now()
);

alter table public.host_settings enable row level security;

-- 掲載中(is_host=true)のホストは誰でも閲覧可(さがす画面用)。
-- 非掲載でも本人だけは自分の設定を見られる。
create policy "host_settings_select_listed_or_own"
  on public.host_settings for select
  to authenticated
  using (is_host = true or user_id = auth.uid());

create policy "host_settings_update_own"
  on public.host_settings for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create trigger host_settings_set_updated_at
  before update on public.host_settings
  for each row execute function public.set_updated_at();

-- 本人確認済みユーザーのみホスト掲載を有効化できる(ROADMAP: 「掲載条件:
-- 本人確認済みのみ」)。is_host を true に変更する更新のみをチェックする。
create function public.check_host_requires_verification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_host and not old.is_host then
    if not exists (
      select 1 from public.profile_trust_stats
      where user_id = new.user_id and is_verified = true
    ) then
      raise exception 'HOST_REQUIRES_VERIFICATION';
    end if;
  end if;
  return new;
end;
$$;

create trigger host_settings_require_verification
  before update on public.host_settings
  for each row execute function public.check_host_requires_verification();

-- ============================================================
-- 新規ユーザー登録時にウォレットとホスト設定行を作成する。
-- (0002_profiles.sql の handle_new_user を拡張する形で、別トリガーとして追加)
-- ============================================================
create function public.handle_new_user_wallet()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.coin_wallets (user_id) values (new.id);
  insert into public.host_settings (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created_wallet
  after insert on auth.users
  for each row execute function public.handle_new_user_wallet();

-- ============================================================
-- bookings: ホストへの時間予約(コイン消費)
-- 注記: 現行フロントエンドUX(Booking.tsx)は「予約確定→即座に合流フローへ」
-- という即時開始モデル。scheduled_at のデフォルトは now() だが、将来の
-- 日時指定予約にも対応できるよう列としては保持する。
-- ============================================================
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null references auth.users (id) on delete cascade,
  host_id uuid not null references auth.users (id) on delete cascade,
  duration_minutes int not null check (duration_minutes in (30, 60, 120)),
  coins int not null check (coins > 0),
  status text not null default 'confirmed'
    check (status in ('confirmed', 'completed', 'cancelled_by_guest', 'cancelled_by_host', 'no_show_host', 'no_show_guest')),
  scheduled_at timestamptz not null default now(),
  cancel_reason text,
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  check (guest_id <> host_id)
);

alter table public.bookings enable row level security;

create policy "bookings_select_participant"
  on public.bookings for select
  to authenticated
  using (guest_id = auth.uid() or host_id = auth.uid());

-- INSERT/UPDATEポリシーは意図的に作成しない(create_booking / cancel_booking
-- 関数のみが残高整合性を保ちながら操作できるようにするため)。

-- ============================================================
-- create_booking: 予約確定 + コイン消費をアトミックに行う
-- ============================================================
create function public.create_booking(p_host_id uuid, p_duration_minutes int)
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
  v_balance int;
  v_booking_id uuid;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_duration_minutes not in (30, 60, 120) then
    raise exception 'INVALID_DURATION';
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings
  where user_id = p_host_id
  for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_coins := round(v_hourly_rate * p_duration_minutes / 60.0);

  select balance into v_balance
  from public.coin_wallets
  where user_id = v_guest_id
  for update;

  if v_balance is null or v_balance < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - v_coins where user_id = v_guest_id;

  insert into public.bookings (guest_id, host_id, duration_minutes, coins)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins)
  returning id into v_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$$;

revoke all on function public.create_booking(uuid, int) from public;
grant execute on function public.create_booking(uuid, int) to authenticated;

-- ============================================================
-- cancel_booking: キャンセル + 返還マトリクス
-- (docs/legal/terms-of-service-draft.md 第9条に対応)
--   ・ホスト都合のキャンセル/無断欠席        → 全額再付与
--   ・ゲスト都合、開始1時間より前のキャンセル → 全額再付与
--   ・ゲスト都合、開始1時間を切ってのキャンセル → 再付与なし
-- ============================================================
create function public.cancel_booking(p_booking_id uuid, p_reason text default null)
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
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_booking.status not in ('confirmed') then
    raise exception 'BOOKING_NOT_CANCELLABLE';
  end if;

  if v_uid = v_booking.host_id then
    v_refund := true;
    v_new_status := 'cancelled_by_host';
    -- ホスト都合のキャンセルはドタキャン実績としてホストのマナースタッツに反映
    update public.profile_trust_stats
      set dotakyan_count = dotakyan_count + 1, updated_at = now()
      where user_id = v_booking.host_id;
  else
    v_new_status := 'cancelled_by_guest';
    v_refund := now() < (v_booking.scheduled_at - interval '1 hour');
    if not v_refund then
      update public.profile_trust_stats
        set dotakyan_count = dotakyan_count + 1, updated_at = now()
        where user_id = v_booking.guest_id;
    end if;
  end if;

  update public.bookings
    set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund then
    update public.coin_wallets set balance = balance + v_booking.coins where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_booking');
  end if;
end;
$$;

revoke all on function public.cancel_booking(uuid, text) from public;
grant execute on function public.cancel_booking(uuid, text) to authenticated;

-- ============================================================
-- purchase_coins: コイン購入の残高反映
-- 決済確認済みの信頼できるバックエンド(service_role)のみが呼び出す想定。
-- 未認証クライアントは呼び出せないよう EXECUTE を authenticated にも
-- 付与しない。
-- ============================================================
create function public.purchase_coins(p_user_id uuid, p_amount int, p_note text default 'purchase')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_amount <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;
  update public.coin_wallets set balance = balance + p_amount where user_id = p_user_id;
  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_amount, 'purchase', p_note);
end;
$$;

revoke all on function public.purchase_coins(uuid, int, text) from public;
-- service_role はデフォルトでRLS/権限をバイパスするため明示的なgrantは不要。
-- authenticated には意図的に grant しない(決済Webhook経由のみで呼び出す)。
