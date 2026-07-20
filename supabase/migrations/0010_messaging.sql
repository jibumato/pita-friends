-- ============================================================
-- チャット(トーク): promise(約束)の当事者間だけがやり取りできる
-- ------------------------------------------------------------
-- 「約束」は invite承認(0004) または コイン予約(0003)から成立する。
-- 0003のcreate_bookingは当初promiseを作っていなかった(promisesの
-- チェック制約は booking_id 経由も許容していたが未実装)ため、
-- ここで実装を完成させ、予約からも実際にトークルームに入れるようにする。
-- ============================================================

-- ------------------------------------------------------------
-- messages
-- ------------------------------------------------------------
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  promise_id uuid not null references public.promises (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

alter table public.messages enable row level security;

create policy "messages_select_participant"
  on public.messages for select
  to authenticated
  using (
    exists (
      select 1 from public.promises pr
      where pr.id = promise_id and (pr.user_a = auth.uid() or pr.user_b = auth.uid())
    )
  );

create policy "messages_insert_participant"
  on public.messages for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.promises pr
      where pr.id = promise_id and (pr.user_a = auth.uid() or pr.user_b = auth.uid())
    )
  );

-- UPDATE/DELETEポリシーは意図的に作らない(送信取り消し・編集は未対応)。

create index messages_promise_created_idx on public.messages (promise_id, created_at);

-- ------------------------------------------------------------
-- message_reads: 相手のトークルームをどこまで読んだか(promise単位)
-- ------------------------------------------------------------
create table public.message_reads (
  promise_id uuid not null references public.promises (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (promise_id, user_id)
);

alter table public.message_reads enable row level security;

create policy "message_reads_select_own"
  on public.message_reads for select
  to authenticated
  using (user_id = auth.uid());

create policy "message_reads_upsert_own"
  on public.message_reads for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.promises pr
      where pr.id = promise_id and (pr.user_a = auth.uid() or pr.user_b = auth.uid())
    )
  );

create policy "message_reads_update_own"
  on public.message_reads for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Realtime配信を有効化(トーク画面が postgres_changes を購読して即時反映する)
alter publication supabase_realtime add table public.messages;

-- ------------------------------------------------------------
-- create_booking を修正: 予約確定時にも promise(約束) を作成する。
-- これにより、コイン予約からも実際のトークルームに入れるようになる
-- (これまでは invite承認からのpromiseしか実装されていなかった)。
-- 戻り値は booking_id ではなく promise_id に変更する
-- (旧戻り値はフロント側で未使用だった。トーク画面への遷移に使う)。
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
  v_balance int;
  v_booking_id uuid;
  v_promise_id uuid;
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

  insert into public.promises (booking_id, user_a, user_b)
  values (v_booking_id, v_guest_id, p_host_id)
  returning id into v_promise_id;

  return v_promise_id;
end;
$$;
