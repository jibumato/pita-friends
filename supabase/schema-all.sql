-- 拡張機能の有効化。gen_random_uuid() 等のため。
create extension if not exists pgcrypto with schema public;

-- updated_at カラムを自動更新する共通トリガー関数。
-- (moddatetime 拡張への依存を避け、環境を問わず動作するよう自前定義)
create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
-- プロフィール・安心設定・本人確認
-- 設計方針: マナースコア等の「信頼スタッツ」は自己申告で書き換えられると意味が
-- ないため、ユーザーが直接編集できる `profiles` と、サーバー側関数のみが
-- 更新できる `profile_trust_stats` をテーブルレベルで分離する。

-- ============================================================
-- profiles: ユーザーが自分で編集できる公開プロフィール
-- ============================================================
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nickname text not null default '',
  gender text not null default 'na' check (gender in ('female', 'male', 'na')),
  avatar_initial text not null default '',
  avatar_color text not null default '#B3E5F2',
  favorite_games text[] not null default '{}',
  play_style text not null default 'エンジョイ',
  bio text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'ユーザーが自分で編集できる公開プロフィール。信頼スコア等は profile_trust_stats を参照。';

alter table public.profiles enable row level security;

-- 閲覧ポリシー(暫定): この時点では blocks テーブルが未作成のため、
-- 全ユーザー閲覧可の暫定ポリシーを置く。ブロック関係の除外は
-- 0005_trust_safety.sql で blocks テーブル作成後にこのポリシーを
-- 置き換える。
create policy "profiles_select_all"
  on public.profiles for select
  to authenticated
  using (true);

create policy "profiles_insert_own"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid());

create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ============================================================
-- profile_trust_stats: サーバー側関数のみが更新できる信頼スタッツ
-- ============================================================
create table public.profile_trust_stats (
  user_id uuid primary key references auth.users (id) on delete cascade,
  manner_score numeric(3, 2) not null default 4.50 check (manner_score between 1.00 and 5.00),
  review_count int not null default 0,
  confirmed_count int not null default 0,
  dotakyan_count int not null default 0,
  is_verified boolean not null default false,
  updated_at timestamptz not null default now()
);

comment on table public.profile_trust_stats is
  'マナースコア/ドタキャン率等。docs/trust-safety-spec.md §1-2 の算出対象。'
  'クライアントからの直接書き込みは不可(RLSに書き込みポリシーを設けない)。'
  '更新は recompute_manner_score 等のSECURITY DEFINER関数経由のみ。';

alter table public.profile_trust_stats enable row level security;

-- 閲覧は誰でも可(さがす・受け取った誘い・プロフィール画面での信頼情報表示のため)
create policy "trust_stats_select_all"
  on public.profile_trust_stats for select
  to authenticated
  using (true);

-- 書き込みポリシーは意図的に作成しない(authenticated/anonからの直接更新を禁止)。

-- ============================================================
-- safety_prefs: 安心設定(女性ファーストの中核コントロール)
-- ============================================================
create table public.safety_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  contact_scope text not null default 'verified' check (contact_scope in ('verified', 'sameGender', 'all')),
  approval_required boolean not null default true,
  show_online boolean not null default true,
  discoverable boolean not null default true,
  block_low_trust boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.safety_prefs enable row level security;

create policy "safety_prefs_select_own"
  on public.safety_prefs for select
  to authenticated
  using (user_id = auth.uid());

create policy "safety_prefs_insert_own"
  on public.safety_prefs for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "safety_prefs_update_own"
  on public.safety_prefs for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create trigger safety_prefs_set_updated_at
  before update on public.safety_prefs
  for each row execute function public.set_updated_at();

-- ============================================================
-- identity_verifications: 本人確認(年齢確認を兼ねる)
-- 設計方針(法務Q&A Q6): 書類原本の画像はDBに保存しない。
-- eKYCベンダーの結果(参照ID・生年月日から算出した年齢が18歳以上か)のみ保持する。
-- ============================================================
create table public.identity_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  provider text,
  provider_reference text,
  is_adult boolean,
  rejected_reason text,
  created_at timestamptz not null default now(),
  verified_at timestamptz
);

comment on table public.identity_verifications is
  '本人確認の結果のみを保持(docs/legal/operations-legal-qa.md Q6)。書類原本の画像はここに保存しない。';

alter table public.identity_verifications enable row level security;

create policy "identity_verifications_select_own"
  on public.identity_verifications for select
  to authenticated
  using (user_id = auth.uid());

-- 申請(pending行の作成)は本人のみ。結果の確定はservice_role(eKYCベンダーからの
-- webhook/Edge Function)のみが行うため、UPDATEポリシーはあえて作成しない。
create policy "identity_verifications_insert_own"
  on public.identity_verifications for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- ============================================================
-- 新規ユーザー登録時に、上記の初期行をまとめて作成するトリガー
-- ============================================================
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id);
  insert into public.profile_trust_stats (user_id) values (new.id);
  insert into public.safety_prefs (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
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
-- マッチングのコアフロー: 誘う → 承認 → 約束
-- 設計方針: 「誰から誘いを受けるか」は safety_prefs.contact_scope
-- (女性ファースト安全設計の中核コントロール)で本人が決めるため、
-- invites の INSERT ポリシーでこれを強制する(アプリ層任せにしない)。

-- ============================================================
-- invites: 誘う/受け取った誘い
-- ============================================================
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users (id) on delete cascade,
  to_user uuid not null references auth.users (id) on delete cascade,
  game text not null,
  when_text text not null,
  message text not null default '',
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'expired')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (from_user <> to_user)
);

alter table public.invites enable row level security;

create policy "invites_select_participant"
  on public.invites for select
  to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());

-- 送信者は、相手の安心設定(contact_scope)を満たす場合のみ誘いを送れる。
-- (暫定): この時点では blocks テーブルが未作成のため、ブロック確認は
-- 含めない。0005_trust_safety.sql で blocks 作成後にこのポリシーを
-- ブロック確認込みで置き換える。
create policy "invites_insert_within_contact_scope"
  on public.invites for insert
  to authenticated
  with check (
    from_user = auth.uid()
    and exists (
      select 1
      from public.safety_prefs sp
      join public.profiles receiver on receiver.id = sp.user_id
      join public.profiles sender on sender.id = from_user
      left join public.profile_trust_stats sender_stats on sender_stats.user_id = from_user
      where sp.user_id = to_user
        and (
          sp.contact_scope = 'all'
          or (sp.contact_scope = 'verified' and coalesce(sender_stats.is_verified, false))
          or (sp.contact_scope = 'sameGender' and sender.gender = receiver.gender)
        )
    )
  );

-- 応答(承認/辞退)は宛先本人のみ。承認/辞退のロジック自体は下記の
-- approve_invite / decline_invite 関数で行うため、直接UPDATEは許可しない。

-- ============================================================
-- promises: 約束(誘いの承認、またはコイン予約から成立)
-- ============================================================
create table public.promises (
  id uuid primary key default gen_random_uuid(),
  invite_id uuid references public.invites (id) on delete set null,
  booking_id uuid references public.bookings (id) on delete set null,
  user_a uuid not null references auth.users (id) on delete cascade,
  user_b uuid not null references auth.users (id) on delete cascade,
  scheduled_at timestamptz not null default now(),
  status text not null default 'scheduled' check (status in ('scheduled', 'joined', 'completed', 'cancelled')),
  friend_code_revealed boolean not null default false,
  created_at timestamptz not null default now(),
  check ((invite_id is not null)::int + (booking_id is not null)::int = 1),
  check (user_a <> user_b)
);

comment on table public.promises is
  '「約束」ステージ。invite_id(承認された誘い)かbooking_id(コイン予約)のいずれか一方から必ず作られる。';

alter table public.promises enable row level security;

create policy "promises_select_participant"
  on public.promises for select
  to authenticated
  using (user_a = auth.uid() or user_b = auth.uid());

-- INSERT/UPDATEは意図的にポリシーを作らない(approve_invite / create_booking
-- 経由の作成、joining/reviewフローでの状態遷移も専用関数を用意する想定)。

-- ============================================================
-- approve_invite / decline_invite: 誘いへの応答
-- ============================================================
create function public.approve_invite(p_invite_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.invites;
  v_promise_id uuid;
begin
  select * into v_invite from public.invites where id = p_invite_id for update;

  if v_invite.id is null then
    raise exception 'INVITE_NOT_FOUND';
  end if;
  if v_invite.to_user <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if v_invite.status <> 'pending' then
    raise exception 'INVITE_NOT_PENDING';
  end if;

  update public.invites set status = 'approved', responded_at = now() where id = p_invite_id;

  insert into public.promises (invite_id, user_a, user_b)
  values (p_invite_id, v_invite.from_user, v_invite.to_user)
  returning id into v_promise_id;

  return v_promise_id;
end;
$$;

revoke all on function public.approve_invite(uuid) from public;
grant execute on function public.approve_invite(uuid) to authenticated;

create function public.decline_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.invites;
begin
  select * into v_invite from public.invites where id = p_invite_id for update;

  if v_invite.id is null then
    raise exception 'INVITE_NOT_FOUND';
  end if;
  if v_invite.to_user <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if v_invite.status <> 'pending' then
    raise exception 'INVITE_NOT_PENDING';
  end if;

  update public.invites set status = 'declined', responded_at = now() where id = p_invite_id;
end;
$$;

revoke all on function public.decline_invite(uuid) from public;
grant execute on function public.decline_invite(uuid) to authenticated;
-- 信頼・安全: レビュー・通報・ブロック・マナースコア算出
-- (docs/trust-safety-spec.md の実装)

-- ============================================================
-- blocks: 片方向のブロック関係
-- ============================================================
create table public.blocks (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  reason text,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

comment on table public.blocks is
  '片方向ブロック。相手に通知しない(docs/legal/operations-legal-qa.md 安全センターの文言と一致)。';

alter table public.blocks enable row level security;

create policy "blocks_select_own"
  on public.blocks for select
  to authenticated
  using (blocker_id = auth.uid());

create policy "blocks_insert_own"
  on public.blocks for insert
  to authenticated
  with check (blocker_id = auth.uid());

create policy "blocks_delete_own"
  on public.blocks for delete
  to authenticated
  using (blocker_id = auth.uid());

-- ============================================================
-- 0002 / 0004 で作った暫定ポリシーを、blocks 作成後の本来の形に置き換える
-- ============================================================
drop policy "profiles_select_all" on public.profiles;

create policy "profiles_select_not_blocked"
  on public.profiles for select
  to authenticated
  using (
    id = auth.uid()
    or not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = profiles.id)
         or (b.blocker_id = profiles.id and b.blocked_id = auth.uid())
    )
  );

drop policy "invites_insert_within_contact_scope" on public.invites;

create policy "invites_insert_within_contact_scope"
  on public.invites for insert
  to authenticated
  with check (
    from_user = auth.uid()
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = to_user and b.blocked_id = from_user)
         or (b.blocker_id = from_user and b.blocked_id = to_user)
    )
    and exists (
      select 1
      from public.safety_prefs sp
      join public.profiles receiver on receiver.id = sp.user_id
      join public.profiles sender on sender.id = from_user
      left join public.profile_trust_stats sender_stats on sender_stats.user_id = from_user
      where sp.user_id = to_user
        and (
          sp.contact_scope = 'all'
          or (sp.contact_scope = 'verified' and coalesce(sender_stats.is_verified, false))
          or (sp.contact_scope = 'sameGender' and sender.gender = receiver.gender)
        )
    )
  );

-- ============================================================
-- reviews: プレイ後レビュー(マナースコアの主要因子)
-- ============================================================
create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  promise_id uuid not null references public.promises (id) on delete cascade,
  reviewer_id uuid not null references auth.users (id) on delete cascade,
  reviewee_id uuid not null references auth.users (id) on delete cascade,
  stars int not null check (stars between 1 and 5),
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (promise_id, reviewer_id),
  check (reviewer_id <> reviewee_id)
);

alter table public.reviews enable row level security;

create policy "reviews_select_participant"
  on public.reviews for select
  to authenticated
  using (reviewer_id = auth.uid() or reviewee_id = auth.uid());

create policy "reviews_insert_participant"
  on public.reviews for insert
  to authenticated
  with check (
    reviewer_id = auth.uid()
    and exists (
      select 1 from public.promises p
      where p.id = promise_id
        and (p.user_a = auth.uid() or p.user_b = auth.uid())
        and reviewee_id = case when p.user_a = auth.uid() then p.user_b else p.user_a end
    )
  );

-- ============================================================
-- reports: 通報
-- docs/trust-safety-spec.md §3.2 の緊急度分類をINSERT時に自動付与する。
-- ============================================================
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users (id) on delete cascade,
  reported_id uuid not null references auth.users (id) on delete cascade,
  category text not null check (category in (
    'external_invite', 'money_request', 'dating_solicitation',
    'harassment', 'impersonation', 'no_show', 'other'
  )),
  severity text not null check (severity in ('low', 'high', 'critical')),
  message_snapshot jsonb,
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved')),
  resolution text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  check (reporter_id <> reported_id)
);

alter table public.reports enable row level security;

-- 通報者は自分が出した通報のみ閲覧可(被通報者には理由の詳細を開示しないことがある、
-- という利用規約の建て付けと一致させ、reported_id側には閲覧ポリシーを与えない)。
create policy "reports_select_own"
  on public.reports for select
  to authenticated
  using (reporter_id = auth.uid());

create policy "reports_insert_own"
  on public.reports for insert
  to authenticated
  with check (reporter_id = auth.uid());

-- ステータス変更(審査・確定)はservice_role(運営の審査オペレーション)のみ。
-- authenticatedへのUPDATEポリシーは意図的に作らない。

create function public.set_report_severity()
returns trigger
language plpgsql
as $$
begin
  new.severity := case new.category
    when 'money_request' then 'critical'
    when 'dating_solicitation' then 'high'
    when 'impersonation' then 'high'
    when 'external_invite' then 'high'
    when 'harassment' then 'high'
    else 'low'
  end;
  return new;
end;
$$;

create trigger reports_set_severity
  before insert on public.reports
  for each row execute function public.set_report_severity();

-- ============================================================
-- manner_penalties: 確定した違反によるスコア減点(サーバー側のみ書込)
-- ============================================================
create table public.manner_penalties (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  report_id uuid references public.reports (id) on delete set null,
  points numeric(3, 2) not null check (points > 0),
  reason text,
  created_at timestamptz not null default now()
);

alter table public.manner_penalties enable row level security;

create policy "manner_penalties_select_own"
  on public.manner_penalties for select
  to authenticated
  using (user_id = auth.uid());

-- INSERTポリシーは意図的に作成しない(resolve_report関数経由のみ)。

-- ============================================================
-- recompute_manner_score: マナースコアの再計算
-- docs/trust-safety-spec.md §1.1 の簡略実装。
-- 直近30件のレビュー星評価の単純平均を基準値とし、確定した違反の
-- 累積減点(manner_penalties)を差し引く。1.00〜5.00にクランプする。
-- ============================================================
create function public.recompute_manner_score(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review_avg numeric;
  v_review_count int;
  v_penalty numeric;
  v_score numeric;
begin
  select avg(stars), count(*) into v_review_avg, v_review_count
  from (
    select stars from public.reviews
    where reviewee_id = p_user_id
    order by created_at desc
    limit 30
  ) recent;

  select coalesce(sum(points), 0) into v_penalty
  from public.manner_penalties
  where user_id = p_user_id;

  v_score := coalesce(v_review_avg, 4.50) - v_penalty;
  v_score := greatest(1.00, least(5.00, v_score));

  update public.profile_trust_stats
    set manner_score = v_score,
        review_count = coalesce(v_review_count, 0),
        updated_at = now()
    where user_id = p_user_id;
end;
$$;

revoke all on function public.recompute_manner_score(uuid) from public;
-- authenticatedには実行権限を与えない(トリガー/moderation関数からのみ呼ぶ)。

create function public.reviews_after_insert_recompute()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recompute_manner_score(new.reviewee_id);

  -- 確定した約束としてカウント(ドタキャン率の分母, docs/trust-safety-spec.md §2)
  update public.profile_trust_stats
    set confirmed_count = confirmed_count + 1
    where user_id = new.reviewee_id;

  return new;
end;
$$;

create trigger reviews_recompute_score
  after insert on public.reviews
  for each row execute function public.reviews_after_insert_recompute();

-- ============================================================
-- resolve_report: 通報の審査確定(運営オペレーション専用)
-- docs/trust-safety-spec.md §3.4 の措置マトリクスに従い、必要なら
-- manner_penaltiesに減点を追加してスコアを再計算する。
-- service_role専用(通報→運営審査→利用制限は運用Q&A Q2/Q3の
-- 「事前通知不要・裁量的措置」に対応するオペレーション行為のため、
-- クライアントロールへは実行権限を与えない)。
-- ============================================================
create function public.resolve_report(
  p_report_id uuid,
  p_resolution text,
  p_status text default 'resolved',
  p_penalty_points numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report public.reports;
begin
  select * into v_report from public.reports where id = p_report_id for update;
  if v_report.id is null then
    raise exception 'REPORT_NOT_FOUND';
  end if;

  update public.reports
    set status = p_status, resolution = p_resolution, resolved_at = now()
    where id = p_report_id;

  if p_penalty_points is not null and p_penalty_points > 0 then
    insert into public.manner_penalties (user_id, report_id, points, reason)
    values (v_report.reported_id, p_report_id, p_penalty_points, p_resolution);

    perform public.recompute_manner_score(v_report.reported_id);
  end if;
end;
$$;

revoke all on function public.resolve_report(uuid, text, text, numeric) from public;
-- service_roleのみが呼び出す想定。authenticatedへは意図的にgrantしない。
-- 本人確認の手動審査運用(初期フェーズ)
-- 方針: 「初期のみ運営(あなた)が目視で審査する」ため、eKYCベンダーとは
-- 異なり、審査担当が実際に画像を確認できる必要がある。そのため、
-- 0002_profiles.sql の設計方針(画像は照合後すぐ削除、結果のみ保持)を
-- 一部緩め、審査が完了するまでの間だけ Supabase Storage に画像を
-- 保持する。審査完了後は運営側で画像を削除する運用とする
-- (docs/manual-verification-review.md 参照)。

alter table public.identity_verifications
  add column document_path text,
  add column selfie_path text;

comment on column public.identity_verifications.document_path is
  '審査完了までの一時保存(Storage: identity-documents/{user_id}/...)。承認/却下後は運営が削除する。';
comment on column public.identity_verifications.selfie_path is
  '審査完了までの一時保存(Storage: identity-documents/{user_id}/...)。承認/却下後は運営が削除する。';

-- ============================================================
-- Storageバケット: identity-documents(非公開)
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('identity-documents', 'identity-documents', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- パスは必ず {auth.uid()}/ファイル名 の形式にし、本人のフォルダにのみ
-- 読み書きできるようにする。運営(Supabaseダッシュボード経由の審査)は
-- service_role相当のアクセスとしてRLSをバイパスするため、別途「審査者用」
-- ポリシーは不要。
create policy "identity_documents_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'identity-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "identity_documents_select_own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "identity_documents_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- 本人確認のアプリ内審査(管理画面)
-- 方針: 「初期のみ運営が見て審査する」を、Supabaseダッシュボードでの
-- 手動SQL操作(0006 / docs/manual-verification-review.md)から、
-- アプリ内の管理画面での承認/却下に置き換える。
--
-- 権限モデル: admins テーブルへの行の有無で管理者を判定する。
-- admins への書き込みポリシーはクライアントに一切与えない
-- (初回管理者の付与は、運営がSupabaseダッシュボードのSQL Editorで
-- 1回だけ手動で行う。docs/manual-verification-review.md 参照)。

-- ============================================================
-- admins: 管理者フラグ
-- ============================================================
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

-- 自分が管理者かどうかはUIの出し分けのため確認できてよい。
-- 他人の管理者権限の有無は見せない。
create policy "admins_select_self"
  on public.admins for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATE/DELETEポリシーは意図的に作らない。

-- ============================================================
-- identity_verifications / storage.objects: 管理者への閲覧権限追加
-- (既存の「本人のみ閲覧可」ポリシーに、管理者向けポリシーを追加する。
-- RLSの複数のpermissiveポリシーはOR結合されるため、一般ユーザーは
-- 従来どおり自分の行だけ、管理者は全件が見えるようになる)
-- ============================================================
create policy "identity_verifications_select_admin"
  on public.identity_verifications for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create policy "identity_documents_select_admin"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and exists (select 1 from public.admins where user_id = auth.uid())
  );

-- ============================================================
-- approve_identity_verification / reject_identity_verification
-- 呼び出し元がadminsに登録されているかを関数内で検証するため、
-- authenticatedロールへ広くEXECUTEを許可してよい
-- (管理者以外が呼んでもNOT_ADMINで失敗するだけ)。
-- 判定後は画像を削除し、docs/legal/operations-legal-qa.md Q6の
-- 「審査完了後は速やかに削除」を自動化する。
-- ============================================================
create function public.approve_identity_verification(p_verification_id uuid, p_is_adult boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'verified', is_adult = p_is_adult, verified_at = now()
    where id = p_verification_id;

  update public.profile_trust_stats
    set is_verified = true, updated_at = now()
    where user_id = v_row.user_id;

  delete from storage.objects
    where bucket_id = 'identity-documents'
      and name in (v_row.document_path, v_row.selfie_path);
end;
$$;

revoke all on function public.approve_identity_verification(uuid, boolean) from public;
grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;

create function public.reject_identity_verification(p_verification_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'rejected', rejected_reason = p_reason
    where id = p_verification_id;

  delete from storage.objects
    where bucket_id = 'identity-documents'
      and name in (v_row.document_path, v_row.selfie_path);
end;
$$;

revoke all on function public.reject_identity_verification(uuid, text) from public;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;
-- 本人確認の承認/却下RPCの修正
-- 問題: 0007の approve/reject 関数は、判定後に storage.objects から画像を
-- 直接 delete していた。SECURITY DEFINER関数の実行ロール(postgres)は
-- storage.objects への DELETE 権限を持たず、42501(insufficient_privilege)
-- → PostgRESTが 403 Forbidden を返し、承認そのものが失敗していた。
--
-- 修正方針:
--   1. RPCはDBの更新(identity_verifications / profile_trust_stats)のみ行う。
--   2. 画像の削除は、判定後にクライアント(管理者のブラウザ)から
--      Storage API 経由で行う。そのための「管理者は identity-documents を
--      削除できる」RLSポリシーを追加する。

-- ============================================================
-- 承認/却下関数を、画像削除なしのDB更新のみに置き換える
-- ============================================================
create or replace function public.approve_identity_verification(p_verification_id uuid, p_is_adult boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'verified', is_adult = p_is_adult, verified_at = now()
    where id = p_verification_id;

  update public.profile_trust_stats
    set is_verified = true, updated_at = now()
    where user_id = v_row.user_id;
end;
$$;

create or replace function public.reject_identity_verification(p_verification_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'rejected', rejected_reason = p_reason
    where id = p_verification_id;
end;
$$;

grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;

-- ============================================================
-- 管理者は identity-documents バケットの画像を削除できる
-- (判定後にクライアントから Storage API で削除するため)
-- ============================================================
create policy "identity_documents_delete_admin"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'identity-documents'
    and exists (select 1 from public.admins where user_id = auth.uid())
  );
-- ============================================================
-- 決済(Stripe)連携: コインパック定義 と 購入履歴(冪等)
-- ------------------------------------------------------------
-- 方針:
--   ・コインの付与はサーバー(Stripe Webhook → service_role → purchase_coins)
--     経由でのみ行う。クライアントは coin_wallets を書けない(0003)。
--   ・パックの価格・付与数は coin_packs(サーバー権威)で確定する。
--     クライアントが送るのは pack_id のみで、金額やコイン数は信用しない。
--   ・二重付与を防ぐため coin_purchases に stripe_session_id の一意制約を置く。
-- 法務: 有償コインは前払式支払手段(資金決済法)。売上開始時の表示義務・
--       基準日残高1,000万円超で届出/供託(docs/legal/coin-economy-legal-review.md §2)。
-- ============================================================

-- ------------------------------------------------------------
-- coin_packs: 販売中のコインパック(公開・読み取りのみ)
-- ------------------------------------------------------------
create table public.coin_packs (
  id text primary key,
  coins int not null check (coins > 0),
  bonus_coins int not null default 0 check (bonus_coins >= 0),
  price_yen int not null check (price_yen > 0),
  sort int not null default 0,
  active boolean not null default true
);

alter table public.coin_packs enable row level security;

-- 誰でも(未ログインでも)一覧を見られる。書き込みは service_role のみ(ポリシー無し)。
create policy "coin_packs_select_all"
  on public.coin_packs for select
  using (active = true);

insert into public.coin_packs (id, coins, bonus_coins, price_yen, sort) values
  ('pack_300', 300, 0, 300, 1),
  ('pack_1000', 1000, 50, 1000, 2),
  ('pack_3000', 3000, 300, 3000, 3),
  ('pack_6000', 6000, 900, 6000, 4);

-- ------------------------------------------------------------
-- coin_purchases: 購入履歴 兼 冪等キー
--   Webhook が checkout.session.completed を受けたときに1行 insert する。
--   stripe_session_id の unique 制約で、同じ決済の二重付与を防ぐ。
-- ------------------------------------------------------------
create table public.coin_purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  pack_id text references public.coin_packs (id),
  coins_credited int not null check (coins_credited > 0),
  price_yen int not null check (price_yen >= 0),
  stripe_session_id text not null unique,
  stripe_payment_intent text,
  created_at timestamptz not null default now()
);

alter table public.coin_purchases enable row level security;

-- 本人は自分の購入履歴のみ閲覧可。書き込みは service_role のみ(ポリシー無し)。
create policy "coin_purchases_select_own"
  on public.coin_purchases for select
  to authenticated
  using (user_id = auth.uid());

-- ------------------------------------------------------------
-- credit_coins_for_purchase: Webhook から呼ぶ冪等な付与関数
--   ・stripe_session_id が既にあれば何もしない(二重付与防止)
--   ・無ければ coin_purchases に記録し、coin_wallets に加算する
--   service_role からのみ呼ばれる想定(authenticated へは grant しない)。
-- ------------------------------------------------------------
create function public.credit_coins_for_purchase(
  p_user_id uuid,
  p_pack_id text,
  p_coins int,
  p_price_yen int,
  p_session_id text,
  p_payment_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 既に処理済みのセッションなら冪等に終了
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets set balance = balance + p_coins where user_id = p_user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$$;

-- authenticated には付与関数を公開しない(サーバーのservice_role専用)。
revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, text, text) from public;
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
-- ============================================================
-- 募集板: 実際に募集を作成・一覧・参加できるようにする
-- ============================================================

create table public.board_posts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users (id) on delete cascade,
  game text not null,
  mood text not null default 'エンジョイ' check (mood in ('エンジョイ', 'ランク上げ', 'ガチ')),
  when_text text not null,
  capacity int not null default 2 check (capacity between 1 and 4),
  vc text not null default 'どちらでも' check (vc in ('必須', 'どちらでも', 'なし')),
  audience text not null default '全員' check (audience in ('全員', '同性のみ')),
  verified_only boolean not null default true,
  note text not null default '',
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),
  created_at timestamptz not null default now()
);

alter table public.board_posts enable row level security;

-- 一覧はブロック関係にない相手の募集のみ見える(0005のprofiles方針と揃える)。
create policy "board_posts_select_not_blocked"
  on public.board_posts for select
  to authenticated
  using (
    creator_id = auth.uid()
    or not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = board_posts.creator_id)
         or (b.blocker_id = board_posts.creator_id and b.blocked_id = auth.uid())
    )
  );

create policy "board_posts_insert_own"
  on public.board_posts for insert
  to authenticated
  with check (creator_id = auth.uid());

-- 作成者は自分の募集を閉じる(キャンセル)ことができる。定員等の直接改変は不可。
create policy "board_posts_update_own_status"
  on public.board_posts for update
  to authenticated
  using (creator_id = auth.uid())
  with check (creator_id = auth.uid());

create index board_posts_status_created_idx on public.board_posts (status, created_at desc);

-- ------------------------------------------------------------
-- board_participants: 参加者(作成者本人は含めない)
-- ------------------------------------------------------------
create table public.board_participants (
  post_id uuid not null references public.board_posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.board_participants enable row level security;

create policy "board_participants_select_related"
  on public.board_participants for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.board_posts bp where bp.id = post_id and bp.creator_id = auth.uid())
  );

-- INSERTは join_board_post 関数経由のみ(定員・条件チェックをアトミックに行うため)。

-- ------------------------------------------------------------
-- join_board_post: 参加表明。定員・本人確認要件・同性のみ要件・
-- ブロック関係をサーバー側でアトミックに検証してから参加者を追加する。
-- ------------------------------------------------------------
create function public.join_board_post(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post public.board_posts;
  v_me uuid := auth.uid();
  v_me_verified boolean;
  v_me_gender text;
  v_creator_gender text;
  v_joined_count int;
begin
  if v_me is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_me then
    raise exception 'CANNOT_JOIN_OWN_POST';
  end if;
  if exists (select 1 from public.board_participants where post_id = p_post_id and user_id = v_me) then
    raise exception 'ALREADY_JOINED';
  end if;
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_me and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_me)
  ) then
    raise exception 'BLOCKED';
  end if;

  select count(*) into v_joined_count from public.board_participants where post_id = p_post_id;
  if v_joined_count >= v_post.capacity then
    raise exception 'POST_FULL';
  end if;

  if v_post.verified_only then
    select is_verified into v_me_verified from public.profile_trust_stats where user_id = v_me;
    if not coalesce(v_me_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_me_gender from public.profiles where id = v_me;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_me_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  insert into public.board_participants (post_id, user_id) values (p_post_id, v_me);

  -- 定員に達したら自動的にクローズする
  if v_joined_count + 1 >= v_post.capacity then
    update public.board_posts set status = 'closed' where id = p_post_id;
  end if;
end;
$$;

revoke all on function public.join_board_post(uuid) from public;
grant execute on function public.join_board_post(uuid) to authenticated;
-- ============================================================
-- 通知: 誘い受信/承認・新着メッセージ・本人確認結果・募集参加を
-- 実際にDBへ記録し、通知画面で表示できるようにする。
-- ============================================================

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  type text not null check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined'
  )),
  title text not null,
  body text not null default '',
  related_id uuid,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.notifications enable row level security;

create policy "notifications_select_own"
  on public.notifications for select
  to authenticated
  using (user_id = auth.uid());

create policy "notifications_update_own"
  on public.notifications for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- INSERTポリシーは意図的に作らない(下記のSECURITY DEFINERトリガー/関数経由のみ)。

create index notifications_user_created_idx on public.notifications (user_id, created_at desc);

alter publication supabase_realtime add table public.notifications;

-- ------------------------------------------------------------
-- 誘いを受け取った時に通知する
-- ------------------------------------------------------------
create function public.notify_invite_received()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  select nickname into v_name from public.profiles where id = new.from_user;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    new.to_user,
    'invite_received',
    coalesce(nullif(v_name, ''), '誰か') || 'さんから誘いが届きました',
    new.game || ' · ' || new.when_text,
    new.id
  );
  return new;
end;
$$;

create trigger invites_notify_received
  after insert on public.invites
  for each row execute function public.notify_invite_received();

-- ------------------------------------------------------------
-- 誘いが承認された時に、送った側へ通知する
-- ------------------------------------------------------------
create function public.notify_invite_approved()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if new.status = 'approved' and old.status <> 'approved' then
    select nickname into v_name from public.profiles where id = new.to_user;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      new.from_user,
      'invite_approved',
      coalesce(nullif(v_name, ''), '相手') || 'さんが誘いを承認しました',
      new.game || ' · ' || new.when_text,
      new.id
    );
  end if;
  return new;
end;
$$;

create trigger invites_notify_approved
  after update on public.invites
  for each row execute function public.notify_invite_approved();

-- ------------------------------------------------------------
-- 新着メッセージをトーク相手に通知する
-- ------------------------------------------------------------
create function public.notify_message_received()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promise public.promises;
  v_recipient uuid;
  v_name text;
begin
  select * into v_promise from public.promises where id = new.promise_id;
  v_recipient := case when v_promise.user_a = new.sender_id then v_promise.user_b else v_promise.user_a end;
  select nickname into v_name from public.profiles where id = new.sender_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_recipient,
    'message_received',
    coalesce(nullif(v_name, ''), '相手') || 'さんからメッセージ',
    left(new.body, 60),
    new.promise_id
  );
  return new;
end;
$$;

create trigger messages_notify_received
  after insert on public.messages
  for each row execute function public.notify_message_received();

-- ------------------------------------------------------------
-- 募集への参加を、募集の作成者に通知する
-- ------------------------------------------------------------
create function public.notify_board_joined()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post public.board_posts;
  v_name text;
begin
  select * into v_post from public.board_posts where id = new.post_id;
  select nickname into v_name from public.profiles where id = new.user_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_joined',
    coalesce(nullif(v_name, ''), '誰か') || 'さんが募集に参加しました',
    v_post.game || ' · ' || v_post.when_text,
    new.post_id
  );
  return new;
end;
$$;

create trigger board_participants_notify_joined
  after insert on public.board_participants
  for each row execute function public.notify_board_joined();

-- ------------------------------------------------------------
-- 本人確認の承認/却下でも通知する(0008の関数にnotifications挿入を追加)。
-- それ以外のロジックは0008から変更しない。
-- ------------------------------------------------------------
create or replace function public.approve_identity_verification(p_verification_id uuid, p_is_adult boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'verified', is_adult = p_is_adult, verified_at = now()
    where id = p_verification_id;

  update public.profile_trust_stats
    set is_verified = true, updated_at = now()
    where user_id = v_row.user_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_row.user_id, 'verification_approved', '本人確認が完了しました', 'プロフィールに確認済みバッジが表示されます', p_verification_id);
end;
$$;

create or replace function public.reject_identity_verification(p_verification_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'rejected', rejected_reason = p_reason
    where id = p_verification_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_row.user_id, 'verification_rejected', '本人確認が承認されませんでした', '書類・写真を選び直して再提出してください', p_verification_id);
end;
$$;

grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- notification_prefs: 通知の受け取り設定(設定画面のトグルを実データに)
-- ------------------------------------------------------------
create table public.notification_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  notify_invites boolean not null default true,
  notify_online_friends boolean not null default true,
  notify_recommendations boolean not null default false
);

alter table public.notification_prefs enable row level security;

create policy "notification_prefs_select_own"
  on public.notification_prefs for select
  to authenticated
  using (user_id = auth.uid());

create policy "notification_prefs_update_own"
  on public.notification_prefs for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- INSERTポリシーは意図的に作らない(新規ユーザー作成時のトリガーのみが作成する)。

create function public.handle_new_user_notification_prefs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_prefs (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created_notification_prefs
  after insert on auth.users
  for each row execute function public.handle_new_user_notification_prefs();

-- ------------------------------------------------------------
-- account_requests: アカウント削除・データダウンロード請求
-- 実際の削除/エクスポート処理は運営が手動で行う(初期フェーズ、
-- docs/manual-verification-review.md と同様の運用)。ここではまず
-- 「実際にリクエストが記録される」ことを保証する。
-- ------------------------------------------------------------
create table public.account_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  type text not null check (type in ('data_export', 'account_deletion')),
  status text not null default 'pending' check (status in ('pending', 'processing', 'completed')),
  created_at timestamptz not null default now()
);

alter table public.account_requests enable row level security;

create policy "account_requests_select_own"
  on public.account_requests for select
  to authenticated
  using (user_id = auth.uid());

create policy "account_requests_insert_own"
  on public.account_requests for insert
  to authenticated
  with check (user_id = auth.uid());

-- ステータス更新(処理完了)は運営(service_role)のみ。authenticatedへのUPDATEポリシーは作らない。
-- ============================================================
-- エスクロー予約決済 + Stripe Connect によるホストへの実際の振込
-- ------------------------------------------------------------
-- 方針(重要・法務上の設計判断):
--   ・「購入したコイン」(coin_wallets.balance)と「予約完了で得た
--     報酬コイン」(coin_wallets.earned_balance)を別会計にする。
--     換金(Stripeへの実振込)できるのは earned_balance のみ。
--     balance を換金可能にしてしまうと、盗難クレジットカード等で
--     購入したコインを即座に現金化できてしまい、マネーロンダリング・
--     チャージバック詐欺の温床になるため、意図的に分離する。
--   ・予約確定(create_booking)時点では、これまでどおりゲストの
--     balance のみを減らす(ホストへは何も渡さない=事実上のエスクロー)。
--   ・「プレイ完了」でゲストが解放操作を行って初めて、対応するコイン数が
--     ホストの earned_balance に加算される(ゲストの検収 = 支払い確定、
--     フリマアプリの「受け取り評価」と同じ考え方。ホストが自分で
--     一方的に解放できないようにする)。
--   ・実際の現金化はホストがStripe Connect(Express)アカウントを
--     開設した上で、earned_balance の範囲でのみ請求できる。実際の
--     Stripe Transfer実行はEdge Function(service_role)が行う。
--
--   ⚠️ この設計(ゲストからホストへの実質的な送金の仲介)は、
--   資金決済法上「収納代行」として扱えるか「資金移動業」に該当するか、
--   具体的な運用(コインの有効期限・購入と予約のひも付き方等)次第で
--   判断が分かれる可能性がある。本番投入前に必ず弁護士レビューを
--   受けること(docs/legal/coin-economy-legal-review.md 追記分を参照)。
-- ============================================================

-- ------------------------------------------------------------
-- coin_wallets: ホストの報酬用の別残高を追加
-- ------------------------------------------------------------
alter table public.coin_wallets
  add column earned_balance int not null default 0 check (earned_balance >= 0);

comment on column public.coin_wallets.balance is
  '購入したコインの残高。予約の支払いに使える。換金は不可(前払式支払手段としての性質を維持するため)。';
comment on column public.coin_wallets.earned_balance is
  'ホストとして完了した予約から得た報酬コインの残高。Stripe Connect経由でのみ換金できる。購入コイン(balance)とは会計を分離している。';

-- coin_transactions.type に完了報酬/払い出しの区分を追加
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in ('purchase', 'booking_spend', 'refund', 'bonus', 'booking_earned', 'payout'));

-- ------------------------------------------------------------
-- complete_booking: ゲストが「プレイ完了」を確定し、エスクローを解放する。
-- ゲスト本人のみが呼べる(ホストが自分で解放することはできない)。
-- ------------------------------------------------------------
create function public.complete_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_COMPLETE';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_CONFIRMABLE';
  end if;

  update public.bookings set status = 'completed' where id = p_booking_id;

  update public.coin_wallets
    set earned_balance = earned_balance + v_booking.coins
    where user_id = v_booking.host_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'complete_booking');
end;
$$;

revoke all on function public.complete_booking(uuid) from public;
grant execute on function public.complete_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- host_payout_accounts: ホストのStripe Connect(Express)アカウント
-- ------------------------------------------------------------
create table public.host_payout_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  stripe_account_id text not null unique,
  payouts_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.host_payout_accounts enable row level security;

create policy "host_payout_accounts_select_own"
  on public.host_payout_accounts for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEは意図的にポリシーを作らない(create-connect-account /
-- stripe-webhook Edge Function が service_role で行う)。

create trigger host_payout_accounts_set_updated_at
  before update on public.host_payout_accounts
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- payouts: 換金(Stripe Transfer)の履歴
-- ------------------------------------------------------------
create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  coins int not null check (coins > 0),
  amount_yen int not null check (amount_yen > 0),
  stripe_transfer_id text,
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed')),
  failure_reason text,
  created_at timestamptz not null default now()
);

alter table public.payouts enable row level security;

create policy "payouts_select_own"
  on public.payouts for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEは意図的にポリシーを作らない(request-payout Edge Function
-- が下記RPC経由(service_role)でのみ行う)。

-- ------------------------------------------------------------
-- reserve_payout: 換金リクエストの残高チェック+仮確保をアトミックに行う。
-- 実際のStripe Transfer実行はEdge Function側で行い、成功/失敗に応じて
-- finalize_payout / fail_payout を呼ぶ。service_role専用(clientから直接
-- 呼べない。実際の送金なしに残高だけ動かせてしまうため)。
-- ------------------------------------------------------------
create function public.reserve_payout(p_user_id uuid, p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance int;
  v_payouts_enabled boolean;
  v_payout_id uuid;
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select coalesce(payouts_enabled, false) into v_payouts_enabled
  from public.host_payout_accounts where user_id = p_user_id;
  if not coalesce(v_payouts_enabled, false) then
    raise exception 'PAYOUTS_NOT_ENABLED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = p_user_id for update;
  if v_balance is null or v_balance < p_coins then
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = p_user_id;

  insert into public.payouts (user_id, coins, amount_yen, status)
    values (p_user_id, p_coins, p_coins, 'pending')
    returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, -p_coins, 'payout', 'reserve_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

revoke all on function public.reserve_payout(uuid, int) from public;
-- authenticatedには意図的にgrantしない(service_role専用)。

create function public.finalize_payout(p_payout_id uuid, p_stripe_transfer_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.payouts
    set status = 'paid', stripe_transfer_id = p_stripe_transfer_id
    where id = p_payout_id and status = 'pending';
end;
$$;

revoke all on function public.finalize_payout(uuid, text) from public;

create function public.fail_payout(p_payout_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payout public.payouts;
begin
  select * into v_payout from public.payouts where id = p_payout_id and status = 'pending' for update;
  if v_payout.id is null then
    return;
  end if;

  update public.payouts set status = 'failed', failure_reason = p_reason where id = p_payout_id;

  -- 送金に失敗したので確保していたコインを払い戻す
  update public.coin_wallets set earned_balance = earned_balance + v_payout.coins where user_id = v_payout.user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_payout.user_id, v_payout.coins, 'refund', 'fail_payout:' || p_payout_id);
end;
$$;

revoke all on function public.fail_payout(uuid, text) from public;
-- ============================================================
-- 換金方式の変更: Stripe Connect → 自社銀行振込(GameRoom型)
-- ------------------------------------------------------------
-- 方針(2026-07-21 決定):
--   ・コイン購入は引き続き Stripe Checkout(0009)。
--   ・ホストへの報酬振込は、Stripe Connect をやめて自社の総合振込
--     (ネットバンキングへのCSV一括アップロード)で行う。
--     理由: Stripe Connect の日本料金(入金ごと0.25%+¥250、
--     有効アカウントごと月額¥200)では、少額ホストを多数抱える
--     本サービスのモデルでは自社振込のほうが大幅に安いため。
--   ・エスクロー設計(0013)はそのまま:
--     purchase balance と earned_balance は別会計、
--     ゲストの complete_booking でのみ報酬が確定する。
--   ・換金の流れ:
--       ホスト: 口座登録(host_bank_accounts) → 換金申請(request_bank_payout)
--       運営:   月次で締め → 振込リストをSQLで出力(docs/payouts-bank-operations.md)
--               → 総合振込を実行 → mark_payout_paid / mark_payout_failed で消し込み
--   ・手数料: 申請1件につき 300コイン(=¥300)をコイン側で控除する
--     (GameRoomと同方式)。振込額 = 申請コイン − 300。
--   ・最低申請額: 1,000コイン。手数料負けと少額振込の事務コストを防ぐ。
--
--   ⚠️ 自社振込は「資金移動の実行主体が当社になる」ため、
--   資金移動業/収納代行の法的整理が Stripe Connect 利用時より
--   シビアになる。本番投入前に必ず弁護士レビューを受けること
--   (docs/legal/coin-economy-legal-review.md §7.2)。
-- ============================================================

-- ------------------------------------------------------------
-- Stripe Connect 用のオブジェクトを撤去
-- (create-connect-account / request-payout Edge Function も削除済み)
-- ------------------------------------------------------------
drop function if exists public.reserve_payout(uuid, int);
drop function if exists public.finalize_payout(uuid, text);
drop function if exists public.fail_payout(uuid, text);
drop table if exists public.host_payout_accounts;

alter table public.payouts drop column if exists stripe_transfer_id;

-- ------------------------------------------------------------
-- host_bank_accounts: ホストの振込先口座
-- 本人のみ登録・閲覧・更新できる。運営はservice_role(SQL Editor)で参照。
-- カナ名義は全銀フォーマットに合わせてカタカナ+英数+記号のみ許可
-- (ひらがな→カタカナ等の正規化はクライアント側で行う)。
-- ------------------------------------------------------------
create table public.host_bank_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  bank_name text not null check (char_length(bank_name) between 1 and 30),
  bank_code text not null check (bank_code ~ '^[0-9]{4}$'),
  branch_name text not null check (char_length(branch_name) between 1 and 30),
  branch_code text not null check (branch_code ~ '^[0-9]{3}$'),
  account_type text not null check (account_type in ('普通', '当座')),
  account_number text not null check (account_number ~ '^[0-9]{7}$'),
  account_holder_kana text not null
    check (account_holder_kana ~ '^[ァ-ヶー0-9A-Z()（）./\- 　]+$'
           and char_length(account_holder_kana) between 1 and 48),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.host_bank_accounts is
  'ホストの報酬振込先口座。運営が総合振込(全銀CSV)を作成する際にservice_roleで参照する。';

alter table public.host_bank_accounts enable row level security;

create policy "host_bank_accounts_select_own"
  on public.host_bank_accounts for select
  to authenticated
  using (user_id = auth.uid());

create policy "host_bank_accounts_insert_own"
  on public.host_bank_accounts for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "host_bank_accounts_update_own"
  on public.host_bank_accounts for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create trigger host_bank_accounts_set_updated_at
  before update on public.host_bank_accounts
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- payouts: 自社振込用の列を追加
-- ・fee_yen: 申請時に控除した振込手数料(コイン=円)
-- ・振込先スナップショット: 申請後にホストが口座を変更しても
--   振込リストが変わらないよう、申請時点の口座情報を写し取る
-- ------------------------------------------------------------
alter table public.payouts
  add column fee_yen int not null default 0 check (fee_yen >= 0),
  add column bank_name text,
  add column bank_code text,
  add column branch_name text,
  add column branch_code text,
  add column account_type text,
  add column account_number text,
  add column account_holder_kana text,
  add column paid_at timestamptz;

comment on column public.payouts.amount_yen is
  '実際に振り込む金額(円)。申請コイン − 手数料(fee_yen)。';

-- ------------------------------------------------------------
-- request_bank_payout: ホスト本人が換金を申請する。
-- earned_balance から申請コインを引き落とし、payouts(pending)を作る。
-- 実際の振込は運営の総合振込で行い、mark_payout_paid で確定する。
-- ------------------------------------------------------------
create function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;       -- 振込手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 1000; -- 最低申請コイン
  v_uid uuid := auth.uid();
  v_balance int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;
  if v_balance is null or v_balance < p_coins then
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;

-- ------------------------------------------------------------
-- mark_payout_paid / mark_payout_failed: 運営の消し込み用。
-- service_role(SQL Editor / 管理スクリプト)専用。クライアントには
-- 意図的にgrantしない(振込せずに残高だけ確定できてしまうため)。
-- ------------------------------------------------------------
create function public.mark_payout_paid(p_payout_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.payouts
    set status = 'paid', paid_at = now()
    where id = p_payout_id and status = 'pending';
end;
$$;

revoke all on function public.mark_payout_paid(uuid) from public;

create function public.mark_payout_failed(p_payout_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payout public.payouts;
begin
  select * into v_payout from public.payouts where id = p_payout_id and status = 'pending' for update;
  if v_payout.id is null then
    return;
  end if;

  update public.payouts set status = 'failed', failure_reason = p_reason where id = p_payout_id;

  -- 振込できなかったので、手数料も含め申請コイン全額を払い戻す
  update public.coin_wallets set earned_balance = earned_balance + v_payout.coins where user_id = v_payout.user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_payout.user_id, v_payout.coins, 'refund', 'mark_payout_failed:' || p_payout_id);
end;
$$;

revoke all on function public.mark_payout_failed(uuid, text) from public;
-- ============================================================
-- 予約ライフサイクルの完成: キャンセル連動・自動確定・通知
-- ------------------------------------------------------------
-- GameRoomの方式を参考にした確定ルール:
--   ・直前(開始1時間前以降)のゲスト都合キャンセルは再付与なし。
--     没収分のコインは**ホストの報酬(earned_balance)として付与**する
--     (GameRoomの「出品者都合でない限り売上を出品者に付与」と同思想。
--      運営が没収コインを取り込むと役務なき対価の受領になり法的にも
--      説明しづらいため、機会損失を被ったホストへの補償とする)
--   ・ゲストが「プレイ完了」を確定しない場合、予約時刻から72時間で
--     自動確定してホストに報酬を渡す(フリマアプリの自動受取評価と
--     同方式。ホストの報酬が宙に浮くのを防ぐ)
--
-- このマイグレーションで直すこと:
--   1. cancel_booking が promise(約束)を残したままにするバグ
--      → トークが「予約中」のまま生き続けるので、promiseも閉じて相手に通知
--   2. complete_booking も promise を完了に遷移させ、ホストに通知
--   3. auto_complete_bookings(): 72時間経過分の自動確定(+pg_cronで毎時実行)
-- ============================================================

-- 通知typeを追加(booking_cancelled / booking_completed)
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed'
  ));

-- ------------------------------------------------------------
-- cancel_booking: 0003版に promise の連動と相手への通知を追加
-- (返還ルール自体は0003から変更なし)
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
  else
    -- 直前のゲスト都合キャンセル: 没収分はホストの報酬として付与(機会損失の補償)
    update public.coin_wallets set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  -- 約束(トーク)も閉じる
  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  -- 相手に通知
  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_other,
    'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case
      when v_refund then 'コインは全額再付与されました'
      else '開始1時間前以降のキャンセルのため、コインはホストの報酬として確定しました'
    end,
    p_booking_id
  );
end;
$$;

-- ------------------------------------------------------------
-- complete_booking: 0013版に promise の完了遷移とホストへの通知を追加
-- ------------------------------------------------------------
create or replace function public.complete_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_COMPLETE';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_CONFIRMABLE';
  end if;

  update public.bookings set status = 'completed' where id = p_booking_id;

  update public.coin_wallets
    set earned_balance = earned_balance + v_booking.coins
    where user_id = v_booking.host_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'complete_booking');

  update public.promises set status = 'completed' where booking_id = p_booking_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.host_id,
    'booking_completed',
    'プレイ完了が確定しました',
    v_booking.coins || 'コインが報酬として確定しました。ウォレットから換金申請できます',
    p_booking_id
  );
end;
$$;

-- ------------------------------------------------------------
-- auto_complete_bookings: 予約時刻から72時間、ゲストの確定操作が
-- ないconfirmedの予約を自動確定する(規約第9条4項)。
-- service_role専用(pg_cron、または運営が手動実行)。
-- ------------------------------------------------------------
create function public.auto_complete_bookings()
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

revoke all on function public.auto_complete_bookings() from public;
-- authenticatedには意図的にgrantしない(service_role/cron専用)。

-- pg_cronが使える環境(Supabaseは有効化可能)なら毎時実行を登録する。
-- 使えない環境ではスキップされる(その場合は docs の手順に従い手動実行)。
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule(
      'auto-complete-bookings',
      '23 * * * *',
      'select public.auto_complete_bookings()'
    );
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end
$do$;
-- ============================================================
-- ボーナスコイン(無償)を有償コインと分離し、有償を先に消費する
-- ------------------------------------------------------------
-- 弁護士回答Q3③への対応:
--   ・無償ボーナス分は対価性がなく、換金されると当社の受領額を超える
--     払出し(=販促費の流出)になる。これを最小化するため:
--       ① 残高を「有償(balance)」「無償ボーナス(bonus_balance)」に分離
--       ② 予約消費は有償分から先に減らす(有償先消費)
--       ③ ボーナス付与は type='bonus' で明示的に記録する
--   ・あわせてコインパックのボーナス率をGameRoom水準(ほぼ0、大口のみ
--     0.5〜1%)に引き下げる。換金があるサービスでは大きなボーナスは
--     そのまま現金流出・不正換金の温床になるため。
--
--   注: 会計の呼称
--     balance         = 有償の購入コイン(換金不可・予約に使える)
--     bonus_balance   = 無償ボーナスコイン(換金不可・予約に使える。有償の後に消費)
--     earned_balance  = ホストの報酬コイン(換金可能・0013)
-- ============================================================

-- ------------------------------------------------------------
-- coin_wallets: 無償ボーナス残高を分離
-- ------------------------------------------------------------
alter table public.coin_wallets
  add column bonus_balance int not null default 0 check (bonus_balance >= 0);

comment on column public.coin_wallets.bonus_balance is
  '無償で付与されたボーナスコインの残高。予約に使えるが、有償コイン(balance)を使い切った後に消費される。換金は不可。';

-- ------------------------------------------------------------
-- bookings: 消費したコインの有償/無償の内訳を記録
-- (キャンセル時に正しいバケットへ払い戻すため)
-- ------------------------------------------------------------
alter table public.bookings
  add column paid_coins int not null default 0 check (paid_coins >= 0),
  add column bonus_coins int not null default 0 check (bonus_coins >= 0);

comment on column public.bookings.paid_coins is '予約消費のうち有償コインから引いた分。';
comment on column public.bookings.bonus_coins is '予約消費のうち無償ボーナスコインから引いた分。';

-- ------------------------------------------------------------
-- credit_coins_for_purchase: 有償分とボーナス分を別会計で付与
-- (webhookから p_coins=有償, p_bonus_coins=無償 を受け取る)
-- ------------------------------------------------------------
drop function if exists public.credit_coins_for_purchase(uuid, text, int, int, text, text);

create function public.credit_coins_for_purchase(
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
as $$
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 既に処理済みのセッションなら冪等に終了
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins + coalesce(p_bonus_coins, 0), p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets
    set balance = balance + p_coins,
        bonus_balance = bonus_balance + coalesce(p_bonus_coins, 0)
    where user_id = p_user_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);

  if coalesce(p_bonus_coins, 0) > 0 then
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, p_bonus_coins, 'bonus', 'stripe:' || p_session_id);
  end if;
end;
$$;

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- create_booking: 有償先消費に変更(0010版をベースに)
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

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets
  where user_id = v_guest_id
  for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 有償分から先に消費し、足りない分だけボーナスから引く
  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus)
  returning id into v_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  insert into public.promises (booking_id, user_a, user_b)
  values (v_booking_id, v_guest_id, p_host_id)
  returning id into v_promise_id;

  return v_promise_id;
end;
$$;

-- ------------------------------------------------------------
-- cancel_booking: 払い戻しを有償/無償の元バケットへ戻す(0015版をベースに)
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
    -- 消費した内訳どおり、有償は有償へ・ボーナスはボーナスへ払い戻す
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 直前のゲスト都合キャンセル: 没収分はホストの報酬として付与(機会損失の補償)
    update public.coin_wallets set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', p_booking_id, 'cancel_booking_late');
  end if;

  update public.promises set status = 'cancelled' where booking_id = p_booking_id;

  v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_other,
    'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case
      when v_refund then 'コインは全額再付与されました'
      else '開始1時間前以降のキャンセルのため、コインはホストの報酬として確定しました'
    end,
    p_booking_id
  );
end;
$$;

-- ------------------------------------------------------------
-- コインパックのボーナスをGameRoom水準に引き下げ、ラインナップを更新
--   ¥500〜¥10,000: ボーナスなし / ¥20,000: +100(0.5%) / ¥50,000: +500(1%)
-- ------------------------------------------------------------
update public.coin_packs set active = false;

insert into public.coin_packs (id, coins, bonus_coins, price_yen, sort, active) values
  ('pack_500',    500,     0,   500, 1, true),
  ('pack_1000',   1000,    0,  1000, 2, true),
  ('pack_3000',   3000,    0,  3000, 3, true),
  ('pack_5000',   5000,    0,  5000, 4, true),
  ('pack_10000',  10000,   0, 10000, 5, true),
  ('pack_20000',  20000,  100, 20000, 6, true),
  ('pack_50000',  50000,  500, 50000, 7, true)
on conflict (id) do update
  set coins = excluded.coins,
      bonus_coins = excluded.bonus_coins,
      price_yen = excluded.price_yen,
      sort = excluded.sort,
      active = true;
-- ============================================================
-- ホストの予約諾否(GameRoom式「承諾で契約成立」)
-- ------------------------------------------------------------
-- 弁護士回答Q8への対応(労務リスクの低減):
--   予約は即時確定ではなく、ホストが承諾して初めて成立する。
--   これにより「ホストは諾否の自由を持つ独立した役務提供者」という
--   整理が明確になる(当社が一方的に労務を割り当てる構造ではない)。
--
-- 状態遷移:
--   requested  … ゲストが申込み、コインは確保(有償先消費)。ホストの応答待ち
--     ├─ approve_booking(ホスト) → confirmed (約束=トークが成立)
--     ├─ decline_booking(ホスト) → declined_by_host (コイン全額返却)
--     ├─ cancel_booking(ゲスト)  → cancelled_by_guest (コイン全額返却・無ペナルティ)
--     └─ 24時間無応答          → expire_stale_booking_requests で自動辞退・返却
--   confirmed 以降は 0015 のとおり(complete / cancel / 72h自動確定)
-- ============================================================

-- 予約ステータスに requested / declined_by_host を追加
alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings
  add constraint bookings_status_check
  check (status in (
    'requested', 'confirmed', 'completed',
    'cancelled_by_guest', 'cancelled_by_host', 'declined_by_host',
    'no_show_host', 'no_show_guest'
  ));

-- 通知タイプに booking_requested / booking_approved を追加
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved'
  ));

-- ------------------------------------------------------------
-- create_booking: 即時確定をやめ、requested(承諾待ち)で作る。
-- コインは確保(有償先消費)するが、約束(トーク)はまだ作らない。
-- 戻り値は booking_id(承諾待ち画面用。約束はまだ無い)。
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
  from public.host_settings
  where user_id = p_host_id
  for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_coins := round(v_hourly_rate * p_duration_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets
  where user_id = v_guest_id
  for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested')
  returning id into v_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  -- ホストに予約リクエストを通知
  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id,
    'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

-- ------------------------------------------------------------
-- approve_booking: ホストが予約を承諾する。約束(トーク)が成立する。
-- 戻り値は promise_id(トークを開くのに使う)。
-- ------------------------------------------------------------
create function public.approve_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 承諾時点を役務の開始時刻とみなす(72時間自動確定の起点をここに合わせる)
  update public.bookings
    set status = 'confirmed', scheduled_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を承諾しました',
    'トークが始まりました。プレイの準備をしましょう',
    v_promise_id
  );

  return v_promise_id;
end;
$$;

revoke all on function public.approve_booking(uuid) from public;
grant execute on function public.approve_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- decline_booking: ホストが予約を辞退する。コインを全額返却する。
-- ------------------------------------------------------------
create function public.decline_booking(p_booking_id uuid)
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

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_DECLINE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = p_booking_id;

  -- 消費した内訳どおりに全額返却
  update public.coin_wallets
    set balance = balance + v_booking.paid_coins,
        bonus_balance = bonus_balance + v_booking.bonus_coins
    where user_id = v_booking.guest_id;
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'decline_booking');

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_cancelled',
    coalesce(nullif(v_host_name, ''), 'ホスト') || 'さんが予約を辞退しました',
    'コインは全額返却されました',
    p_booking_id
  );
end;
$$;

revoke all on function public.decline_booking(uuid) from public;
grant execute on function public.decline_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- cancel_booking: requested(承諾待ち)のゲスト取消にも対応(0016版を拡張)。
--   requested → 全額返却・無ペナルティ(まだ約束は成立していない)
--   confirmed 以降は従来どおり(1時間ルール・ドタキャン反映)
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

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then
    raise exception 'FORBIDDEN';
  end if;

  -- 承諾待ちの取消: 誰が取り消しても全額返却・無ペナルティ・約束なし
  if v_booking.status = 'requested' then
    update public.bookings
      set status = case when v_uid = v_booking.host_id then 'declined_by_host' else 'cancelled_by_guest' end,
          cancel_reason = p_reason, cancelled_at = now()
      where id = p_booking_id;

    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', p_booking_id, 'cancel_requested');

    v_other := case when v_uid = v_booking.host_id then v_booking.guest_id else v_booking.host_id end;
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other,
      'booking_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが予約リクエストを取り消しました',
      'コインは全額返却されました',
      p_booking_id
    );
    return;
  end if;

  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_CANCELLABLE';
  end if;

  if v_uid = v_booking.host_id then
    v_refund := true;
    v_new_status := 'cancelled_by_host';
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
    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
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
  values (
    v_other,
    'booking_cancelled',
    coalesce(nullif(v_name, ''), '相手') || 'さんが予約をキャンセルしました',
    case
      when v_refund then 'コインは全額再付与されました'
      else '開始1時間前以降のキャンセルのため、コインはホストの報酬として確定しました'
    end,
    p_booking_id
  );
end;
$$;

-- ------------------------------------------------------------
-- expire_stale_booking_requests: 24時間ホストが応答しない requested を
-- 自動辞退し、コインを返却する。service_role/cron専用。
-- ------------------------------------------------------------
create function public.expire_stale_booking_requests()
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
    where status = 'requested'
      and created_at + interval '24 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'declined_by_host', cancelled_at = now() where id = v_booking.id;

    update public.coin_wallets
      set balance = balance + v_booking.paid_coins,
          bonus_balance = bonus_balance + v_booking.bonus_coins
      where user_id = v_booking.guest_id;
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_booking.coins, 'refund', v_booking.id, 'expire_request');

    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_booking.guest_id,
      'booking_cancelled',
      '予約リクエストが期限切れになりました',
      'ホストからの応答がなかったため、コインを全額返却しました',
      v_booking.id
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_stale_booking_requests() from public;

-- cronに登録(pg_cronが使える環境のみ。毎時47分に実行)
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule(
      'expire-stale-booking-requests',
      '47 * * * *',
      'select public.expire_stale_booking_requests()'
    );
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end
$do$;
-- ============================================================
-- コインの有効期限(取得日から6か月未満)を実装する
-- ------------------------------------------------------------
-- 事業判断(2026-07-21): コインの有効期限を「取得日から起算して6か月を
-- 経過する日の前日まで」= 6か月未満に設定する。これにより資金決済法上の
-- 適用除外(発行の日から6月内に限り使用できる前払式支払手段)の要件を満たし、
-- 表示義務・届出・供託が不要になりうる(最終文言は弁護士確認: Q10)。
--
-- 適用除外を「本当に」成立させるには、コインが実際に6か月で失効する必要が
-- あるため、ロット(取得ロット)単位で有効期限を管理し、期限切れを失効させる。
--   ・購入コイン(paid)とボーナスコイン(bonus)は 前払式支払手段 として失効対象。
--   ・報酬コイン(earned_balance)は役務対価の未払金であり前払式ではないため、
--     この失効の対象外(換金で精算される)。
--   ・消費は「期限が近いロットから先に(FIFO)」引く。有償先消費(0016)は維持。
--   ・balance / bonus_balance は「未失効ロット合計」のキャッシュとして維持し、
--     フロントの残高表示はこれまでどおり動く。
-- ============================================================

-- coin_transactions.type に失効(expire)を追加
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in ('purchase', 'booking_spend', 'refund', 'bonus', 'booking_earned', 'payout', 'expire'));

-- ------------------------------------------------------------
-- coin_lots: 取得ロット(有効期限つき)。paid/bonusのみを管理する。
-- ------------------------------------------------------------
create table public.coin_lots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('paid', 'bonus')),
  remaining int not null check (remaining >= 0),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

comment on table public.coin_lots is
  '購入/ボーナスコインの取得ロット。残(remaining)と有効期限(expires_at)を持ち、期限が近い順に消費・失効する。balance/bonus_balanceは未失効ロット合計のキャッシュ。';

alter table public.coin_lots enable row level security;

create policy "coin_lots_select_own"
  on public.coin_lots for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは SECURITY DEFINER 関数経由のみ(INSERT/UPDATEポリシーは作らない)。

create index coin_lots_consume_idx on public.coin_lots (user_id, kind, expires_at) where remaining > 0;

-- コインの有効期限(取得日から6か月を経過する日の前日まで)
create function public.coin_expiry_from(p_ts timestamptz)
returns timestamptz
language sql
immutable
as $$
  select p_ts + interval '6 months' - interval '1 day';
$$;

-- ------------------------------------------------------------
-- _consume_coin_lots: 指定種別のロットを期限が近い順に p_amount 減らす。
-- 内部ヘルパー(残高チェックは呼び出し側で済ませている前提。ロットが
-- キャッシュに満たない場合(移行前の残高等)は減らせる分だけ減らす)。
-- ------------------------------------------------------------
create function public._consume_coin_lots(p_user_id uuid, p_kind text, p_amount int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_left int := p_amount;
  v_lot record;
  v_take int;
begin
  if p_amount <= 0 then
    return;
  end if;
  for v_lot in
    select id, remaining from public.coin_lots
    where user_id = p_user_id and kind = p_kind and remaining > 0
    order by expires_at asc
    for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.remaining, v_left);
    update public.coin_lots set remaining = remaining - v_take where id = v_lot.id;
    v_left := v_left - v_take;
  end loop;
end;
$$;

revoke all on function public._consume_coin_lots(uuid, text, int) from public;

-- ------------------------------------------------------------
-- 既存残高のロットを埋める(移行): balance/bonus_balance>0で
-- ロットが無いユーザーに、6か月の有効期限でロットを作る。
-- ------------------------------------------------------------
insert into public.coin_lots (user_id, kind, remaining, expires_at)
select w.user_id, 'paid', w.balance, public.coin_expiry_from(now())
from public.coin_wallets w
where w.balance > 0
  and not exists (select 1 from public.coin_lots l where l.user_id = w.user_id and l.kind = 'paid');

insert into public.coin_lots (user_id, kind, remaining, expires_at)
select w.user_id, 'bonus', w.bonus_balance, public.coin_expiry_from(now())
from public.coin_wallets w
where w.bonus_balance > 0
  and not exists (select 1 from public.coin_lots l where l.user_id = w.user_id and l.kind = 'bonus');

-- ------------------------------------------------------------
-- credit_coins_for_purchase: 付与時に有効期限つきロットも作る(0016版に追加)
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
as $$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins + coalesce(p_bonus_coins, 0), p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets
    set balance = balance + p_coins,
        bonus_balance = bonus_balance + coalesce(p_bonus_coins, 0)
    where user_id = p_user_id;

  insert into public.coin_lots (user_id, kind, remaining, expires_at)
    values (p_user_id, 'paid', p_coins, v_expires);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);

  if coalesce(p_bonus_coins, 0) > 0 then
    insert into public.coin_lots (user_id, kind, remaining, expires_at)
      values (p_user_id, 'bonus', p_bonus_coins, v_expires);
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, p_bonus_coins, 'bonus', 'stripe:' || p_session_id);
  end if;
end;
$$;

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- create_booking: 消費時にロットも期限が近い順に減らす(0017版に追加)
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

  perform public._consume_coin_lots(v_guest_id, 'paid', v_from_paid);
  perform public._consume_coin_lots(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status)
  values (v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested')
  returning id into v_booking_id;

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
-- 返金時のロット復元ヘルパー: 返金分を新しい6か月期限のロットで戻す。
--
-- ⚠️ 【0030で修正済み】当初「各ロットが6か月未満なら適用除外の趣旨に
--    反しない」と整理していたが、これは誤りだった。資金決済法4条2号の基準は
--    「発行の日から6月内」であり、購入から5か月後にキャンセルすると
--    当初発行日からの通算で約11か月使えてしまう。
--    0030_refund_lot_expiry.sql で、消費したロットの当初の期限を記録し
--    返金時はその期限のまま戻すよう改めた(この関数自体も0030で削除される)。
--    経緯: docs/legal/lawyer-review-answers-round2-draft.md
-- ------------------------------------------------------------
create function public._refund_coin_lots(p_user_id uuid, p_paid int, p_bonus int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
begin
  if p_paid > 0 then
    insert into public.coin_lots (user_id, kind, remaining, expires_at)
      values (p_user_id, 'paid', p_paid, v_expires);
  end if;
  if p_bonus > 0 then
    insert into public.coin_lots (user_id, kind, remaining, expires_at)
      values (p_user_id, 'bonus', p_bonus, v_expires);
  end if;
end;
$$;

revoke all on function public._refund_coin_lots(uuid, int, int) from public;

-- cancel_booking / decline_booking / expire_stale_booking_requests は、
-- 返金時に _refund_coin_lots を呼ぶよう作り直す(0017版がベース)。
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
    perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
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
    perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
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
  perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
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
    perform public._refund_coin_lots(v_booking.guest_id, v_booking.paid_coins, v_booking.bonus_coins);
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
-- expire_coins: 期限切れロットを失効させ、キャッシュ残高を減らす。
-- service_role/cron専用。1日1回の実行を想定。
-- ------------------------------------------------------------
create function public.expire_coins()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot record;
  v_drop int;
  v_count int := 0;
begin
  for v_lot in
    select id, user_id, kind, remaining from public.coin_lots
    where remaining > 0 and expires_at < now()
    for update skip locked
  loop
    v_drop := v_lot.remaining;
    update public.coin_lots set remaining = 0 where id = v_lot.id;

    if v_lot.kind = 'paid' then
      update public.coin_wallets set balance = greatest(0, balance - v_drop) where user_id = v_lot.user_id;
    else
      update public.coin_wallets set bonus_balance = greatest(0, bonus_balance - v_drop) where user_id = v_lot.user_id;
    end if;

    insert into public.coin_transactions (user_id, amount, type, note)
      values (v_lot.user_id, -v_drop, 'expire', 'lot:' || v_lot.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.expire_coins() from public;

-- cronに登録(pg_cronが使える環境のみ。毎日 03:11 に実行)
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('expire-coins', '11 3 * * *', 'select public.expire_coins()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end
$do$;
-- ============================================================
-- ギフト(投げ銭): トークの相手にコインを贈る
-- ------------------------------------------------------------
-- 目的: 予約(時間の対価)とは別に、「楽しかった」「応援したい」という
-- 気持ちをコインで相手に贈れるようにする。ホストがより稼げる導線を増やす。
--
-- 会計・不正対策(0016の方針を踏襲):
--   ・ギフトの原資は「有償の購入コイン(balance)」のみ。
--     無償ボーナス(bonus_balance)は換金可能なearned_balanceに化けさせない
--     (無償→換金の抜け道を塞ぐ)。よって paid 残高が不足なら失敗させる。
--   ・受け取った側は earned_balance(換金可能な報酬コイン)として受領する。
--     ホスト報酬(0013/0014)と同じ扱いで、換金フローで精算できる。
--   ・運営マージンは購入額と換金(手数料)の差で従来どおり確保。ギフト自体に
--     追加の手数料は取らない(ホストにやさしい設計・「稼げる」導線を優先)。
--
-- 安全:
--   ・贈れる相手は「トーク(promise)の相手」に限定する。任意ユーザーへは
--     贈れない(実際につながった相手だけ)。これで乱用を構造的に抑える。
--   ・どちらか一方でもブロックしている関係では贈れない。
-- ============================================================

-- coin_transactions.type にギフトを追加
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus',
    'booking_earned', 'payout', 'expire',
    'gift_sent', 'gift_received'
  ));

-- notifications.type にギフト受領を追加
-- (0017までの全種別を維持したうえで gift_received を足すこと。
--  既存行に booking_completed / booking_approved があるため欠かすと制約違反になる)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received'
  ));

-- ------------------------------------------------------------
-- gifts: 贈答の記録
-- ------------------------------------------------------------
create table public.gifts (
  id uuid primary key default gen_random_uuid(),
  promise_id uuid not null references public.promises (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  receiver_id uuid not null references auth.users (id) on delete cascade,
  coins int not null check (coins > 0),
  message text check (message is null or char_length(message) <= 100),
  created_at timestamptz not null default now(),
  check (sender_id <> receiver_id)
);

comment on table public.gifts is
  'トークの相手に贈るギフト(投げ銭)。原資は贈り主の有償コイン、受領者はearned_balanceで受け取る。';

alter table public.gifts enable row level security;

-- 当事者(贈り主・受領者)だけが閲覧できる。書き込みは send_gift 経由のみ。
create policy "gifts_select_participant"
  on public.gifts for select
  to authenticated
  using (sender_id = auth.uid() or receiver_id = auth.uid());

create index gifts_receiver_idx on public.gifts (receiver_id, created_at desc);
create index gifts_promise_idx on public.gifts (promise_id, created_at);

-- ------------------------------------------------------------
-- send_gift: トーク相手にコインを贈る
--   p_promise_id  贈る相手とのトーク(promise)
--   p_coins       贈るコイン数(10〜50000)
--   p_message     添えるひとこと(任意・100字まで)
-- ------------------------------------------------------------
create function public.send_gift(p_promise_id uuid, p_coins int, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_gift_id uuid;
  v_sender_name text;
  v_msg text;
  v_body text;
begin
  if v_sender is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < 10 or p_coins > 50000 then
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

  if exists (
    select 1 from public.blocks
    where (blocker_id = v_sender and blocked_id = v_receiver)
       or (blocker_id = v_receiver and blocked_id = v_sender)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 有償残高のみを原資にする(ボーナスは使わせない)
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  -- 受領者のウォレットが無ければ作成してから加算(換金可能なearned_balanceへ)
  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg)
    returning id into v_gift_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_sender, -p_coins, 'gift_sent', 'gift:' || v_gift_id);
  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_receiver, p_coins, 'gift_received', 'gift:' || v_gift_id);

  -- トークに履歴として残す(Realtimeで相手にも即時表示)
  v_body := '🎁 ' || p_coins || 'コインのギフトを贈りました';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 受領者へ通知(ベルのバッジを光らせる)
  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんからギフトが届きました',
    p_coins || 'コインを受け取りました' || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

revoke all on function public.send_gift(uuid, int, text) from public;
grant execute on function public.send_gift(uuid, int, text) to authenticated;
-- ============================================================
-- ギフト(投げ銭)を「役務に付随する謝礼」へ作り替える(弁護士Q11回答対応)
-- ------------------------------------------------------------
-- 弁護士見解(2026-07-22)の要旨:
--   ・現行の「トーク相手なら誰でも・自由に・換金可」は最もリスクが高い。
--     役務対価が不明確な任意の価値移転は、収納代行の説明が苦しく、為替取引
--     (資金移動業)該当リスクも上がる。
--   ・「実際に一緒に遊んだ相手への“ありがとうチップ”」に限定すれば、役務に
--     付随する謝礼として整理しやすく、各規制のリスクを相対的に下げられる。
--   ・換金ロンダリング(クレカ現金化)対策として、保留期間・上限・相互送金禁止・
--     チャージ直後送金禁止・端末/IP監視を推奨。
--
-- 事業判断(2026-07-22):
--   ・送信条件 = 送り主と受け手の間に「完了した予約(status='completed')」が
--     1回以上あること(付随謝礼として最小要件)。
--   ・上限: 1回50,000 / 直近24時間で50,000 / 直近30日で200,000(コイン=円)。
--   ・相互送金禁止(A→Bが存在すればB→Aは不可、逆も同様)。
--   ・チャージ後24時間は送金不可(クレカ現金化の抑止)。
--   ・受領ギフトは7日間は換金不可(request_bank_payout側で保留を差し引く)。
--   ・同一端末/IP/カード等の自動監視は、クライアントの端末情報取得が必要な
--     ため本マイグレーションの範囲外(別途フォロー)。ここではサーバ側で
--     機械的に判定できる制限をすべて実装する。
-- ============================================================

-- ------------------------------------------------------------
-- send_gift: 完了予約のある相手への“ありがとうギフト”に限定し、各種の
-- 不正・マネロン対策を組み込む(0019版を置き換え)。
-- ------------------------------------------------------------
create or replace function public.send_gift(p_promise_id uuid, p_coins int, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_per_tx    constant int := 50000;   -- 1回あたり上限
  c_max_per_day   constant int := 50000;   -- 直近24時間の合計上限
  c_max_per_month constant int := 200000;  -- 直近30日の合計上限
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_last_purchase timestamptz;
  v_sum_day int;
  v_sum_month int;
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

  -- ブロック関係では贈れない
  if exists (
    select 1 from public.blocks
    where (blocker_id = v_sender and blocked_id = v_receiver)
       or (blocker_id = v_receiver and blocked_id = v_sender)
  ) then
    raise exception 'BLOCKED';
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

  -- 【相互送金禁止】相手から自分へのギフトが既にあるなら、こちらからは贈れない
  if exists (
    select 1 from public.gifts where sender_id = v_receiver and receiver_id = v_sender
  ) then
    raise exception 'MUTUAL_GIFT_FORBIDDEN';
  end if;

  -- 【チャージ直後禁止】最後のコイン購入から24時間は送金不可(クレカ現金化の抑止)
  select max(created_at) into v_last_purchase from public.coin_purchases where user_id = v_sender;
  if v_last_purchase is not null and v_last_purchase > now() - interval '24 hours' then
    raise exception 'RECENT_PURCHASE_COOLDOWN';
  end if;

  -- 【上限】直近24時間・直近30日の送金合計(自分が贈った額)
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

  -- 原資は有償の購入コイン(balance)のみ。無償ボーナスは換金ルートに流入させない。
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  -- 受領者のウォレットが無ければ作成してから加算(換金可能なearned_balanceへ)。
  -- ただし受領後7日間は換金保留(request_bank_payoutで直近7日の受領分を差し引く)。
  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg)
    returning id into v_gift_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_sender, -p_coins, 'gift_sent', 'gift:' || v_gift_id);
  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_receiver, p_coins, 'gift_received', 'gift:' || v_gift_id);

  -- トークに履歴として残す(Realtimeで相手にも即時表示)
  v_body := '🎁 ' || p_coins || 'コインのありがとうギフトを贈りました';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 受領者へ通知
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

revoke all on function public.send_gift(uuid, int, text) from public;
grant execute on function public.send_gift(uuid, int, text) to authenticated;

-- ------------------------------------------------------------
-- request_bank_payout: 直近7日に受領したギフト分は換金保留として差し引く。
-- (ホスト報酬(予約)は検収済みで即時に換金可能。ギフトのみ7日保留。)
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;
  c_min_coins constant int := 1000;
  v_uid uuid := auth.uid();
  v_balance int;
  v_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;

  -- 直近7日に受領したギフトは換金保留(マネロン対策)。換金可能額から差し引く。
  select coalesce(sum(coins), 0) into v_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';
  v_available := coalesce(v_balance, 0) - v_hold;

  if p_coins > v_available then
    if v_hold > 0 and p_coins <= coalesce(v_balance, 0) then
      raise exception 'GIFT_ON_HOLD';
    end if;
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;
-- ============================================================
-- ギフトの端末監視: 同一端末での自己取引(換金ロンダリング)を検知・遮断する
-- ------------------------------------------------------------
-- 弁護士Q11(c)の推奨「同一IP・端末・カード・Wi-Fiを監視し、換金停止・調査の
-- 対象とする」への対応の一部。
--
-- 本マイグレーションで実装する範囲(サーバ側で機械的に判定できるもの):
--   ・クライアントが localStorage に永続化する端末ID(device_id)を、ログイン中の
--     ユーザーごとに user_devices へ記録する(record_device)。
--   ・ギフト送信時に、送り主と受け手が「同一端末を共有した履歴」があれば、
--     ほぼ同一人物による自己取引とみなして送信を遮断する(SAME_DEVICE_FORBIDDEN)。
--   ・監視・調査用に、送り主の端末IDをギフトに記録する。
--
-- 本マイグレーションの範囲外(継続課題・別途フォロー):
--   ・IPアドレス監視: PostgRESTのRPCからクライアントIPを確実に取得できないため、
--     Edge Function 経由(ヘッダのX-Forwarded-Forを読む)にするか、別途ログ基盤が必要。
--   ・カード(決済手段)フィンガープリント監視: 購入フロー(Stripe webhook)側で
--     payment_method のフィンガープリントを保存する改修が必要。
--   端末IDはクリアされうる(完全ではない)が、通常の自己取引の主要導線は捕捉できる。
-- ============================================================

-- ------------------------------------------------------------
-- user_devices: ユーザーが使った端末(ブラウザ)の記録
-- ------------------------------------------------------------
create table public.user_devices (
  user_id uuid not null references auth.users (id) on delete cascade,
  device_id text not null check (char_length(device_id) between 8 and 128),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  uses int not null default 1,
  primary key (user_id, device_id)
);

comment on table public.user_devices is
  'ユーザーが利用した端末ID(クライアントのlocalStorageに永続化したランダムID)の記録。ギフトの自己取引検知に用いる。';

alter table public.user_devices enable row level security;

create policy "user_devices_select_own"
  on public.user_devices for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは record_device / send_gift(SECURITY DEFINER)経由のみ。

create index user_devices_device_idx on public.user_devices (device_id);

-- ------------------------------------------------------------
-- gifts に監視用の端末IDを追加
-- ------------------------------------------------------------
alter table public.gifts add column sender_device_id text;

-- ------------------------------------------------------------
-- record_device: ログイン中ユーザーの端末IDを記録(アプリ起動時に呼ぶ)
-- ------------------------------------------------------------
create function public.record_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return;
  end if;
  if p_device_id is null or char_length(p_device_id) < 8 or char_length(p_device_id) > 128 then
    return;
  end if;
  insert into public.user_devices (user_id, device_id)
    values (v_uid, p_device_id)
  on conflict (user_id, device_id) do update
    set last_seen_at = now(), uses = public.user_devices.uses + 1;
end;
$$;

revoke all on function public.record_device(text) from public;
grant execute on function public.record_device(text) to authenticated;

-- ------------------------------------------------------------
-- send_gift: 端末IDを受け取り、同一端末の自己取引を遮断する(0020版を置き換え)
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

  -- 【同一端末の自己取引を遮断】送り主と受け手が同じ端末を共有した履歴があれば拒否
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

  -- 原資は有償の購入コイン(balance)のみ
  select balance into v_paid from public.coin_wallets where user_id = v_sender for update;
  if v_paid is null or v_paid < p_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  update public.coin_wallets set balance = balance - p_coins where user_id = v_sender;
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message, sender_device_id)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg, p_device_id)
    returning id into v_gift_id;

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

-- 旧シグネチャ(4引数でない版)は不要になるが、明示的に削除はしない
-- (PostgRESTは引数名で解決するため、フロントは常に4引数版を呼ぶ)。
-- ============================================================
-- ギフトのIP監視: 送り主と受け手のIP共有を検知してフラグを立てる
-- ------------------------------------------------------------
-- 弁護士Q11(c)の推奨「同一IPを監視」への対応。
--
-- 設計上の要点:
--   ・クライアントの正しい公開IPはブラウザからは取得できない(信頼できない)ため、
--     アプリ起動時に Edge Function(record-ip)がリクエストヘッダの
--     X-Forwarded-For から実IPを読み、record_ip でユーザーごとに記録する。
--   ・IPは同一Wi-Fi・同一キャリアのNAT(CGNAT)・同じカフェ等で「正当に」一致
--     しうる(一緒に遊んだ相手が同居家族・同じ回線というのは普通)。よって
--     IP一致は端末一致(=ほぼ同一人物)と違い、**遮断ではなく調査用フラグ**に
--     とどめる。送信は止めない。
--   ・send_gift は user_ips(record-ipが蓄積)を参照し、送り主と受け手のIP共有
--     履歴があれば gifts.ip_flagged=true を立てる。運用の目視・振込前チェックで使う。
-- ============================================================

-- ------------------------------------------------------------
-- user_ips: ユーザーが利用したIPの記録(Edge Function経由でのみ書き込む)
-- ------------------------------------------------------------
create table public.user_ips (
  user_id uuid not null references auth.users (id) on delete cascade,
  ip text not null check (char_length(ip) between 3 and 64),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  uses int not null default 1,
  primary key (user_id, ip)
);

comment on table public.user_ips is
  'ユーザーが利用した公開IPの記録(Edge Function record-ip がX-Forwarded-Forから記録)。ギフトのIP共有検知に用いる。IP一致は遮断せず調査フラグに使う。';

alter table public.user_ips enable row level security;

create policy "user_ips_select_own"
  on public.user_ips for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは record_ip(SECURITY DEFINER)経由のみ。

create index user_ips_ip_idx on public.user_ips (ip);

-- ------------------------------------------------------------
-- gifts に IP要確認フラグを追加
-- ------------------------------------------------------------
alter table public.gifts add column ip_flagged boolean not null default false;

comment on column public.gifts.ip_flagged is
  '送り主と受け手が同一IPを共有した履歴がある場合にtrue。遮断はしないが、換金前の目視確認対象。';

-- ------------------------------------------------------------
-- record_ip: ログイン中ユーザーのIPを記録(Edge Function record-ip が呼ぶ)
-- ------------------------------------------------------------
create function public.record_ip(p_ip text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ip text := btrim(coalesce(p_ip, ''));
begin
  if v_uid is null then
    return;
  end if;
  if char_length(v_ip) < 3 or char_length(v_ip) > 64 then
    return;
  end if;
  insert into public.user_ips (user_id, ip)
    values (v_uid, v_ip)
  on conflict (user_id, ip) do update
    set last_seen_at = now(), uses = public.user_ips.uses + 1;
end;
$$;

revoke all on function public.record_ip(text) from public;
grant execute on function public.record_ip(text) to authenticated;

-- ------------------------------------------------------------
-- send_gift: IP共有履歴があれば ip_flagged を立てて記録(0021版に追加)
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
  perform public._consume_coin_lots(v_sender, 'paid', p_coins);

  insert into public.coin_wallets (user_id) values (v_receiver)
    on conflict (user_id) do nothing;
  update public.coin_wallets set earned_balance = earned_balance + p_coins
    where user_id = v_receiver;

  v_msg := nullif(btrim(coalesce(p_message, '')), '');

  insert into public.gifts (promise_id, sender_id, receiver_id, coins, message, sender_device_id, ip_flagged)
    values (p_promise_id, v_sender, v_receiver, p_coins, v_msg, p_device_id, coalesce(v_ip_flag, false))
    returning id into v_gift_id;

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
-- ============================================================
-- ホストランキング(デイリー/ウィークリー/マンスリー)
-- ------------------------------------------------------------
-- 事業判断(2026-07-23)+弁護士Q11(d)対応:
--   ランキングは「スキル・活動・品質」ベースにする。**金額(投げ銭・稼ぎ)は
--   スコアに一切含めない**。「人気女性への金銭提供サービス」と見られる
--   投げ銭/稼ぎ額ランキングは作らない(出会い系印象・射幸性の回避)。
--
--   スコア = 完了予約数(活動量)
--          × (manner_score / 5)        … 品質(レビュー由来)
--          × 信頼性(完了 /(完了 + ホスト都合キャンセル)) … 応答・低ドタキャン
--
--   期間の起点は日本時間(Asia/Tokyo)基準:
--     daily   = 本日0時〜 / weekly = 今週(月曜)〜 / monthly = 今月1日〜
--   活動の時刻は予約の scheduled_at(実際に遊んだ時刻)を用いる。
--
--   上位特典は「バッジ・露出」等にとどめ、高額現金賞は設けない(射幸性回避)。
-- ============================================================

create function public.host_ranking(p_period text default 'weekly', p_limit int default 30)
returns table (
  rank bigint,
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  completed_count bigint,
  manner_score numeric,
  score numeric,
  is_verified boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with win as (
    select case p_period
             when 'daily'   then date_trunc('day',   (now() at time zone 'Asia/Tokyo'))
             when 'weekly'  then date_trunc('week',  (now() at time zone 'Asia/Tokyo'))
             when 'monthly' then date_trunc('month', (now() at time zone 'Asia/Tokyo'))
             else date_trunc('week', (now() at time zone 'Asia/Tokyo'))
           end as start_jst
  ),
  agg as (
    select b.host_id,
           count(*) filter (where b.status = 'completed') as completed,
           count(*) filter (where b.status in ('cancelled_by_host', 'no_show_host')) as host_cancel
    from public.bookings b, win
    where (b.scheduled_at at time zone 'Asia/Tokyo') >= win.start_jst
    group by b.host_id
    having count(*) filter (where b.status = 'completed') > 0
  ),
  scored as (
    select a.host_id,
           a.completed,
           round(
             a.completed
             * (coalesce(ts.manner_score, 4.50) / 5.0)
             * (a.completed::numeric / nullif(a.completed + a.host_cancel, 0)),
             2
           ) as score,
           coalesce(ts.manner_score, 4.50) as manner_score,
           coalesce(ts.is_verified, false) as is_verified
    from agg a
    left join public.profile_trust_stats ts on ts.user_id = a.host_id
  )
  select row_number() over (order by s.score desc, s.completed desc) as rank,
         s.host_id,
         p.nickname,
         p.avatar_initial,
         p.avatar_color,
         s.completed as completed_count,
         s.manner_score,
         s.score,
         s.is_verified
  from scored s
  join public.profiles p on p.id = s.host_id
  order by s.score desc, s.completed desc
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

comment on function public.host_ranking(text, int) is
  'ホストのデイリー/ウィークリー/マンスリーランキング。スコア=完了予約数×品質(manner_score)×信頼性。金額(投げ銭・稼ぎ)は一切含めない(弁護士Q11(d))。';

revoke all on function public.host_ranking(text, int) from public;
grant execute on function public.host_ranking(text, int) to authenticated;
-- ============================================================
-- 声の挨拶(ボイスプロフィール)。B方式=即公開+通報で削除。
-- ------------------------------------------------------------
-- プロフィールに15秒までの音声挨拶を録音・公開できる。
-- 事業判断(2026-07-23): 音声はテキストの自動みまもりが効かないため、
--   ・録音時に注意書き(外部連絡先・出会い目的・不適切表現は禁止)を表示
--   ・即時公開し、通報があれば管理者が削除(admin_clear_voice_greeting)
--   ・15秒上限で悪用余地を最小化
-- 承認制(A方式)はとらず、運用負荷の軽いB方式を採用。将来 文字起こしチェック等へ拡張可。
-- ============================================================

-- ------------------------------------------------------------
-- Storageバケット: voice-greetings(公開・2MBまで・音声のみ)
-- パスは {auth.uid()}/greeting.webm 形式。公開URLで再生する。
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'voice-greetings', 'voice-greetings', true, 2097152,
  array['audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/aac']
)
on conflict (id) do nothing;

create policy "voice_greetings_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'voice-greetings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "voice_greetings_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'voice-greetings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "voice_greetings_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'voice-greetings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 公開バケットなので再生(公開URL)にselectポリシーは不要。

-- ------------------------------------------------------------
-- profiles: 音声挨拶のパスと長さ
-- ------------------------------------------------------------
alter table public.profiles
  add column voice_path text,
  add column voice_seconds int check (voice_seconds is null or voice_seconds between 1 and 30);

comment on column public.profiles.voice_path is
  'voice-greetingsバケット内の音声挨拶のパス({uid}/greeting.webm)。公開URLで再生。';

-- ------------------------------------------------------------
-- set_voice_greeting: 本人の音声挨拶を設定(アップロード後に呼ぶ)
-- ------------------------------------------------------------
create function public.set_voice_greeting(p_path text, p_seconds int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_seconds is null or p_seconds < 1 or p_seconds > 15 then
    raise exception 'INVALID_DURATION';
  end if;
  -- パスは必ず本人フォルダ配下
  if split_part(p_path, '/', 1) <> v_uid::text then
    raise exception 'FORBIDDEN_PATH';
  end if;
  update public.profiles set voice_path = p_path, voice_seconds = p_seconds where id = v_uid;
end;
$$;

revoke all on function public.set_voice_greeting(text, int) from public;
grant execute on function public.set_voice_greeting(text, int) to authenticated;

-- ------------------------------------------------------------
-- clear_voice_greeting: 本人が自分の音声挨拶を削除
-- ------------------------------------------------------------
create function public.clear_voice_greeting()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  update public.profiles set voice_path = null, voice_seconds = null where id = v_uid;
end;
$$;

revoke all on function public.clear_voice_greeting() from public;
grant execute on function public.clear_voice_greeting() to authenticated;

-- ------------------------------------------------------------
-- admin_clear_voice_greeting: 管理者による削除(通報対応・B方式の要)
-- ------------------------------------------------------------
create function public.admin_clear_voice_greeting(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (select 1 from public.admins where user_id = v_uid) then
    raise exception 'FORBIDDEN';
  end if;
  update public.profiles set voice_path = null, voice_seconds = null where id = p_user_id;
end;
$$;

revoke all on function public.admin_clear_voice_greeting(uuid) from public;
grant execute on function public.admin_clear_voice_greeting(uuid) to authenticated;
-- ============================================================
-- プロフィールのアイコン画像(アバター)。ボイス挨拶(0024)と同じB方式。
-- ------------------------------------------------------------
-- 頭文字＋カラーの既定アバターに加え、任意で画像をアップロードできる。
-- 画像はテキストの自動みまもりが効かないため、
--   ・アップロード時に注意書き(他人の写真・不適切画像の禁止)を表示
--   ・即時公開し、通報があれば管理者が削除(admin_clear_avatar)
-- とするB方式。avatar_path が null のときは従来の頭文字＋カラーで表示する。
-- ============================================================

-- ------------------------------------------------------------
-- Storageバケット: avatars(公開・3MBまで・画像のみ)
-- パスは {auth.uid()}/avatar.webp 形式。公開URLで表示する。
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 3145728,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

create policy "avatars_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 公開バケットなので表示(公開URL)にselectポリシーは不要。

-- ------------------------------------------------------------
-- profiles: アイコン画像のパス(null=頭文字＋カラーの既定アバター)
-- ------------------------------------------------------------
alter table public.profiles
  add column avatar_path text;

comment on column public.profiles.avatar_path is
  'avatarsバケット内のアイコン画像のパス({uid}/avatar.webp)。null なら頭文字＋カラーの既定アバター。';

-- ------------------------------------------------------------
-- set_avatar: 本人のアイコン画像を設定(アップロード後に呼ぶ)
-- ------------------------------------------------------------
create function public.set_avatar(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  -- パスは必ず本人フォルダ配下
  if split_part(p_path, '/', 1) <> v_uid::text then
    raise exception 'FORBIDDEN_PATH';
  end if;
  update public.profiles set avatar_path = p_path where id = v_uid;
end;
$$;

revoke all on function public.set_avatar(text) from public;
grant execute on function public.set_avatar(text) to authenticated;

-- ------------------------------------------------------------
-- clear_avatar: 本人が自分のアイコン画像を削除(既定アバターに戻す)
-- ------------------------------------------------------------
create function public.clear_avatar()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  update public.profiles set avatar_path = null where id = v_uid;
end;
$$;

revoke all on function public.clear_avatar() from public;
grant execute on function public.clear_avatar() to authenticated;

-- ------------------------------------------------------------
-- admin_clear_avatar: 管理者による削除(通報対応・B方式の要)
-- ------------------------------------------------------------
create function public.admin_clear_avatar(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (select 1 from public.admins where user_id = v_uid) then
    raise exception 'FORBIDDEN';
  end if;
  update public.profiles set avatar_path = null where id = p_user_id;
end;
$$;

revoke all on function public.admin_clear_avatar(uuid) from public;
grant execute on function public.admin_clear_avatar(uuid) to authenticated;
-- ============================================================
-- オンラインステータス(最終ログイン + 手動ステータス)
-- ------------------------------------------------------------
-- これまでのオンライン表示は Realtime Presence のみで、
-- 「いまアプリを開いている人」しか出せなかった。ユーザーが少ない間は
-- 一覧がほぼ空になるため、profiles に last_seen_at を持たせて
-- 「5分前」「1時間前」といった表示ができるようにする。
--
-- あわせて、オンライン=誘ってよい とは限らないので、本人が意思表示できる
-- presence_status(ready/online/busy)を用意する。
--
-- プライバシー: safety_prefs は本人しか select できない一方、profiles は
-- 全ユーザーが select できる。そのため公開可否は「書き込み時」に制御する。
--   ・show_online = false の間は last_seen_at を更新しない
--   ・show_online を false にした瞬間に last_seen_at を null に戻す(トリガー)
-- これにより、非公開の人の在席情報が profiles に残らない。
-- ============================================================

-- ------------------------------------------------------------
-- profiles: 最終在席時刻と手動ステータス
-- ------------------------------------------------------------
alter table public.profiles
  add column last_seen_at timestamptz,
  add column presence_status text not null default 'online'
    check (presence_status in ('ready', 'online', 'busy'));

comment on column public.profiles.last_seen_at is
  '最後にアプリを開いていた時刻。オンライン状態を公開している人のみ記録され、非公開にすると null に戻る。';
comment on column public.profiles.presence_status is
  '本人が選ぶ状態。ready=今すぐ遊べる / online=オンライン / busy=取り込み中。';

-- 一覧を「最近いた順」で並べるため
create index profiles_last_seen_at_idx
  on public.profiles (last_seen_at desc nulls last);

-- ------------------------------------------------------------
-- touch_presence: 在席を記録する(アプリを開いている間、定期的に呼ぶ)
-- show_online が false のときは何もしない(非公開の人は記録しない)。
-- ------------------------------------------------------------
create function public.touch_presence()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.safety_prefs
    where user_id = v_uid and show_online
  ) then
    return;
  end if;
  update public.profiles set last_seen_at = now() where id = v_uid;
end;
$$;

revoke all on function public.touch_presence() from public;
grant execute on function public.touch_presence() to authenticated;

-- ------------------------------------------------------------
-- set_presence_status: 本人が状態を選ぶ
-- ------------------------------------------------------------
create function public.set_presence_status(p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_status not in ('ready', 'online', 'busy') then
    raise exception 'INVALID_STATUS';
  end if;
  update public.profiles set presence_status = p_status where id = v_uid;
end;
$$;

revoke all on function public.set_presence_status(text) from public;
grant execute on function public.set_presence_status(text) to authenticated;

-- ------------------------------------------------------------
-- オンライン状態を非公開にしたら、記録済みの last_seen_at を消す。
-- 「非公開にしたのに最終ログインが残っている」を防ぐための要。
-- ------------------------------------------------------------
create function public.clear_last_seen_on_hide()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.show_online and not new.show_online then
    update public.profiles set last_seen_at = null where id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger safety_prefs_clear_last_seen
  after update of show_online on public.safety_prefs
  for each row
  execute function public.clear_last_seen_on_hide();
-- ============================================================
-- avatars バケットのポリシー修復(何度実行しても安全)
-- ------------------------------------------------------------
-- 症状: アイコン画像のアップロードで
--   new row violates row-level security policy
-- が出る = storage.objects への INSERT がRLSで弾かれている。
--
-- 原因として多いのは、0025 の create policy が
--   ・別の実行で同名ポリシーが既にあり "already exists" で全体が中断した
--   ・schema-all.sql をまとめて流して途中で失敗し、列だけ作られた
-- といった理由で「avatar_path 列はあるがポリシーが無い」状態になること。
-- アプリ自体は動くのでアップロード時にだけ表面化する。
--
-- そのため、ここではバケットとポリシーを drop → create で作り直す。
-- 既に正しく入っていても同じ結果になるので、安心して再実行できる。
-- ============================================================

-- ------------------------------------------------------------
-- バケット(無ければ作る / あれば制限値を今の仕様に揃える)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 3145728,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
-- ポリシー(本人フォルダ配下 {auth.uid()}/... のみ書き込み可)
-- ------------------------------------------------------------
drop policy if exists "avatars_insert_own" on storage.objects;
drop policy if exists "avatars_update_own" on storage.objects;
drop policy if exists "avatars_delete_own" on storage.objects;

create policy "avatars_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- upsert(上書き保存)では UPDATE も通る必要がある。
-- using だけだと更新後の行が検査されないため with check も明示する。
create policy "avatars_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 公開バケットなので表示(公開URL)にselectポリシーは不要。

-- ------------------------------------------------------------
-- 0025 が中断していた場合に備えて、列と関数も無ければ作る。
-- (既にあれば何もしない)
-- ------------------------------------------------------------
alter table public.profiles
  add column if not exists avatar_path text;

create or replace function public.set_avatar(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if split_part(p_path, '/', 1) <> v_uid::text then
    raise exception 'FORBIDDEN_PATH';
  end if;
  update public.profiles set avatar_path = p_path where id = v_uid;
end;
$$;

revoke all on function public.set_avatar(text) from public;
grant execute on function public.set_avatar(text) to authenticated;

create or replace function public.clear_avatar()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  update public.profiles set avatar_path = null where id = v_uid;
end;
$$;

revoke all on function public.clear_avatar() from public;
grant execute on function public.clear_avatar() to authenticated;
-- ============================================================
-- 「みまもり」一次検知のエスカレーション記録
-- 設計: docs/trust-safety-spec.md §4.2
-- ------------------------------------------------------------
-- 送信前の自動検知(外部連絡先・金銭要求・出会い目的)でヒットした事実を
-- 記録し、人による確認の対象を絞り込むためのテーブル。
--
-- 方針(§4.2):
--   ・検知しても送信はブロックしない。記録するだけ
--   ・「金銭要求」は1回でも確認対象(needs_review = true)
--   ・同一ユーザーで繰り返しヒットした場合も確認対象に上げる
--
-- 本文そのものは保存しない。一致した短い断片(matched)のみ残す。
-- 会話の全文保存は「みまもり」同意の範囲を超えるため意図的に避けている。
-- ============================================================

create table public.content_flags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  category text not null check (category in ('contact', 'money', 'dating')),
  -- どこで検知したか(message=トーク, board=募集文, profile=プロフィール文)
  surface text not null check (surface in ('message', 'board', 'profile')),
  -- 一致した断片のみ。本文は保存しない
  matched text not null check (char_length(matched) <= 200),
  -- 本人が警告を見たうえで送信を続行したか
  proceeded boolean not null default false,
  needs_review boolean not null default false,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table public.content_flags is
  '送信前の自動検知(みまもり)のヒット記録。本文は保存せず一致断片のみ。運営の確認対象の絞り込みに使う。';

alter table public.content_flags enable row level security;

-- 本人にも他ユーザーにも開示しない(運営のみがservice roleで参照する)。
-- select ポリシーを置かないことで既定の拒否になる。

create index content_flags_review_idx
  on public.content_flags (needs_review, created_at desc)
  where needs_review and reviewed_at is null;

create index content_flags_user_idx
  on public.content_flags (user_id, created_at desc);

-- ------------------------------------------------------------
-- record_content_flag: 検知結果を記録する(本人のみ・本人の分だけ)
-- 直近24時間に3件以上ヒットしている場合も確認対象に引き上げる。
-- ------------------------------------------------------------
create function public.record_content_flag(
  p_category text,
  p_surface text,
  p_matched text,
  p_proceeded boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_recent int;
  v_needs boolean;
begin
  if v_uid is null then
    return;
  end if;
  if p_category not in ('contact', 'money', 'dating') then
    return;
  end if;
  if p_surface not in ('message', 'board', 'profile') then
    return;
  end if;

  -- 金銭要求は1回でも確認対象(§4.2-3)
  v_needs := (p_category = 'money');

  -- 繰り返しヒットも確認対象に上げる
  if not v_needs then
    select count(*) into v_recent
    from public.content_flags
    where user_id = v_uid and created_at > now() - interval '24 hours';
    if v_recent >= 2 then
      v_needs := true;
    end if;
  end if;

  insert into public.content_flags (user_id, category, surface, matched, proceeded, needs_review)
  values (v_uid, p_category, p_surface, left(coalesce(p_matched, ''), 200), coalesce(p_proceeded, false), v_needs);
end;
$$;

revoke all on function public.record_content_flag(text, text, text, boolean) from public;
grant execute on function public.record_content_flag(text, text, text, boolean) to authenticated;
-- ============================================================
-- マナースコアの算出を設計どおりに置き換える
-- 設計: docs/trust-safety-spec.md §1.1 / §1.2
-- ------------------------------------------------------------
-- 0005 の実装は「直近30件の単純平均 − 減点」という簡略版で、次の問題があった。
--   ・レビュー1件で満点(★5.00)になってしまい、実績のあるユーザーと並ぶ
--   ・新しいレビューほど重く扱う指数減衰(半減期90日)が入っていない
--   ・base=4.50 の「中立スタート」がレビュー1件で消える
--
-- ここでは次の式に置き換える。
--
--   score = (BASE * PRIOR_W + Σ(w_i * stars_i)) / (PRIOR_W + Σ w_i) - penalty
--   w_i   = 0.5 ^ (経過日数 / 90)      … 半減期90日の指数減衰
--
-- 設計書の "base + review_component - penalty_component" は、そのまま足すと
-- 4.50 + 4.80 のようになり上限に張り付くため、**baseを事前分布(中立な仮想レビュー)
-- として扱い、レビューが増えるほどbaseの影響が薄れる**形で解釈した。
-- これにより「新規は中立、実績が積まれるほど実際の評価に寄る」という
-- 設計意図(コールドスタート対策)を満たす。
--
-- PRIOR_W = 3 は「レビュー3件で事前分布と実測が同じ重みになる」設定で、
-- §1.2 の「3件未満はスコアを表示しない」というしきい値と揃えてある。
-- ============================================================

create or replace function public.recompute_manner_score(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 新規ユーザーの中立スタート(§1.1)
  c_base constant numeric := 4.50;
  -- 事前分布の重み。レビュー3件で実測と同等になる
  c_prior_w constant numeric := 3.0;
  -- 指数減衰の半減期(日)
  c_half_life constant numeric := 90.0;

  v_weighted_sum numeric := 0;
  v_weight_sum numeric := 0;
  v_review_count int := 0;
  v_penalty numeric;
  v_score numeric;
begin
  -- 直近30件のみを対象に、新しいレビューほど重く重み付けする
  select
    coalesce(sum(power(0.5, extract(epoch from (now() - r.created_at)) / 86400.0 / c_half_life) * r.stars), 0),
    coalesce(sum(power(0.5, extract(epoch from (now() - r.created_at)) / 86400.0 / c_half_life)), 0),
    count(*)
  into v_weighted_sum, v_weight_sum, v_review_count
  from (
    select stars, created_at
    from public.reviews
    where reviewee_id = p_user_id
    order by created_at desc
    limit 30
  ) r;

  select coalesce(sum(points), 0) into v_penalty
  from public.manner_penalties
  where user_id = p_user_id;

  -- baseを仮想レビューとして混ぜる(レビューが増えるほど影響が薄れる)
  v_score := (c_base * c_prior_w + v_weighted_sum) / (c_prior_w + v_weight_sum) - v_penalty;
  v_score := greatest(1.00, least(5.00, v_score));

  update public.profile_trust_stats
    set manner_score = round(v_score, 2),
        review_count = v_review_count,
        updated_at = now()
    where user_id = p_user_id;
end;
$$;

comment on function public.recompute_manner_score(uuid) is
  'マナースコアの再計算(docs/trust-safety-spec.md §1.1)。baseを事前分布として扱い、半減期90日で減衰させた直近30件のレビューを加重平均し、確定した違反の減点を差し引く。';

-- ------------------------------------------------------------
-- 既存ユーザーのスコアを新しい式で一度ならす
-- (旧式で満点になっていたユーザーが残らないようにする)
-- ------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in select user_id from public.profile_trust_stats loop
    perform public.recompute_manner_score(r.user_id);
  end loop;
end;
$$;
-- ============================================================
-- 返金コインの有効期限を「当初の発行日」基準に改める
-- 論点: docs/legal/lawyer-review-round2-request.md Q18
-- 記録: docs/legal/lawyer-review-answers-round2-draft.md 「未対応の実装課題」
-- ------------------------------------------------------------
-- 適用済み(2026-07-26)。修正方法の妥当性は弁護士Q18で事後確認する。
-- 別の整理を指示された場合は、追加のマイグレーションで対応すること。
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
-- ============================================================
-- みまもり(メッセージ等の自動検知)への同意の記録
-- 論点: docs/legal/lawyer-review-round2-request.md Q19
--       docs/legal/lawyer-review-round2-amendments.md C-2 / E-4
-- ------------------------------------------------------------
-- 何が足りなかったか:
--   同意画面(src/screens/Consent.tsx)は既にあり、規約同意とは別の専用画面で
--   目的・範囲・方法を示してチェックを必須にしている。しかし同意した事実が
--   どこにも保存されておらず、チェックを次画面への遷移条件にしているだけだった。
--   そのため「同意を取得している」ことを後から証明できない。
--
--   通信の秘密(電気通信事業法4条)との関係で個別同意を根拠にする以上、
--   同意の事実・日時・同意した文言のバージョンは残す必要がある。
--
-- 設計:
--   ・履歴として積む(1ユーザー1行に上書きしない)。文言を改定したら
--     新しいバージョンで再同意を取り、いつどの版に同意したかを追えるようにする
--   ・撤回(revoked_at)も同じ表で扱う。撤回導線の実装(E-5)は
--     撤回条項の書き方がQ19の回答待ちのため、ここでは器だけ用意する
--   ・本人は自分の同意履歴を参照できる(開示請求への対応のため)
-- ============================================================

create table public.monitoring_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 同意した文言のバージョン(src/content/consentText.ts と対応)
  version text not null check (char_length(version) between 1 and 40),
  agreed_at timestamptz not null default now(),
  -- 撤回した場合の時刻。null なら有効
  revoked_at timestamptz
);

comment on table public.monitoring_consents is
  'みまもり(メッセージ等の自動検知)への同意の記録。通信の秘密との関係で個別同意を根拠にするため、同意日時と同意した文言のバージョンを履歴として残す。';

alter table public.monitoring_consents enable row level security;

-- 本人は自分の同意履歴を参照できる(開示請求への対応)
create policy "monitoring_consents_select_own"
  on public.monitoring_consents for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは SECURITY DEFINER 関数経由のみ(INSERT/UPDATEポリシーは作らない)。

create index monitoring_consents_user_idx
  on public.monitoring_consents (user_id, agreed_at desc);

-- ------------------------------------------------------------
-- record_monitoring_consent: 同意を記録する。
-- 同じバージョンに有効な同意が既にあれば何もしない(再ログイン等での重複防止)。
-- ------------------------------------------------------------
create function public.record_monitoring_consent(p_version text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return;
  end if;
  if p_version is null or char_length(p_version) not between 1 and 40 then
    return;
  end if;

  if exists (
    select 1 from public.monitoring_consents
    where user_id = v_uid and version = p_version and revoked_at is null
  ) then
    return;
  end if;

  insert into public.monitoring_consents (user_id, version)
  values (v_uid, p_version);
end;
$$;

revoke all on function public.record_monitoring_consent(text) from public;
grant execute on function public.record_monitoring_consent(text) to authenticated;

-- ------------------------------------------------------------
-- revoke_monitoring_consent: 同意を撤回する。
-- 撤回時のサービス提供の可否は運用・規約側の論点(Q19)。
-- ここでは記録のみを行い、機能の制限はしない。
-- ------------------------------------------------------------
create function public.revoke_monitoring_consent()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return;
  end if;
  update public.monitoring_consents
    set revoked_at = now()
    where user_id = v_uid and revoked_at is null;
end;
$$;

revoke all on function public.revoke_monitoring_consent() from public;
grant execute on function public.revoke_monitoring_consent() to authenticated;
-- ============================================================
-- キャンセルポリシーの同意記録と、キャンセル実態の集計
-- 論点: docs/legal/lawyer-review-round2-request.md Q14
--       (直前キャンセルの没収と消費者契約法9条)
-- 対応: open-issues.md の E-1 / E-2
-- ------------------------------------------------------------
-- Q14で示された条件のうち、①「予約確定前にキャンセルポリシーを明示し、
-- 同意の痕跡(ログ)を残す」③「争いになった際の『平均的な損害』の立証材料を
-- 蓄積する」に対応する。
--
-- ■ E-1: 同意の記録
--   予約時に、そのとき画面に表示していたポリシーのバージョンを予約行に残す。
--   別テーブルにせず bookings に持たせるのは、証跡が予約と1対1で、
--   予約を見れば「どの版のポリシーに同意して申し込んだか」が分かるため。
--
-- ■ E-2: 「平均的な損害」の立証材料
--   当初は「直前キャンセルされた枠がその後埋まったか(再販売率)」を記録する
--   想定だったが、本サービスに将来日時の予約は無く、ホストが承諾した時点で
--   役務が始まる(approve_booking が scheduled_at = now() を設定する)。
--   「空いた枠が後で売れたか」という概念が成立しないため、代わりに
--   **承諾からキャンセルまでの経過時間と没収額**を集計する。
--   これらは bookings の既存カラム(scheduled_at = 承諾時刻, cancelled_at)から
--   導出できるので、新しい列は増やさずビューだけを用意する。
-- ============================================================

-- ------------------------------------------------------------
-- E-1: 同意したポリシーのバージョンを予約に記録する
-- ------------------------------------------------------------
alter table public.bookings
  add column policy_version text,
  add column policy_agreed_at timestamptz;

comment on column public.bookings.policy_version is
  '予約申込時に画面へ表示していたキャンセルポリシーのバージョン(src/content/bookingPolicy.ts と対応)。消費者契約法9条の争いに備えた同意の痕跡。';
comment on column public.bookings.policy_agreed_at is
  '上記ポリシーに同意して申し込んだ時刻。';

-- create_booking に p_policy_version を足す。
--
-- 旧2引数版は「まだ残す」。main へのマージで自動デプロイされる構成のため、
-- マイグレーションの適用とフロントのデプロイの順序が前後しうる。
-- ここで2引数版を消すと、適用前にデプロイされた瞬間に予約が作れなくなる。
--
-- なお3引数版の p_policy_version に既定値を持たせると、2引数での呼び出しが
-- どちらの関数にも一致して "function is not unique" になるため、
-- **3引数版は必須引数**にしてある。
--
-- ⚠️ フロントのデプロイ完了後に、旧2引数版は削除すること(同意記録の無い予約が
--    作れる状態を残さないため)。削除は次のマイグレーションで行う。
drop function if exists public.create_booking(uuid, int, text);

create function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text
)
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

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end
  )
  returning id into v_booking_id;

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

-- 旧2引数版を、3引数版へ委譲する薄いラッパーに置き換える(経過措置)。
-- 同意バージョンは null になるので、記録の無い予約は「デプロイ前の申込み」と
-- 判別できる。
create or replace function public.create_booking(p_host_id uuid, p_duration_minutes int)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.create_booking(p_host_id, p_duration_minutes, null::text);
$$;

comment on function public.create_booking(uuid, int) is
  '経過措置。フロントのデプロイ完了後に削除すること(同意記録の無い予約が作れる状態を残さないため)。';

-- ------------------------------------------------------------
-- E-2: キャンセル実態の集計(「平均的な損害」の立証材料)
--
-- security_invoker により、通常のユーザーには bookings のRLSがそのまま効く
-- (自分が当事者の予約しか見えない)。運営はダッシュボード/service_roleで全件見る。
-- ------------------------------------------------------------
create view public.guest_cancellation_evidence
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.host_id,
  b.duration_minutes,
  b.coins as forfeited_coins,
  b.policy_version,
  b.scheduled_at as approved_at,
  b.cancelled_at,
  -- 承諾(=役務の開始)からキャンセルまでの経過秒数
  extract(epoch from (b.cancelled_at - b.scheduled_at))::int as seconds_after_approval,
  -- 経過時間が予約時間に占める割合(1.0 = 予定時間をすべて消化してからキャンセル)
  round(
    extract(epoch from (b.cancelled_at - b.scheduled_at))::numeric
      / nullif(b.duration_minutes * 60, 0),
    3
  ) as elapsed_ratio
from public.bookings b
where b.status = 'cancelled_by_guest'
  and b.cancelled_at is not null
  -- 承諾前(status='requested')の取消は全額返金なので対象外。
  -- 没収が起きたケースだけを見る。
  and b.scheduled_at is not null
  and b.cancelled_at >= b.scheduled_at;

comment on view public.guest_cancellation_evidence is
  'ゲスト都合キャンセルで没収が生じた予約の一覧。承諾からキャンセルまでの経過時間と没収額を出す。消費者契約法9条の「平均的な損害」を検討・立証するための材料(docs/legal/lawyer-review-round2-request.md Q14)。';
-- ============================================================
-- ホスト手数料(超過累進ティア + 指名リピート割引)の導入
-- ------------------------------------------------------------
-- これまでホストは消費されたコインを100%受け取っており、運営の収益は
-- 換金手数料(300コイン/回)とコインの購入・失効差分だけだった。
-- ここでプラットフォーム手数料を導入する。
--
-- ■ 料率(超過累進。所得税と同じで、超えた分にだけ高い率がかかるのではなく
--   「各段の範囲にその段の率」がかかる)
--     〜30,000コイン      20%
--     30,000〜100,000     17%
--     100,000〜300,000    14%
--     300,000〜           12%
--   判定の母数は「その月に確定した予約(チケット)売上」。ギフトは含めない。
--
-- ■ 指名リピート割引
--   同じゲストからの2回目以降の予約は、その予約に適用される料率から3pt引く。
--   ただし下限10%。ホストが自分の顧客を育てるほど手取りが増える設計。
--
-- ■ ギフト
--   累進の対象外で一律30%。金額が任意で青天井になりうるため、
--   ティア判定に混ぜると料率設計が歪むため分けている。
--
-- ■ 月内の整合性(ここが実装上の肝)
--   超過累進を「確定のたびに」適用するので、確定時点の限界料率だけで引くと
--   月末に遡及補正が必要になる。それを避けるため、各確定では
--     手数料 = 累進手数料(確定後の月間GMV) − 累進手数料(確定前の月間GMV)
--   を引く。こうすると月末時点の合計が必ず累進計算と一致し、補正がいらない。
--
-- ⚠️ 法務: 手数料の導入は規約(第8条)・特商法表記への反映が必要。
--    収納代行の整理(弁護士Q1)自体は、プラットフォームが仲介手数料を
--    取ること自体で崩れるものではないが、料率と控除の明示は必要。
--    docs/open-issues.md の E-11 を参照。
-- ============================================================

-- ------------------------------------------------------------
-- 料率マスタ(将来の改定はこの表を差し替えるだけで済むようにする)
-- ------------------------------------------------------------
create table public.host_fee_tiers (
  step smallint primary key,
  -- その段の上限(コイン)。null は上限なし
  upper_bound int,
  rate numeric(4, 3) not null check (rate >= 0 and rate <= 1)
);

comment on table public.host_fee_tiers is
  'ホスト手数料の超過累進ティア。月間の予約売上(ギフト除く)に対して、各段の範囲にその段の率をかける。';

insert into public.host_fee_tiers (step, upper_bound, rate) values
  (1, 30000, 0.200),
  (2, 100000, 0.170),
  (3, 300000, 0.140),
  (4, null, 0.120);

alter table public.host_fee_tiers enable row level security;

-- 料率は利用者に開示する情報なので誰でも読める
create policy "host_fee_tiers_select_all"
  on public.host_fee_tiers for select
  to authenticated
  using (true);

-- ------------------------------------------------------------
-- 手数料の明細(ダッシュボードの内訳・運営の突合に使う)
-- ------------------------------------------------------------
create table public.platform_fees (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('booking', 'gift')),
  booking_id uuid references public.bookings (id) on delete set null,
  gift_id uuid references public.gifts (id) on delete set null,
  gross_coins int not null check (gross_coins >= 0),
  fee_coins int not null check (fee_coins >= 0),
  net_coins int not null check (net_coins >= 0),
  -- 実際に適用された率(gross に対する fee の比)。表示用
  applied_rate numeric(5, 4) not null,
  -- 指名リピート割引が効いたか
  repeat_discounted boolean not null default false,
  created_at timestamptz not null default now()
);

comment on table public.platform_fees is
  'ホストから控除したプラットフォーム手数料の明細。ダッシュボードの内訳表示と、運営の突合に使う。';

alter table public.platform_fees enable row level security;

create policy "platform_fees_select_own"
  on public.platform_fees for select
  to authenticated
  using (host_id = auth.uid());

create index platform_fees_host_idx on public.platform_fees (host_id, created_at desc);

-- coin_transactions に手数料の控除を記録できるようにする
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus',
    'booking_earned', 'payout', 'expire',
    'gift_sent', 'gift_received',
    'platform_fee'
  ));

-- ------------------------------------------------------------
-- host_progressive_fee: 月間GMVに対する累進手数料の累計額
-- ------------------------------------------------------------
create function public.host_progressive_fee(p_gmv int)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_fee numeric := 0;
  v_prev int := 0;
  v_tier record;
begin
  if p_gmv is null or p_gmv <= 0 then
    return 0;
  end if;
  for v_tier in select upper_bound, rate from public.host_fee_tiers order by step loop
    exit when p_gmv <= v_prev;
    v_fee := v_fee + (least(p_gmv, coalesce(v_tier.upper_bound, p_gmv)) - v_prev) * v_tier.rate;
    v_prev := coalesce(v_tier.upper_bound, p_gmv);
  end loop;
  return v_fee;
end;
$$;

comment on function public.host_progressive_fee(int) is
  '月間の予約売上に対する累進手数料の累計額。各確定では「確定後 − 確定前」の差分を引くことで、月末に遡及補正が要らないようにしている。';

-- ------------------------------------------------------------
-- host_monthly_ticket_gmv: JSTの当月に確定した予約売上(自分がホストの分)
-- p_exclude_booking を指定すると、その予約を除いた額を返す(確定前の額を出す用)
-- ------------------------------------------------------------
create function public.host_monthly_ticket_gmv(
  p_host_id uuid,
  p_at timestamptz default now(),
  p_exclude_booking uuid default null
)
returns int
language sql
stable
set search_path = public
as $$
  select coalesce(sum(b.coins), 0)::int
  from public.bookings b
  where b.host_id = p_host_id
    and b.status = 'completed'
    and date_trunc('month', (b.scheduled_at at time zone 'Asia/Tokyo'))
        = date_trunc('month', (p_at at time zone 'Asia/Tokyo'))
    and (p_exclude_booking is null or b.id <> p_exclude_booking);
$$;

-- ------------------------------------------------------------
-- 手数料の控除はトリガーで行う。
--
-- 報酬を付与している関数(complete_booking / auto_complete_bookings /
-- send_gift)はいずれも長く、send_gift は 0019→0022 で4回作り直している。
-- これらを丸ごと複製して手数料版に差し替えると、以後の改修でロジックが
-- 二重管理になりズレる。そこで既存関数は「満額を付与する」ままにしておき、
-- 直後にトリガーで手数料ぶんを引き戻す形にする。
-- 取引履歴も booking_earned(満額) + platform_fee(控除) の2行になり、
-- ホストから見て「いくら稼いで、いくら引かれたか」がそのまま読める。
-- ------------------------------------------------------------

-- 予約が completed になったときに手数料を引く
create function public._apply_booking_fee()
returns trigger
language plpgsql
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
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(new.host_id, new.scheduled_at, new.id);
  v_gmv_after := v_gmv_before + new.coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after)
              - public.host_progressive_fee(v_gmv_before);
  v_rate := v_base_fee / new.coins;

  -- 指名リピート: 同じゲストと過去に完了した予約があるか
  select exists (
    select 1 from public.bookings b
    where b.host_id = new.host_id
      and b.guest_id = new.guest_id
      and b.status = 'completed'
      and b.id <> new.id
      and b.scheduled_at < new.scheduled_at
  ) into v_is_repeat;

  if v_is_repeat then
    v_discount := least(c_repeat_discount, greatest(0, v_rate - c_rate_floor)) * new.coins;
  end if;

  v_fee := least(greatest(0, round(v_base_fee - v_discount))::int, new.coins);

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
    round(v_fee::numeric / new.coins, 4), v_is_repeat);

  return new;
end;
$$;

-- 「完了になった瞬間」だけを拾う。再実行や他の更新では発火させない。
--
-- ⚠️ deferrable initially deferred にしているのは必須。
--    complete_booking は「bookings を completed にする」→「報酬を満額付与する」
--    の順で書かれているため、通常の AFTER UPDATE では**付与より前**に
--    トリガーが走ってしまい、まだ残高が無いところから手数料を引こうとして
--    控除が丸ごと消える(実際に検証で1件目の手数料400コインが消えた)。
--    トランザクション終了時まで遅延させることで、付与済みの残高から引ける。
create constraint trigger bookings_apply_fee
  after update on public.bookings
  deferrable initially deferred
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function public._apply_booking_fee();

-- ギフト受領時に一律30%を引く
create function public._apply_gift_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c_gift_rate constant numeric := 0.30;
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;
  v_fee := least(greatest(round(new.coins * c_gift_rate)::int, 0), new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.receiver_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (new.receiver_id, -v_fee, 'platform_fee', 'gift_fee:' || new.id);
  end if;

  insert into public.platform_fees (
    host_id, kind, gift_id, gross_coins, fee_coins, net_coins, applied_rate)
  values (new.receiver_id, 'gift', new.id, new.coins, v_fee, new.coins - v_fee, c_gift_rate);

  return new;
end;
$$;

create trigger gifts_apply_fee
  after insert on public.gifts
  for each row
  execute function public._apply_gift_fee();

-- ------------------------------------------------------------
-- 手数料をかけない経路(意図的)
--   ・直前キャンセルの没収分(ゲスト都合・開始後)は、役務の対価ではなく
--     機会損失の補償なので手数料を取らない。
--     そもそもこの没収の設計自体が見直し対象(open-issues.md の E-10)。
--   ・換金申請が却下されて戻る分(return_payout)は再付与なので対象外。
-- ------------------------------------------------------------
-- ============================================================
-- ホスト向けダッシュボードの集計
-- ------------------------------------------------------------
-- 「頑張れる目標が見つかる」ことを目的にした集計。既存データから導出でき、
-- 実在する数字だけを返す。集計はすべて JST の暦月を基準にする。
--
-- ⚠️ ここに金額ベースの「ランキング(他人との順位)」は含めない。
--    弁護士見解(Q11-d)で「投げ銭ランキング・人気ランキングは
--    『人気女性への金銭提供サービス』と見られ危険」と明確に指摘されており、
--    既存の host_ranking も金額を一切スコアに入れていない。
--    ここで返すのは**自分自身の実績**だけ。
-- ============================================================

create function public.host_dashboard(p_at timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_ticket int;
  v_gift int;
  v_fee int;
  v_next_bound int;
  v_cur_rate numeric;
  v_next_rate numeric;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- JSTの当月[start, end)
  v_start := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) at time zone 'Asia/Tokyo');
  v_end   := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) + interval '1 month')
             at time zone 'Asia/Tokyo';

  v_ticket := public.host_monthly_ticket_gmv(v_uid, p_at);

  select coalesce(sum(pf.gross_coins), 0)::int into v_gift
  from public.platform_fees pf
  where pf.host_id = v_uid and pf.kind = 'gift'
    and pf.created_at >= v_start and pf.created_at < v_end;

  select coalesce(sum(pf.fee_coins), 0)::int into v_fee
  from public.platform_fees pf
  where pf.host_id = v_uid
    and pf.created_at >= v_start and pf.created_at < v_end;

  -- 次のティア(超過累進の次の段)
  select t.upper_bound, t.rate into v_next_bound, v_cur_rate
  from public.host_fee_tiers t
  where t.upper_bound is null or v_ticket < t.upper_bound
  order by t.step
  limit 1;

  select t.rate into v_next_rate
  from public.host_fee_tiers t
  where t.step = (
    select min(step) + 1 from public.host_fee_tiers
    where upper_bound is null or v_ticket < upper_bound
  );

  v_result := jsonb_build_object(
    'month_start', v_start,
    'ticket_coins', v_ticket,
    'gift_coins', v_gift,
    'gross_coins', v_ticket + v_gift,
    'fee_coins', v_fee,
    'net_coins', (v_ticket + v_gift) - v_fee,
    'effective_rate', case when (v_ticket + v_gift) > 0
                           then round(v_fee::numeric / (v_ticket + v_gift), 4) else 0 end,
    'tier', jsonb_build_object(
      'current_rate', v_cur_rate,
      'next_bound', v_next_bound,
      'next_rate', v_next_rate,
      'remaining_coins', case when v_next_bound is null then null
                              else greatest(0, v_next_bound - v_ticket) end
    )
  );

  -- 日別の売上(予約の確定額)
  v_result := v_result || jsonb_build_object('daily', coalesce((
    select jsonb_agg(jsonb_build_object('day', d.day, 'coins', d.coins) order by d.day)
    from (
      select extract(day from (b.scheduled_at at time zone 'Asia/Tokyo'))::int as day,
             sum(b.coins)::int as coins
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
      group by 1
    ) d
  ), '[]'::jsonb));

  -- 指名リピート(金額ベース)と人数
  v_result := v_result || (
    select jsonb_build_object(
      'repeat', jsonb_build_object(
        'repeat_coins', coalesce(sum(x.coins) filter (where x.is_repeat), 0)::int,
        'total_coins', coalesce(sum(x.coins), 0)::int,
        'repeat_rate', case when coalesce(sum(x.coins), 0) > 0
          then round(coalesce(sum(x.coins) filter (where x.is_repeat), 0)::numeric / sum(x.coins), 4)
          else 0 end,
        -- 「リピーター」は当月に2回目以降の予約が1件でもあるゲスト。
        -- 「新規」は残り。初回と2回目が同じ月にあるゲストを両方に数えないよう、
        -- 差し引きで出す(単純に filter で数えると二重計上になる)。
        'repeater_guests', count(distinct x.guest_id) filter (where x.is_repeat),
        'new_guests', count(distinct x.guest_id)
                      - count(distinct x.guest_id) filter (where x.is_repeat)
      ))
    from (
      select b.guest_id, b.coins,
             exists (
               select 1 from public.bookings p
               where p.host_id = b.host_id and p.guest_id = b.guest_id
                 and p.status = 'completed' and p.scheduled_at < b.scheduled_at
             ) as is_repeat
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
    ) x
  );

  -- 成約率と初回応答の速さ
  -- 承諾されたかどうかは promises の有無で判定する(promiseは approve_booking でしか作られない)
  v_result := v_result || (
    select jsonb_build_object(
      'response', jsonb_build_object(
        'requests', count(*),
        'approved', count(*) filter (where pr.id is not null),
        'approval_rate', case when count(*) > 0
          then round(count(*) filter (where pr.id is not null)::numeric / count(*), 4) else 0 end,
        'median_reply_seconds', percentile_cont(0.5) within group (
          order by extract(epoch from (b.scheduled_at - b.created_at))
        ) filter (where pr.id is not null)
      ))
    from public.bookings b
    left join public.promises pr on pr.booking_id = b.id
    where b.host_id = v_uid
      and b.created_at >= v_start and b.created_at < v_end
  );

  -- 埋まりやすい時間帯(直近4週に自分へ届いたリクエストの 曜日×時間)
  v_result := v_result || jsonb_build_object('heatmap', coalesce((
    select jsonb_agg(jsonb_build_object('dow', h.dow, 'hour', h.hour, 'count', h.c))
    from (
      select extract(isodow from (b.created_at at time zone 'Asia/Tokyo'))::int as dow,
             extract(hour   from (b.created_at at time zone 'Asia/Tokyo'))::int as hour,
             count(*)::int as c
      from public.bookings b
      where b.host_id = v_uid
        and b.created_at >= p_at - interval '28 days'
      group by 1, 2
    ) h
  ), '[]'::jsonb));

  return v_result;
end;
$$;

comment on function public.host_dashboard(timestamptz) is
  'ホスト向けダッシュボードの集計(自分自身の実績のみ)。JSTの暦月基準。金額ベースの他人との順位は意図的に含めない(弁護士Q11-d)。';

revoke all on function public.host_dashboard(timestamptz) from public;
grant execute on function public.host_dashboard(timestamptz) to authenticated;
-- ============================================================
-- 収益施策: (1) あんしんサポート料  (3) 延長課金
-- ------------------------------------------------------------
-- ■ あんしんサポート料
--   コイン購入時に価格の一定率を上乗せして預かる。ホストの取り分には
--   一切触れないため、既存ホストの手取りを下げずにテイクレートを上げられる。
--   根拠は承認制・本人確認・通報ブロック・トラブル時の返金対応という
--   既存の安全機能で、その提供の対価として受け取る。
--
--   ⚠️ 名称に「保険」を使わないこと。返金保証を「保険料」と称すると
--      保険業法の議論を招く。当社が提供する役務の対価として書く。
--   ⚠️ 特商法表記の「商品代金以外の必要料金」への記載が必須。
--
--   料率は1行だけの設定表に持たせる。パックごとに持たせると改定のたびに
--   全行を書き換えることになり、取りこぼしが出るため。
--
-- ■ 延長課金
--   進行中(confirmed)の予約に時間とコインを追加する。単価を上げずに
--   分母を増やせる、最も摩擦の少ない導線。
--
--   実装上の注意: 予約作成時と同じく、消費したロットの有効期限を
--   coin_lot_consumptions に記録する必要がある。これを忘れると、
--   延長した予約をキャンセルしたときに 0030 の「当初の期限で戻す」処理が
--   延長分を取りこぼす(記録が無い＝旧予約とみなされ、予約作成時刻を基準に
--   期限が引き直されてしまう)。
-- ============================================================

-- ------------------------------------------------------------
-- 価格設定(1行のみ)
-- ------------------------------------------------------------
create table public.platform_pricing (
  id smallint primary key default 1 check (id = 1),
  -- コイン購入時に上乗せする「あんしんサポート料」の率
  safety_fee_rate numeric(4, 3) not null default 0.050
    check (safety_fee_rate >= 0 and safety_fee_rate <= 0.5),
  updated_at timestamptz not null default now()
);

comment on table public.platform_pricing is
  'プラットフォームの価格設定(1行のみ)。あんしんサポート料の率など、改定しうる数値をここに集約する。';

insert into public.platform_pricing (id) values (1);

alter table public.platform_pricing enable row level security;

-- 料率は購入前に利用者へ示す情報なので誰でも読める
create policy "platform_pricing_select_all"
  on public.platform_pricing for select
  to authenticated
  using (true);

-- 購入履歴に、預かったサポート料を残す
alter table public.coin_purchases
  add column safety_fee_yen int not null default 0 check (safety_fee_yen >= 0);

comment on column public.coin_purchases.safety_fee_yen is
  'コイン代金に上乗せして預かったあんしんサポート料(円)。price_yen はコイン本体の価格で、請求総額は price_yen + safety_fee_yen。';

-- ------------------------------------------------------------
-- safety_fee_for: 指定価格に対するサポート料(円)。Edge Function から使う
-- ------------------------------------------------------------
create function public.safety_fee_for(p_price_yen int)
returns int
language sql
stable
set search_path = public
as $$
  select greatest(0, round(p_price_yen * (select safety_fee_rate from public.platform_pricing where id = 1)))::int;
$$;

comment on function public.safety_fee_for(int) is
  'コイン価格に対するあんしんサポート料(円)。料率は platform_pricing に持つ。';

-- ------------------------------------------------------------
-- extend_booking: 進行中の予約に時間とコインを追加する
-- ------------------------------------------------------------
create function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  -- 進行中のものだけ。完了後・キャンセル後は延長できない
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;
  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  -- 予約作成時と同じく、消費したロットの当初の期限を記録する。
  -- これを忘れると延長分がキャンセル返金で期限を引き直されてしまう(0030参照)。
  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  -- 予約本体に積み増す。完了時の手数料は増えた後の coins に対してかかる
  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

revoke all on function public.extend_booking(uuid, int) from public;
grant execute on function public.extend_booking(uuid, int) to authenticated;

-- 通知種別に延長を追加(既存の種別を落とさないこと。既存行が制約違反になる)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended'
  ));

-- duration_minutes は 30/60/120 固定だったが、延長で任意の合計になりうる
alter table public.bookings drop constraint if exists bookings_duration_minutes_check;
alter table public.bookings
  add constraint bookings_duration_minutes_check
  check (duration_minutes >= 30 and duration_minutes <= 600);
-- ============================================================
-- 募集の取り消し(論理削除)と、更新経路の絞り込み
-- ------------------------------------------------------------
-- ■ 取り消し導線が無かった問題
--   board_posts は open/closed/cancelled の状態を持っていたが、作成者が
--   自分の募集を取り消す手段がアプリ内に無く、定員が埋まるまで残り続けていた。
--
-- ■ 更新ポリシーが緩すぎた問題
--   0011 の board_posts_update_own_status には
--   「定員等の直接改変は不可」とコメントされていたが、実際には**全カラムを
--   更新できる**状態だった。PostgreSQL の RLS はカラム単位の制限ができず
--   (それは列レベル GRANT の役割)、列レベルの grant も置かれていなかったため。
--
--   このままだと作成者は、参加者が集まった後にゲーム名・定員・募集文を
--   書き換えられる。「Apexのエンジョイ枠」に参加したら別ゲームのガチ募集に
--   変わっている、ということが起こりうる。
--
--   直接 UPDATE を禁止し、状態変更は本マイグレーションの RPC 経由に一本化する。
--
-- ■ 物理削除はしない
--   参加者がいる募集がレコードごと消えると、参加履歴や通報の追跡ができなく
--   なるため、cancelled にする論理削除にとどめる(delete ポリシーは作らない)。
-- ============================================================

-- 直接更新を禁止する。以後、状態の変更は cancel_board_post / join_board_post のみ。
drop policy if exists "board_posts_update_own_status" on public.board_posts;

-- 取り消し理由(任意)。運営が経緯を追えるように残す。
alter table public.board_posts
  add column cancelled_at timestamptz,
  add column cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 200);

comment on column public.board_posts.cancelled_at is
  '作成者が募集を取り消した時刻。物理削除はせず、この列で論理削除を表す。';

-- 通知種別に募集の取り消しを追加(既存の種別を落とさないこと。既存行が制約違反になる)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled'
  ));

-- ------------------------------------------------------------
-- cancel_board_post: 作成者が自分の募集を取り消す。
-- 参加者がいる場合は全員に通知する(黙って消えると、参加者は待ち続けてしまう)。
-- ------------------------------------------------------------
create function public.cancel_board_post(p_post_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_name text;
  v_reason text;
  v_participant record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.creator_id <> v_uid then
    raise exception 'ONLY_CREATOR_CAN_CANCEL';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り消しは何もしない(連打対策)
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left(v_reason, 200)
    where id = p_post_id;

  select nickname into v_name from public.profiles where id = v_uid;

  -- 参加表明していた人に知らせる
  for v_participant in
    select user_id from public.board_participants where post_id = p_post_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_participant.user_id,
      'board_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが募集を取り消しました',
      v_post.game || '・' || v_post.when_text
        || case when v_reason is null then '' else '（' || v_reason || '）' end,
      p_post_id
    );
  end loop;
end;
$$;

revoke all on function public.cancel_board_post(uuid, text) from public;
grant execute on function public.cancel_board_post(uuid, text) to authenticated;
-- ============================================================
-- ホストランキングにプロフィール写真を含める
-- ------------------------------------------------------------
-- host_ranking() が avatar_path を返していなかったため、フロントは常に
-- 頭文字+カラーのプレースホルダーしか表示できなかった(実写真があっても
-- 反映されない)。avatar_path を追加で返し、フロント側で公開URLに変換する。
-- 戻り値の列を追加するため、関数を一度dropしてから再作成する。
-- ============================================================

drop function if exists public.host_ranking(text, int);

create function public.host_ranking(p_period text default 'weekly', p_limit int default 30)
returns table (
  rank bigint,
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  completed_count bigint,
  manner_score numeric,
  score numeric,
  is_verified boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with win as (
    select case p_period
             when 'daily'   then date_trunc('day',   (now() at time zone 'Asia/Tokyo'))
             when 'weekly'  then date_trunc('week',  (now() at time zone 'Asia/Tokyo'))
             when 'monthly' then date_trunc('month', (now() at time zone 'Asia/Tokyo'))
             else date_trunc('week', (now() at time zone 'Asia/Tokyo'))
           end as start_jst
  ),
  agg as (
    select b.host_id,
           count(*) filter (where b.status = 'completed') as completed,
           count(*) filter (where b.status in ('cancelled_by_host', 'no_show_host')) as host_cancel
    from public.bookings b, win
    where (b.scheduled_at at time zone 'Asia/Tokyo') >= win.start_jst
    group by b.host_id
    having count(*) filter (where b.status = 'completed') > 0
  ),
  scored as (
    select a.host_id,
           a.completed,
           round(
             a.completed
             * (coalesce(ts.manner_score, 4.50) / 5.0)
             * (a.completed::numeric / nullif(a.completed + a.host_cancel, 0)),
             2
           ) as score,
           coalesce(ts.manner_score, 4.50) as manner_score,
           coalesce(ts.is_verified, false) as is_verified
    from agg a
    left join public.profile_trust_stats ts on ts.user_id = a.host_id
  )
  select row_number() over (order by s.score desc, s.completed desc) as rank,
         s.host_id,
         p.nickname,
         p.avatar_initial,
         p.avatar_color,
         p.avatar_path,
         s.completed as completed_count,
         s.manner_score,
         s.score,
         s.is_verified
  from scored s
  join public.profiles p on p.id = s.host_id
  order by s.score desc, s.completed desc
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

comment on function public.host_ranking(text, int) is
  'ホストのデイリー/ウィークリー/マンスリーランキング。スコア=完了予約数×品質(manner_score)×信頼性。金額(投げ銭・稼ぎ)は一切含めない(弁護士Q11(d))。0037でavatar_pathを追加(ランキングに写真を表示するため)。';

revoke all on function public.host_ranking(text, int) from public;
grant execute on function public.host_ranking(text, int) to authenticated;
-- ============================================================
-- ホストが自分で設定する「初回お試し割引」
-- ------------------------------------------------------------
-- ホストがマイページ(ホスト設定)から割引率を自由に決められるようにする。
-- そのホストと初めて遊ぶゲストにだけ適用される。
--
-- 設計の要点:
--  * 割引率はホストが 0〜90% の範囲で自由に設定(0=キャンペーンなし)。
--    100%(無料)は bookings.coins > 0 制約に反するうえ、無償提供は
--    「一緒に遊ぶ時間の対価」という建て付けを崩すため認めない。
--  * 手数料は**割引後の金額**(=ゲストが実際に払ったコイン)に対してかかる。
--    _apply_booking_fee() は new.coins を基準にしているため、割引後の額を
--    coins に入れておけば自動的にそうなる(0033は変更不要)。
--  * 定価(list_coins)と割引率(discount_percent)を予約に残す。
--    特商法の価格表示・領収の裏づけと、キャンセル時の「平均的な損害」の
--    立証材料(0032)のために、いくらの取引だったのかを後から辿れるようにする。
--  * 既存の「指名リピート割引」(0033)はホストの**手数料率**を下げるもので、
--    2回目以降が対象。本キャンペーンはゲストの**支払額**を下げるもので、
--    初回のみが対象。軸も対象も違うため衝突しない(1件の予約が両方の
--    条件を満たすことはない)。
--
-- 「初回」の判定:
--   そのホストとの間に、ゲスト側に帰属する予約が1件も無いこと。
--   ホスト都合で流れたもの(辞退・ホストキャンセル・ホスト無断欠席)は
--   カウントしない。ゲストのせいで成立しなかったわけではないため。
--   一方 requested(承諾待ち)は含める。含めないと、承諾される前に
--   何件でも割引価格で申し込めてしまう。
-- ============================================================

alter table public.host_settings
  add column if not exists trial_discount_percent int not null default 0;

alter table public.host_settings
  drop constraint if exists host_settings_trial_discount_percent_check;
alter table public.host_settings
  add constraint host_settings_trial_discount_percent_check
  check (trial_discount_percent between 0 and 90);

comment on column public.host_settings.trial_discount_percent is
  '初回お試し割引の割引率(%)。0でキャンペーンなし。ホストが自分で設定する。';

-- 予約に「定価」と「適用した割引率」を残す。
-- 既存行は割引なしの扱い(list_coins = coins)。
alter table public.bookings
  add column if not exists list_coins int;
alter table public.bookings
  add column if not exists discount_percent int not null default 0;

update public.bookings set list_coins = coins where list_coins is null;

comment on column public.bookings.list_coins is
  '割引前の定価(コイン)。割引が無い場合は coins と同じ。';
comment on column public.bookings.discount_percent is
  '適用した初回お試し割引の割引率(%)。予約成立時点の値で固定する。';

-- ------------------------------------------------------------
-- 適用される割引率を返す(対象外なら0)
-- ------------------------------------------------------------
create or replace function public.host_trial_discount_for(p_host_id uuid, p_guest_id uuid)
returns int
language sql
security definer
set search_path = public
stable
as $$
  select case
           when p_host_id is null or p_guest_id is null then 0
           when p_host_id = p_guest_id then 0
           when exists (
             select 1 from public.bookings b
             where b.host_id = p_host_id
               and b.guest_id = p_guest_id
               -- ホスト都合で流れたものは「利用済み」と見なさない
               and b.status in (
                 'requested', 'confirmed', 'completed',
                 'cancelled_by_guest', 'no_show_guest'
               )
           ) then 0
           else coalesce(
             (select hs.trial_discount_percent
              from public.host_settings hs
              where hs.user_id = p_host_id and hs.is_host), 0)
         end;
$$;

comment on function public.host_trial_discount_for(uuid, uuid) is
  'そのゲストにいま適用される初回お試し割引の割引率(%)。対象外・未設定なら0。';

-- フロント表示用。自分(auth.uid())がゲストの場合の割引率を返す。
create or replace function public.my_trial_discount(p_host_id uuid)
returns int
language sql
security definer
set search_path = public
stable
as $$
  select public.host_trial_discount_for(p_host_id, auth.uid());
$$;

comment on function public.my_trial_discount(uuid) is
  '予約画面の価格表示用。自分に適用される初回お試し割引の割引率(%)を返す。';

revoke all on function public.host_trial_discount_for(uuid, uuid) from public;
revoke all on function public.my_trial_discount(uuid) from public;
grant execute on function public.host_trial_discount_for(uuid, uuid) to authenticated;
grant execute on function public.my_trial_discount(uuid) to authenticated;

-- ------------------------------------------------------------
-- create_booking: 割引後の金額で消費・記録する
--   引数は変えない(mainにマージすると即デプロイされるため、
--   RPCのシグネチャ変更はフロントのデプロイ順と競合しうる)。
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_discount int;
  v_list_coins int;
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

  -- 定価 → 初回お試し割引 → 実際に払う額。
  -- 割引率はこの時点の値で固定し、予約に残す。
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

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

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at, list_coins, discount_percent
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end,
    v_list_coins, v_discount
  )
  returning id into v_booking_id;

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

comment on function public.create_booking(uuid, int, text) is
  '予約リクエストを作成し、コインをエスクローする。0038で初回お試し割引に対応(割引後の額を coins に入れるため、手数料も割引後の額にかかる)。';

-- ------------------------------------------------------------
-- extend_booking: 元の予約と同じ割引率で延長する
--   同じセッションの途中で単価が変わると説明がつかない(特商法の
--   価格表示上も不親切)ため、予約時に固定した割引率を引き継ぐ。
-- ------------------------------------------------------------
create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_list_add int;
  v_add_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_list_add := round(v_hourly_rate * p_additional_minutes / 60.0);
  v_add_coins := greatest(1, round(v_list_add * (100 - coalesce(v_booking.discount_percent, 0)) / 100.0));

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  -- 延長分もロットの消費として記録する。記録しないと、返金(0030)のときに
  -- 当初の有効期限を引き直せず、資金決済法の適用除外(6か月)が崩れる。
  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_list_add
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

comment on function public.extend_booking(uuid, int) is
  'ゲストが進行中の予約を延長する。0038で、元の予約に適用した初回お試し割引を引き継ぐようにした。';
-- ============================================================
-- 初回お試し割引を「最初に予約した分」だけに限定する
-- ------------------------------------------------------------
-- 0038 では延長にも同じ割引率を引き継いでいたが、これをやめて
-- 延長分は通常価格で請求する。
--
-- 理由:
--  1. ホストの持ち出しに上限が無かった。割引率はホストが90%まで
--     設定できるため、引き継ぎ方式だと「30分だけ安く試してもらう」
--     つもりで設定したホストが、延長を重ねられて何時間ぶんもの時間を
--     1割の単価で提供する状態になりうる。割引の対象を「最初に予約した
--     時間」に閉じると、ホストが負担する上限が予約時点で確定する。
--  2. 結果として、最初から長めに予約したほうが得になる。
--     (例: 30分1000コイン・初回30%OFF のホストで1時間遊ぶ場合)
--       最初から60分   … 定価2000 → 1400
--       30分+30分延長  … 700 + 1000 = 1700
--
-- 表示について:
--   「初回30%OFF」と見せた取引の一部が割引対象外になるため、
--   予約画面と延長の導線の両方で、延長分が通常価格であることを
--   明示する必要がある(景表法の有利誤認・特商法の価格表示)。
--   規約 第8条の4 第6項、特商法表記もあわせて改めている。
-- ============================================================

comment on column public.bookings.discount_percent is
  '最初に予約した分に適用した初回お試し割引の割引率(%)。予約成立時点の値で固定する。延長分には適用しない(0039)。';

create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  -- 予約作成時と同じく、消費したロットの当初の期限を記録する。
  -- これを忘れると延長分がキャンセル返金で期限を引き直されてしまう(0030参照)。
  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  -- 延長分は割引が無いので、定価(list_coins)と請求額(coins)には同額を積む
  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

comment on function public.extend_booking(uuid, int) is
  'ゲストが進行中の予約を延長する。0039で、延長分は通常価格(初回お試し割引の対象外)に変更した。';
-- ============================================================
-- 予約の開始時刻をゲストが指定できるようにし、キャンセルを段階制にする
-- ------------------------------------------------------------
-- これまでは approve_booking() が scheduled_at を now() で上書きしていたため、
-- 「開始1時間前まで全額返還」という説明が**構造上ずっと成立しない**状態だった
-- (承諾した瞬間が開始時刻なので、承諾直後のキャンセルでも常に「1時間前以降」)。
-- open-issues.md の E-10、弁護士質問 Q14-b/c の本体。
--
-- ■ 受付の締切とキャンセル猶予を「別の基準」にする
--   締切を1つの数字で決めようとすると必ずどちらかが壊れる。直前まで予約できる
--   ようにすると、そのゲストには無料でキャンセルできる時間が最初から存在しない。
--   そこで2本立てにする。
--     * 開始時刻を基準とする猶予  … 開始1時間前まで全額
--     * 承諾時刻を基準とする猶予  … 承諾から5分以内は全額(誤タップ・翻意の救済)
--   どちらか有利なほうを適用する。これで、
--     3日先の予約   → 開始1時間前まで自由にキャンセルできる
--     30分後の予約  → 承諾から5分は全額戻る
--   と、どちらのケースでも逃げ道が残る。
--
-- ■ 100%没収をやめ、段階制にする
--   消費者契約法9条(平均的な損害を超えるキャンセル料は無効)への対応。
--   開始1時間前を切ってからは一部返還とし、開始後・無断欠席のみ返還なしとする。
--   **返還率・猶予の数値は platform_pricing に置く**。弁護士の回答(Q14-b/c)で
--   数値が変わってもコードを触らずに済むようにするため。
--
-- ■ 「今すぐ」も残す
--   requested_start_at が null なら従来どおり承諾時点が開始時刻。
--   このアプリの中心にある「今夜すぐ」の体験を壊さない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 予約に「希望開始時刻」と「承諾時刻」を持たせる
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists requested_start_at timestamptz;
alter table public.bookings
  add column if not exists confirmed_at timestamptz;

comment on column public.bookings.requested_start_at is
  'ゲストが指定した希望開始時刻。null なら「今すぐ」(承諾時点が開始時刻)。';
comment on column public.bookings.confirmed_at is
  'ホストが承諾した時刻。キャンセル猶予の起点。0040以前の行は null。';

-- 既存行は「承諾時点＝開始時刻」だったので、確定済みのものはそこを承諾時刻とみなす
update public.bookings
  set confirmed_at = scheduled_at
  where confirmed_at is null
    and status in ('confirmed', 'completed', 'cancelled_by_guest', 'cancelled_by_host',
                   'no_show_host', 'no_show_guest');

-- ------------------------------------------------------------
-- 2. キャンセルポリシーの数値を platform_pricing に集約する
-- ------------------------------------------------------------
alter table public.platform_pricing
  add column if not exists free_cancel_hours numeric(4, 2) not null default 1;
alter table public.platform_pricing
  add column if not exists cancel_grace_minutes int not null default 5;
alter table public.platform_pricing
  add column if not exists late_cancel_refund_percent int not null default 50;
alter table public.platform_pricing
  add column if not exists min_lead_minutes int not null default 30;
alter table public.platform_pricing
  add column if not exists max_lead_days int not null default 7;

alter table public.platform_pricing
  drop constraint if exists platform_pricing_late_refund_check;
alter table public.platform_pricing
  add constraint platform_pricing_late_refund_check
  check (late_cancel_refund_percent between 0 and 100);

comment on column public.platform_pricing.free_cancel_hours is
  '全額返還となる「開始の何時間前まで」。';
comment on column public.platform_pricing.cancel_grace_minutes is
  '承諾から何分以内なら全額返還とするか。「今すぐ」の予約では開始＝承諾なので、'
  'この猶予だけが誤タップ・翻意の救済になる。長すぎると「無料で遊べる時間」に'
  'なってしまうため短く取る(既定5分。最短予約枠30分の1/6)。';
comment on column public.platform_pricing.late_cancel_refund_percent is
  '開始直前(無料枠を過ぎてから開始まで)のキャンセルで返還する割合(%)。'
  '消費者契約法9条の「平均的な損害」との関係で、弁護士回答により変わりうる数値。';
comment on column public.platform_pricing.min_lead_minutes is
  '開始時刻を指定する場合、いま から最短で何分先を選べるか。';
comment on column public.platform_pricing.max_lead_days is
  '開始時刻を指定する場合、いま から最長で何日先を選べるか。';

-- ------------------------------------------------------------
-- 3. 返還率の判定(1か所に集約し、画面とサーバで必ず同じ答えを出す)
-- ------------------------------------------------------------
create or replace function public.booking_refund_percent(
  p_status text,
  p_confirmed_at timestamptz,
  p_scheduled_at timestamptz,
  p_at timestamptz default now()
)
returns int
language sql
stable
set search_path = public
as $$
  select case
    -- 承諾前(リクエスト中)の取り消しは全額
    when p_status = 'requested' then 100
    when p_status <> 'confirmed' then 0
    -- 承諾から一定時間内は全額(直前予約でも猶予が残るように)
    -- 「今すぐ」の予約は開始時刻＝承諾時刻なので、ここに「開始前」の条件を
    -- 付けると猶予そのものが打ち消される(まさに E-10 で問題にしている
    -- 「承諾の瞬間から100%没収」が残ってしまう)。開始時刻とは切り離す。
    when p_confirmed_at is not null
     and p_at < p_confirmed_at + make_interval(mins => (select cancel_grace_minutes from public.platform_pricing where id = 1)) then 100
    -- 開始の一定時間前までは全額
    when p_at < p_scheduled_at - make_interval(mins => (select round(free_cancel_hours * 60)::int from public.platform_pricing where id = 1)) then 100
    -- 開始までは一部返還
    when p_at < p_scheduled_at then (select late_cancel_refund_percent from public.platform_pricing where id = 1)
    -- 開始後は返還なし
    else 0
  end;
$$;

comment on function public.booking_refund_percent(text, timestamptz, timestamptz, timestamptz) is
  'ゲスト都合でキャンセルしたときに返還される割合(%)。画面の見積りとサーバの実処理で必ず同じ式を使う。';

-- 画面表示用。自分が当事者の予約について、いまキャンセルしたら何%戻るかを返す。
create or replace function public.my_booking_refund_percent(p_booking_id uuid)
returns int
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;
  return public.booking_refund_percent(v_b.status, v_b.confirmed_at, v_b.scheduled_at, now());
end;
$$;

revoke all on function public.my_booking_refund_percent(uuid) from public;
grant execute on function public.my_booking_refund_percent(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4. create_booking: 希望開始時刻を受け取れるようにする
--    引数を増やすため、旧3引数版は薄いラッパーとして残す
--    (main にマージすると即デプロイされるので、フロントの反映順と競合しうる)
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_discount int;
  v_list_coins int;
  v_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_guest_name text;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_days int;
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

  -- 開始時刻を指定する場合の受付範囲を確かめる
  if p_scheduled_at is not null then
    select min_lead_minutes, max_lead_days into v_min_lead, v_max_days
    from public.platform_pricing where id = 1;
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_days) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings where user_id = p_host_id for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

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

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at, list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
  )
  returning id into v_booking_id;

  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id, 'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分'
      || case when p_scheduled_at is null then '(今すぐ)'
              else '(' || to_char(p_scheduled_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜)' end
      || '。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

-- 旧3引数版は「今すぐ」として新版へ委譲する(経過措置)
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text
)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.create_booking(p_host_id, p_duration_minutes, p_policy_version, null::timestamptz);
$$;

comment on function public.create_booking(uuid, int, text) is
  '経過措置。開始時刻を指定しない(=今すぐ)申込み。フロントのデプロイ完了後に削除してよい。';

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 5. approve_booking: 希望開始時刻があればそれを尊重する
-- ------------------------------------------------------------
create or replace function public.approve_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
  v_start timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 指定があればその時刻、無ければ従来どおり承諾時点が開始時刻。
  -- 承諾時刻は別に持つ(キャンセル猶予の起点になるため。0040以前は
  -- scheduled_at が承諾時刻を兼ねていた)。
  v_start := coalesce(v_booking.requested_start_at, now());

  update public.bookings
    set status = 'confirmed', scheduled_at = v_start, confirmed_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ピタメイト') || 'さんが予約を承諾しました',
    case when v_booking.requested_start_at is null
         then 'トークが始まりました。プレイの準備をしましょう'
         else to_char(v_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜 で成立しました' end,
    v_promise_id
  );

  return v_promise_id;
end;
$$;

-- ------------------------------------------------------------
-- 6. ロットの返還を一部返還に対応させる
--    p_paid / p_bonus に「戻す枚数」を渡す。null なら全部戻す(従来どおり)。
--    戻さなかった分は没収(ホストの報酬)になるので、restored_at は立てて
--    しまってよい。予約は取り消しで終端状態になり、二重返還は起きない。
-- ------------------------------------------------------------
-- 旧(1引数)と新(3引数)の両方を落としてから作る。新しいほうも落とすのは、
-- このファイルをもう一度流したときに「同じ引数の関数が既にある」で
-- 止まらないようにするため(適用済みか分からなくなったとき、番号順に
-- 流し直せるほうが安全)。
drop function if exists public._refund_coin_lots_for_booking(uuid);
drop function if exists public._refund_coin_lots_for_booking(uuid, int, int);

create function public._refund_coin_lots_for_booking(
  p_booking_id uuid,
  p_paid int default null,
  p_bonus int default null
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
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, -(v_lapsed_paid + v_lapsed_bonus), 'expire', p_booking_id,
              'refund_lapsed');
  end if;
end;
$$;

revoke all on function public._refund_coin_lots_for_booking(uuid, int, int) from public;

-- ------------------------------------------------------------
-- 7. cancel_booking: 段階制の返還にする
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
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  -- 承諾前の取り消しは、どちらからでも全額返還(従来どおり)
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

  -- 返す枚数。購入コインから先に返す(消費したときと同じ順序)
  v_refund_total := round(v_booking.coins * v_pct / 100.0);
  v_refund_paid := least(v_booking.paid_coins, v_refund_total);
  v_refund_bonus := v_refund_total - v_refund_paid;
  v_to_host := v_booking.coins - v_refund_total;

  update public.bookings set status = v_new_status, cancel_reason = p_reason, cancelled_at = now()
    where id = p_booking_id;

  if v_refund_total > 0 then
    update public.coin_wallets
      set balance = balance + v_refund_paid, bonus_balance = bonus_balance + v_refund_bonus
      where user_id = v_booking.guest_id;
    perform public._refund_coin_lots_for_booking(p_booking_id, v_refund_paid, v_refund_bonus);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_refund_total, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 一部も戻らない場合でも、消費記録は閉じておく(期限管理のため)
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0);
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
    case when v_pct = 100 then 'コインは全額戻りました'
         when v_pct = 0 then '開始後のキャンセルのため、コインは報酬として確定しました'
         else v_pct || '%のコインが戻り、残りは報酬として確定しました' end,
    p_booking_id);
end;
$$;

-- ------------------------------------------------------------
-- 8. 立証材料ビューを承諾時刻ベースに直す
--    0032 では scheduled_at が承諾時刻を兼ねていたため
--    `scheduled_at as approved_at` としていたが、開始時刻を指定できるように
--    なった以上その等式は成り立たない。
-- ------------------------------------------------------------
drop view if exists public.guest_cancellation_evidence;

create view public.guest_cancellation_evidence
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.status,
  b.policy_version,
  b.policy_agreed_at,
  b.created_at as requested_at,
  b.confirmed_at as approved_at,
  b.requested_start_at,
  b.scheduled_at as starts_at,
  b.cancelled_at,
  b.coins,
  b.list_coins,
  b.discount_percent,
  extract(epoch from (b.cancelled_at - b.confirmed_at))::int as seconds_after_approval,
  extract(epoch from (b.scheduled_at - b.cancelled_at))::int as seconds_before_start,
  public.booking_refund_percent(b.status, b.confirmed_at, b.scheduled_at, b.cancelled_at)
    as refund_percent_at_cancel
from public.bookings b
where b.cancelled_at is not null;

comment on view public.guest_cancellation_evidence is
  'キャンセルの実態(承諾からの経過・開始までの残り・適用された返還率)。'
  '消費者契約法9条の「平均的な損害」を検討するための材料。0040で承諾時刻ベースに修正。';
-- ============================================================
-- あそぶ時間を30分刻み・最長4時間にし、予約できる先を2週間に延ばす
-- ------------------------------------------------------------
-- ■ あそぶ時間: 30/60/120 の3択 → 30分刻みで 30〜240分
--   ランクを回す・レイドを進める等、実際のプレイは中途半端な長さになる。
--   3択だと「1時間半だけ」が取れず、2時間にするか諦めるかになっていた。
--   上限を4時間に留めるのは、
--     * それ以上は延長(第8条の3)で足せる
--     * 初回に長時間を前払いさせると、直前キャンセル時の没収額が大きくなり
--       消費者契約法9条の論点が重くなる
--   ため。延長を重ねた合計は従来どおり bookings の制約(600分)まで。
--
-- ■ 予約できる先: 7日 → 14日
--   7日だと「再来週の週末」が取れない。一方で1か月先まで開けると、空き時間を
--   管理する仕組みが無い現状ではピタメイトが都合を確認できないまま長い約束を
--   抱えることになり、直前キャンセルが増える。2週間なら「次の週末」と
--   「その次」が収まる。
--
-- 数値はいずれも platform_pricing に置く。運用データを見て変えられるように
-- するため(コード改修が要らない)。
-- ============================================================

alter table public.platform_pricing
  add column if not exists max_duration_minutes int not null default 240;

alter table public.platform_pricing
  drop constraint if exists platform_pricing_max_duration_check;
alter table public.platform_pricing
  add constraint platform_pricing_max_duration_check
  check (max_duration_minutes between 30 and 600 and max_duration_minutes % 30 = 0);

comment on column public.platform_pricing.max_duration_minutes is
  '1件の予約で最初に申し込めるプレイ時間の上限(分)。30の倍数。'
  'これを超える分は延長(第8条の3)で足す。';

-- 既定値だけでなく、すでにある1行も更新する
alter table public.platform_pricing alter column max_lead_days set default 14;
update public.platform_pricing set max_lead_days = 14, max_duration_minutes = 240 where id = 1;

-- ------------------------------------------------------------
-- create_booking: 30分刻み・上限までを受け付ける
--   検査以外は 0040 と同じ。
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_discount int;
  v_list_coins int;
  v_coins int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_guest_name text;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_days int;
  v_max_duration int;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select min_lead_minutes, max_lead_days, max_duration_minutes
    into v_min_lead, v_max_days, v_max_duration
  from public.platform_pricing where id = 1;

  -- 30分刻みで、30分以上、上限まで
  if p_duration_minutes is null
     or p_duration_minutes < 30
     or p_duration_minutes > v_max_duration
     or p_duration_minutes % 30 <> 0 then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_days) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hourly_rate, is_host into v_hourly_rate, v_is_host
  from public.host_settings where user_id = p_host_id for share;

  if v_hourly_rate is null or not v_is_host then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

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

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status,
    policy_version, policy_agreed_at, list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, v_from_paid, v_from_bonus, 'requested',
    nullif(btrim(coalesce(p_policy_version, '')), ''),
    case when nullif(btrim(coalesce(p_policy_version, '')), '') is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
  )
  returning id into v_booking_id;

  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  select nickname into v_guest_name from public.profiles where id = v_guest_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    p_host_id, 'booking_requested',
    coalesce(nullif(v_guest_name, ''), '誰か') || 'さんから予約リクエストが届きました',
    v_coins || 'コイン・' || p_duration_minutes || '分'
      || case when p_scheduled_at is null then '(今すぐ)'
              else '(' || to_char(p_scheduled_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜)' end
      || '。承諾するとトークが始まります',
    v_booking_id
  );

  return v_booking_id;
end;
$$;

comment on function public.create_booking(uuid, int, text, timestamptz) is
  '予約リクエストを作成し、コインをエスクローする。0041でプレイ時間を30分刻み(上限は platform_pricing.max_duration_minutes)に対応。';
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
-- ============================================================
-- 0043_integrity_checks.sql
-- 取引データの整合性を毎日自動で照合し、ズレを検知する
-- ------------------------------------------------------------
-- 背景: お金を扱う以上、いちばん怖いのは「壊れたことに気づかないまま
-- 時間が経つ」ことです。バックアップを持っていても、破損に3か月気づかなければ
-- どの時点まで巻き戻すのが正しいのか判断できず、復元しても意味がありません。
-- 予防(0044の追記専用化)や復旧(PITR)より先に、まず**検知**を置きます。
--
-- 幸い、この設計にはもともと冗長性があります。
--   ・coin_wallets.balance / bonus_balance は coin_lots の集計キャッシュ
--   ・coin_transactions は全ての残高変動の履歴(0003〜0042で67か所から記録)
--   ・coin_purchases は Stripe 側にも同じ記録が残る
-- つまり「同じ事実を別の形で持っている」ため、突き合わせれば破損が分かります。
--
-- いちばん効く不変条件はこれです:
--   Σ coin_transactions.amount == balance + bonus_balance + earned_balance
-- 残高の変動は必ず1行の履歴を伴うので、どのバケット(有償/ボーナス/報酬)に
-- 入ったかを分類しなくても、合計だけで全てのズレを捕まえられます。
--
-- 特に危ないのは greatest(0, balance - X) 形式の更新です(0018のexpire_coins、
-- 0030/0040の失効差し引き、0033の手数料控除)。既にズレていると更新側だけが
-- 0で止まり、履歴には満額が残るため、ズレが静かに拡大します。C3がこれを捕まえます。
-- ============================================================

-- ------------------------------------------------------------
-- integrity_checks: 照合結果の記録
-- ------------------------------------------------------------
create table if not exists public.integrity_checks (
  id uuid primary key default gen_random_uuid(),
  ran_at timestamptz not null default now(),
  check_name text not null,
  severity text not null check (severity in ('ok', 'warn', 'error')),
  -- ズレていた対象の件数(ok のときは 0、情報系は対象数)
  affected_count int not null default 0,
  -- ズレの合計(コイン単位)。情報系の指標値もここに入れる
  total_gap bigint not null default 0,
  -- 対象の内訳(先頭20件まで)。運営が個別に追える形で残す
  detail jsonb not null default '{}'::jsonb
);

comment on table public.integrity_checks is
  '取引データの日次整合性チェックの結果。severity=error の行が出たら、その日のうちに原因を特定すること。';

alter table public.integrity_checks enable row level security;

-- 閲覧は管理者のみ。書き込みポリシーは作らない(関数経由のみ)。
drop policy if exists "integrity_checks_select_admin" on public.integrity_checks;
create policy "integrity_checks_select_admin"
  on public.integrity_checks for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create index if not exists integrity_checks_ran_idx
  on public.integrity_checks (ran_at desc, check_name);

-- 通知タイプに整合性アラートを追加
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled',
    'integrity_alert'
  ));

-- ------------------------------------------------------------
-- run_integrity_checks: 全チェックを実行して結果を記録する
--   ・cron(service_role)からの実行と、管理者による手動実行の両方を許可
--   ・error が1件でもあれば管理者全員に通知する
--   ・戻り値は error だったチェックの数(0なら健全)
-- ------------------------------------------------------------
create or replace function public.run_integrity_checks()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run_at timestamptz := now();
  v_errors int := 0;
  v_count int;
  v_gap bigint;
  v_detail jsonb;
begin
  -- service_role/cron から呼ぶときは auth.uid() が null。
  -- ログイン中のユーザーが呼ぶ場合は管理者に限る。
  if auth.uid() is not null
     and not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  -- ============================================================
  -- C1/C2: 残高キャッシュ vs コインロットの残
  --   balance は「未失効ロットの合計」のキャッシュ。ここがズレると
  --   利用者から見える残高が実体と食い違う。
  --   失効済みロットは expire_coins() が remaining=0 にするため、
  --   期限で絞らず全ロットを合計してよい。
  -- ============================================================
  with agg as (
    select w.user_id,
           w.balance as cached,
           coalesce((select sum(l.remaining) from public.coin_lots l
                     where l.user_id = w.user_id and l.kind = 'paid'), 0) as lots
    from public.coin_wallets w
  ),
  bad as (select * from agg where cached <> lots)
  select count(*), coalesce(sum(abs(cached - lots)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'cached', cached, 'lots', lots)
         ) filter (where true), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(cached - lots) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'wallet_vs_lots_paid',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  with agg as (
    select w.user_id,
           w.bonus_balance as cached,
           coalesce((select sum(l.remaining) from public.coin_lots l
                     where l.user_id = w.user_id and l.kind = 'bonus'), 0) as lots
    from public.coin_wallets w
  ),
  bad as (select * from agg where cached <> lots)
  select count(*), coalesce(sum(abs(cached - lots)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'cached', cached, 'lots', lots)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(cached - lots) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'wallet_vs_lots_bonus',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C3: 残高の合計 vs 履歴の累計(いちばん強いチェック)
  --   残高変動は必ず coin_transactions に1行残るので、3つの残高の合計は
  --   履歴の累計と一致するはず。バケットの分類が要らないのが利点。
  -- ============================================================
  with agg as (
    select w.user_id,
           w.balance + w.bonus_balance + w.earned_balance as wallet_total,
           coalesce((select sum(t.amount) from public.coin_transactions t
                     where t.user_id = w.user_id), 0) as ledger_total
    from public.coin_wallets w
  ),
  bad as (select * from agg where wallet_total <> ledger_total)
  select count(*), coalesce(sum(abs(wallet_total - ledger_total)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'wallet_total', wallet_total, 'ledger_total', ledger_total)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(wallet_total - ledger_total) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'wallet_vs_ledger',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C4: 入金記録 vs 履歴(Stripe経由の付与)
  --   coin_purchases.coins_credited は「有償分+ボーナス分」の合計。
  --   Webhookの二重処理や付与漏れをここで捕まえる。
  --   Stripeのダッシュボード側とも突き合わせられる唯一の接点。
  -- ============================================================
  with agg as (
    select p.user_id,
           sum(p.coins_credited) as purchased,
           coalesce((select sum(t.amount) from public.coin_transactions t
                     where t.user_id = p.user_id
                       and t.type in ('purchase', 'bonus')
                       and t.note like 'stripe:%'), 0) as ledger
    from public.coin_purchases p
    group by p.user_id
  ),
  bad as (select * from agg where purchased <> ledger)
  select count(*), coalesce(sum(abs(purchased - ledger)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'purchased', purchased, 'ledger', ledger)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(purchased - ledger) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'purchase_vs_ledger',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C5: 換金申請 vs 履歴
  --   換金は申請時点(reserve)で earned_balance から引き、type='payout' を
  --   記録する。失敗時は 'refund' で戻すので、payoutの合計は申請の合計と一致する。
  --   ここがズレると「振り込んだのに残高が減っていない」等の直接の損失になる。
  -- ============================================================
  with agg as (
    select p.user_id,
           sum(p.coins) as requested,
           coalesce((select -sum(t.amount) from public.coin_transactions t
                     where t.user_id = p.user_id and t.type = 'payout'), 0) as ledger
    from public.payouts p
    group by p.user_id
  ),
  bad as (select * from agg where requested <> ledger)
  select count(*), coalesce(sum(abs(requested - ledger)), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'user_id', user_id, 'requested', requested, 'ledger', ledger)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (select * from bad order by abs(requested - ledger) desc limit 20) t;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'payout_vs_ledger',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C6: 預かり中の予約の内訳
  --   coins = paid_coins + bonus_coins が崩れていると、キャンセル返還で
  --   戻す量を誤る(返しすぎ/返し足りない)。
  -- ============================================================
  select count(*), coalesce(sum(abs(b.coins - (b.paid_coins + b.bonus_coins))), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'booking_id', b.id, 'coins', b.coins,
           'paid_coins', b.paid_coins, 'bonus_coins', b.bonus_coins)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (
    select * from public.bookings
    where status in ('requested', 'confirmed')
      and coins <> paid_coins + bonus_coins
    order by abs(coins - (paid_coins + bonus_coins)) desc
    limit 20
  ) b;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'escrow_split',
          case when v_count = 0 then 'ok' else 'error' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));
  v_errors := v_errors + case when v_count = 0 then 0 else 1 end;

  -- ============================================================
  -- C7: 失効処理が動いているか
  --   期限切れなのに残っているロットが溜まっていたら、日次の
  --   expire_coins() が止まっている(=資金決済法の適用除外の前提が崩れる)。
  --   1日1回の実行なので、2日の猶予を見てから警告する。
  -- ============================================================
  select count(*), coalesce(sum(l.remaining), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'lot_id', l.id, 'user_id', l.user_id,
           'remaining', l.remaining, 'expires_at', l.expires_at)), '[]'::jsonb)
    into v_count, v_gap, v_detail
  from (
    select * from public.coin_lots
    where remaining > 0 and expires_at < now() - interval '2 days'
    order by expires_at
    limit 20
  ) l;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'stale_expired_lots',
          case when v_count = 0 then 'ok' else 'warn' end,
          v_count, v_gap, jsonb_build_object('rows', v_detail));

  -- ============================================================
  -- C8(情報): 預かり中コインの総額
  --   ズレではないが、毎日記録して時系列で見られるようにする。
  --   前払式支払手段の残高監視(基準日3/31・9/30)の材料にもなる。
  -- ============================================================
  select count(*), coalesce(sum(coins), 0)
    into v_count, v_gap
  from public.bookings
  where status in ('requested', 'confirmed');

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'escrow_outstanding', 'ok', v_count, v_gap,
          jsonb_build_object('note', '預かり中(未完了)の予約とコイン総額'));

  -- ============================================================
  -- C9(情報): 未使用コインの総額(発行残高)
  -- ============================================================
  select count(*), coalesce(sum(balance + bonus_balance), 0)
    into v_count, v_gap
  from public.coin_wallets
  where balance + bonus_balance > 0;

  insert into public.integrity_checks (ran_at, check_name, severity, affected_count, total_gap, detail)
  values (v_run_at, 'unused_coin_balance', 'ok', v_count, v_gap,
          jsonb_build_object('note', '未使用の前払式コイン(有償+ボーナス)の総額'));

  -- ============================================================
  -- error が出たら管理者に通知する
  -- ============================================================
  if v_errors > 0 then
    insert into public.notifications (user_id, type, title, body)
    select a.user_id, 'integrity_alert',
           '取引データの不整合を検知しました',
           v_errors::text || '件のチェックがエラーになりました。integrity_checks を確認してください。'
    from public.admins a;
  end if;

  return v_errors;
end;
$$;

comment on function public.run_integrity_checks() is
  '取引データの整合性を照合し integrity_checks に記録する。errorがあれば管理者に通知。cronから毎日実行。';

revoke all on function public.run_integrity_checks() from public;
grant execute on function public.run_integrity_checks() to authenticated;

-- ------------------------------------------------------------
-- integrity_latest: 直近の実行結果だけを見るビュー(運営用)
-- ------------------------------------------------------------
create or replace view public.integrity_latest
with (security_invoker = true) as
select c.*
from public.integrity_checks c
where c.ran_at = (select max(ran_at) from public.integrity_checks)
order by
  case c.severity when 'error' then 0 when 'warn' then 1 else 2 end,
  c.check_name;

comment on view public.integrity_latest is
  '最後に実行した整合性チェックの結果。severityの重い順に並ぶ。';

-- ------------------------------------------------------------
-- 古い記録の掃除(90日より前は消す。日次×9チェックなので放置しても
-- 大きくはならないが、無限に増やす理由もない)
-- ------------------------------------------------------------
create or replace function public.prune_integrity_checks()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted int;
begin
  delete from public.integrity_checks where ran_at < now() - interval '90 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.prune_integrity_checks() from public;

-- ------------------------------------------------------------
-- cronに登録(pg_cronが使える環境のみ)
--   毎日 04:07 に実行。expire_coins(03:11)の後になるよう時刻をずらしている
--   (失効処理の直後に照合したいため)。
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('run-integrity-checks', '7 4 * * *', 'select public.run_integrity_checks()');
    perform cron.schedule('prune-integrity-checks', '37 4 * * 0', 'select public.prune_integrity_checks()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end;
$$;
-- ============================================================
-- 0044_ledger_immutable.sql
-- 取引台帳を追記専用にし、誤操作による破壊を防ぐ
-- ------------------------------------------------------------
-- 背景: 実務でDBが壊れる原因は、ハードウェア故障よりも運用中の人為ミスが
-- 圧倒的に多いです。Supabaseの管理画面から行を選んで消す、SQL Editorで
-- where を付け忘れた UPDATE を流す、といったものです。
-- RLSは効きません。管理画面もEdge Functionも service_role で動くため、
-- RLSを迂回できるからです。テーブル側で拒否する必要があります。
--
-- ただし「絶対に変更できない」のは運用として無理があります。いつか正当な
-- 訂正(誤った付与の取り消しなど)が必要になり、そのときトリガーごと外されて
-- 二度と戻らない、というのが最悪の結末です。
-- そこで「明示的に宣言すれば通るが、宣言は必ず記録される」形にします。
--
--   set local app.ledger_override = 'on';   -- 同一トランザクション内でのみ有効
--
-- これで防げるのは「うっかり」です。狙いはそこで十分で、意図的な操作は
-- ledger_audit に旧値ごと残るため、後から必ず追えます。
--
-- どこを守るか:
--   coin_transactions / coin_purchases … 変更も削除も禁止(純粋な履歴)
--   payouts                            … 削除禁止。金額・宛先の変更も禁止
--                                        (status/振込結果の更新は通常運用)
--   coin_lots                          … 削除禁止(remainingの更新は消費・失効で必要)
--   coin_lot_consumptions              … 削除禁止(restored_atの更新のみ許可)
--   bookings                           … 削除禁止(預かり中のコインが宙に浮く)
-- ============================================================

-- ------------------------------------------------------------
-- ledger_audit: 保護を明示的に解除して行った変更の記録
-- ------------------------------------------------------------
create table if not exists public.ledger_audit (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(),
  table_name text not null,
  op text not null check (op in ('UPDATE', 'DELETE')),
  actor uuid,
  old_row jsonb,
  new_row jsonb
);

comment on table public.ledger_audit is
  '追記専用の保護を app.ledger_override で解除して行った台帳の変更履歴。旧値を含むので、誤った訂正はここから復元できる。';

alter table public.ledger_audit enable row level security;

drop policy if exists "ledger_audit_select_admin" on public.ledger_audit;
create policy "ledger_audit_select_admin"
  on public.ledger_audit for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create index if not exists ledger_audit_at_idx on public.ledger_audit (at desc);

-- ------------------------------------------------------------
-- _ledger_override_on: 保護の解除が宣言されているか
-- ------------------------------------------------------------
create or replace function public._ledger_override_on()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('app.ledger_override', true), '') = 'on';
$$;

-- ------------------------------------------------------------
-- _ledger_record_bypass: 解除して行った操作を記録する
-- ------------------------------------------------------------
create or replace function public._ledger_record_bypass(
  p_table text, p_op text, p_old jsonb, p_new jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.ledger_audit (table_name, op, actor, old_row, new_row)
  values (p_table, p_op, auth.uid(), p_old, p_new);
$$;

-- ------------------------------------------------------------
-- _ledger_immutable: 変更も削除も禁止(coin_transactions / coin_purchases)
-- ------------------------------------------------------------
create or replace function public._ledger_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._ledger_override_on() then
    raise exception 'LEDGER_IMMUTABLE: % は追記専用です(% は禁止)。訂正が必要な場合は打ち消しの行を追加してください。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。',
      TG_TABLE_NAME, TG_OP;
  end if;

  perform public._ledger_record_bypass(
    TG_TABLE_NAME, TG_OP,
    to_jsonb(OLD),
    case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);

  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- _ledger_no_delete: 削除のみ禁止(coin_lots / bookings)
-- ------------------------------------------------------------
create or replace function public._ledger_no_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._ledger_override_on() then
    raise exception 'LEDGER_IMMUTABLE: % の行は削除できません。やむを得ない場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。',
      TG_TABLE_NAME;
  end if;

  perform public._ledger_record_bypass(TG_TABLE_NAME, 'DELETE', to_jsonb(OLD), null);
  return OLD;
end;
$$;

-- ------------------------------------------------------------
-- _payout_amount_immutable: 換金の金額・宛先の変更を禁止
--   status / stripe_transfer_id / failure_reason の更新は通常運用なので通す。
-- ------------------------------------------------------------
create or replace function public._payout_amount_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.user_id is distinct from NEW.user_id
     or OLD.coins is distinct from NEW.coins
     or OLD.amount_yen is distinct from NEW.amount_yen
     or OLD.created_at is distinct from NEW.created_at then
    if not public._ledger_override_on() then
      raise exception 'LEDGER_IMMUTABLE: 換金の金額・宛先は変更できません。取り消す場合は mark_payout_failed() で失敗にして戻してください。';
    end if;
    perform public._ledger_record_bypass('payouts', 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
  end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- _consumption_restore_only: 消費記録は restored_at の更新のみ許可
--   (0030の返金で「当初の有効期限」を引き継ぐための記録。ここが書き換わると
--    返金コインの期限が延び、資金決済法の適用除外の前提が崩れる)
-- ------------------------------------------------------------
create or replace function public._consumption_restore_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.user_id is distinct from NEW.user_id
     or OLD.booking_id is distinct from NEW.booking_id
     or OLD.kind is distinct from NEW.kind
     or OLD.expires_at is distinct from NEW.expires_at
     or OLD.coins is distinct from NEW.coins
     or OLD.created_at is distinct from NEW.created_at then
    if not public._ledger_override_on() then
      raise exception 'LEDGER_IMMUTABLE: coin_lot_consumptions は restored_at 以外を変更できません。';
    end if;
    perform public._ledger_record_bypass('coin_lot_consumptions', 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
  end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- トリガーの設置
-- ------------------------------------------------------------
drop trigger if exists coin_transactions_immutable on public.coin_transactions;
create trigger coin_transactions_immutable
  before update or delete on public.coin_transactions
  for each row execute function public._ledger_immutable();

drop trigger if exists coin_purchases_immutable on public.coin_purchases;
create trigger coin_purchases_immutable
  before update or delete on public.coin_purchases
  for each row execute function public._ledger_immutable();

drop trigger if exists payouts_no_delete on public.payouts;
create trigger payouts_no_delete
  before delete on public.payouts
  for each row execute function public._ledger_no_delete();

drop trigger if exists payouts_amount_immutable on public.payouts;
create trigger payouts_amount_immutable
  before update on public.payouts
  for each row execute function public._payout_amount_immutable();

drop trigger if exists coin_lots_no_delete on public.coin_lots;
create trigger coin_lots_no_delete
  before delete on public.coin_lots
  for each row execute function public._ledger_no_delete();

drop trigger if exists coin_lot_consumptions_no_delete on public.coin_lot_consumptions;
create trigger coin_lot_consumptions_no_delete
  before delete on public.coin_lot_consumptions
  for each row execute function public._ledger_no_delete();

drop trigger if exists coin_lot_consumptions_restore_only on public.coin_lot_consumptions;
create trigger coin_lot_consumptions_restore_only
  before update on public.coin_lot_consumptions
  for each row execute function public._consumption_restore_only();

drop trigger if exists bookings_no_delete on public.bookings;
create trigger bookings_no_delete
  before delete on public.bookings
  for each row execute function public._ledger_no_delete();

-- ------------------------------------------------------------
-- 補足: この時点で auth.users の削除は失敗するようになります。
-- 上記テーブルは全て auth.users に on delete cascade でぶら下がっているため、
-- ユーザーを物理削除しようとすると台帳の削除が走り、ここで止まります。
-- 「入金記録も換金記録も黙って消える」よりは、止まって気づけるほうが安全です。
-- 退会そのものは 0045 の匿名化で行います。
-- ------------------------------------------------------------
-- ============================================================
-- 0045_evidence_refund_percent.sql
-- 立証材料ビューの返還率が常に0%になる不具合を直す
-- ------------------------------------------------------------
-- 0040 で guest_cancellation_evidence を作り直したとき、返還率の算出に
-- b.status(=キャンセル**後**の状態)をそのまま渡していました。
-- booking_refund_percent() は「'confirmed' 以外は0」と判定するため、
-- キャンセル済みの行では必ず 0 が返っていました。
--
-- このビューは消費者契約法9条の「平均的な損害」を検討するための材料です。
-- 実際には全額戻していたケースまで「返還0%」と記録されるので、そのまま
-- 弁護士や当局に出すと事実と逆の説明をしてしまいます。
--
-- キャンセル直前の状態を confirmed_at の有無から復元して渡します。
-- あわせて、ゲスト都合以外(ピタメイト都合・辞退・無断欠席)は「率」の
-- 概念が違うので null にし、混ざらないようにします。
-- ============================================================

drop view if exists public.guest_cancellation_evidence;

create view public.guest_cancellation_evidence
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.status,
  b.policy_version,
  b.policy_agreed_at,
  b.created_at as requested_at,
  b.confirmed_at as approved_at,
  b.requested_start_at,
  b.scheduled_at as starts_at,
  b.cancelled_at,
  b.coins,
  b.list_coins,
  b.discount_percent,
  extract(epoch from (b.cancelled_at - b.confirmed_at))::int as seconds_after_approval,
  extract(epoch from (b.scheduled_at - b.cancelled_at))::int as seconds_before_start,
  -- キャンセル直前の状態を復元して率を出す。
  -- ゲスト都合のキャンセルだけが「段階制の返還率」の対象。
  case
    when b.status = 'cancelled_by_guest' then
      public.booking_refund_percent(
        case when b.confirmed_at is not null then 'confirmed' else 'requested' end,
        b.confirmed_at, b.scheduled_at, b.cancelled_at)
    else null
  end as refund_percent_at_cancel
from public.bookings b
where b.cancelled_at is not null;

comment on view public.guest_cancellation_evidence is
  'キャンセルの実態(承諾からの経過・開始までの残り・適用された返還率)。'
  '消費者契約法9条の「平均的な損害」を検討するための材料。0040で承諾時刻ベースに修正し、'
  '0045でキャンセル直前の状態から返還率を復元するよう修正(それ以前は常に0%と表示されていた)。';
-- ============================================================
-- 0046_account_anonymize.sql
-- 退会を「物理削除」から「匿名化」に変える
-- ------------------------------------------------------------
-- 【いま何が起きるか】
-- coin_wallets / coin_transactions / coin_lots / coin_purchases / payouts /
-- bookings は、すべて auth.users に on delete cascade でぶら下がっています。
-- つまり Supabase の管理画面からユーザーを1人消すと、その人の入金記録も
-- 換金記録も一緒に消えます。警告は出ません。「監査用」と書いた
-- coin_transactions ごと消えます。
--
-- そして account_requests(アカウント削除請求)は運営が手動で対応する設計なので、
-- 退会対応をした瞬間にこれを踏みます。事故ではなく通常運用で起きます。
--
-- 【なぜ消してはいけないか】
-- 消えるのは帳簿として保存義務のある記録です(所得税法上7年、資金決済法上の
-- 記録保持)。削除請求に応じる義務があるのは**個人情報**であって、取引金額の
-- 記録ではありません。プライバシーポリシー草案も
-- 「法令上の保存義務がある場合を除き削除」と書いており、実装と食い違っています。
--
-- 【この移行でやること】
--   ・氏名・連絡先・口座・画像など、その人を識別する情報は消す
--   ・金額と日時の記録は残す(誰のものかは user_id でのみ辿れる状態にする)
--   ・未処理の取引が残っているうちは実行できないようにする
--   ・残っている前払いコインは失効させ、履歴に1行残す(残高だけ0にすると
--     0043の照合が鳴るため)
--
-- なお 0044 の保護により、この関数を使わずユーザーを物理削除しようとすると
-- LEDGER_IMMUTABLE で止まります。黙って消えることはもうありません。
-- ============================================================

-- 退会時のコイン失効を履歴で区別できるようにする
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus',
    'booking_earned', 'payout', 'expire',
    'gift_sent', 'gift_received',
    'platform_fee', 'withdrawal'
  ));

-- 匿名化済みかどうかを画面側で判別できるようにする
alter table public.profiles
  add column if not exists anonymized_at timestamptz;

comment on column public.profiles.anonymized_at is
  '退会により匿名化した時刻。非nullの行は「退会したユーザー」として表示する。';

-- ------------------------------------------------------------
-- account_anonymizations: 匿名化の実施記録
--   誰の請求で・いつ・誰が実行したかを残す(個人情報保護法上の対応記録)
-- ------------------------------------------------------------
create table if not exists public.account_anonymizations (
  user_id uuid primary key references auth.users (id) on delete cascade,
  anonymized_at timestamptz not null default now(),
  actor uuid,
  reason text not null default 'user_request',
  forfeited_paid int not null default 0,
  forfeited_bonus int not null default 0
);

comment on table public.account_anonymizations is
  '退会(匿名化)の実施記録。個人情報の削除請求に対応したことの証跡。';

alter table public.account_anonymizations enable row level security;

drop policy if exists "account_anonymizations_select_admin" on public.account_anonymizations;
create policy "account_anonymizations_select_admin"
  on public.account_anonymizations for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

-- ------------------------------------------------------------
-- anonymize_user: 退会処理の本体(管理者のみ)
-- ------------------------------------------------------------
create or replace function public.anonymize_user(
  p_user_id uuid,
  p_reason text default 'user_request'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid int;
  v_bonus int;
  v_earned int;
  v_open_bookings int;
  v_pending_payouts int;
  v_has_deleted_at boolean;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_user_id is null then
    raise exception 'INVALID_USER';
  end if;
  if exists (select 1 from public.account_anonymizations where user_id = p_user_id) then
    raise exception 'ALREADY_ANONYMIZED';
  end if;

  -- ------------------------------------------------------------
  -- 未処理の取引が残っているうちは実行しない。
  -- 匿名化してから「振込先が分からない」「相手が誰か分からない」と
  -- なるのを防ぐ。先に決着をつけてから退会させる。
  -- ------------------------------------------------------------
  select count(*) into v_open_bookings from public.bookings
    where (guest_id = p_user_id or host_id = p_user_id)
      and status in ('requested', 'confirmed');
  if v_open_bookings > 0 then
    raise exception 'OPEN_BOOKINGS_REMAIN';
  end if;

  select count(*) into v_pending_payouts from public.payouts
    where user_id = p_user_id and status = 'pending';
  if v_pending_payouts > 0 then
    raise exception 'PENDING_PAYOUT_REMAINS';
  end if;

  select balance, bonus_balance, earned_balance
    into v_paid, v_bonus, v_earned
    from public.coin_wallets where user_id = p_user_id for update;

  -- 報酬は役務の対価(未払金)なので、勝手に消してはいけない。
  -- 換金するか、本人の意思で放棄してもらうまで退会させない。
  if coalesce(v_earned, 0) > 0 then
    raise exception 'EARNED_BALANCE_REMAINS';
  end if;

  -- ------------------------------------------------------------
  -- 残っている前払いコインを失効させる(規約:退会時の払戻しなし)。
  -- 残高だけ0にすると履歴と食い違い、0043の照合が鳴るので、
  -- ロット・残高・履歴の3点セットで落とす。
  -- ------------------------------------------------------------
  update public.coin_lots set remaining = 0
    where user_id = p_user_id and remaining > 0;

  if coalesce(v_paid, 0) + coalesce(v_bonus, 0) > 0 then
    update public.coin_wallets set balance = 0, bonus_balance = 0
      where user_id = p_user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, -(coalesce(v_paid, 0) + coalesce(v_bonus, 0)),
              'withdrawal', 'anonymize:' || p_reason);
  end if;

  -- ------------------------------------------------------------
  -- ここから個人を識別する情報を消す
  -- ------------------------------------------------------------
  update public.profiles set
    nickname = '退会したユーザー',
    gender = 'na',
    avatar_initial = '',
    avatar_color = '#CCCCCC',
    favorite_games = '{}',
    play_style = 'エンジョイ',
    bio = '',
    voice_path = null,
    voice_seconds = null,
    avatar_path = null,
    last_seen_at = null,
    -- presence_status に「退会」は無いので、少なくとも空き扱いにならない値にする
    -- (一覧からは anonymized_at と is_host=false で外れる)
    presence_status = 'busy',
    anonymized_at = now()
  where id = p_user_id;

  -- 掲載を止め、紹介文を消す
  update public.host_settings set
    is_host = false,
    games = '{}',
    bio = ''
  where user_id = p_user_id;

  -- 振込先口座は保存義務の対象ではない(金額はpayoutsに残る)
  delete from public.host_bank_accounts where user_id = p_user_id;

  -- 本人確認書類の参照を外す(実体はstorageから消す)
  update public.identity_verifications set
    document_path = null,
    selfie_path = null,
    provider_reference = null
  where user_id = p_user_id;

  delete from storage.objects
    where name like p_user_id::text || '/%'
       or owner = p_user_id;

  -- 端末・IPは不正検知用の識別子なので消す
  delete from public.user_devices where user_id = p_user_id;
  delete from public.user_ips where user_id = p_user_id;

  -- 通知・通知設定・安心設定は残す理由がない
  delete from public.notifications where user_id = p_user_id;
  delete from public.notification_prefs where user_id = p_user_id;
  delete from public.safety_prefs where user_id = p_user_id;

  -- 募集は取り下げ、自由記述を消す
  update public.board_posts set
    status = 'cancelled',
    note = null,
    cancelled_at = coalesce(cancelled_at, now()),
    cancel_reason = coalesce(cancel_reason, '投稿者の退会')
  where creator_id = p_user_id and status <> 'cancelled';

  -- 削除請求があれば完了にする
  update public.account_requests set status = 'completed'
    where user_id = p_user_id and type = 'account_deletion' and status <> 'completed';

  -- ------------------------------------------------------------
  -- 認証情報(メールアドレス)も消す。
  -- 本番の auth.users には deleted_at があるので論理削除にし、行そのものは
  -- 残す(消すと台帳が道連れになるため)。テスト用シムには無いので、
  -- 列の有無を見てから実行する。
  -- ------------------------------------------------------------
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users' and column_name = 'deleted_at'
  ) into v_has_deleted_at;

  if v_has_deleted_at then
    execute format(
      'update auth.users set email = %L, deleted_at = coalesce(deleted_at, now()) where id = %L',
      'anonymized+' || p_user_id::text || '@invalid.local', p_user_id);
  else
    execute format('update auth.users set email = %L where id = %L',
      'anonymized+' || p_user_id::text || '@invalid.local', p_user_id);
  end if;

  insert into public.account_anonymizations
    (user_id, actor, reason, forfeited_paid, forfeited_bonus)
    values (p_user_id, auth.uid(), p_reason, coalesce(v_paid, 0), coalesce(v_bonus, 0));
end;
$$;

comment on function public.anonymize_user(uuid, text) is
  '退会処理。個人を識別する情報を消し、金額と日時の記録は残す。'
  '未処理の予約・換金・報酬残高があるときは実行できない。管理者のみ。';

revoke all on function public.anonymize_user(uuid, text) from public;
grant execute on function public.anonymize_user(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- pending_account_deletions: 退会請求の一覧(運営用)
--   実行できない理由(未処理の取引)も一緒に出す
-- ------------------------------------------------------------
create or replace view public.pending_account_deletions
with (security_invoker = true) as
select
  r.user_id,
  r.created_at as requested_at,
  p.nickname,
  (select count(*) from public.bookings b
    where (b.guest_id = r.user_id or b.host_id = r.user_id)
      and b.status in ('requested', 'confirmed')) as open_bookings,
  (select count(*) from public.payouts po
    where po.user_id = r.user_id and po.status = 'pending') as pending_payouts,
  coalesce(w.earned_balance, 0) as earned_balance,
  coalesce(w.balance, 0) + coalesce(w.bonus_balance, 0) as prepaid_balance
from public.account_requests r
join public.profiles p on p.id = r.user_id
left join public.coin_wallets w on w.user_id = r.user_id
where r.type = 'account_deletion' and r.status <> 'completed'
order by r.created_at;

comment on view public.pending_account_deletions is
  '未対応の退会請求。open_bookings/pending_payouts/earned_balance が全て0でないと anonymize_user() は実行できない。';
-- ============================================================
-- 0047_ledger_export_heartbeat.sql
-- 外部へのエクスポートが止まったことを検知する
-- ------------------------------------------------------------
-- `workers/ledger-export` が Cloudflare R2 へ取引データを写し取る。
-- ただし**止まったことに気づけないバックアップは無いのと同じ**なので、
-- 実行結果をここに書き戻させ、途絶えたら整合性チェックで鳴らす。
--
-- あわせて integrity_latest の定義を直す。これまでは
--   ran_at = (select max(ran_at) from integrity_checks)
-- で「最後の実行」の行だけを出していたが、これだと
--   ・実行の周期が違うチェックを足せない
--   ・あるチェックだけ落ちて行が書かれなかったとき、静かに消える
-- という問題がある。チェック名ごとの最新を出す形に変える。
-- ============================================================

-- ------------------------------------------------------------
-- ledger_exports: エクスポートの実行記録(Workerがservice_roleで書く)
-- ------------------------------------------------------------
create table if not exists public.ledger_exports (
  id uuid primary key default gen_random_uuid(),
  ran_at timestamptz not null default now(),
  kind text not null check (kind in ('incremental', 'snapshot')),
  ok boolean not null default true,
  row_count int not null default 0,
  detail jsonb not null default '{}'::jsonb,
  error text
);

comment on table public.ledger_exports is
  'R2への取引データ書き出しの実行記録。途絶えると整合性チェックの ledger_export_freshness が鳴る。';

alter table public.ledger_exports enable row level security;

-- 閲覧は管理者のみ。書き込みポリシーは作らない(Workerのservice_roleのみ)。
drop policy if exists "ledger_exports_select_admin" on public.ledger_exports;
create policy "ledger_exports_select_admin"
  on public.ledger_exports for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

create index if not exists ledger_exports_recent_idx
  on public.ledger_exports (kind, ran_at desc) where ok;

-- ------------------------------------------------------------
-- integrity_latest: チェック名ごとの最新を出す
-- ------------------------------------------------------------
drop view if exists public.integrity_latest;

create view public.integrity_latest
with (security_invoker = true) as
select *
from (
  select distinct on (check_name) *
  from public.integrity_checks
  order by check_name, ran_at desc
) t
order by
  case severity when 'error' then 0 when 'warn' then 1 else 2 end,
  check_name;

comment on view public.integrity_latest is
  '各チェックの最新の結果。severityの重い順に並ぶ。実行周期の違うチェックが混ざっても正しく出る。';

-- ------------------------------------------------------------
-- check_ledger_export: エクスポートの鮮度を見る
--   差分は毎時、全量は毎日の想定。取りこぼしを許す幅を持たせている。
--   結果は integrity_checks に同じ形で積むので、運用の見方は変わらない。
-- ------------------------------------------------------------
create or replace function public.check_ledger_export()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inc timestamptz;
  v_snap timestamptz;
  v_inc_age numeric;
  v_snap_age numeric;
  v_severity text;
  v_failures int;
begin
  if auth.uid() is not null
     and not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select max(ran_at) into v_inc from public.ledger_exports
    where kind = 'incremental' and ok;
  select max(ran_at) into v_snap from public.ledger_exports
    where kind = 'snapshot' and ok;

  v_inc_age := extract(epoch from (now() - v_inc)) / 3600.0;
  v_snap_age := extract(epoch from (now() - v_snap)) / 3600.0;

  -- 直近24時間の失敗回数(成功していても、失敗が続いているなら知りたい)
  select count(*) into v_failures from public.ledger_exports
    where not ok and ran_at > now() - interval '24 hours';

  -- 毎時実行なので3時間(2回分の取りこぼし)まで許す。
  -- 全量は毎日なので26時間まで許す。
  v_severity := case
    when v_inc is null or v_snap is null then 'error'
    when v_inc_age > 3 or v_snap_age > 26 then 'error'
    when v_failures > 0 then 'warn'
    else 'ok'
  end;

  insert into public.integrity_checks
    (check_name, severity, affected_count, total_gap, detail)
  values (
    'ledger_export_freshness',
    v_severity,
    v_failures,
    coalesce(round(greatest(coalesce(v_inc_age, 999), 0))::bigint, 999),
    jsonb_build_object(
      'last_incremental', v_inc,
      'last_snapshot', v_snap,
      'incremental_age_hours', round(coalesce(v_inc_age, 0), 1),
      'snapshot_age_hours', round(coalesce(v_snap_age, 0), 1),
      'failures_24h', v_failures,
      'note', 'R2への書き出しが止まっていないか。止まったバックアップは無いのと同じ。'
    ));

  if v_severity = 'error' then
    insert into public.notifications (user_id, type, title, body)
    select a.user_id, 'integrity_alert',
           '取引データの外部バックアップが止まっています',
           coalesce(
             '最後の書き出しは差分=' || coalesce(v_inc::text, 'なし') ||
             ' / 全量=' || coalesce(v_snap::text, 'なし') || ' です。',
             'まだ一度も実行されていません。')
    from public.admins a;
    return 1;
  end if;

  return 0;
end;
$$;

comment on function public.check_ledger_export() is
  'R2へのエクスポートが止まっていないかを確認し、integrity_checks に記録する。errorなら管理者に通知。';

revoke all on function public.check_ledger_export() from public;
grant execute on function public.check_ledger_export() to authenticated;

-- ------------------------------------------------------------
-- 古い実行記録の掃除(90日)。integrity_checks と同じ扱い。
-- ------------------------------------------------------------
create or replace function public.prune_ledger_exports()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_deleted int;
begin
  delete from public.ledger_exports where ran_at < now() - interval '90 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.prune_ledger_exports() from public;

-- ------------------------------------------------------------
-- cronに登録。整合性チェック(04:07)の直後に見る。
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('check-ledger-export', '17 4 * * *', 'select public.check_ledger_export()');
    perform cron.schedule('prune-ledger-exports', '47 4 * * 0', 'select public.prune_ledger_exports()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end;
$$;
-- ============================================================
-- 0048_longer_play_12h.sql
-- あそぶ時間を最長12時間にする
-- ------------------------------------------------------------
-- 上限を 240分 → 720分 に上げるだけでは、次の3つが壊れます。
--
-- ① 遊んでいる最中に自動確定される
--    auto_complete_bookings は scheduled_at(=開始時刻) + 72時間 を基準に
--    していました。4時間なら終了後68時間の猶予がありますが、長時間化すると
--    縮みます。さらに extend_booking には**総時間の上限が無い**ため、
--    延長を重ねると開始+72時間を追い越し、**プレイ中に報酬が確定**します。
--    → 基準を「終了時刻 + 72時間」に変え、延長にも上限を入れます。
--
-- ② キャンセル時の没収額が消費者契約法9条に触れる
--    時給2,000円×12時間 = 24,000コイン。開始直前キャンセルで50%没収なら
--    12,000円です。「平均的な損害」としてこの額を説明するのは困難です。
--
--    「平均的な損害」の実質は**その枠で他の客を取れなかった機会損失**です。
--    12時間予約する客が別にいる確率は低いので、損害を予約時間に比例させるのは
--    実態に合いません。差し押さえられる時間はせいぜい2〜3時間分、と整理して
--    **没収額に上限**を設けます。
--
--      没収額 = min(従来の計算, 経過時間分 + 上限(既定3時間分))
--
--    経過時間分を足しているのは、開始後のキャンセルでは**既に提供された役務の
--    対価**は当然ピタメイトのものだからです。これを入れないと、12時間予約の
--    11時間目にキャンセルされたピタメイトが3時間分しか受け取れません。
--
--    この式は**4時間以下の予約の挙動をほぼ変えません**(4時間予約の開始直前
--    キャンセルは50%=2時間分で、上限3時間分に届かない)。長時間予約だけが
--    頭打ちになります。唯一変わるのは「開始直後のキャンセル」で、従来の全額
--    没収から「経過分+3時間分」に緩みます。これはゲストに有利な方向であり、
--    9条のリスクを下げるので、弁護士査読前に入れても問題は増えません。
--
-- ③ 予約時間の刻みが細かすぎて選べない
--    30分刻みのままだと720分で24択。4時間を超えたら1時間刻みにして16択に
--    します。サーバ側も同じ規則で検査します(画面とサーバがずれると、
--    選べるのに申込時に INVALID_DURATION で弾かれる)。
--
-- なお**予約時間帯の重複チェックは、いまも入っていません**。12時間予約は
-- 1日の枠を大きく占めるため早めに必要ですが、「必ず壊れる」ものではないので
-- 別の課題として open-issues.md に切り出しています。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 上限と刻みのパラメータ
-- ------------------------------------------------------------
-- 0041 の制約は上限600分だった。12時間(720分)を許すため引き上げる。
alter table public.platform_pricing
  drop constraint if exists platform_pricing_max_duration_check;
alter table public.platform_pricing
  add constraint platform_pricing_max_duration_check
  check (max_duration_minutes between 30 and 1440 and max_duration_minutes % 30 = 0);

update public.platform_pricing set max_duration_minutes = 720 where id = 1;

-- bookings 側の上限も 0035 で 600分に固定されていた。
-- ここは「延長も含めた最終的な長さ」なので、上限と揃える。
alter table public.bookings drop constraint if exists bookings_duration_minutes_check;
alter table public.bookings
  add constraint bookings_duration_minutes_check
  check (duration_minutes >= 30 and duration_minutes <= 1440);

alter table public.platform_pricing
  add column if not exists duration_fine_step_minutes int not null default 30,
  add column if not exists duration_coarse_step_minutes int not null default 60,
  -- 細かい刻みを使う上限。ここを超えたら粗い刻みになる
  add column if not exists duration_fine_until_minutes int not null default 240,
  -- キャンセルで没収できる上限(ピタメイトの時間換算)。機会損失の見積り
  add column if not exists cancel_forfeit_cap_minutes int not null default 180;

comment on column public.platform_pricing.cancel_forfeit_cap_minutes is
  'キャンセル時に没収できる上限を「予約の何分ぶんの対価か」で表す。消費者契約法9条の平均的な損害に寄せるための頭打ち。既定180分(3時間)。';

-- ------------------------------------------------------------
-- 2. 予約時間の妥当性。画面とサーバで同じ規則を使うため関数に切り出す
-- ------------------------------------------------------------
create or replace function public.is_valid_booking_duration(p_minutes int)
returns boolean
language sql
stable
set search_path = public
as $$
  select case
    when p_minutes is null then false
    else exists (
      select 1 from public.platform_pricing p
      where p.id = 1
        and p_minutes >= p.duration_fine_step_minutes
        and p_minutes <= p.max_duration_minutes
        and case
              when p_minutes <= p.duration_fine_until_minutes
                then p_minutes % p.duration_fine_step_minutes = 0
              else p_minutes % p.duration_coarse_step_minutes = 0
            end
    )
  end;
$$;

comment on function public.is_valid_booking_duration(int) is
  'あそぶ時間として受け付ける値か。4時間までは30分刻み、それ以降は1時間刻み(既定)。';

-- ------------------------------------------------------------
-- 3. create_booking: 刻みの判定を関数に委ねる
--    (0041版から、時間の検査部分だけを差し替える)
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

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
$$;

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 4. extend_booking: 合計時間に上限を入れる
--    これが無いと、延長を重ねて自動確定の72時間を追い越せてしまう。
-- ------------------------------------------------------------
create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_max int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
  values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

revoke all on function public.extend_booking(uuid, int) from public;
grant execute on function public.extend_booking(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 5. 返還額の計算。率だけでなく「没収の上限」を効かせる
--    率(booking_refund_percent)はそのまま残し、額の算出をここに集約する。
-- ------------------------------------------------------------
create or replace function public.booking_refund_coins(
  p_coins int,
  p_duration_minutes int,
  p_percent int,
  p_scheduled_at timestamptz,
  p_at timestamptz default now()
)
returns int
language sql
stable
set search_path = public
as $$
  with p as (select cancel_forfeit_cap_minutes as cap from public.platform_pricing where id = 1),
  calc as (
    select
      -- 1分あたりの対価。割引後の実額(coins)を基準にする
      p_coins::numeric / greatest(p_duration_minutes, 1) as per_min,
      -- 開始からの経過(分)。開始前は0
      greatest(0, extract(epoch from (p_at - p_scheduled_at)) / 60.0) as elapsed_min,
      (select cap from p) as cap_min
  )
  select greatest(0, least(
    p_coins,
    -- 返還額 = 予約額 − 没収額
    p_coins - least(
      -- 従来の計算(率による没収)
      p_coins - round(p_coins * p_percent / 100.0),
      -- 上限: 提供済みの分 + 機会損失の上限
      round(least(calc.per_min * calc.elapsed_min, p_coins::numeric))
        + round(calc.per_min * calc.cap_min)
    )
  ))::int
  from calc;
$$;

comment on function public.booking_refund_coins(int, int, int, timestamptz, timestamptz) is
  'キャンセル時に実際に返すコイン数。率による没収に「提供済み分+機会損失の上限」の頭打ちをかける。'
  '消費者契約法9条の平均的な損害に寄せるための調整で、4時間以下の予約ではほぼ従来どおり。';

-- 画面表示用。いまキャンセルしたら実際に何コイン戻るかを返す。
-- 率だけでは上限が反映されないため、フロントでの掛け算をやめてこちらを使う。
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
    'capped', v_refund > round(v_b.coins * v_pct / 100.0)
  );
end;
$$;

revoke all on function public.my_booking_refund_quote(uuid) from public;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. cancel_booking: 返還額の算出を booking_refund_coins に委ねる
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
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then raise exception 'BOOKING_NOT_FOUND'; end if;
  if v_uid not in (v_booking.guest_id, v_booking.host_id) then raise exception 'FORBIDDEN'; end if;

  -- 承諾前の取り消しは、どちらからでも全額返還(従来どおり)
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
    perform public._refund_coin_lots_for_booking(p_booking_id, v_refund_paid, v_refund_bonus);
    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.guest_id, v_refund_total, 'refund', p_booking_id, 'cancel_booking');
  else
    -- 一部も戻らない場合でも、消費記録は閉じておく(期限管理のため)
    perform public._refund_coin_lots_for_booking(p_booking_id, 0, 0);
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
-- 7. 自動確定を「終了時刻 + 72時間」に変える
--    開始基準のままだと、長時間予約や延長でプレイ中に確定してしまう。
-- ------------------------------------------------------------
create or replace function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select id, host_id, coins
    from public.bookings
    where status = 'confirmed'
      and held_at is null
      and scheduled_at + make_interval(mins => duration_minutes) + interval '72 hours' < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  'ゲストが完了操作をしないまま終了から72時間が過ぎた予約を自動確定する。'
  '保留中(held_at)のものは対象外(E-12)。0048で基準を開始時刻から終了時刻に変更。';

revoke all on function public.auto_complete_bookings() from public;

-- ------------------------------------------------------------
-- 8. 通報による保留の対象範囲も終了時刻ベースに揃える
--    (自動確定の窓と一致していないと、確定済みのものを保留しようとしたり
--     まだ確定していないものを取りこぼしたりする)
-- ------------------------------------------------------------
create or replace function public._hold_bookings_on_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
begin
  for v_b in
    select b.id
    from public.bookings b
    where b.status = 'confirmed'
      and b.held_at is null
      and (
        (b.guest_id = NEW.reporter_id and b.host_id = NEW.reported_id) or
        (b.host_id = NEW.reporter_id and b.guest_id = NEW.reported_id)
      )
      and b.scheduled_at + make_interval(mins => b.duration_minutes) + interval '72 hours' >= now()
  loop
    perform public._hold_booking(v_b.id, 'report');
  end loop;
  return NEW;
end;
$$;

drop trigger if exists reports_hold_bookings on public.reports;
create trigger reports_hold_bookings
  after insert on public.reports
  for each row execute function public._hold_bookings_on_report();
-- ============================================================
-- 0049_booking_slot_conflict.sql
-- 上限を10時間にし、予約時間帯の重複を防ぐ(E-13)
-- ------------------------------------------------------------
-- `create_booking` には**予約の時間帯が他の予約と重なっていないかの検査が
-- ありませんでした**。最長4時間のうちは衝突が稀で表面化しませんでしたが、
-- 長時間の予約は1件で1日の枠の大半を占めます。同じピタメイトに同じ時間帯の
-- 予約が2件入ると、どちらかは必ず反故になります。ゲスト側も同じです。
--
-- 【どの予約が枠を占めるか】
--   status が 'requested' か 'confirmed' のもの。
--   開始時刻は coalesce(requested_start_at, scheduled_at) で見ます。
--   「今すぐ」の申し込みは requested_start_at が null で、この場合
--   scheduled_at は作成時刻(既定値)なので、実質「申し込んだ時点から
--   duration 分」を押さえていることになります。承諾で正式な開始時刻に
--   置き換わります。
--
-- 【同時申し込みへの対処】
--   検査してから INSERT するまでの間に他のトランザクションが割り込むと、
--   両方とも検査を通ってしまいます(TOCTOU)。当事者2人の user_id で
--   トランザクション内アドバイザリロックを取り、同じ人が絡む予約作成を
--   直列化します。デッドロックを避けるため、必ず**同じ順序**で取ります。
--
-- 【承諾時にも検査が要る理由】
--   「今すぐ」や希望時刻つきのリクエストは、承諾されるまで枠が確定しません。
--   リクエスト中に別の予約が確定していると、承諾した瞬間に重なります。
--   approve_booking でも同じ検査をします。
--
-- 【延長時にも検査が要る理由】
--   延長は終了時刻を後ろにずらすので、次の予約に食い込みます。
--
-- 【どの状態を「ふさがっている」と見るかは、場面で変える】
--   ・新規の申し込み … 申請中 + 成立済み
--       先に申し込んだ人の枠を守る。コインは申込時点で確保されているので、
--       申請中でも「押さえた」と扱うのが筋。
--   ・承諾 / 延長  … 成立済みのみ
--       申請中まで見ると、同じ枠に2件のリクエストが並んだときに
--       **どちらも承諾できなくなります**。申請は希望であって確約ではないので、
--       承諾の可否を縛るべきではありません。先に1件を承諾すれば、もう1件は
--       承諾の時点で弾かれ、全額返還されます。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 上限を10時間(600分)にする
-- ------------------------------------------------------------
update public.platform_pricing set max_duration_minutes = 600 where id = 1;

-- ------------------------------------------------------------
-- 2. 予約が占める時間帯
--    ビューにしておくと、検査・一覧・デバッグで同じ定義を使い回せる。
-- ------------------------------------------------------------
create or replace view public.booking_slots
with (security_invoker = true) as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.status,
  coalesce(b.requested_start_at, b.scheduled_at) as starts_at,
  coalesce(b.requested_start_at, b.scheduled_at)
    + make_interval(mins => b.duration_minutes) as ends_at
from public.bookings b
where b.status in ('requested', 'confirmed');

comment on view public.booking_slots is
  '枠を占めている予約(申請中・成立済み)の時間帯。重複検査と空き状況の表示で使う。';

-- ------------------------------------------------------------
-- 3. 重複の検査。ぶつかった予約のidを返す(無ければ null)
-- ------------------------------------------------------------
create or replace function public._booking_slot_conflict(
  p_user_id uuid,
  p_start timestamptz,
  p_minutes int,
  p_exclude_booking_id uuid default null,
  p_statuses text[] default array['requested', 'confirmed']
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select b.id
  from public.bookings b
  where b.status = any (p_statuses)
    and (b.guest_id = p_user_id or b.host_id = p_user_id)
    and (p_exclude_booking_id is null or b.id <> p_exclude_booking_id)
    and tstzrange(
          coalesce(b.requested_start_at, b.scheduled_at),
          coalesce(b.requested_start_at, b.scheduled_at)
            + make_interval(mins => b.duration_minutes),
          '[)')
        && tstzrange(p_start, p_start + make_interval(mins => p_minutes), '[)')
  limit 1;
$$;

comment on function public._booking_slot_conflict(uuid, timestamptz, int, uuid, text[]) is
  '指定の時間帯に、その人の予約が既に入っているかを調べる。'
  '見る状態は呼び出し側が選ぶ(新規申込は申請中も含め、承諾・延長は成立済みのみ)。';

-- ------------------------------------------------------------
-- 4. 当事者2人ぶんのロック。順序を固定してデッドロックを避ける
-- ------------------------------------------------------------
create or replace function public._lock_booking_slots(p_a uuid, p_b uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_first uuid;
  v_second uuid;
begin
  -- uuid の大小で順序を決める。どのトランザクションでも同じ順で取れば
  -- 相互待ちにならない。
  if p_a <= p_b then
    v_first := p_a; v_second := p_b;
  else
    v_first := p_b; v_second := p_a;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_first::text, 0));
  if v_second is distinct from v_first then
    perform pg_advisory_xact_lock(hashtextextended(v_second::text, 0));
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 5. 空き状況の照会(画面用)
--    ピタメイトの埋まっている時間帯と、自分の予約で埋まっている時間帯を返す。
--    どちらも新しい予約を弾く要因なので、まとめて返して画面で灰色にする。
--    他人の予約の中身(相手が誰か・何コインか)は返さない。
-- ------------------------------------------------------------
create or replace function public.booking_busy_slots(
  p_host_id uuid,
  p_days int default 14
)
returns table (starts_at timestamptz, ends_at timestamptz, who text)
language sql
stable
security definer
set search_path = public
as $$
  select s.starts_at, s.ends_at,
         case when s.guest_id = auth.uid() or s.host_id = auth.uid()
              then 'me' else 'host' end as who
  from public.booking_slots s
  where (s.host_id = p_host_id or s.guest_id = p_host_id
         or s.guest_id = auth.uid() or s.host_id = auth.uid())
    and s.ends_at > now()
    and s.starts_at < now() + make_interval(days => greatest(p_days, 1))
  order by s.starts_at;
$$;

comment on function public.booking_busy_slots(uuid, int) is
  'そのピタメイトと自分の、埋まっている時間帯。予約画面で選べない時刻を示すために使う。相手が誰か等は返さない。';

revoke all on function public.booking_busy_slots(uuid, int) from public;
grant execute on function public.booking_busy_slots(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 6. create_booking: 重複検査を入れる
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

  -- 枠の検査。ロックを取ってから調べる(同時申し込みで両方通るのを防ぐ)
  v_start := coalesce(p_scheduled_at, now());
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

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

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
$$;

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 7. approve_booking: 承諾の瞬間にも重複を検査する
--    リクエスト中に別の予約が確定していると、承諾した瞬間に重なるため。
-- ------------------------------------------------------------
create or replace function public.approve_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
  v_start timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 指定があればその時刻、無ければ従来どおり承諾時点が開始時刻。
  -- 承諾時刻は別に持つ(キャンセル猶予の起点になるため。0040以前は
  -- scheduled_at が承諾時刻を兼ねていた)。
  v_start := coalesce(v_booking.requested_start_at, now());

  -- ここで見るのは**成立済み(confirmed)だけ**。
  -- 申請中の予約まで見ると、同じ枠に2件のリクエストが並んだときに
  -- ピタメイトが**どちらも承諾できなくなります**。申請は「希望」であって
  -- 確約ではないので、承諾の可否を縛るべきではありません。
  -- (先に1件を承諾すれば、もう1件はここで弾かれて全額返還されます。)
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_start, v_booking.duration_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(
       v_booking.guest_id, v_start, v_booking.duration_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  update public.bookings
    set status = 'confirmed', scheduled_at = v_start, confirmed_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ピタメイト') || 'さんが予約を承諾しました',
    case when v_booking.requested_start_at is null
         then 'トークが始まりました。プレイの準備をしましょう'
         else to_char(v_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜 で成立しました' end,
    v_promise_id
  );

  return v_promise_id;
end;
$$;

revoke all on function public.approve_booking(uuid) from public;
grant execute on function public.approve_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. extend_booking: 延長で次の予約に食い込まないようにする
-- ------------------------------------------------------------
create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_max int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
  end if;

  -- 延長は終了時刻を後ろにずらすので、次の予約に食い込まないか確かめる。
  -- ここも成立済みだけを見る。まだ承諾されていない後続のリクエストのために
  -- 進行中のプレイの延長を止めるのは、優先順位が逆。
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(
       v_booking.guest_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  v_from_paid := least(v_paid, v_add_coins);
  v_from_bonus := v_add_coins - v_from_paid;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
  values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

revoke all on function public.extend_booking(uuid, int) from public;
grant execute on function public.extend_booking(uuid, int) to authenticated;

-- 検査を効かせるための索引(開始時刻で絞ってから範囲を見る)
create index if not exists bookings_slot_idx
  on public.bookings (host_id, scheduled_at)
  where status in ('requested', 'confirmed');
create index if not exists bookings_slot_guest_idx
  on public.bookings (guest_id, scheduled_at)
  where status in ('requested', 'confirmed');
-- ============================================================
-- 0050_no_show_auto.sql
-- 無断欠席を、運営の判断なしに自動で解決する
-- ------------------------------------------------------------
-- 【解きたい問題】
-- 相手が来なかったゲストが取れる自己解決の手段が「キャンセル」しかなく、
-- それは**ゲスト都合**として処理されます。相手が来なかったのにゲストが
-- 没収されるのは筋が通りません。正しい行き先は通報ですが、「通報」という
-- 言葉は心理的に重く、面倒がって黙って去る人が出ます(E-12で見送った論点)。
--
-- 【運営が判断しない設計にする】
-- 「相手が来たか」は運営には観測できません。Discordに移って遊ぶことが普通に
-- あるので、チャットの沈黙は不在の証拠になりません(0042で自動保留を見送った
-- 理由)。そこで**運営が観測しようとせず、当事者の不作為で決まる**形にします。
--
--   開始時刻を過ぎると、両者に「はじめました」ボタン
--     ※ ピタメイトがメッセージを1通でも送れば自動でチェックイン扱い
--   開始+15分: ゲストのみチェックイン済みなら → 自動で保留(お金が止まる)
--   保留中にピタメイトがチェックイン → 自動で保留解除。通常フローへ
--   保留から24時間、一度も反応なし → 自動で no_show_host。全額返還
--
-- 【なぜ成立するか】
--   ・ゲストは嘘をつけない。結果を決めるのはゲストのボタンではなく、
--     **ピタメイトの不作為**。ピタメイトが一言でも喋れば無効になる。
--   ・ピタメイトも不当に損をしない。15分後に通知が飛び、24時間の猶予があり、
--     ボタンでもメッセージでも救われる。自分の行動で結果を完全に決められる。
--   ・押した瞬間に全額返還にはしない。それでは「無料キャンセルの抜け道」に
--     なる。押して起きるのは**お金を止めること**だけ。
--
-- なお no_show_host / no_show_guest は 0017 で宣言されて以来、**どのRPCも
-- セットしていない死んだ状態**でした。ここで初めて実際に使われます。
-- ============================================================

-- ------------------------------------------------------------
-- 1. チェックインの記録とパラメータ
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists guest_checked_in_at timestamptz,
  add column if not exists host_checked_in_at timestamptz;

comment on column public.bookings.guest_checked_in_at is
  'ゲストが「はじめました」を押した時刻。無断欠席の自動判定に使う。';
comment on column public.bookings.host_checked_in_at is
  'ピタメイトが「はじめました」を押した(またはメッセージを送った)時刻。';

alter table public.platform_pricing
  -- 開始からこの時間を過ぎてもピタメイトが現れなければ保留する
  add column if not exists checkin_grace_minutes int not null default 15,
  -- 保留してからこの時間、ピタメイトが一度も反応しなければ無断欠席で確定する
  add column if not exists no_show_resolve_hours int not null default 24;

comment on column public.platform_pricing.checkin_grace_minutes is
  '開始からこの分数を過ぎてもピタメイトのチェックインが無ければ自動で保留する。既定15分。';
comment on column public.platform_pricing.no_show_resolve_hours is
  '無断欠席で保留してから、ピタメイトの反応が無いまま自動確定するまでの時間。既定24時間。';

-- 保留の理由に無断欠席を追加
alter table public.bookings drop constraint if exists bookings_hold_reason_check;
alter table public.bookings
  add constraint bookings_hold_reason_check
  check (hold_reason is null or hold_reason in ('claim', 'report', 'manual', 'no_show'));

-- 通知の種類に無断欠席まわりを追加
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled',
    'integrity_alert', 'booking_no_show'
  ));

create index if not exists bookings_no_show_watch_idx
  on public.bookings (scheduled_at)
  where status = 'confirmed' and host_checked_in_at is null;

-- ------------------------------------------------------------
-- 2. チェックイン
--    どちらの当事者も押せる。冪等(2回押しても最初の時刻を保つ)。
--    ピタメイトのチェックインは、無断欠席の保留を自動的に解除する。
-- ------------------------------------------------------------
create or replace function public.check_in_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_b public.bookings;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_b.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_ACTIVE';
  end if;
  -- 開始前に押せてしまうと「押したのに来ない」が起きるので、開始後だけ。
  if now() < v_b.scheduled_at then
    raise exception 'NOT_STARTED_YET';
  end if;

  if v_uid = v_b.guest_id then
    update public.bookings
      set guest_checked_in_at = coalesce(guest_checked_in_at, now())
      where id = p_booking_id;
    return;
  end if;

  update public.bookings
    set host_checked_in_at = coalesce(host_checked_in_at, now())
    where id = p_booking_id;

  -- 無断欠席で保留していたなら、本人が現れたので自動で解く。
  -- ここに運営の判断は要らない。
  if v_b.held_at is not null and v_b.hold_reason = 'no_show' then
    update public.bookings set held_at = null, hold_reason = null
      where id = p_booking_id;

    select nickname into v_name from public.profiles where id = v_b.host_id;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.guest_id, 'booking_no_show',
      coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが参加しました',
      '一時停止していたコインの確定を再開しました。', p_booking_id);
  end if;
end;
$$;

comment on function public.check_in_booking(uuid) is
  'プレイの開始を記録する。ピタメイトのチェックインは無断欠席の保留を自動解除する。';

revoke all on function public.check_in_booking(uuid) from public;
grant execute on function public.check_in_booking(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. メッセージを送ったら自動でチェックイン扱いにする
--    「ボタンを押し忘れただけ」で無断欠席にされるのを防ぐ最大の安全弁。
--    実際に参加している人は、まず何か喋る。
-- ------------------------------------------------------------
create or replace function public._checkin_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  select b.* into v_b
  from public.bookings b
  join public.promises p on p.booking_id = b.id
  where p.id = NEW.promise_id and b.status = 'confirmed' and now() >= b.scheduled_at
  for update;

  if v_b.id is null then
    return NEW;
  end if;

  if NEW.sender_id = v_b.guest_id then
    update public.bookings
      set guest_checked_in_at = coalesce(guest_checked_in_at, now())
      where id = v_b.id;
  elsif NEW.sender_id = v_b.host_id then
    update public.bookings
      set host_checked_in_at = coalesce(host_checked_in_at, now())
      where id = v_b.id;
    -- 保留中なら解除(check_in_booking と同じ扱い)
    if v_b.held_at is not null and v_b.hold_reason = 'no_show' then
      update public.bookings set held_at = null, hold_reason = null where id = v_b.id;
      insert into public.notifications (user_id, type, title, body, related_id)
      values (v_b.guest_id, 'booking_no_show',
        'ピタメイトさんが参加しました',
        '一時停止していたコインの確定を再開しました。', v_b.id);
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists messages_checkin on public.messages;
create trigger messages_checkin
  after insert on public.messages
  for each row execute function public._checkin_on_message();

-- ------------------------------------------------------------
-- 4. 開始+猶予でピタメイト未チェックインなら自動で保留する
--    お金を止めるだけ。ここでは何も確定させない。
-- ------------------------------------------------------------
create or replace function public.auto_hold_no_show_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b record;
  v_grace int;
  v_count int := 0;
begin
  select checkin_grace_minutes into v_grace from public.platform_pricing where id = 1;

  for v_b in
    select id, guest_id, host_id
    from public.bookings
    where status = 'confirmed'
      and held_at is null
      -- ゲストは来ている(自分で申告した)が、ピタメイトの気配がない
      and guest_checked_in_at is not null
      and host_checked_in_at is null
      and now() >= scheduled_at + make_interval(mins => v_grace)
    for update skip locked
  loop
    update public.bookings
      set held_at = now(), hold_reason = 'no_show'
      where id = v_b.id;

    -- ピタメイトには「まだ間に合う」ことを伝える。ここが救済の要。
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.host_id, 'booking_no_show',
      'プレイの開始が確認できていません',
      'トークで「はじめました」を押すか、メッセージを送ってください。'
        || 'このまま反応が無いと、無断欠席としてコインがゲストへ返還されます。',
      v_b.id);

    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_b.guest_id, 'booking_no_show',
      'コインの確定を一時停止しました',
      '相手の参加が確認できていないため、コインが相手に渡らないよう止めました。'
        || '相手が参加すれば自動で再開します。',
      v_b.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.auto_hold_no_show_bookings() is
  'ゲストだけがチェックインした予約を、開始+猶予で自動的に保留する。お金を止めるだけで確定はしない。';

revoke all on function public.auto_hold_no_show_bookings() from public;

-- ------------------------------------------------------------
-- 5. 保留から一定時間、ピタメイトの反応が無ければ無断欠席で確定する
--    全額返還し、ドタキャン記録を付ける。運営の判断は入らない。
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
    perform public._refund_coin_lots_for_booking(v_b.id);
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

comment on function public.auto_resolve_no_show_bookings() is
  '無断欠席で保留した予約を、一定時間の無反応をもって自動的に確定し全額返還する。運営の判断を要しない。';

revoke all on function public.auto_resolve_no_show_bookings() from public;

-- ------------------------------------------------------------
-- 6. 画面用: この予約でいま何を出すべきか
-- ------------------------------------------------------------
create or replace function public.my_booking_checkin_state(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_b public.bookings;
  v_grace int;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if v_b.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if auth.uid() not in (v_b.guest_id, v_b.host_id) then
    raise exception 'FORBIDDEN';
  end if;

  select checkin_grace_minutes into v_grace from public.platform_pricing where id = 1;

  return jsonb_build_object(
    'started', now() >= v_b.scheduled_at,
    'i_am_guest', auth.uid() = v_b.guest_id,
    'my_checked_in', case when auth.uid() = v_b.guest_id
                          then v_b.guest_checked_in_at is not null
                          else v_b.host_checked_in_at is not null end,
    'partner_checked_in', case when auth.uid() = v_b.guest_id
                               then v_b.host_checked_in_at is not null
                               else v_b.guest_checked_in_at is not null end,
    'held_for_no_show', coalesce(v_b.hold_reason, '') = 'no_show',
    'grace_minutes', v_grace
  );
end;
$$;

revoke all on function public.my_booking_checkin_state(uuid) from public;
grant execute on function public.my_booking_checkin_state(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. cronに登録
--    保留の判定は細かく(5分ごと)、確定は1時間ごとで十分。
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('auto-hold-no-show', '*/5 * * * *',
      'select public.auto_hold_no_show_bookings()');
    perform cron.schedule('auto-resolve-no-show', '13 * * * *',
      'select public.auto_resolve_no_show_bookings()');
  end if;
exception when others then
  raise notice 'pg_cronの登録をスキップしました: %', sqlerrm;
end;
$$;
-- ============================================================
-- 0051_host_availability.sql
-- ピタメイトが「いつ募集しているか」を持ち、空き状況を誰でも見られるようにする
-- ------------------------------------------------------------
-- これまで、ピタメイトが**いつ遊べるのか**を表す情報がどこにもありませんでした。
-- `booking_busy_slots`(0049)が返すのは「予約が入っている時間」だけで、
-- 空いている時間が「募集しているから空いている」のか「そもそも出ていない」のか
-- を区別できません。ゲストから見ると、深夜3時に申し込んでよいのか分かりません。
--
-- 【持ち方】
-- 曜日 × 時 の1時間単位で持ちます。日付ごとではなく**毎週くり返し**にするのは、
-- ピタメイトが毎週メンテナンスする負担をなくすためです。
--
-- 1時間単位にしたのは、週のタイル(7日 × 24時間 = 168枠)として一望できる
-- 粒度がここだからです。30分にすると336枠になり、一覧の意味が薄れます。
-- 予約自体は従来どおり30分刻みで、開いている枠の中なら :30 開始もできます。
--
-- 曜日と時は**日本時間(Asia/Tokyo)**で解釈します。
--
-- 【募集枠の外は予約できるのか】
--   ・1枠も設定していないピタメイト → 従来どおり、いつでも申し込める
--   ・1枠でも設定したピタメイト     → その枠の中だけ申し込める
-- 設定していない人をいきなり予約不可にすると、既存のピタメイトが黙って
-- 消えてしまいます。「設定したら効く」なら、そのピタメイトの意思表示に沿います。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 募集枠
-- ------------------------------------------------------------
create table if not exists public.host_availability (
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 0=日曜 〜 6=土曜(日本時間)
  weekday smallint not null check (weekday between 0 and 6),
  hour smallint not null check (hour between 0 and 23),
  primary key (user_id, weekday, hour)
);

comment on table public.host_availability is
  'ピタメイトが募集している曜日・時(日本時間・1時間単位・毎週くり返し)。1枠も無い場合は「いつでも可」として扱う。';

alter table public.host_availability enable row level security;

-- 誰でも見られる。これが「みんなが見れるスケジュール」の土台。
drop policy if exists "host_availability_select_all" on public.host_availability;
create policy "host_availability_select_all"
  on public.host_availability for select
  to authenticated
  using (true);

-- 書き込みは本人のみ。
drop policy if exists "host_availability_write_own" on public.host_availability;
create policy "host_availability_write_own"
  on public.host_availability for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ------------------------------------------------------------
-- 2. まとめて保存する
--    画面はタイルを塗る操作なので、1枠ずつではなく全体を置き換える。
--    p_slots は [{"weekday":1,"hour":20}, ...] の形。
-- ------------------------------------------------------------
create or replace function public.set_host_availability(p_slots jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if jsonb_typeof(coalesce(p_slots, '[]'::jsonb)) <> 'array' then
    raise exception 'INVALID_SLOTS';
  end if;

  delete from public.host_availability where user_id = v_uid;

  insert into public.host_availability (user_id, weekday, hour)
  select distinct v_uid,
         (s->>'weekday')::smallint,
         (s->>'hour')::smallint
  from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) s
  where (s->>'weekday')::int between 0 and 6
    and (s->>'hour')::int between 0 and 23;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.set_host_availability(jsonb) is
  '自分の募集枠をまとめて置き換える。[{"weekday":1,"hour":20},...] を渡す。';

revoke all on function public.set_host_availability(jsonb) from public;
grant execute on function public.set_host_availability(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 3. 募集枠を設定しているか(判定を1か所に集約する)
-- ------------------------------------------------------------
create or replace function public.host_has_availability(p_host_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.host_availability where user_id = p_host_id);
$$;

-- 指定の時刻(日本時間で解釈)が募集枠に入っているか。
-- 枠を1つも設定していないピタメイトは常に true(従来どおり)。
create or replace function public.host_is_open_at(p_host_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not public.host_has_availability(p_host_id) then true
    else exists (
      select 1 from public.host_availability a
      where a.user_id = p_host_id
        and a.weekday = extract(dow from (p_at at time zone 'Asia/Tokyo'))::smallint
        and a.hour = extract(hour from (p_at at time zone 'Asia/Tokyo'))::smallint
    )
  end;
$$;

comment on function public.host_is_open_at(uuid, timestamptz) is
  'その時刻が募集枠の中か。枠を設定していないピタメイトは常に受け付ける(true)。';

-- ------------------------------------------------------------
-- 4. 誰でも見られるスケジュール
--    これから p_days 日ぶんを1時間ごとに返す。画面はこれをタイルに並べるだけ。
--
--    state:
--      past   … 過ぎた
--      closed … 募集していない
--      booked … 予約が入っている
--      open   … 募集していて空いている
--
--    予約の中身(相手が誰か・何コインか)は返しません。
-- ------------------------------------------------------------
create or replace function public.host_schedule(
  p_host_id uuid,
  p_days int default 7
)
returns table (slot_at timestamptz, state text)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      -- 「今の時間」から始める(過ぎた枠も1日目の頭に出して、位置がずれないように)
      date_trunc('hour', now()) as from_at,
      date_trunc('day', (now() at time zone 'Asia/Tokyo')
        + make_interval(days => greatest(p_days, 1))) at time zone 'Asia/Tokyo' as to_at
  ),
  slots as (
    select generate_series(
      date_trunc('day', (select from_at from bounds) at time zone 'Asia/Tokyo')
        at time zone 'Asia/Tokyo',
      (select to_at from bounds) - interval '1 hour',
      interval '1 hour') as slot_at
  )
  select
    s.slot_at,
    case
      when s.slot_at < date_trunc('hour', now()) then 'past'
      when exists (
        select 1 from public.booking_slots b
        where (b.host_id = p_host_id or b.guest_id = p_host_id)
          and b.starts_at < s.slot_at + interval '1 hour'
          and s.slot_at < b.ends_at
      ) then 'booked'
      when not public.host_is_open_at(p_host_id, s.slot_at) then 'closed'
      else 'open'
    end as state
  from slots s
  order by s.slot_at;
$$;

comment on function public.host_schedule(uuid, int) is
  'ピタメイトの空き状況を1時間ごとに返す(past/closed/booked/open)。誰でも見られる。予約の中身は返さない。';

revoke all on function public.host_schedule(uuid, int) from public;
grant execute on function public.host_schedule(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 5. 募集枠の外は予約できないようにする
--    枠を設定していないピタメイトは従来どおり(host_is_open_at が true を返す)。
--    プレイ時間の全体が枠に収まっている必要がある。
-- ------------------------------------------------------------
create or replace function public.booking_fits_availability(
  p_host_id uuid,
  p_start timestamptz,
  p_minutes int
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_at timestamptz;
  v_end timestamptz;
begin
  if not public.host_has_availability(p_host_id) then
    return true;
  end if;

  v_at := date_trunc('hour', p_start);
  v_end := p_start + make_interval(mins => p_minutes);

  -- 開始の属する時間から、終了の直前の時間まで、すべて開いていること
  while v_at < v_end loop
    if not public.host_is_open_at(p_host_id, v_at) then
      return false;
    end if;
    v_at := v_at + interval '1 hour';
  end loop;
  return true;
end;
$$;

comment on function public.booking_fits_availability(uuid, timestamptz, int) is
  'プレイ時間の全体が募集枠に収まっているか。枠を設定していないピタメイトは常にtrue。';

create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

  -- 募集していない時間帯には申し込めない(0051)。
  -- 枠を1つも設定していないピタメイトは従来どおり制限なし。
  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 枠の検査。ロックを取ってから調べる(同時申し込みで両方通るのを防ぐ)
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

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

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
$$;

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 6. さがす画面などで「いま募集中か」をひと目で出せるように
-- ------------------------------------------------------------
create or replace function public.host_open_now(p_host_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.host_is_open_at(p_host_id, now())
     and public._booking_slot_conflict(p_host_id, now(), 60) is null;
$$;

comment on function public.host_open_now(uuid) is
  'いま募集枠の中で、かつ直近1時間に予約が入っていないか。「いま遊べる」表示に使う。';

revoke all on function public.host_open_now(uuid) from public;
grant execute on function public.host_open_now(uuid) to authenticated;
-- ============================================================
-- 0052_public_host_listing.sql
-- 未ログインの訪問者に「掲載中のピタメイト」だけを見せる
-- ------------------------------------------------------------
-- これまで profiles / host_settings のRLSは to authenticated で、
-- ログインしていない訪問者にはピタメイトが1件も返らなかった。
-- そのためトップに人を出せず、「見つける→興味が湧く→登録」という
-- 導線が成立しなかった(ピタメイトがSNSにURLを貼っても中身が出ない)。
--
-- **RLSは緩めない。** テーブルを直接読めるようにすると、掲載していない
-- 利用者の情報まで芋づるで出る。代わりに、掲載カードに必要な項目だけを
-- 返す関数を用意し、そこにだけ anon の実行権を渡す。
--
-- 出さないもの(意図的):
--   ・性別、last_seen_at、presence_status(いま誰がオンラインかは、
--     未ログインの相手に教える必要が無い。付きまといの材料になる)
--   ・ボイスあいさつ(ストレージを公開せずに済ませる)
--   ・掲載していない利用者、本人確認前の利用者、掲載を望まない利用者
-- ============================================================

-- ------------------------------------------------------------
-- public_host_cards(): 掲載中のピタメイトのカード情報
-- ------------------------------------------------------------
drop function if exists public.public_host_cards(int);

create or replace function public.public_host_cards(p_limit int default 24)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  bio text,
  manner_score numeric,
  review_count int,
  is_verified boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select h.user_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         h.hourly_rate,
         h.games,
         h.bio,
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false)
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  left join public.profile_trust_stats ts on ts.user_id = h.user_id
  left join public.safety_prefs sp on sp.user_id = h.user_id
  where h.is_host = true
    -- 掲載条件は本人確認済み(0003のトリガーと同じ条件)。
    -- 未確認の人が公開の場に出ることが無いよう、ここでも確かめる。
    and coalesce(ts.is_verified, false) = true
    -- 本人が「さがすに出さない」を選んでいれば、公開の場にも出さない。
    -- 設定が未作成なら既定(true)として扱う。
    and coalesce(sp.discoverable, true) = true
  order by coalesce(ts.manner_score, 4.50) desc, coalesce(ts.review_count, 0) desc, h.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;

-- ------------------------------------------------------------
-- ランキングも未ログインで見せる
-- ------------------------------------------------------------
-- host_ranking は元から security definer で、返すのは順位・名前・アバター・
-- 完了数・マナースコアのみ(金額は含まない)。掲載カードと同じ性質なので、
-- 実行権を anon にも渡す。
grant execute on function public.host_ranking(text, int) to anon;

comment on function public.host_ranking(text, int) is
  'ホストのデイリー/ウィークリー/マンスリーランキング。スコア=完了予約数×品質(manner_score)×信頼性。金額(投げ銭・稼ぎ)は一切含めない(弁護士Q11(d))。0037でavatar_pathを追加。0052で未ログインにも公開。';
-- ============================================================
-- 0053_favorites.sql
-- お気に入り登録
-- ------------------------------------------------------------
-- これまで「気になるピタメイトを見つけた」あと、その人にたどり着く手段が
-- 予約するか名前を覚えて検索し直すかしかなかった。
-- 「見つける → 気に留める → 予約する」の真ん中が無い状態。
--
-- プライバシーの方針(ここが設計の中心):
--   ・**誰が誰をお気に入りにしているかは、本人以外に見えない。** お気に入りの一覧が他人に
--     見えると、行動の追跡や付きまといの材料になる。
--   ・お気に入りにされた側には**人数だけ**返す。励みにはなるが、誰かは分からない。
--   ・ブロック関係があれば、どちら向きでも一覧から外す。
--
-- 相手が掲載をやめた場合は、一覧から黙って消さずに「いまは募集していない」
-- と分かる形で残す。黙って消えると、お気に入りに入れていた人には理由が分からない。
-- ============================================================

create table if not exists public.favorites (
  -- お気に入りに入れている人(この行を作った本人)
  user_id uuid not null references auth.users (id) on delete cascade,
  -- お気に入りに入れられた側のピタメイト
  host_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, host_id),
  constraint favorites_no_self check (user_id <> host_id)
);

comment on table public.favorites is
  'お気に入り登録。誰が誰をお気に入りにしているかは本人以外に見えない。お気に入りにされた側には人数のみ返す。';

-- 「自分をお気に入りに入れている人数」を数えるための索引
create index if not exists favorites_host_idx on public.favorites (host_id);

alter table public.favorites enable row level security;

-- 自分のお気に入りだけを読み書きできる。他人のお気に入りは一切見えない。
drop policy if exists "favorites_select_own" on public.favorites;
create policy "favorites_select_own"
  on public.favorites for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "favorites_insert_own" on public.favorites;
create policy "favorites_insert_own"
  on public.favorites for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "favorites_delete_own" on public.favorites;
create policy "favorites_delete_own"
  on public.favorites for delete
  to authenticated
  using (user_id = auth.uid());

-- ------------------------------------------------------------
-- set_favorite(): お気に入り登録の追加・解除
-- ------------------------------------------------------------
drop function if exists public.set_favorite(uuid, boolean);

create or replace function public.set_favorite(p_host_id uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_host_id = v_me then
    raise exception 'CANNOT_FAVORITE_SELF';
  end if;

  if not p_on then
    delete from public.favorites where user_id = v_me and host_id = p_host_id;
    return;
  end if;

  -- ブロック関係があるなら登録させない。解除は上で済ませているので、
  -- 「ブロックしたがお気に入りには残っている」状態は作れない。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_me and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_me)
  ) then
    raise exception 'BLOCKED';
  end if;

  if not exists (select 1 from public.profiles where id = p_host_id) then
    raise exception 'HOST_NOT_FOUND';
  end if;

  insert into public.favorites (user_id, host_id)
  values (v_me, p_host_id)
  on conflict (user_id, host_id) do nothing;
end;
$$;

comment on function public.set_favorite(uuid, boolean) is
  'お気に入り登録の追加(p_on=true)と解除(false)。ブロック関係があると登録できない。';

revoke all on function public.set_favorite(uuid, boolean) from public;
grant execute on function public.set_favorite(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- my_favorites(): 自分がお気に入りに入れているピタメイトの一覧
-- ------------------------------------------------------------
drop function if exists public.my_favorites();

create or replace function public.my_favorites()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  manner_score numeric,
  review_count int,
  is_verified boolean,
  /** いま予約を受け付けているか。false なら「募集を休んでいる」と出す。 */
  is_active boolean,
  favorited_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select f.host_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         coalesce(h.hourly_rate, 0),
         coalesce(h.games, '{}'),
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         coalesce(h.is_host, false)
           and coalesce(ts.is_verified, false)
           and coalesce(sp.discoverable, true),
         f.created_at
  from public.favorites f
  join public.profiles p on p.id = f.host_id
  left join public.host_settings h on h.user_id = f.host_id
  left join public.profile_trust_stats ts on ts.user_id = f.host_id
  left join public.safety_prefs sp on sp.user_id = f.host_id
  where f.user_id = auth.uid()
    -- ブロックした/された相手は出さない
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = f.host_id)
         or (b.blocker_id = f.host_id and b.blocked_id = auth.uid())
    )
  order by f.created_at desc;
$$;

comment on function public.my_favorites() is
  '自分がお気に入りに入れているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からないため)。';

revoke all on function public.my_favorites() from public;
grant execute on function public.my_favorites() to authenticated;

-- ------------------------------------------------------------
-- my_favorite_count(): 自分をお気に入りに入れている人数
-- ------------------------------------------------------------
-- **人数だけ**を返す。誰がお気に入りにしているかは返さない。
drop function if exists public.my_favorite_count();

create or replace function public.my_favorite_count()
returns int
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(count(*), 0)::int
  from public.favorites f
  where f.host_id = auth.uid();
$$;

comment on function public.my_favorite_count() is
  '自分をお気に入りに入れている人数。誰かは返さない(お気に入りに入れた側の行動を相手に知らせない)。';

revoke all on function public.my_favorite_count() from public;
grant execute on function public.my_favorite_count() to authenticated;
-- ============================================================
-- 0054_favorite_slot_notify.sql
-- お気に入りのピタメイトが枠を開けたら知らせる
-- ------------------------------------------------------------
-- 0051で週間の募集枠を持てるようにしたが、**枠を開けても誰にも伝わらなかった**。
-- ファンが毎日スケジュールを見に来ることはないので、開けた枠が埋まらないまま
-- 終わる。0053のお気に入り登録と繋いで、開けたときに知らせる。
--
-- 設計で気をつけたこと:
--   ・**増えた枠だけ**を対象にする。減らしただけで通知が飛ぶのはおかしい。
--   ・**24時間に1回まで**に絞る。編集は続けて何度も行われるので、
--     素直に流すとお気に入り1人あたり1日に何通も届く。
--   ・**誰がお気に入りにしているかはピタメイトに伝えない。** 通知は各ファンの行として
--     入るだけで、関数は件数も返さない(0053の方針をここでも守る)。
--   ・通知を止めたい人はお気に入りを解除すればよい。細かい設定は今は持たない
--     (使われない設定を増やすより、外せることが分かるほうが良い)。
-- ============================================================

-- 通知の種別を追加(既存の種別を欠かさないこと)
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed',
    'booking_requested', 'booking_approved',
    'gift_received', 'booking_extended', 'board_cancelled',
    'integrity_alert', 'booking_no_show',
    'host_slots_opened'
  ));

-- 連投を抑えるための最終通知時刻
alter table public.host_settings
  add column if not exists slots_notified_at timestamptz;

comment on column public.host_settings.slots_notified_at is
  'お気に入りに入れている人へ「枠を開けました」を最後に送った時刻。24時間に1回までに絞るために使う。';

-- ------------------------------------------------------------
-- set_host_availability(): 枠の保存時に、増えた分があればお気に入りに入れている人へ知らせる
-- ------------------------------------------------------------
create or replace function public.set_host_availability(p_slots jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cooldown constant interval := interval '24 hours';
  v_uid uuid := auth.uid();
  v_count int;
  v_added int;
  v_sample text;
  v_name text;
  v_last timestamptz;
  v_is_host boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if jsonb_typeof(coalesce(p_slots, '[]'::jsonb)) <> 'array' then
    raise exception 'INVALID_SLOTS';
  end if;

  -- 新しく指定された枠を一時表に取る(重複と範囲外はここで落とす)
  create temporary table if not exists _new_slots (weekday smallint, hour smallint) on commit drop;
  delete from _new_slots;
  insert into _new_slots (weekday, hour)
  select distinct (s->>'weekday')::smallint, (s->>'hour')::smallint
  from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) s
  where (s->>'weekday')::int between 0 and 6
    and (s->>'hour')::int between 0 and 23;

  -- **入れ替える前に**「増えた枠」を数える。減った枠は対象にしない。
  select count(*),
         string_agg(
           case n.weekday when 0 then '日' when 1 then '月' when 2 then '火' when 3 then '水'
                          when 4 then '木' when 5 then '金' else '土' end
           || n.hour || '時', '・' order by n.weekday, n.hour)
    into v_added, v_sample
  from _new_slots n
  where not exists (
    select 1 from public.host_availability a
    where a.user_id = v_uid and a.weekday = n.weekday and a.hour = n.hour
  );

  delete from public.host_availability where user_id = v_uid;

  insert into public.host_availability (user_id, weekday, hour)
  select v_uid, weekday, hour from _new_slots;

  get diagnostics v_count = row_count;

  -- ここから通知。掲載中のピタメイトが枠を増やしたときだけ。
  select coalesce(h.is_host, false), h.slots_notified_at
    into v_is_host, v_last
  from public.host_settings h where h.user_id = v_uid;

  if coalesce(v_added, 0) > 0
     and coalesce(v_is_host, false)
     and (v_last is null or v_last < now() - c_cooldown)
  then
    select nickname into v_name from public.profiles where id = v_uid;

    insert into public.notifications (user_id, type, title, body, related_id)
    select f.user_id,
           'host_slots_opened',
           coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが枠を開けました',
           -- 長くなりすぎないよう、先頭のいくつかだけ見せる
           case when v_added > 3
                then split_part(v_sample, '・', 1) || '・' || split_part(v_sample, '・', 2)
                     || ' ほか' || (v_added - 2) || '枠'
                else v_sample end,
           v_uid
    from public.favorites f
    where f.host_id = v_uid
      -- ブロック関係があれば送らない
      and not exists (
        select 1 from public.blocks b
        where (b.blocker_id = f.user_id and b.blocked_id = v_uid)
           or (b.blocker_id = v_uid and b.blocked_id = f.user_id)
      );

    update public.host_settings set slots_notified_at = now() where user_id = v_uid;
  end if;

  -- **件数は返さない。** 誰がお気に入りにしているかに繋がる情報を渡さない(0053の方針)。
  return v_count;
end;
$$;

comment on function public.set_host_availability(jsonb) is
  '週間の募集枠を丸ごと入れ替える。0054で、枠が増えたときにお気に入りに入れているファンへ通知する(24時間に1回まで・増えた分のみ)。';

revoke all on function public.set_host_availability(jsonb) from public;
grant execute on function public.set_host_availability(jsonb) to authenticated;
-- ============================================================
-- 0055_play_history_with.sql
-- 「この人とは何回遊んだか」を返す
-- ------------------------------------------------------------
-- プロフィールに出ている「一緒に遊んだ」はその人の**通算**の回数で、
-- 見ている自分との関係は何も表していない。3回一緒に遊んだ相手も、
-- 今日はじめて見た相手も、同じ画面に見える。
--
-- お気に入りに入れてもらうには、積み上がっているものが本人に見えている必要がある。
-- 「あなたとは3回目」と出れば、次も同じ人に頼む理由になる。
--
-- 気をつけたこと:
--   ・**自分が関わった予約しか数えない。** 他人同士の回数は返さない
--     (第三者の交友関係が読めてしまう)。
--   ・完了した予約だけを数える。キャンセルや無断欠席は入れない。
--   ・向きは問わない。ゲストとして遊んだ回とピタメイトとして遊んだ回を
--     合算する(同じ相手との回数であることに変わりはない)。
-- ============================================================

create or replace function public.my_play_history_with(p_other uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'count', count(*),
    'last_played_at', max(coalesce(b.confirmed_at, b.scheduled_at))
  )
  from public.bookings b
  where b.status = 'completed'
    -- **自分が当事者である予約に限る。** ここを外すと他人同士の回数が引ける。
    and (
      (b.guest_id = auth.uid() and b.host_id = p_other)
      or (b.host_id = auth.uid() and b.guest_id = p_other)
    );
$$;

comment on function public.my_play_history_with(uuid) is
  '自分とこの相手が一緒に遊んだ回数と、最後に遊んだ日。自分が当事者の予約しか数えない。';

revoke all on function public.my_play_history_with(uuid) from public;
grant execute on function public.my_play_history_with(uuid) to authenticated;
-- ============================================================
-- 0056_host_status.sql
-- ピタメイトの「ひとこと」(近況)
-- ------------------------------------------------------------
-- お気に入りがいる人がホームに来る目的は「その人の様子を見ること」なのに、
-- 今のホームには**更新されるものが何も無い**。名前も料金もプロフィール文も
-- 昨日と同じで、開く理由が続かない。
--
-- 既にある bio(200字)は自己紹介で、書き換える性質のものではない。
-- 別に、短くて頻繁に書き換わる欄をひとつ持たせる。
--
-- 設計で気をつけたこと:
--   ・**60字まで。** 長くすると自己紹介と同じになり、書き換えられなくなる。
--   ・**古いひとことは出さない。** 「今日は21時から!」が2か月前のものだと、
--     何も無いより悪い。14日を過ぎたものは返さない(消しはしない。本人には
--     見えていて、書き直せばまた出る)。
--   ・**通知は出さない。** 0054で枠の通知を24時間に1回まで絞ったのに、
--     ひとことで毎回鳴らしたら同じことになる。ホームで見えれば足りる。
--   ・掲載条件(掲載中・本人確認済み・さがすに出す)を満たす人のものだけを
--     公開の場に返す。カードに出る他の項目と同じ扱いにする。
-- ============================================================

alter table public.host_settings
  add column if not exists status_text text,
  add column if not exists status_updated_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'host_settings_status_text_len'
  ) then
    alter table public.host_settings
      add constraint host_settings_status_text_len
      check (status_text is null or char_length(status_text) <= 60);
  end if;
end $$;

comment on column public.host_settings.status_text is
  'ピタメイトの「ひとこと」(近況)。60字まで。14日を過ぎたものは公開の場には出さない。';
comment on column public.host_settings.status_updated_at is
  'ひとことを最後に書き換えた時刻。「3時間前」の表示と、古いものを隠す判定に使う。';

-- ------------------------------------------------------------
-- set_host_status(): 自分のひとことを書き換える
-- ------------------------------------------------------------
create or replace function public.set_host_status(p_text text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_clean text;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 前後の空白と改行を落とす。改行を許すと1行の表示欄が崩れる
  v_clean := nullif(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), '');
  if v_clean is not null and char_length(v_clean) > 60 then
    raise exception 'STATUS_TOO_LONG';
  end if;

  -- ひとことは掲載設定の一部。まだ host_settings が無い人にも書けるようにする
  insert into public.host_settings (user_id, status_text, status_updated_at)
  values (v_uid, v_clean, case when v_clean is null then null else v_now end)
  on conflict (user_id) do update
    set status_text = excluded.status_text,
        -- 消したときは時刻も消す(「0分前に空を投稿」を出さないため)
        status_updated_at = case when excluded.status_text is null then null else v_now end;

  return case when v_clean is null then null else v_now end;
end;
$$;

comment on function public.set_host_status(text) is
  '自分の「ひとこと」を書き換える。空文字を渡すと消える。60字まで。';

revoke all on function public.set_host_status(text) from public;
grant execute on function public.set_host_status(text) to authenticated;

-- ------------------------------------------------------------
-- 公開の場に出すときの共通判定
-- ------------------------------------------------------------
-- 同じ「14日」をカードと一覧とプロフィールに三度書くと、いずれ食い違う。
create or replace function public.fresh_host_status(p_text text, p_at timestamptz)
returns text
language sql
-- now() を見るので immutable にはできない(定数として畳まれ、古いひとことが
-- いつまでも出続ける)。
stable
set search_path = public
as $$
  select case
    when p_text is null or p_at is null then null
    when p_at < now() - interval '14 days' then null
    else p_text
  end;
$$;

comment on function public.fresh_host_status(text, timestamptz) is
  'ひとことを公開の場に出してよいか判定する。14日を過ぎたものは null を返す。';

grant execute on function public.fresh_host_status(text, timestamptz) to anon, authenticated;

-- ------------------------------------------------------------
-- 掲載カード・お気に入り一覧にひとことを載せる
-- ------------------------------------------------------------
-- 戻り値の型が変わるので、作り直す(create or replace では変えられない)。
drop function if exists public.public_host_cards(int);

create function public.public_host_cards(p_limit int default 24)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  bio text,
  manner_score numeric,
  review_count int,
  is_verified boolean,
  status_text text,
  status_updated_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select h.user_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         h.hourly_rate,
         h.games,
         h.bio,
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         public.fresh_host_status(h.status_text, h.status_updated_at),
         case when public.fresh_host_status(h.status_text, h.status_updated_at) is null
              then null else h.status_updated_at end
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  left join public.profile_trust_stats ts on ts.user_id = h.user_id
  left join public.safety_prefs sp on sp.user_id = h.user_id
  where h.is_host = true
    and coalesce(ts.is_verified, false) = true
    and coalesce(sp.discoverable, true) = true
  order by coalesce(ts.manner_score, 4.50) desc, coalesce(ts.review_count, 0) desc, h.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。0056でひとことを追加。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;

drop function if exists public.my_favorites();

create function public.my_favorites()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  manner_score numeric,
  review_count int,
  is_verified boolean,
  is_active boolean,
  favorited_at timestamptz,
  status_text text,
  status_updated_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select f.host_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         coalesce(h.hourly_rate, 0),
         coalesce(h.games, '{}'),
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         coalesce(h.is_host, false)
           and coalesce(ts.is_verified, false)
           and coalesce(sp.discoverable, true),
         f.created_at,
         public.fresh_host_status(h.status_text, h.status_updated_at),
         case when public.fresh_host_status(h.status_text, h.status_updated_at) is null
              then null else h.status_updated_at end
  from public.favorites f
  join public.profiles p on p.id = f.host_id
  left join public.host_settings h on h.user_id = f.host_id
  left join public.profile_trust_stats ts on ts.user_id = f.host_id
  left join public.safety_prefs sp on sp.user_id = f.host_id
  where f.user_id = auth.uid()
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = f.host_id)
         or (b.blocker_id = f.host_id and b.blocked_id = auth.uid())
    )
  order by f.created_at desc;
$$;

comment on function public.my_favorites() is
  '自分がお気に入りに入れているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からない)。0056でひとことを追加。';

revoke all on function public.my_favorites() from public;
grant execute on function public.my_favorites() to authenticated;
-- ============================================================
-- 0057_regulars_first.sql
-- 常連への先行予約枠
-- ------------------------------------------------------------
-- 人気のピタメイトの枠は、早く見つけた人から埋まる。何度も遊んでいる常連が
-- 「気づいたら埋まっていた」を繰り返すと、その人との関係はそこで切れる。
-- ピタメイト側から見ても、続けて来てくれる人を取りこぼしているだけで得がない。
--
-- そこで、**開始の N 時間前までは常連だけが予約できる**枠を持てるようにする。
-- N を過ぎれば誰でも取れるので、埋まらないまま流れることはない。
--
-- 「枠を開けてから N 時間」ではなく「開始まで N 時間」にした理由:
--   ・枠を開けた時刻を持たずに済む(host_availability は曜日×時のくり返し)
--   ・ゲストに説明しやすい(「金曜22時の枠は水曜22時から誰でも」)
--   ・埋まらなかった枠が自動的に全体へ開く。運営が何もしなくてよい
--
-- 値引きではないので、ピタメイトの取り分は1コインも減らない。
-- 減るのは「常連に取られる前に他人に取られる」という取りこぼしだけ。
-- ============================================================

alter table public.host_settings
  add column if not exists regulars_first_hours smallint not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'host_settings_regulars_first_hours_range'
  ) then
    alter table public.host_settings
      add constraint host_settings_regulars_first_hours_range
      -- 上限は72時間。これ以上にすると、常連がいないピタメイトの枠が
      -- ほとんど誰にも見えない状態になり、新規が入る余地が無くなる。
      check (regulars_first_hours between 0 and 72);
  end if;
end $$;

comment on column public.host_settings.regulars_first_hours is
  '常連への先行予約。開始までこの時間数より先の枠は、一緒に遊んだことのある人だけが予約できる。0で無効。';

-- ------------------------------------------------------------
-- 内部ヘルパー: 二人が一緒に遊んだ回数
-- ------------------------------------------------------------
-- 0055 の my_play_history_with は auth.uid() 固定で、他人同士は数えられない。
-- サーバ内の判定では任意の二人を数える必要があるため別に用意する。
--
-- **authenticated には渡さない。** 渡すと「AとBが何回遊んだか」を誰でも
-- 引けることになり、0055で閉じたはずの穴がここから開く。
create or replace function public._played_together_count(p_a uuid, p_b uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.bookings b
  where b.status = 'completed'
    and ((b.guest_id = p_a and b.host_id = p_b)
      or (b.host_id = p_a and b.guest_id = p_b));
$$;

comment on function public._played_together_count(uuid, uuid) is
  '二人が一緒に遊んだ回数(内部用)。任意の二人を数えられるので authenticated には渡さない。';

revoke all on function public._played_together_count(uuid, uuid) from public;

-- ------------------------------------------------------------
-- その枠を、この人がいま予約できるか
-- ------------------------------------------------------------
create or replace function public.slot_open_to(p_host_id uuid, p_guest_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_guest_id is null then false
    -- 先行予約を使っていなければ従来どおり
    when coalesce((select h.regulars_first_hours from public.host_settings h
                   where h.user_id = p_host_id), 0) = 0 then true
    -- 開始が近づいたら誰でも取れる
    when p_at <= now() + make_interval(
           hours => (select h.regulars_first_hours from public.host_settings h
                     where h.user_id = p_host_id)) then true
    else public._played_together_count(p_host_id, p_guest_id) > 0
  end;
$$;

comment on function public.slot_open_to(uuid, uuid, timestamptz) is
  'その時刻の枠を、この人がいま予約できるか。先行予約の期間中は一緒に遊んだことのある人だけ true。';

revoke all on function public.slot_open_to(uuid, uuid, timestamptz) from public;
grant execute on function public.slot_open_to(uuid, uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- スケジュールに「常連のみ」を出す
-- ------------------------------------------------------------
-- 見えないと「募集していない」と誤解され、常連になれば取れることが伝わらない。
-- 状態として見せることで、むしろ「また来よう」の理由になる。
create or replace function public.host_schedule(
  p_host_id uuid,
  p_days int default 7
)
returns table (slot_at timestamptz, state text)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      date_trunc('hour', now()) as from_at,
      date_trunc('day', (now() at time zone 'Asia/Tokyo')
        + make_interval(days => greatest(p_days, 1))) at time zone 'Asia/Tokyo' as to_at
  ),
  slots as (
    select generate_series(
      date_trunc('day', (select from_at from bounds) at time zone 'Asia/Tokyo')
        at time zone 'Asia/Tokyo',
      (select to_at from bounds) - interval '1 hour',
      interval '1 hour') as slot_at
  )
  select
    s.slot_at,
    case
      when s.slot_at < date_trunc('hour', now()) then 'past'
      when exists (
        select 1 from public.booking_slots b
        where (b.host_id = p_host_id or b.guest_id = p_host_id)
          and b.starts_at < s.slot_at + interval '1 hour'
          and s.slot_at < b.ends_at
      ) then 'booked'
      when not public.host_is_open_at(p_host_id, s.slot_at) then 'closed'
      -- 本人には自分の枠をそのまま見せる(自分は予約できないので判定しても意味がない)
      when auth.uid() = p_host_id then 'open'
      when not public.slot_open_to(p_host_id, auth.uid(), s.slot_at) then 'regulars'
      else 'open'
    end as state
  from slots s
  order by s.slot_at;
$$;

comment on function public.host_schedule(uuid, int) is
  'ピタメイトの空き状況を1時間ごとに返す(past/closed/booked/regulars/open)。誰でも見られる。予約の中身は返さない。0057で「常連のみ」を追加。';

revoke all on function public.host_schedule(uuid, int) from public;
grant execute on function public.host_schedule(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 予約時に弾く
-- ------------------------------------------------------------
-- 画面で隠すだけでは足りない。RPCを直接叩けば取れてしまうので、
-- create_booking の中でも同じ判定をする。
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

  v_from_paid := least(v_paid, v_coins);
  v_from_bonus := v_coins - v_from_paid;

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
$$;

revoke all on function public.create_booking(uuid, int, text, timestamptz) from public;
grant execute on function public.create_booking(uuid, int, text, timestamptz) to authenticated;
-- ============================================================
-- 0058_repeat_proof.sql
-- 「また呼ばれている」ことを見せる
-- ------------------------------------------------------------
-- いま公開されている実績は マナースコア・レビュー件数・通算のプレイ回数 で、
-- **どれも「1回来た人」を何度数えても増える**。初めてのゲストから見ると、
-- 100人が1回ずつ来たピタメイトと、10人が10回ずつ来たピタメイトが同じに見える。
--
-- 後者を選びたい人は多いはずで、しかも後者こそがこのサービスが機能している
-- 状態そのものだ。リピーターの数を出せば、常連を大事にすることが
-- そのまま新規の獲得につながる。
--
-- 気をつけたこと:
--   ・**金額は一切出さない。** 弁護士Q11(d)の方針をここでも守る。
--   ・**誰がリピーターかは返さない。** 返すのは人数だけ。誰と誰が繰り返し
--     遊んでいるかが読めると、0053・0055で閉じた穴がここから開く。
--   ・**0人のときは何も出さない**(フロント側の判断)。始めたばかりの人に
--     「リピーター0人」を貼るのは、0056で新規を守った方針と逆になる。
-- ============================================================

-- ------------------------------------------------------------
-- host_repeat_guests(): 2回以上遊んでくれた人の数
-- ------------------------------------------------------------
create or replace function public.host_repeat_guests(p_host_id uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from (
    select b.guest_id
    from public.bookings b
    where b.host_id = p_host_id and b.status = 'completed'
    group by b.guest_id
    having count(*) >= 2
  ) r;
$$;

comment on function public.host_repeat_guests(uuid) is
  'そのピタメイトと2回以上遊んだ人の数。人数だけで、誰かは返さない。金額は含まない(弁護士Q11(d))。';

revoke all on function public.host_repeat_guests(uuid) from public;
grant execute on function public.host_repeat_guests(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- host_repeat_guest_counts(): 一覧向けにまとめて取る
-- ------------------------------------------------------------
-- 「さがす」は数十人を一度に出すので、1人ずつ問い合わせると往復が増える。
create or replace function public.host_repeat_guest_counts(p_host_ids uuid[])
returns table (host_id uuid, repeat_guests int)
language sql
stable
security definer
set search_path = public
as $$
  select h.id, coalesce(r.n, 0)::int
  from unnest(coalesce(p_host_ids, '{}'::uuid[])) as h(id)
  left join (
    select g.host_id, count(*) as n
    from (
      select b.host_id, b.guest_id
      from public.bookings b
      where b.status = 'completed'
        and b.host_id = any (coalesce(p_host_ids, '{}'::uuid[]))
      group by b.host_id, b.guest_id
      having count(*) >= 2
    ) g
    group by g.host_id
  ) r on r.host_id = h.id;
$$;

comment on function public.host_repeat_guest_counts(uuid[]) is
  '複数のピタメイトについて、2回以上遊んだ人の数をまとめて返す。誰かは返さない。';

revoke all on function public.host_repeat_guest_counts(uuid[]) from public;
grant execute on function public.host_repeat_guest_counts(uuid[]) to anon, authenticated;

-- ------------------------------------------------------------
-- 掲載カードにも載せる
-- ------------------------------------------------------------
drop function if exists public.public_host_cards(int);

create function public.public_host_cards(p_limit int default 24)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  bio text,
  manner_score numeric,
  review_count int,
  is_verified boolean,
  status_text text,
  status_updated_at timestamptz,
  repeat_guests int
)
language sql
security definer
set search_path = public
stable
as $$
  select h.user_id,
         coalesce(nullif(p.nickname, ''), '(名前未設定)'),
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         h.hourly_rate,
         h.games,
         h.bio,
         coalesce(ts.manner_score, 4.50),
         coalesce(ts.review_count, 0),
         coalesce(ts.is_verified, false),
         public.fresh_host_status(h.status_text, h.status_updated_at),
         case when public.fresh_host_status(h.status_text, h.status_updated_at) is null
              then null else h.status_updated_at end,
         public.host_repeat_guests(h.user_id)
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  left join public.profile_trust_stats ts on ts.user_id = h.user_id
  left join public.safety_prefs sp on sp.user_id = h.user_id
  where h.is_host = true
    and coalesce(ts.is_verified, false) = true
    and coalesce(sp.discoverable, true) = true
  order by coalesce(ts.manner_score, 4.50) desc, coalesce(ts.review_count, 0) desc, h.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。0056でひとこと、0058でリピーター数を追加。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;
-- ============================================================
-- 0059_last_play_shape.sql
-- 「前回と同じ条件」を出せるようにする
-- ------------------------------------------------------------
-- 続けて遊ぶ相手が決まっているのに、毎回ゼロから時間と長さを選び直させている。
-- 決まりきった相手・決まりきった曜日でも、予約のたびに同じ操作をさせられる。
-- ここが面倒だと「まあ今週はいいか」で終わる。値引きより、この摩擦を取るほうが
-- 繰り返しには効く。
--
-- 0055 の my_play_history_with に、前回の**長さ**と**日時**を足すだけ。
-- 画面側はこれを見て「前回と同じ(金22時・60分)」を1タップで出せる。
--
-- 自分が当事者の予約しか見ない点は0055のまま。ここを緩めると、他人同士が
-- いつ何分遊んでいるかまで読めるようになる。
-- ============================================================

create or replace function public.my_play_history_with(p_other uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select b.duration_minutes,
           coalesce(b.confirmed_at, b.scheduled_at) as played_at,
           b.scheduled_at
    from public.bookings b
    where b.status = 'completed'
      -- **自分が当事者である予約に限る。** ここを外すと他人同士の回数が引ける。
      and (
        (b.guest_id = auth.uid() and b.host_id = p_other)
        or (b.host_id = auth.uid() and b.guest_id = p_other)
      )
  ),
  last_one as (
    select * from mine order by played_at desc limit 1
  )
  select jsonb_build_object(
    'count', (select count(*) from mine),
    'last_played_at', (select max(played_at) from mine),
    -- 前回の長さと開始時刻。「前回と同じ」の材料にする
    'last_duration_minutes', (select duration_minutes from last_one),
    'last_scheduled_at', (select scheduled_at from last_one)
  );
$$;

comment on function public.my_play_history_with(uuid) is
  '自分とこの相手が一緒に遊んだ回数・最後に遊んだ日と、前回の長さ・開始時刻。自分が当事者の予約しか見ない。0059で前回の条件を追加。';

revoke all on function public.my_play_history_with(uuid) from public;
grant execute on function public.my_play_history_with(uuid) to authenticated;
-- ============================================================
-- 0060_discovery_repeat_rank.sql
-- 「また呼ばれているか」を掲載順に入れる
-- ------------------------------------------------------------
-- 「さがす」の一覧には**並び順が無かった**(is_host で絞るだけで order 句なし)。
-- 未ログイン向けの掲載カードはマナースコア順で、こちらは「1回来た人」を
-- 何度数えても上がる指標だった。
--
-- 掲載順は予約数に直結するので、実質いちばん大きな報酬でもある。
-- そこを「また呼ばれているか」で決めれば、常連を大事にすることがそのまま
-- 新規の流入につながる。指標としても素直で、レビューを稼ぐより偽装しにくい。
--
-- ■ 小さい母数をどう扱うか(ここが肝)
--   素のリピート率は、1人来て1回また来ただけで100%になる。それを上位に
--   置くと、実績のある人が下がって順位が壊れる。
--   ベイズ平均で丸める:
--     score = (repeat_guests + m * prior) / (guests + m)   … m=5, prior=0.25
--   こうすると、
--     ・まだ誰も来ていない人      → 0.25(不明であって、悪いではない)
--     ・1人来て1回リピート        → 0.375(上がるが独占はしない)
--     ・10人中8人がリピート       → 0.617
--     ・10人来て誰も戻らなかった  → 0.083(新規より下)
--   「実績が無い」を「実績が悪い」と同じ扱いにしないことが大事で、
--   でなければ始めたばかりの人が永久に埋もれる。
--
-- ■ 金額は使わない
--   稼いだ額・投げ銭額は一切入れない(弁護士Q11(d))。使うのは人数だけ。
-- ============================================================

-- ------------------------------------------------------------
-- host_repeat_stats(): まとめて「来た人数・戻った人数・丸めた率」を返す
-- ------------------------------------------------------------
-- 0058 の host_repeat_guest_counts を置き換える(人数だけでは並べられないため)。
drop function if exists public.host_repeat_guest_counts(uuid[]);

create or replace function public.host_repeat_stats(p_host_ids uuid[])
returns table (host_id uuid, guests int, repeat_guests int, repeat_score numeric)
language sql
stable
security definer
set search_path = public
as $$
  with c_const as (select 5.0::numeric as m, 0.25::numeric as prior),
  per_guest as (
    select b.host_id, b.guest_id, count(*) as n
    from public.bookings b
    where b.status = 'completed'
      and b.host_id = any (coalesce(p_host_ids, '{}'::uuid[]))
    group by b.host_id, b.guest_id
  ),
  agg as (
    select pg.host_id,
           count(*)::int as guests,
           count(*) filter (where pg.n >= 2)::int as repeat_guests
    from per_guest pg
    group by pg.host_id
  )
  select h.id,
         coalesce(a.guests, 0),
         coalesce(a.repeat_guests, 0),
         round(
           (coalesce(a.repeat_guests, 0) + k.m * k.prior) / (coalesce(a.guests, 0) + k.m),
           4)
  from unnest(coalesce(p_host_ids, '{}'::uuid[])) as h(id)
  cross join c_const k
  left join agg a on a.host_id = h.id;
$$;

comment on function public.host_repeat_stats(uuid[]) is
  'ピタメイトごとの「来た人数・2回以上来た人数・丸めたリピート率」。誰かは返さない。金額は含まない(弁護士Q11(d))。母数が小さいときはベイズ平均で0.25へ寄せる。';

revoke all on function public.host_repeat_stats(uuid[]) from public;
grant execute on function public.host_repeat_stats(uuid[]) to anon, authenticated;

-- ------------------------------------------------------------
-- 掲載カードもこの順に並べる
-- ------------------------------------------------------------
-- 未ログインとログイン後で並びが違うと、登録した瞬間に一覧が入れ替わって
-- 「さっき見た人がいない」になる。同じ式を使う。
drop function if exists public.public_host_cards(int);

create function public.public_host_cards(p_limit int default 24)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  games text[],
  bio text,
  manner_score numeric,
  review_count int,
  is_verified boolean,
  status_text text,
  status_updated_at timestamptz,
  repeat_guests int
)
language sql
security definer
set search_path = public
stable
as $$
  with listed as (
    select h.user_id, h.hourly_rate, h.games, h.bio, h.status_text, h.status_updated_at,
           p.nickname, p.avatar_initial, p.avatar_color, p.avatar_path,
           ts.manner_score, ts.review_count, ts.is_verified
    from public.host_settings h
    join public.profiles p on p.id = h.user_id
    left join public.profile_trust_stats ts on ts.user_id = h.user_id
    left join public.safety_prefs sp on sp.user_id = h.user_id
    where h.is_host = true
      and coalesce(ts.is_verified, false) = true
      and coalesce(sp.discoverable, true) = true
  ),
  scored as (
    select l.*, r.repeat_guests, r.repeat_score
    from listed l
    join public.host_repeat_stats(array(select user_id from listed)) r on r.host_id = l.user_id
  )
  select s.user_id,
         coalesce(nullif(s.nickname, ''), '(名前未設定)'),
         coalesce(nullif(s.avatar_initial, ''), left(coalesce(nullif(s.nickname, ''), '?'), 1)),
         coalesce(nullif(s.avatar_color, ''), '#B3E5F2'),
         s.avatar_path,
         s.hourly_rate,
         s.games,
         s.bio,
         coalesce(s.manner_score, 4.50),
         coalesce(s.review_count, 0),
         coalesce(s.is_verified, false),
         public.fresh_host_status(s.status_text, s.status_updated_at),
         case when public.fresh_host_status(s.status_text, s.status_updated_at) is null
              then null else s.status_updated_at end,
         s.repeat_guests
  from scored s
  order by s.repeat_score desc,
           coalesce(s.manner_score, 4.50) desc,
           coalesce(s.review_count, 0) desc,
           s.user_id
  limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;

comment on function public.public_host_cards(int) is
  '未ログインでも見える「掲載中のピタメイト」カード。掲載を選び、本人確認を通り、さがすに出す設定の人だけ。オンライン状態・性別・ボイスは返さない。0056でひとこと、0058でリピーター数、0060で「また呼ばれているか」順に並べる。';

revoke all on function public.public_host_cards(int) from public;
grant execute on function public.public_host_cards(int) to anon, authenticated;
-- ============================================================
-- 0061_booking_series.sql
-- まとめ予約(毎週くり返し)
-- ------------------------------------------------------------
-- 「毎週金曜22時」が決まっている二人でも、いまは毎週その都度予約する。
-- ピタメイト側から見ると、続けて来る人がいても枠は毎回ゼロから埋め直しで、
-- 先の予定が立たない。
--
-- 同じ相手・同じ時刻を4回分まとめて押さえられるようにする。
-- **新しいお金の仕組みは作らない。** 既存の create_booking を回数分呼ぶだけで、
-- 料金・割引・コインの消費・キャンセル規定はすべて1件ずつ従来どおり効く。
-- 回数券でも定期契約でもないので、前払式支払手段の整理も変わらない。
--
-- ■ 全部通るか、1件も作らないか
--   3週目だけ埋まっていたときに1・2・4週目を作ると、ゲストは頼んでいない
--   組み合わせに払わされる。同じトランザクションの中で回すので、どこかで
--   失敗すれば全部巻き戻る。エラーには何回目で落ちたかを載せる。
--
-- ■ 予約できる先を35日に延ばす
--   14日のままだと「4回分」が入らない(4回目が28日先になる)。
--   遠い予約ほどキャンセルの返還率は高い(0040の段階制)ので、ゲスト側の
--   不利は増えない。コインの有効期限は取得から6か月なので、そちらとも
--   ぶつからない。
-- ============================================================

update public.platform_pricing set max_lead_days = 35 where id = 1 and max_lead_days < 35;
alter table public.platform_pricing alter column max_lead_days set default 35;

comment on column public.platform_pricing.max_lead_days is
  '何日先まで予約できるか。0061でまとめ予約(4回分=28日先)が入るよう35日にした。';

-- ------------------------------------------------------------
-- create_booking_series(): 同じ時刻を毎週くり返して押さえる
-- ------------------------------------------------------------
create or replace function public.create_booking_series(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_first_start timestamptz,
  p_count int
)
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_count constant int := 4;
  v_ids uuid[] := '{}';
  v_at timestamptz;
  i int;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_first_start is null then
    raise exception 'SERIES_NEEDS_START';
  end if;
  -- 1回だけなら create_booking をそのまま使えばよい。ここは2回以上のための口。
  if p_count is null or p_count < 2 or p_count > c_max_count then
    raise exception 'INVALID_SERIES_COUNT';
  end if;

  for i in 0 .. p_count - 1 loop
    v_at := p_first_start + make_interval(days => 7 * i);
    begin
      -- 料金・割引・コイン消費・枠の重複・常連への先行予約(0057)は
      -- すべて create_booking の中の判定に委ねる。ここで写し取らない。
      v_ids := v_ids || public.create_booking(p_host_id, p_duration_minutes, p_policy_version, v_at);
    exception when others then
      -- 何回目で落ちたかを添えて投げ直す。元のメッセージは残すので、
      -- 画面側の INSUFFICIENT_COINS 等の判定はそのまま効く。
      raise exception '% [まとめ予約 %回目/%]', sqlerrm, i + 1, p_count;
    end;
  end loop;

  return v_ids;
end;
$$;

comment on function public.create_booking_series(uuid, int, text, timestamptz, int) is
  '同じ時刻を毎週くり返して2〜4回まとめて予約する。中身は create_booking を回数分呼ぶだけで、料金・割引・キャンセル規定は1件ずつ従来どおり。どこかで失敗すれば全部巻き戻る。';

revoke all on function public.create_booking_series(uuid, int, text, timestamptz, int) from public;
grant execute on function public.create_booking_series(uuid, int, text, timestamptz, int) to authenticated;
-- ============================================================
-- 0062_fast_release.sql
-- 常連との予約だけ、自動確定を早める(ゲストが選んだときだけ)
-- ------------------------------------------------------------
-- いまはプレイ終了から72時間で自動確定する。ゲストが毎回「完了」を押せば
-- すぐ確定するが、実際には押し忘れる。押し忘れた分、ピタメイトの入金は
-- 3日遅れる。手取りは1コインも変わらないのに、体感だけが悪い。
--
-- 何度も遊んでいる相手なら、ゲスト側も毎回確認する必要を感じていない。
-- そこで「この人との予約は24時間で確定してよい」を**一度選べば以降ずっと**
-- 効くようにする。押し忘れが構造的に消える。
--
-- ■ ここは慎重に設計する必要がある
--   72時間は、ゲストが申し出(0042の保留)を出すための窓でもある。
--   短くすることは消費者側の権利を削る方向で、運営が勝手に決めれば
--   消費者契約法10条(一方的に不利な条項)の問題になりうる。
--   だから:
--     ・**ゲストが自分で選んだときだけ**適用する。既定は72時間のまま
--     ・**いつでも外せる。** 外した瞬間から72時間に戻る(保存済みの
--       予約にも効く。判定は自動確定の実行時に読むため)
--     ・**下限24時間。** 0時間を許すと、前払いして即座に取り返せない
--       のと区別がつかなくなる
--     ・**3回以上遊んだ相手にだけ**選べる。初回から出すと、
--       仕組みを理解する前に押させることになる
--     ・保留(held_at)は従来どおり優先。通報・申し出があれば確定しない
--
-- ■ ピタメイト側からは設定できない
--   相手に「早く確定して」と言わせる余地を作らない。設定はゲストの側にしか
--   置かず、ピタメイトからは誰が設定しているかも見えない。
-- ============================================================

create table if not exists public.fast_release_prefs (
  guest_id uuid not null references auth.users (id) on delete cascade,
  host_id uuid not null references auth.users (id) on delete cascade,
  -- 終了から何時間で自動確定してよいか。24時間未満は認めない
  hours smallint not null check (hours between 24 and 72),
  created_at timestamptz not null default now(),
  primary key (guest_id, host_id),
  check (guest_id <> host_id)
);

comment on table public.fast_release_prefs is
  'ゲストが「この相手とは早く確定してよい」と選んだ設定。既定(72時間)より短くするのはゲスト本人だけで、いつでも外せる。ピタメイト側からは設定も参照もできない。';

alter table public.fast_release_prefs enable row level security;

-- 自分の行だけ。ピタメイト側に見せる口はどこにも作らない。
-- 当て直しても壊れないよう、いったん落としてから作る。
drop policy if exists "fast_release_select_own" on public.fast_release_prefs;
drop policy if exists "fast_release_insert_own" on public.fast_release_prefs;
drop policy if exists "fast_release_delete_own" on public.fast_release_prefs;

create policy "fast_release_select_own"
  on public.fast_release_prefs for select
  to authenticated
  using (guest_id = auth.uid());

create policy "fast_release_insert_own"
  on public.fast_release_prefs for insert
  to authenticated
  with check (guest_id = auth.uid());

create policy "fast_release_delete_own"
  on public.fast_release_prefs for delete
  to authenticated
  using (guest_id = auth.uid());

-- ------------------------------------------------------------
-- set_fast_release(): 設定する / 外す
-- ------------------------------------------------------------
create or replace function public.set_fast_release(p_host_id uuid, p_hours int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_min_plays constant int := 3;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if v_uid = p_host_id then
    raise exception 'CANNOT_SET_SELF';
  end if;

  -- null または 72 で「既定に戻す」= 行を消す
  if p_hours is null or p_hours >= 72 then
    delete from public.fast_release_prefs where guest_id = v_uid and host_id = p_host_id;
    return;
  end if;

  if p_hours < 24 then
    raise exception 'FAST_RELEASE_TOO_SHORT';
  end if;

  -- 仕組みを理解する前に押させないため、何度か遊んだ相手にだけ許す
  if public._played_together_count(v_uid, p_host_id) < c_min_plays then
    raise exception 'NOT_ENOUGH_PLAYS';
  end if;

  insert into public.fast_release_prefs (guest_id, host_id, hours)
  values (v_uid, p_host_id, p_hours)
  on conflict (guest_id, host_id) do update set hours = excluded.hours, created_at = now();
end;
$$;

comment on function public.set_fast_release(uuid, int) is
  'この相手との予約を終了から何時間で自動確定してよいか(24〜71)。nullまたは72で既定に戻す。3回以上遊んだ相手にだけ設定できる。';

revoke all on function public.set_fast_release(uuid, int) from public;
grant execute on function public.set_fast_release(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- my_fast_release(): いまの設定と、設定できる状態か
-- ------------------------------------------------------------
create or replace function public.my_fast_release(p_host_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'hours', (select f.hours from public.fast_release_prefs f
              where f.guest_id = auth.uid() and f.host_id = p_host_id),
    'eligible', coalesce(public._played_together_count(auth.uid(), p_host_id) >= 3, false)
  );
$$;

comment on function public.my_fast_release(uuid) is
  '自分がこの相手に設定している自動確定の時間と、設定できる状態かどうか。';

revoke all on function public.my_fast_release(uuid) from public;
grant execute on function public.my_fast_release(uuid) to authenticated;

-- ------------------------------------------------------------
-- 自動確定が、この設定を見るようにする
-- ------------------------------------------------------------
-- 設定を**実行時に読む**のが肝。予約を作った時点で焼き付けると、
-- あとから設定を外しても、既にある予約は短いままになってしまう。
create or replace function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_default_hours constant int := 72;
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select b.id, b.host_id, b.coins
    from public.bookings b
    where b.status = 'confirmed'
      -- 保留(通報・申し出)は従来どおり優先。短くしても確定しない
      and b.held_at is null
      -- 相関副問い合わせで引くこと。left join にすると
      -- 「FOR UPDATE cannot be applied to the nullable side of an outer join」で落ちる。
      and b.scheduled_at
          + make_interval(mins => b.duration_minutes)
          + make_interval(hours => coalesce(
              (select f.hours from public.fast_release_prefs f
               where f.guest_id = b.guest_id and f.host_id = b.host_id),
              c_default_hours)) < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  'ゲストが完了操作をしないまま終了から一定時間が過ぎた予約を自動確定する。'
  '既定72時間。0062でゲストが相手ごとに24時間まで短くできるようにした(設定は実行時に読むので、外せば即座に既定へ戻る)。'
  '保留中(held_at)のものは対象外(E-12)。';

revoke all on function public.auto_complete_bookings() from public;
-- ============================================================
-- 0063_align_payout_terms.sql
-- 換金とギフトの条件を競合と揃える
-- ------------------------------------------------------------
-- GameRoom の公表条件(2022/08/02 時点のヘルプ)を確認したところ、
--   ・チケット手数料 15%
--   ・ギフト手数料 35%
--   ・出金手数料 300円/回
--   ・**最低出金額 5,000円**
--   ・**振込は毎週月曜**
-- だった。こちらは ギフト30% / 最低1,000コイン / 月末締め翌月払い。
--
-- ギフトと最低額を相手に合わせ、振込は週次にして追い越す。
--   ・ギフト 30% → **35%**
--       お気に入り中心のサービスなのでギフトの比重は大きい。ここを5pt低く保つと
--       収益の主要な柱を自分から削ることになる。相手が35%で成立している
--       以上、揃えて問題ない。
--   ・最低出金 1,000 → **5,000コイン**
--       少額振込の事務コスト(ワンオペ)を抑える。報酬コインは失効しない
--       設計(0018)なので、届くまで待っても目減りしない。
--   ・振込は週次(このファイルでは扱わない。運用手順とUI表記の変更)
--       毎週日曜締め・翌週金曜払い。締め〜支払いの日数は締め曜日に依存しないが、
--       日曜締めにすると不正チェック(手順書①-2)に使える営業日が2日→4日になる。
--
-- ⚠️ **どちらも公開前に決めきること。** 公開後にギフト率を上げるのも
--    最低額を上げるのも、ピタメイトにとっては不利益変更で、規約上の
--    2週間周知が要るうえ、いちばん失いたくない層の心証を損なう。
-- ⚠️ 法務: 手数料率と最低額は特商法表記・規約の記載対象。
-- ============================================================

-- ------------------------------------------------------------
-- ギフト手数料 30% → 35%
-- ------------------------------------------------------------
create or replace function public._apply_gift_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 0063で30%→35%。変更したらUI(ギフト送信シート)と特商法表記も更新すること
  c_gift_rate constant numeric := 0.35;
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;
  v_fee := least(greatest(round(new.coins * c_gift_rate)::int, 0), new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.receiver_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (new.receiver_id, -v_fee, 'platform_fee', 'gift_fee:' || new.id);
  end if;

  insert into public.platform_fees (
    host_id, kind, gift_id, gross_coins, fee_coins, net_coins, applied_rate)
  values (new.receiver_id, 'gift', new.id, new.coins, v_fee, new.coins - v_fee, c_gift_rate);

  return new;
end;
$$;

comment on function public._apply_gift_fee() is
  'ギフト受領時に一律35%を引く(0063で30%から変更)。累進の対象外なのは、金額が任意で青天井になりうるため。';

-- ------------------------------------------------------------
-- 最低換金額 1,000 → 5,000コイン
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 振込手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;
  if v_balance is null or v_balance < p_coins then
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(int) is
  '報酬コインの銀行振込を申請する。最低5,000コイン(0063で1,000から変更)・手数料300コイン/回。締めは毎週日曜・翌週金曜払い。';

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;
-- ============================================================
-- 0064_web_push.sql
-- ブラウザへのプッシュ通知(Web Push)
-- ------------------------------------------------------------
-- これまで notifications は**アプリを開いたときにしか見えなかった**。
-- 0054の「お気に入りのピタメイトが枠を開けました」も、開いてくれなければ意味がない。
-- ピタフレはApp Storeに出していないので、届く経路はWeb Pushだけになる。
--
-- ■ 設計で外せない点
--
-- 1. **通知の記録とプッシュの送信を切り離す。**
--    トリガーの中からHTTPを叩くと、プッシュ配信元(FCM/Apple)が落ちている
--    ときに notifications の insert ごと失敗する。予約や通報の通知が
--    「プッシュが送れなかったから」消えるのは本末転倒。
--    そこで push_outbox に積むだけにして、送信は別プロセス(Edge Function)が
--    引き取る。失敗しても再試行できて、溜まっている様子も見える。
--
-- 2. **プッシュは既存の通知設定とは別の口。**
--    notification_prefs の3つのトグルは「何を」の設定で、
--    プッシュは「どうやって」の設定。混ぜると
--    「アプリ内では見たいがロック画面には出したくない」が表現できない。
--    push_enabled を足して独立に切れるようにする。
--
-- 3. **ロック画面に本文を出さない種類がある。**
--    message_received はメッセージ本文の先頭60文字を、
--    gift_received は金額と添えた言葉を body に入れている(0012/0019)。
--    ロック画面は他人の目に入る場所なので、この2つは**題名だけ**にする。
--    「誰から来たか」は伝わるので用は足りる。
--
-- 4. **静かにする時間は既定で入れない。**
--    ゲームは夜に遊ぶもので、深夜の誘いはむしろ本題。運営が勝手に
--    止めると使えない通知になる。設定した人にだけ効かせ、しかも
--    急がない種類(枠が空いた・ギフト・募集)だけを止める。
--    判定は**送信時**に行う(0062と同じ理由。設定を変えたら即座に効く)。
--
-- 5. **iOSはホーム画面に追加しないと通知が使えない。** これは仕様。
--    追加への案内(src/lib/install.ts)と地続きの導線になっている。
--
-- ⚠️ 送信には VAPID 鍵が必要です。手順は docs/web-push-setup.md。
--    **秘密鍵はリポジトリに置かないこと。** Supabase の Secrets に入れる。
-- ============================================================

-- ------------------------------------------------------------
-- push_subscriptions: 端末ごとの購読先
-- ------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 配信元が発行するURL。端末+ブラウザを一意に指す
  endpoint text not null unique,
  -- 本文を暗号化するための公開鍵と認証シークレット(ブラウザが発行する)
  p256dh text not null,
  auth text not null,
  -- どの端末か(利用者が設定画面で見分けるため。判定には使わない)
  ua text,
  created_at timestamptz not null default now(),
  -- 起動ごとに更新する。古いものを片付ける目印
  last_seen_at timestamptz not null default now(),
  -- 配信元が404/410を返した(購読が消えた)。再送しない
  disabled_at timestamptz,
  fail_count smallint not null default 0
);

comment on table public.push_subscriptions is
  'Web Pushの購読先。endpointが端末+ブラウザを一意に指すので、同じ端末で別の人がログインしたら user_id が付け替わる(その端末には前の人へのプッシュは行かなくなる。これが正しい)。';

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id) where disabled_at is null;

alter table public.push_subscriptions enable row level security;

-- 自分の行だけ。設定画面で端末一覧を出し、消せるようにする。
drop policy if exists "push_subscriptions_select_own" on public.push_subscriptions;
drop policy if exists "push_subscriptions_delete_own" on public.push_subscriptions;

create policy "push_subscriptions_select_own"
  on public.push_subscriptions for select
  to authenticated
  using (user_id = auth.uid());

create policy "push_subscriptions_delete_own"
  on public.push_subscriptions for delete
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEポリシーは作らない。下の RPC 経由だけにして、
-- user_id を他人のものにできないようにする。

-- ------------------------------------------------------------
-- プッシュの受け取り設定
-- ------------------------------------------------------------
alter table public.notification_prefs
  add column if not exists push_enabled boolean not null default true;
-- 静かにする時間(JSTの時。null で無効)。23→7 のように日付をまたいでよい
alter table public.notification_prefs
  add column if not exists push_quiet_from smallint;
alter table public.notification_prefs
  add column if not exists push_quiet_to smallint;

alter table public.notification_prefs
  drop constraint if exists notification_prefs_quiet_range_check;
alter table public.notification_prefs
  add constraint notification_prefs_quiet_range_check check (
    (push_quiet_from is null and push_quiet_to is null)
    or (push_quiet_from between 0 and 23 and push_quiet_to between 0 and 23)
  );

comment on column public.notification_prefs.push_enabled is
  'ロック画面へのプッシュを受け取るか。アプリ内の通知一覧とは独立(見たいがロック画面には出したくない、を表現できるようにするため)。';
comment on column public.notification_prefs.push_quiet_from is
  'プッシュを止める開始時刻(JSTの時)。既定はnull=止めない。ゲームは夜に遊ぶので運営が勝手に止めない。';

-- ------------------------------------------------------------
-- 種類ごとの扱い
-- ------------------------------------------------------------
/**
 * 急がない種類か。静かにする時間で止めてよいのはこれだけ。
 * 予約・通報・本人確認・メッセージ・誘いは、深夜でも本題なので止めない
 * (2時に届いたメッセージは2時に読みたい)。
 */
create or replace function public._push_is_casual(p_type text)
returns boolean
language sql
immutable
as $$
  select p_type in (
    'host_slots_opened',  -- 0054。もともと24時間に1回に絞ってある
    'gift_received',
    'board_joined',
    'board_cancelled',
    'booking_completed'
  );
$$;

/**
 * ロック画面に出す本文。**他人の目に入る前提で削る。**
 * message_received はメッセージ本文、gift_received は金額と添えた言葉が
 * body に入っている(0012/0019)。この2つは題名だけにする。
 */
create or replace function public._push_lockscreen_body(p_type text, p_body text)
returns text
language sql
immutable
as $$
  select case when p_type in ('message_received', 'gift_received') then '' else coalesce(p_body, '') end;
$$;

/** いま静かにする時間の中か。日付をまたぐ指定(23→7)も扱う。 */
create or replace function public._push_in_quiet_hours(p_from smallint, p_to smallint)
returns boolean
language sql
stable
as $$
  select case
    when p_from is null or p_to is null or p_from = p_to then false
    when p_from < p_to then t.h >= p_from and t.h < p_to
    else t.h >= p_from or t.h < p_to
  end
  from (select extract(hour from now() at time zone 'Asia/Tokyo')::int as h) t;
$$;

-- ------------------------------------------------------------
-- push_outbox: 送信待ち
-- ------------------------------------------------------------
create table if not exists public.push_outbox (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  type text not null,
  title text not null,
  body text not null default '',
  related_id uuid,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts smallint not null default 0,
  last_error text
);

comment on table public.push_outbox is
  '送信待ちのプッシュ。トリガーからHTTPを叩くと配信元の障害でnotificationsのinsertごと失敗するので、いったんここへ積んで別プロセスが引き取る。';

create index if not exists push_outbox_pending_idx
  on public.push_outbox (created_at) where sent_at is null;

alter table public.push_outbox enable row level security;
-- 利用者に見せるものではない(自分の通知は notifications で見える)。
-- ポリシーを1本も作らないので、authenticated からは一切読めない。

-- ------------------------------------------------------------
-- notifications への insert で積む
-- ------------------------------------------------------------
create or replace function public._enqueue_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 端末を1つも登録していない人の分は積まない(大半はこれで落ちる)。
  -- push_enabled と静かにする時間は**送信時**に見る。設定を変えたら
  -- 積んである分にもすぐ効くようにするため(0062と同じ考え)。
  if not exists (
    select 1 from public.push_subscriptions s
    where s.user_id = new.user_id and s.disabled_at is null
  ) then
    return new;
  end if;

  insert into public.push_outbox (notification_id, user_id, type, title, body, related_id)
  values (
    new.id, new.user_id, new.type, new.title,
    public._push_lockscreen_body(new.type, new.body),
    new.related_id
  );
  return new;
end;
$$;

drop trigger if exists notifications_enqueue_push on public.notifications;
create trigger notifications_enqueue_push
  after insert on public.notifications
  for each row execute function public._enqueue_push();

-- ------------------------------------------------------------
-- 端末の登録・解除(本人のみ)
-- ------------------------------------------------------------
create or replace function public.save_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text, p_ua text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_endpoint is null or p_endpoint = '' or p_p256dh is null or p_auth is null then
    raise exception 'INVALID_SUBSCRIPTION';
  end if;

  -- 同じ端末で別の人がログインしたら付け替える。disabled_at も戻す
  -- (購読し直したということなので、また生きている)
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, ua)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(coalesce(p_ua, ''), 300))
  on conflict (endpoint) do update
    set user_id = v_uid,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        ua = excluded.ua,
        last_seen_at = now(),
        disabled_at = null,
        fail_count = 0;
end;
$$;

comment on function public.save_push_subscription(text, text, text, text) is
  'この端末をプッシュの宛先として登録する。起動ごとに呼んでよい(last_seen_atが更新される)。';

revoke all on function public.save_push_subscription(text, text, text, text) from public;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  delete from public.push_subscriptions
    where endpoint = p_endpoint and user_id = v_uid;
end;
$$;

revoke all on function public.delete_push_subscription(text) from public;
grant execute on function public.delete_push_subscription(text) to authenticated;

-- ------------------------------------------------------------
-- 送信側(service_role のみ)
-- ------------------------------------------------------------
/**
 * 送るぶんを取り出して、試行回数を1つ増やす。
 *
 * 1つの通知に対して端末ぶんの行を返す。静かにする時間・push_enabled は
 * ここで見るので、止まっている間は attempts が増えない(時間が明けたら
 * そのまま届く。「朝になったらまとめて来る」が正しい振る舞い)。
 */
create or replace function public.claim_push_batch(p_limit int default 100)
returns table (
  outbox_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  payload jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_attempts constant int := 3;
begin
  return query
  with picked as (
    select o.id
    from public.push_outbox o
    join public.notification_prefs np on np.user_id = o.user_id
    where o.sent_at is null
      and o.attempts < c_max_attempts
      and np.push_enabled
      -- 急がない種類だけ、静かにする時間のあいだ待たせる
      and not (
        public._push_is_casual(o.type)
        and public._push_in_quiet_hours(np.push_quiet_from, np.push_quiet_to)
      )
      and exists (
        select 1 from public.push_subscriptions s
        where s.user_id = o.user_id and s.disabled_at is null
      )
    order by o.created_at
    limit p_limit
    for update of o skip locked
  ),
  bumped as (
    update public.push_outbox o
      set attempts = o.attempts + 1
      where o.id in (select id from picked)
      returning o.id, o.user_id, o.type, o.title, o.body, o.related_id
  )
  select b.id, s.endpoint, s.p256dh, s.auth,
         jsonb_build_object(
           'type', b.type,
           'title', b.title,
           'body', b.body,
           'relatedId', b.related_id,
           'notificationId', b.id
         )
  from bumped b
  join public.push_subscriptions s
    on s.user_id = b.user_id and s.disabled_at is null;
end;
$$;

comment on function public.claim_push_batch(int) is
  '送信待ちを端末ぶんに展開して取り出す。運営(Edge Function)専用。試行3回で諦める。';

revoke all on function public.claim_push_batch(int) from public;
grant execute on function public.claim_push_batch(int) to service_role;

/** 1件でも届いたら完了にする。0件なら次の回に再試行(3回で諦める)。 */
create or replace function public.mark_push_result(
  p_outbox_id uuid, p_delivered int, p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.push_outbox
    set sent_at = case when p_delivered > 0 then now() else sent_at end,
        last_error = left(p_error, 500)
    where id = p_outbox_id;
end;
$$;

revoke all on function public.mark_push_result(uuid, int, text) from public;
grant execute on function public.mark_push_result(uuid, int, text) to service_role;

/**
 * 配信元が404/410を返した購読を止める。**行は消さない。**
 * 消してしまうと、同じ端末から登録し直したときに履歴が切れて、
 * 「登録したのに来ない」を調べる手がかりが無くなる。
 */
create or replace function public.disable_push_subscription(p_endpoint text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.push_subscriptions
    set disabled_at = now(), fail_count = fail_count + 1
    where endpoint = p_endpoint;
end;
$$;

revoke all on function public.disable_push_subscription(text, text) from public;
grant execute on function public.disable_push_subscription(text, text) to service_role;

/**
 * 片付け。pg_cron から1日1回。
 *   ・送信済み/諦めた outbox を7日で消す
 *   ・積んだまま1日たった分を捨てる(登録が消えた等で送り先が無い)
 *   ・180日起動されていない購読を消す(端末を手放している)
 */
create or replace function public.prune_push()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int := 0;
  v_x int;
begin
  delete from public.push_outbox
    where sent_at is not null and sent_at < now() - interval '7 days';
  get diagnostics v_x = row_count;
  v_n := v_n + v_x;

  delete from public.push_outbox
    where sent_at is null and created_at < now() - interval '1 day';
  get diagnostics v_x = row_count;
  v_n := v_n + v_x;

  delete from public.push_subscriptions
    where last_seen_at < now() - interval '180 days';
  get diagnostics v_x = row_count;
  v_n := v_n + v_x;

  return v_n;
end;
$$;

revoke all on function public.prune_push() from public;

-- ------------------------------------------------------------
-- 自分の設定を読む/書く(設定画面用)
-- ------------------------------------------------------------
create or replace function public.my_push_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'enabled', coalesce((select np.push_enabled from public.notification_prefs np
                         where np.user_id = auth.uid()), true),
    'quietFrom', (select np.push_quiet_from from public.notification_prefs np
                  where np.user_id = auth.uid()),
    'quietTo', (select np.push_quiet_to from public.notification_prefs np
                where np.user_id = auth.uid()),
    'devices', coalesce((select count(*) from public.push_subscriptions s
                         where s.user_id = auth.uid() and s.disabled_at is null), 0)
  );
$$;

revoke all on function public.my_push_settings() from public;
grant execute on function public.my_push_settings() to authenticated;

create or replace function public.set_push_settings(
  p_enabled boolean, p_quiet_from int default null, p_quiet_to int default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  -- 片方だけ指定されたら「指定なし」に倒す(半端な状態を残さない)
  if p_quiet_from is null or p_quiet_to is null then
    p_quiet_from := null;
    p_quiet_to := null;
  end if;

  insert into public.notification_prefs (user_id, push_enabled, push_quiet_from, push_quiet_to)
  values (v_uid, coalesce(p_enabled, true), p_quiet_from::smallint, p_quiet_to::smallint)
  on conflict (user_id) do update
    set push_enabled = coalesce(p_enabled, true),
        push_quiet_from = p_quiet_from::smallint,
        push_quiet_to = p_quiet_to::smallint;
end;
$$;

revoke all on function public.set_push_settings(boolean, int, int) from public;
grant execute on function public.set_push_settings(boolean, int, int) to authenticated;
-- ============================================================
-- 0065_lock_down_function_grants.sql
-- 意図せず未ログインに開いていた関数を閉じる（セキュリティ修正）
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   PostgreSQL は **関数を作ると既定で PUBLIC に EXECUTE を与える。**
--   `revoke all ... from public` を書かなかった関数は、そのぶん
--   anon（未ログイン）からも呼べる状態になっていた。
--   RLS も権限も正しく張れていて、anon はどのテーブルも直接は読めない
--   （`grant` が1つも無い）のに、**SECURITY DEFINER 関数はそれを飛び越える**
--   ため、内部用の補助関数が抜け穴になっていた。
--
-- ■ 実際に未ログインで再現した2件
--
--   (1) `_booking_slot_conflict(user, 開始, 分)` — **他人の予定を丸ごと引ける**
--       指定した相手がその時間に予約を持っていれば予約IDを返す。
--       時刻をずらして繰り返せば、任意の相手の予約表が復元できる。
--       しかも相手のUUIDは `public_host_cards()`（未ログインで見える一覧）が
--       返しているので、**掲載中のピタメイト全員の稼働予定が外から読めた。**
--       このサービスで「誰がいつ誰と遊ぶか」は最も漏らしてはいけない情報で、
--       出会い系非該当の実態維持にも関わる。
--
--   (2) `_ledger_record_bypass(表, 操作, 旧, 新)` — **台帳に嘘を書ける**
--       0044 の追記専用台帳（`ledger_audit`）へ、引数そのままの行を差し込む。
--       未ログインで「payouts を 9,999,999 円に更新した」という記録を
--       作れてしまった。金銭トラブルの立証や税務で使う記録なので、
--       汚染されると価値が消える。無制限に積めるので保管費用にも響く。
--
--   どちらも「読めてしまう / 書けてしまう」だけで、正規の残高やコインを
--   動かせるものではない。だが (1) は個人情報の漏えい、(2) は証跡の汚染で、
--   どちらも公開前に閉じる必要がある。
--
-- ■ 方針
--   内部用の補助関数と、トリガー用の関数は **PUBLIC から取り上げる。**
--   これらは SECURITY DEFINER 関数の中から呼ばれるだけで、そのときは
--   定義者の権限で動くため、PUBLIC の EXECUTE は要らない。
--
--   未ログインに見せてよいもの（`public_host_cards` / `host_ranking` /
--   `host_repeat_guests` / `host_repeat_stats` など、掲載一覧に出す材料）は
--   そのまま残す。閉じると未ログインのトップが空になる。
--
-- ■ 同じ穴を二度作らないために
--   `supabase/tests/74_anon_surface.sql` で、**未ログインが実行できる
--   SECURITY DEFINER 関数の一覧を固定**した。関数を足して revoke を
--   忘れると、そのテストが落ちる。
-- ============================================================

-- ------------------------------------------------------------
-- (1) 他人の予定を引ける穴を閉じる
-- ------------------------------------------------------------
-- create_booking / approve_booking / extend_booking の中から呼ばれるだけ。
-- 呼び出し元が SECURITY DEFINER なので、そこでは定義者の権限で実行される。
revoke all on function
  public._booking_slot_conflict(uuid, timestamptz, int, uuid, text[]) from public;

-- 予約枠の排他ロック。外から取れると予約作成を妨害できる（DoS）
revoke all on function public._lock_booking_slots(uuid, uuid) from public;

-- ------------------------------------------------------------
-- (2) 台帳に嘘を書ける穴を閉じる
-- ------------------------------------------------------------
-- 0044 の各トリガーの中からだけ呼ばれる。誰にも grant しない。
revoke all on function public._ledger_record_bypass(text, text, jsonb, jsonb) from public;

-- ------------------------------------------------------------
-- 旧シグネチャの create_booking（3引数）
-- ------------------------------------------------------------
-- 中で4引数版に委ねており、そちらが auth.uid() を検査するので実害は無いが、
-- 未ログインに見せる理由も無い。クライアントは4引数版しか使っていない。
revoke all on function public.create_booking(uuid, int, text) from public;
grant execute on function public.create_booking(uuid, int, text) to authenticated;

-- ------------------------------------------------------------
-- トリガー用の関数
-- ------------------------------------------------------------
-- plpgsql のトリガー関数は直接呼ぶとエラーになるので実害は無い。
-- ただし「未ログインに開いている SECURITY DEFINER 関数」の一覧に紛れると、
-- 本当に危ないものを見落とす。監査できる状態を保つために閉じる。
revoke all on function public._apply_booking_fee() from public;
revoke all on function public._apply_gift_fee() from public;
revoke all on function public._checkin_on_message() from public;
revoke all on function public._consumption_restore_only() from public;
revoke all on function public._enqueue_push() from public;
revoke all on function public._hold_bookings_on_report() from public;
revoke all on function public._ledger_immutable() from public;
revoke all on function public._ledger_no_delete() from public;
revoke all on function public._payout_amount_immutable() from public;
revoke all on function public.check_host_requires_verification() from public;
revoke all on function public.clear_last_seen_on_hide() from public;
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user_notification_prefs() from public;
revoke all on function public.handle_new_user_wallet() from public;
revoke all on function public.notify_board_joined() from public;
revoke all on function public.notify_invite_approved() from public;
revoke all on function public.notify_invite_received() from public;
revoke all on function public.notify_message_received() from public;
revoke all on function public.reviews_after_insert_recompute() from public;
revoke all on function public.set_report_severity() from public;
revoke all on function public.set_updated_at() from public;

-- ------------------------------------------------------------
-- 内部計算用の関数
-- ------------------------------------------------------------
-- SECURITY DEFINER ではないので RLS は飛び越えないが、
-- 手数料や失効日の計算を外から叩けるようにしておく理由も無い。
revoke all on function public._push_is_casual(text) from public;
revoke all on function public._push_lockscreen_body(text, text) from public;
revoke all on function public._push_in_quiet_hours(smallint, smallint) from public;
revoke all on function public._ledger_override_on() from public;
revoke all on function public.host_progressive_fee(int) from public;
revoke all on function public.host_monthly_ticket_gmv(uuid, timestamptz, uuid) from public;
revoke all on function public.safety_fee_for(int) from public;
revoke all on function public.coin_expiry_from(timestamptz) from public;
revoke all on function public.is_valid_booking_duration(int) from public;
revoke all on function public.booking_refund_percent(text, timestamptz, timestamptz, timestamptz) from public;
revoke all on function public.booking_refund_coins(int, int, int, timestamptz, timestamptz) from public;
revoke all on function public.fresh_host_status(text, timestamptz) from public;
revoke all on function public.booking_fits_availability(uuid, timestamptz, int) from public;
-- 枠の判定はどちらも public_host_cards / create_booking の中から呼ばれるだけで、
-- クライアントは直接叩いていない。掲載一覧に必要な情報は
-- public_host_cards が返しているので、こちらは閉じる。
revoke all on function public.host_has_availability(uuid) from public;
revoke all on function public.host_is_open_at(uuid, timestamptz) from public;

-- ------------------------------------------------------------
-- 未ログインに残すもの（意図的）
-- ------------------------------------------------------------
-- 掲載中のピタメイト一覧・ランキングは未ログインでも見える設計（0052）。
-- 閉じるとトップページが空になる。返している内容は
-- 86_public_host_listing.sql で「未ログインに見せてよいか」を都度確認している。
--   public_host_cards(int)         … 一覧そのもの
--   host_ranking(text, int)        … ランキング（金額は含めない：弁護士Q11(d)）
--   host_repeat_guests(uuid)       … リピーター数（人数のみ。一覧にも出ている）
--   host_repeat_stats(uuid[])      … 同上を一括で
-- この4本はクライアントが実際に未ログインで呼んでいる。ほかは閉じてよい。
grant execute on function public.public_host_cards(int) to anon, authenticated;
grant execute on function public.host_ranking(text, int) to anon, authenticated;
grant execute on function public.host_repeat_guests(uuid) to anon, authenticated;
grant execute on function public.host_repeat_stats(uuid[]) to anon, authenticated;
-- ============================================================
-- 0066_admin_console.sql
-- 運営コンソール（管理画面）の読み取り口と、操作の記録
-- ------------------------------------------------------------
-- ■ 何が問題だったか
--   書き込み側のRPCは揃っているのに、**運営が「何が溜まっているか」を
--   アプリから見られなかった。** RLSは利用者本人に絞られているので、
--   運営でも `reports` / `payouts` / 保留中の `bookings` が読めない。
--   結果、次の作業がすべて Supabase の SQL Editor 送りになっていた。
--
--     ・通報の審査（`resolve_report`）
--     ・保留の解除（`release_hold_and_complete` / `_refund`）
--       — **その間ピタメイトの報酬が凍結されたままになる。**
--         0042 は14日の督促まで作ったのに、解除する画面が無かった
--     ・換金申請の処理（`mark_payout_paid` / `_failed`）
--       — 毎週日曜締め・翌週金曜払いという**締切のある作業**
--     ・開示・削除請求の処理（個人情報保護法の期限がある）
--     ・整合性チェックと台帳バックアップの確認
--
--   締切のある作業を毎回SQL Editorでやるのは、ワンオペではまず破綻する。
--   間違ったUPDATEを打てば台帳が壊れる。
--
-- ■ 追加するもの
--   (1) 読み取り口。**すべて管理者判定つき**で、返す列は作業に要るものだけ
--   (2) `admin_actions`。**誰がいつ何をしたかを残す。**
--       返金の承認・振込の消し込み・通報の処分は、後から
--       「誰の判断か」を説明できる必要がある（金銭トラブル・税務・弁護士対応）
--   (3) 既存の書き込みRPCの薄い包み。中身は複製せず、記録だけ足す
--
-- ■ 権限の考え方
--   `resolve_report` / `mark_payout_paid` / `mark_payout_failed` は
--   **中に管理者判定を持っていない**（service_role専用として revoke だけで
--   守られていた）。そのまま authenticated に開くと誰でも叩けてしまうので、
--   **判定を持つ包みを作り、開くのは包みだけ**にする。
--
-- ⚠️ 換金について: **弁護士の確認が済むまで実際の銀行振込は行わないこと。**
--    この画面は申請の確認とCSV出力までを担う。消し込み（振込済みにする）は
--    実際に振り込んだ後の記録なので、押す前に必ず入金を確認する。
-- ============================================================

-- ------------------------------------------------------------
-- 管理者判定（あちこちで同じ exists を書かないため）
-- ------------------------------------------------------------
create or replace function public._is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

revoke all on function public._is_admin() from public;

-- ------------------------------------------------------------
-- admin_actions: 運営の操作記録
-- ------------------------------------------------------------
create table if not exists public.admin_actions (
  id uuid primary key default gen_random_uuid(),
  -- 誰が。auth.users を消しても記録は残す（退会しても操作履歴は必要）
  actor uuid references auth.users (id) on delete set null,
  -- 何を。'resolve_report' / 'release_hold_complete' など
  kind text not null,
  -- 対象の行（通報ID・予約ID・換金申請IDなど）
  target_id uuid,
  note text,
  at timestamptz not null default now()
);

comment on table public.admin_actions is
  '運営が行った操作の記録。返金の承認・振込の消し込み・通報の処分は、後から「誰の判断か」を説明できる必要があるため残す。';

create index if not exists admin_actions_at_idx on public.admin_actions (at desc);

alter table public.admin_actions enable row level security;

drop policy if exists "admin_actions_select_admin" on public.admin_actions;
create policy "admin_actions_select_admin"
  on public.admin_actions for select
  to authenticated
  using (public._is_admin());

-- 書き込みポリシーは作らない。下の関数（SECURITY DEFINER）経由だけにして、
-- 記録を後から書き換えたり足したりできないようにする。

create or replace function public._log_admin_action(
  p_kind text, p_target uuid default null, p_note text default null
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.admin_actions (actor, kind, target_id, note)
  values (auth.uid(), p_kind, p_target, left(p_note, 500));
$$;

revoke all on function public._log_admin_action(text, uuid, text) from public;

-- ------------------------------------------------------------
-- ダッシュボード: いま何が溜まっているか
-- ------------------------------------------------------------
/**
 * 「今日やること」の件数だけを返す。**数だけで、中身は返さない。**
 * 一覧は個別のRPCで取る（開いた画面のぶんだけ読む）。
 */
create or replace function public.admin_console_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return jsonb_build_object(
    '未審査の本人確認', (select count(*) from public.identity_verifications where status = 'pending'),
    '未対応の通報', (select count(*) from public.reports where status = 'open'),
    -- 保留中はピタメイトの報酬が凍結されている。日数も出す（0042の督促は14日）
    '保留中の予約', (select count(*) from public.bookings where held_at is not null and status = 'confirmed'),
    '保留の最長日数', coalesce((select floor(extract(epoch from (now() - min(held_at))) / 86400)::int
                               from public.bookings where held_at is not null and status = 'confirmed'), 0),
    '未処理の換金申請', (select count(*) from public.payouts where status = 'pending'),
    '換金申請の合計コイン', coalesce((select sum(coins)::int from public.payouts where status = 'pending'), 0),
    '未処理の開示・削除請求', (select count(*) from public.account_requests where status <> 'completed'),
    -- 直近24時間の整合性チェックで warning/error が出ているか
    '整合性の警告', (select count(*) from public.integrity_checks
                     where ran_at > now() - interval '24 hours'
                       and severity in ('warning', 'error') and affected_count > 0),
    -- プッシュの滞留（送れていない分）
    'プッシュ送信待ち', (select count(*) from public.push_outbox where sent_at is null),
    'プッシュ諦めた件数', (select count(*) from public.push_outbox where sent_at is null and attempts >= 3),
    -- 台帳の外部バックアップが何時間前か（0047）
    '台帳バックアップ経過時間', (select floor(extract(epoch from (now() - max(ran_at))) / 3600)::int
                                 from public.ledger_exports where ok)
  );
end;
$$;

revoke all on function public.admin_console_summary() from public;
grant execute on function public.admin_console_summary() to authenticated;

-- ------------------------------------------------------------
-- 通報の一覧
-- ------------------------------------------------------------
/**
 * 未対応の通報。**メッセージのスナップショットも返す**（判断に必要）。
 * ニックネームは付けるが、メールアドレス等は返さない。
 * `message_snapshot` は jsonb（通報時の会話の抜粋がそのまま入っている）。
 */
create or replace function public.admin_reports(p_status text default 'open', p_limit int default 50)
returns table (
  id uuid,
  reporter_name text,
  reported_id uuid,
  reported_name text,
  category text,
  severity text,
  message_snapshot jsonb,
  status text,
  resolution text,
  created_at timestamptz,
  -- 相手のいまのマナースコアと通報の累計（常習かどうかの判断に使う）
  reported_manner numeric,
  reported_report_count int
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
  select r.id,
         coalesce(nullif(pr.nickname, ''), '(不明)'),
         r.reported_id,
         coalesce(nullif(pt.nickname, ''), '(不明)'),
         r.category,
         r.severity,
         r.message_snapshot,
         r.status,
         r.resolution,
         r.created_at,
         ts.manner_score,
         (select count(*)::int from public.reports r2 where r2.reported_id = r.reported_id)
  from public.reports r
  left join public.profiles pr on pr.id = r.reporter_id
  left join public.profiles pt on pt.id = r.reported_id
  left join public.profile_trust_stats ts on ts.user_id = r.reported_id
  where p_status = 'all' or r.status = p_status
  order by
    -- 重いものと古いものを上に
    case r.severity when 'high' then 0 when 'medium' then 1 else 2 end,
    r.created_at
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.admin_reports(text, int) from public;
grant execute on function public.admin_reports(text, int) to authenticated;

-- ------------------------------------------------------------
-- 保留中の予約
-- ------------------------------------------------------------
/**
 * 保留中の予約。**ここが放置されるとピタメイトの報酬が凍結され続ける。**
 * 何日経ったかを返し、画面で目立たせる（0042 の督促は14日）。
 */
create or replace function public.admin_held_bookings(p_limit int default 50)
returns table (
  id uuid,
  guest_id uuid,
  guest_name text,
  host_id uuid,
  host_name text,
  coins int,
  paid_coins int,
  duration_minutes int,
  scheduled_at timestamptz,
  held_at timestamptz,
  held_days int,
  hold_reason text,
  -- この予約に紐づく通報があるか（あれば通報の側も見る）
  report_count int
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
  select b.id,
         b.guest_id, coalesce(nullif(pg.nickname, ''), '(不明)'),
         b.host_id, coalesce(nullif(ph.nickname, ''), '(不明)'),
         b.coins, b.paid_coins, b.duration_minutes,
         b.scheduled_at, b.held_at,
         floor(extract(epoch from (now() - b.held_at)) / 86400)::int,
         b.hold_reason,
         (select count(*)::int from public.reports r
          where r.reporter_id in (b.guest_id, b.host_id)
            and r.reported_id in (b.guest_id, b.host_id)
            and r.created_at > b.scheduled_at - interval '1 day')
  from public.bookings b
  left join public.profiles pg on pg.id = b.guest_id
  left join public.profiles ph on ph.id = b.host_id
  where b.held_at is not null and b.status = 'confirmed'
  order by b.held_at  -- 古い順。放置しているものを上に
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.admin_held_bookings(int) from public;
grant execute on function public.admin_held_bookings(int) to authenticated;

-- ------------------------------------------------------------
-- 換金申請
-- ------------------------------------------------------------
/**
 * 未処理の換金申請。**口座情報を返す**（振込作業に必要）。
 *
 * ここはこのシステムでいちばん機微な情報を返す口なので、
 * **呼ばれたこと自体を admin_actions に残す。** 誰がいつ口座を見たかが
 * 分かるようにしておく（弁護士Q16/口座情報の取扱いに対応）。
 */
create or replace function public.admin_pending_payouts(p_limit int default 100)
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  coins int,
  amount_yen int,
  fee_yen int,
  created_at timestamptz,
  bank_name text,
  bank_code text,
  branch_name text,
  branch_code text,
  account_type text,
  account_number text,
  account_holder_kana text,
  is_verified boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*) into v_n from public.payouts p where p.status = 'pending';
  perform public._log_admin_action('view_pending_payouts', null, v_n || '件の口座情報を表示');

  return query
  select p.id, p.user_id,
         coalesce(nullif(pf.nickname, ''), '(不明)'),
         p.coins, p.amount_yen, p.fee_yen, p.created_at,
         p.bank_name, p.bank_code, p.branch_name, p.branch_code,
         p.account_type, p.account_number, p.account_holder_kana,
         coalesce(ts.is_verified, false)
  from public.payouts p
  left join public.profiles pf on pf.id = p.user_id
  left join public.profile_trust_stats ts on ts.user_id = p.user_id
  where p.status = 'pending'
  order by p.created_at
  limit greatest(1, least(p_limit, 500));
end;
$$;

revoke all on function public.admin_pending_payouts(int) from public;
grant execute on function public.admin_pending_payouts(int) to authenticated;

-- ------------------------------------------------------------
-- 開示・削除請求
-- ------------------------------------------------------------
create or replace function public.admin_account_requests(p_limit int default 50)
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  type text,
  status text,
  created_at timestamptz,
  waiting_days int
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
  select a.id, a.user_id,
         coalesce(nullif(pf.nickname, ''), '(不明)'),
         a.type, a.status, a.created_at,
         floor(extract(epoch from (now() - a.created_at)) / 86400)::int
  from public.account_requests a
  left join public.profiles pf on pf.id = a.user_id
  where a.status <> 'completed'
  order by a.created_at
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.admin_account_requests(int) from public;
grant execute on function public.admin_account_requests(int) to authenticated;

-- ------------------------------------------------------------
-- 整合性チェック・台帳バックアップ・プッシュの状況
-- ------------------------------------------------------------
/**
 * 直近の整合性チェック（0043）。**check_name ごとに最新1件だけ**返す。
 * 毎日走るので全件返すと古いものに埋もれる。
 */
create or replace function public.admin_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return jsonb_build_object(
    'integrity', coalesce((
      select jsonb_agg(x order by x->>'severity', x->>'check_name')
      from (
        select distinct on (c.check_name)
          jsonb_build_object(
            'check_name', c.check_name, 'severity', c.severity,
            'affected_count', c.affected_count, 'total_gap', c.total_gap,
            'ran_at', c.ran_at, 'detail', c.detail
          ) as x
        from public.integrity_checks c
        order by c.check_name, c.ran_at desc
      ) t
    ), '[]'::jsonb),
    'ledgerExport', (
      select jsonb_build_object('ran_at', l.ran_at, 'ok', l.ok,
                                'row_count', l.row_count, 'error', l.error)
      from public.ledger_exports l order by l.ran_at desc limit 1
    ),
    'push', jsonb_build_object(
      'pending', (select count(*) from public.push_outbox where sent_at is null),
      'givenUp', (select count(*) from public.push_outbox where sent_at is null and attempts >= 3),
      'devices', (select count(*) from public.push_subscriptions where disabled_at is null),
      'disabled', (select count(*) from public.push_subscriptions where disabled_at is not null),
      'lastError', (select o.last_error from public.push_outbox o
                    where o.last_error is not null order by o.created_at desc limit 1)
    )
  );
end;
$$;

revoke all on function public.admin_health() from public;
grant execute on function public.admin_health() to authenticated;

-- ------------------------------------------------------------
-- 操作の記録を見る
-- ------------------------------------------------------------
create or replace function public.admin_recent_actions(p_limit int default 50)
returns table (id uuid, actor_name text, kind text, target_id uuid, note text, at timestamptz)
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
  select a.id, coalesce(nullif(pf.nickname, ''), '(不明)'), a.kind, a.target_id, a.note, a.at
  from public.admin_actions a
  left join public.profiles pf on pf.id = a.actor
  order by a.at desc
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.admin_recent_actions(int) from public;
grant execute on function public.admin_recent_actions(int) to authenticated;

-- ============================================================
-- 書き込み側の包み
-- ------------------------------------------------------------
-- 中身は複製しない（複製すると片方だけ直して食い違う）。
-- 包みがやるのは「管理者判定」と「記録」の2つだけ。
-- ============================================================

/**
 * 通報の処分。
 * `resolve_report` は**中に管理者判定を持っていない**（service_role専用
 * だったため）。そのまま開くと誰でも他人の処分を書けるので、
 * **開くのはこの包みだけ**にする。
 */
create or replace function public.admin_resolve_report(
  p_report_id uuid,
  p_resolution text,
  p_status text default 'resolved',
  p_penalty_points numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_resolution is null or length(btrim(p_resolution)) = 0 then
    raise exception 'RESOLUTION_REQUIRED';  -- 理由の無い処分を残さない
  end if;

  perform public.resolve_report(p_report_id, p_resolution, p_status, p_penalty_points);
  perform public._log_admin_action('resolve_report', p_report_id,
    p_status || coalesce(' / 減点' || p_penalty_points, '') || ' / ' || p_resolution);
end;
$$;

revoke all on function public.admin_resolve_report(uuid, text, text, numeric) from public;
grant execute on function public.admin_resolve_report(uuid, text, text, numeric) to authenticated;

/** 保留を解いて確定（申し出を退ける）。判定は中の関数が持っているので記録だけ。 */
create or replace function public.admin_release_hold_complete(p_booking_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.release_hold_and_complete(p_booking_id, p_note);
  perform public._log_admin_action('release_hold_complete', p_booking_id, p_note);
end;
$$;

revoke all on function public.admin_release_hold_complete(uuid, text) from public;
grant execute on function public.admin_release_hold_complete(uuid, text) to authenticated;

/** 保留を解いて返還。**割合を記録に残す**（後から「なぜ50%か」を説明できるように）。 */
create or replace function public.admin_release_hold_refund(
  p_booking_id uuid, p_refund_percent int, p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.release_hold_and_refund(p_booking_id, p_refund_percent, p_note);
  perform public._log_admin_action('release_hold_refund', p_booking_id,
    p_refund_percent || '%返還 / ' || coalesce(p_note, '(理由なし)'));
end;
$$;

revoke all on function public.admin_release_hold_refund(uuid, int, text) from public;
grant execute on function public.admin_release_hold_refund(uuid, int, text) to authenticated;

/**
 * 振込の消し込み。
 * ⚠️ **実際に振り込んだ後にだけ押すもの。** 押すと申請が「振込済み」になり、
 *    ピタメイトのウォレットからは引かれたままになる。取り消す手立ては無い。
 * `mark_payout_paid` も中に管理者判定が無いので、ここで判定する。
 */
create or replace function public.admin_mark_payout_paid(p_payout_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_p public.payouts;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  select * into v_p from public.payouts where id = p_payout_id;
  if v_p.id is null then raise exception 'PAYOUT_NOT_FOUND'; end if;
  if v_p.status <> 'pending' then raise exception 'PAYOUT_NOT_PENDING'; end if;

  perform public.mark_payout_paid(p_payout_id);
  perform public._log_admin_action('mark_payout_paid', p_payout_id,
    v_p.amount_yen || '円 / ' || coalesce(p_note, ''));
end;
$$;

revoke all on function public.admin_mark_payout_paid(uuid, text) from public;
grant execute on function public.admin_mark_payout_paid(uuid, text) to authenticated;

/** 振込の失敗。申請コインは全額戻る（手数料も含む。0014）。 */
create or replace function public.admin_mark_payout_failed(p_payout_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'REASON_REQUIRED';  -- 何が起きたか分からない失敗を残さない
  end if;

  perform public.mark_payout_failed(p_payout_id, p_reason);
  perform public._log_admin_action('mark_payout_failed', p_payout_id, p_reason);
end;
$$;

revoke all on function public.admin_mark_payout_failed(uuid, text) from public;
grant execute on function public.admin_mark_payout_failed(uuid, text) to authenticated;

/**
 * 開示・削除請求の状態を進める。
 * **削除請求で実際に匿名化するのは `anonymize_user()`（0046）の側。**
 * ここは「対応した」という記録だけで、データは消さない。
 * 取り違えると復旧できないので、混ぜない。
 */
create or replace function public.admin_set_account_request_status(p_request_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_status not in ('pending', 'processing', 'completed') then
    raise exception 'INVALID_STATUS';
  end if;

  update public.account_requests set status = p_status where id = p_request_id;
  perform public._log_admin_action('account_request_' || p_status, p_request_id, null);
end;
$$;

revoke all on function public.admin_set_account_request_status(uuid, text) from public;
grant execute on function public.admin_set_account_request_status(uuid, text) to authenticated;
-- ============================================================
-- 0067: 「推し」という言い方をやめて「お気に入り」に統一する
-- ============================================================
-- 利用者に見せる言葉を「お気に入り」に統一した(画面・通知・説明文)。
-- DBの中身は変わらないが、`comment on` に残っている説明文だけが
-- 「推し」のままだと、あとからスキーマを読んだ人が古い言い方を
-- 復活させてしまう。**言葉のゆれは、実装のゆれになる。**
--
-- ここで変えるのはコメント(メタデータ)だけ。テーブル・関数・
-- ポリシー・権限には一切触れない。0053/0054/0056 のファイル側も
-- 同じ文言に直してあるので、新しく作ったDBとこの移行を当てた
-- DBのコメントは一致する。
--
-- 通知の本文は 0054 の時点から
-- 「<名前>さんが枠を開けました」で、「推し」を含んでいない。
-- つまり利用者に届く文面を変える必要はない。
-- ============================================================

comment on table public.favorites is
  'お気に入り登録。誰が誰をお気に入りにしているかは本人以外に見えない。お気に入りにされた側には人数のみ返す。';

comment on function public.set_favorite(uuid, boolean) is
  'お気に入り登録の追加(p_on=true)と解除(false)。ブロック関係があると登録できない。';

comment on function public.my_favorites() is
  '自分がお気に入りに入れているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からない)。0056でひとことを追加。';

comment on function public.my_favorite_count() is
  '自分をお気に入りに入れている人数。誰かは返さない(お気に入りに入れた側の行動を相手に知らせない)。';

comment on column public.host_settings.slots_notified_at is
  'お気に入りに入れている人へ「枠を開けました」を最後に送った時刻。24時間に1回までに絞るために使う。';

comment on function public.set_host_availability(jsonb) is
  '週間の募集枠を丸ごと入れ替える。0054で、枠が増えたときにお気に入りに入れているファンへ通知する(24時間に1回まで・増えた分のみ)。';
-- ============================================================
-- 0068: 管理操作の記録漏れをふさぐ(弁護士指摘7)
-- ------------------------------------------------------------
-- 弁護士から、管理画面について
--   「本人確認情報・口座情報・メッセージへのアクセス権限の範囲と
--     操作ログの有無を、プライバシーポリシーの安全管理措置の記載と
--     矛盾しない状態にしておくこと」
-- という指摘を受けた。棚卸ししたところ、0066で入れた記録には2つ穴があった。
--
--   ・**本人確認の承認/却下**(0007/0008/0012 で作った関数)は 0066 より前から
--     あるため、`_log_admin_action` を呼んでいない。**本人確認は最も機微な
--     情報の判断**なのに、誰がいつ承認したかが残っていない。
--   ・**admin_reports** は `message_snapshot`(通報されたメッセージの中身)を
--     返すのに、閲覧の記録を残していない。口座情報の閲覧
--     (admin_pending_payouts)は記録しているので、扱いが揃っていない。
--
-- ここで揃える方針: **機微な情報を「見た」ことと、身分に関わる「判断」を
-- 記録する。** 0066で入れた書き込み系のログと同じ `admin_actions` に入れる。
-- テーブルには書き込みポリシーが無く、service_role でしか挿せないため、
-- 記録そのものを利用者・運営者が偽造できない(0066の設計)。
--
-- ■ できないことも書いておく(実装できない旨を正直に残す)
--   本人確認の**一覧**(審査待ちキュー)は、画面が `identity_verifications` を
--   RLSごしに直接 select している。PostgreSQL に SELECT トリガは無いため、
--   一覧を「見た」こと自体はSQL側では記録できない。記録できるのは
--   **承認/却下という判断**まで。ここは運用(単独運営)で補う前提とし、
--   将来 RPC 経由の一覧に変えるときに記録を足せるようにしておく。
--
-- 機能は変えない。**戻り値・引数・権限は一切変更していない。**
-- ============================================================

-- ------------------------------------------------------------
-- 1. 本人確認の承認/却下に記録を足す
-- ------------------------------------------------------------
-- 本体のロジックは 0012 のものと同一。末尾に記録を1行足しただけ。
create or replace function public.approve_identity_verification(p_verification_id uuid, p_is_adult boolean default true)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'verified', is_adult = p_is_adult, verified_at = now()
    where id = p_verification_id;

  update public.profile_trust_stats
    set is_verified = true, updated_at = now()
    where user_id = v_row.user_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_row.user_id, 'verification_approved', '本人確認が完了しました', 'プロフィールに確認済みバッジが表示されます', p_verification_id);

  -- 0068: 誰がいつ承認したかを残す。対象は申請ではなく**本人**にする
  -- (あとから「この人の本人確認は誰が通したか」で辿れるようにするため)。
  perform public._log_admin_action(
    'approve_identity_verification', v_row.user_id,
    case when p_is_adult then '成人として承認' else '成人でないとして承認' end);
end;
$$;

create or replace function public.reject_identity_verification(p_verification_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.identity_verifications;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_row from public.identity_verifications where id = p_verification_id;
  if v_row.id is null then
    raise exception 'VERIFICATION_NOT_FOUND';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'VERIFICATION_NOT_PENDING';
  end if;

  update public.identity_verifications
    set status = 'rejected', rejected_reason = p_reason
    where id = p_verification_id;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_row.user_id, 'verification_rejected', '本人確認が承認されませんでした', '書類・写真を選び直して再提出してください', p_verification_id);

  perform public._log_admin_action('reject_identity_verification', v_row.user_id, p_reason);
end;
$$;

revoke all on function public.approve_identity_verification(uuid, boolean) from public;
revoke all on function public.reject_identity_verification(uuid, text) from public;
grant execute on function public.approve_identity_verification(uuid, boolean) to authenticated;
grant execute on function public.reject_identity_verification(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 2. 通報の閲覧に記録を足す(メッセージの中身を返すため)
-- ------------------------------------------------------------
-- `stable` を外して volatile にする。記録(insert)を行うため。
-- **戻り値と引数は 0066 と同一**なので、画面side の変更は要らない。
--
-- 口座情報の閲覧(admin_pending_payouts)と同じ粒度に揃える:
-- 1件ずつではなく「何件見たか」を1行残す。誰の通報かは reports 側に
-- 残っているので、ここで対象IDを列挙する必要はない。
create or replace function public.admin_reports(p_status text default 'open', p_limit int default 50)
returns table (
  id uuid,
  reporter_name text,
  reported_id uuid,
  reported_name text,
  category text,
  severity text,
  message_snapshot jsonb,
  status text,
  resolution text,
  created_at timestamptz,
  reported_manner numeric,
  reported_report_count int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  -- 0068: メッセージの中身(message_snapshot)を見たことを記録する。
  -- 返す件数を先に数えてから記録し、そのあと同じ条件で返す。
  select count(*)::int into v_n
  from public.reports r
  where p_status = 'all' or r.status = p_status;

  perform public._log_admin_action(
    'view_reports', null,
    'status=' || coalesce(p_status, 'open') || ' / 該当' || v_n || '件を表示(メッセージの中身を含む)');

  return query
  select r.id,
         coalesce(nullif(pr.nickname, ''), '(不明)'),
         r.reported_id,
         coalesce(nullif(pt.nickname, ''), '(不明)'),
         r.category,
         r.severity,
         r.message_snapshot,
         r.status,
         r.resolution,
         r.created_at,
         ts.manner_score,
         (select count(*)::int from public.reports r2 where r2.reported_id = r.reported_id)
  from public.reports r
  left join public.profiles pr on pr.id = r.reporter_id
  left join public.profiles pt on pt.id = r.reported_id
  left join public.profile_trust_stats ts on ts.user_id = r.reported_id
  where p_status = 'all' or r.status = p_status
  order by
    case r.severity when 'high' then 0 when 'medium' then 1 else 2 end,
    r.created_at
  limit greatest(1, least(p_limit, 200));
end;
$$;

revoke all on function public.admin_reports(text, int) from public;
grant execute on function public.admin_reports(text, int) to authenticated;
-- ============================================================
-- 0069: ギフトの7日換金保留を復活させる(0063で消えていた)
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   0020 で `request_bank_payout` に「**受領から7日以内のギフトは換金保留**」を
--   入れた(マネー・ローンダリング / クレジットカード現金化の対策)。
--   ところが 0063(最低換金額を1,000→5,000に変えた移行)が、**0020ではなく
--   0014 の本文をベースに `create or replace` してしまい、保留のロジックが
--   まるごと消えた。** 関数は正常に動くので気づけず、テストも無かった。
--
-- ■ なぜ重大か
--   この保留は、単なる機能ではなく**対外的に説明している統制**である。
--     ・利用規約 第7条の2第5号「受領日から7日間は換金できない保留期間を設けます」
--     ・弁護士への説明(Q11-c)で、換金ロンダリング対策の一つとして挙げている
--   つまり「規約に書いてあるのに実装されていない」状態だった。
--   条文と実装の食い違いは、それ自体が説明責任の問題になる。
--
-- ■ ここで直すこと
--   0063 の内容(手数料300・最低5,000コイン)は維持したうえで、
--   0020 の保留ロジックを戻す。**両方が入った状態が正しい。**
--
--   ・換金可能額 = 報酬コイン残高 − 直近7日に受領したギフトの合計
--   ・保留のせいで足りない場合は `GIFT_ON_HOLD` を返す
--     (残高不足 `INSUFFICIENT_EARNED_BALANCE` と区別する。利用者に
--      「あと何日待てばよいか」を案内できるようにするため)
--
-- ■ 再発防止
--   `supabase/tests/89_gift_legal_invariants.sql` を追加した。
--   保留の境界を両側から確かめる(保留分を含む額は弾かれ、
--   換金可能額ちょうどは通る)ので、次に誰かが同じ消し方をすれば落ちる。
-- ============================================================

create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 振込手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';
  v_available := coalesce(v_balance, 0) - v_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、そう伝える
    if v_hold > 0 and p_coins <= coalesce(v_balance, 0) then
      raise exception 'GIFT_ON_HOLD';
    end if;
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(int) is
  '報酬コインの換金申請。最低5,000コイン・手数料300コイン。直近7日に受領したギフトは換金保留(0069で0063から復活)。';

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;
-- ============================================================
-- 0070: 月次の残高照合と、将来のインボイス対応の下地
-- ------------------------------------------------------------
-- 税理士の回答(2026-07-30)§6-1 より:
--   「設計の要は、補助元帳の残高とシステム上のコイン残高を毎月末に
--     照合すること。『前受金(コイン)の帳簿残高 ＝ DB上の未使用コイン総数
--     (円換算)』が一致することを月次で証跡化してください。これは会計目的
--     だけでなく、**資金決済法上の分別管理の説明資料**にもなり、弁護士側の
--     推奨事項にも同時に応えます。」
--
-- 0043 の整合チェックは**利用者ごとの不一致**を探すもので、
-- 記帳に必要な**会社全体の残高**は出せない。ここで足す。
--
-- ■ 勘定科目との対応(税理士の提示した勘定設計に合わせている)
--   前受金(コイン)        … 未使用の**有償**コイン。1コイン=1円
--   前受金(予約エスクロー) … 予約成立済み・完了未確定のコイン
--   預り金(ホスト報酬)     … 確定済み・未換金の報酬コイン
--   未払金(換金申請中)     … 換金申請済み・未振込
--
-- ■ **無償コイン(ボーナス)は前受金に入れない。**
--   現金を受け取っていないので負債ではない。ただし利用者は使えるので、
--   「将来の値引き原資」として**別建てで参考表示**する。ここを混ぜると
--   前受金残高が現金と合わなくなり、分別管理の説明が崩れる。
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 会計用の残高サマリー(運営のみ)
-- ------------------------------------------------------------
create or replace function public.accounting_balances()
returns table (
  区分 text,
  勘定科目 text,
  金額円 bigint,
  備考 text
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
  -- 未使用の有償コイン = 前受金。現金を受け取っている分だけを負債に立てる
  select '負債'::text, '前受金(コイン)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '未使用の有償コイン。1コイン=1円。分別口座の残高と対応させる'::text
  from public.coin_lots l
  where l.kind = 'paid' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 予約成立済み・完了未確定 = まだ誰の収益にもなっていない
  select '負債'::text, '前受金(予約エスクロー)'::text,
         coalesce(sum(b.coins), 0)::bigint,
         '予約成立済み・プレイ完了未確定。確定時に利用料と報酬に分かれる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')

  union all
  -- 確定済み・未換金のホスト報酬 = 預り金
  select '負債'::text, '預り金(ホスト報酬)'::text,
         coalesce(sum(w.earned_balance), 0)::bigint,
         '確定済み・未換金の報酬コイン。**失効しない**(0018)'::text
  from public.coin_wallets w

  union all
  -- 換金申請済み・未振込 = 未払金(振込額と手数料を分けて持つ)
  select '負債'::text, '未払金(換金申請中)'::text,
         coalesce(sum(p.amount_yen), 0)::bigint,
         '換金申請済み・未振込の振込予定額(手数料控除後)'::text
  from public.payouts p
  where p.status = 'pending'

  union all
  -- ここから下は負債ではない参考値
  select '参考'::text, '無償コイン残(ボーナス)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '**前受金に含めない**(現金を受け取っていない)。将来の値引き原資'::text
  from public.coin_lots l
  where l.kind = 'bonus' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 期限切れで未処理のロット。ここが0でないと失効処理が追いついていない
  select '要確認'::text, '期限切れ・失効処理待ち'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '0でなければ expire_coins() が動いていない。雑収入の計上漏れになる'::text
  from public.coin_lots l
  where l.remaining > 0 and l.expires_at <= now();
end;
$$;

comment on function public.accounting_balances() is
  '月次の記帳・照合用の残高サマリー(運営のみ)。税理士の勘定設計に対応。読み取りのみ。';

revoke all on function public.accounting_balances() from public;
grant execute on function public.accounting_balances() to authenticated;

-- ------------------------------------------------------------
-- 2. 期間の損益サマリー(運営のみ)
-- ------------------------------------------------------------
-- 税理士の指摘 §1-2: 手数料の計上時期は「コイン消費時」ではなく
-- **「プレイ完了確定時」**(権利確定主義・所得税法36条1項)。
-- platform_fees は完了確定時に記録されるので、その期間合計を出せば
-- そのまま売上になる。あわせて、一覧から漏れていた
-- **換金手数料(§2-3 ④)**と**コイン失効益**も出す。
create or replace function public.accounting_revenue(p_from date, p_to date)
returns table (
  区分 text,
  科目 text,
  金額円 bigint,
  消費税 text
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
  -- プラットフォーム利用料(予約) … 完了確定時に platform_fees へ記録される
  select '売上'::text, 'PF利用料(予約)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'booking'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  select '売上'::text, 'PF利用料(ギフト)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'gift'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  -- あんしんサポート料。購入時に売上計上する(税理士 §1-4)。0071で「あんしん保証料」から改称
  select '売上'::text, 'あんしんサポート料(購入時)'::text,
         coalesce(sum(cp.safety_fee_yen), 0)::bigint, '課税10%'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- 換金手数料。**当初の資料で漏れていた課税売上**(税理士 §2-3 ④)
  select '売上'::text, '換金手数料'::text,
         coalesce(sum(p.fee_yen), 0)::bigint, '課税10%'::text
  from public.payouts p
  where p.status = 'paid'
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all
  -- コイン失効益。不課税(対価性がない)
  select '雑収入'::text, 'コイン失効益'::text,
         coalesce(-sum(t.amount), 0)::bigint, '不課税'::text
  from public.coin_transactions t
  where t.type = 'expire'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- 参考: 期間中のコイン販売額。**売上ではない**(前受金)
  select '参考(売上でない)'::text, 'コイン販売額(前受金の増加)'::text,
         coalesce(sum(cp.price_yen), 0)::bigint, '不課税'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1);
end;
$$;

comment on function public.accounting_revenue(date, date) is
  '期間の売上サマリー(運営のみ)。手数料は完了確定時ベース。換金手数料と失効益を含む。コイン販売額は前受金なので参考表示。';

revoke all on function public.accounting_revenue(date, date) from public;
grant execute on function public.accounting_revenue(date, date) to authenticated;

-- ------------------------------------------------------------
-- 3. ホストごとの年間支払額(税理士 §4・§5-1)
-- ------------------------------------------------------------
-- 支払調書の提出義務は無い見込み(6号非該当)。ただし税理士の指摘どおり
-- 「**提出義務がないことと、記録を残さなくてよいことは別**」であり、
-- 国税通則法74条の7の2の情報照会に応じられる状態を保つ必要がある。
-- 「ホストごとの年間支払額を随時出力できる状態を常に保ってください」。
create or replace function public.accounting_host_payments(p_year int)
returns table (
  user_id uuid,
  nickname text,
  件数 int,
  支払額円 bigint,
  手数料円 bigint,
  最終支払日 timestamptz
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
  select p.user_id,
         coalesce(nullif(pr.nickname, ''), '(不明)'),
         count(*)::int,
         coalesce(sum(p.amount_yen), 0)::bigint,
         coalesce(sum(p.fee_yen), 0)::bigint,
         max(p.paid_at)
  from public.payouts p
  left join public.profiles pr on pr.id = p.user_id
  where p.status = 'paid'
    and p.paid_at >= make_date(p_year, 1, 1)
    and p.paid_at < make_date(p_year + 1, 1, 1)
  group by p.user_id, pr.nickname
  order by sum(p.amount_yen) desc;
end;
$$;

comment on function public.accounting_host_payments(int) is
  'ホストごとの年間支払額(運営のみ)。支払調書の義務は無い見込みだが、税務照会に応じられる状態を保つために持つ。';

revoke all on function public.accounting_host_payments(int) from public;
grant execute on function public.accounting_host_payments(int) to authenticated;

-- ------------------------------------------------------------
-- 4. 将来のインボイス対応の下地(列だけ用意する)
-- ------------------------------------------------------------
-- 税理士の指摘 §2-4:
--   「将来、当社が登録し、かつ課税事業者のホストが一定数を超えた段階で、
--     ホストから登録番号を収集し、当社が一括して適格請求書を発行する
--     仕組み(媒介者交付特例)として検討価値があります。システム改修が
--     必要になる論点なので、**DB設計の段階で「ホストの登録番号を持てる
--     列」だけは用意しておくと後が楽**です。」
--
-- いま使う予定はない。**画面も作らない。**列だけ置いておく。
-- 形式は「T + 13桁」。null を既定にし、入力を強制しない。
alter table public.host_settings
  add column if not exists invoice_registration_number text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'host_settings_invoice_number_format'
  ) then
    alter table public.host_settings
      add constraint host_settings_invoice_number_format
      check (invoice_registration_number is null
             or invoice_registration_number ~ '^T[0-9]{13}$');
  end if;
end $$;

comment on column public.host_settings.invoice_registration_number is
  '適格請求書発行事業者の登録番号(T+13桁)。将来の媒介者交付特例に備えた予約列で、現時点では未使用・画面も無い。';
-- ============================================================
-- 0071: 「あんしん保証料」→「あんしんサポート料」に改称
-- ------------------------------------------------------------
-- ■ なぜ変えるか(税理士・弁護士の**双方**から指摘)
--
--   税理士(2026-07-30 回答 §1-4):
--     消費税法別表第二第3号・施行令10条3項により「**信用の保証**としての
--     役務の提供」の対価(=保証料)は**非課税**とされている。当社が受け取る
--     のは本人確認・みまもり・トラブル対応という**課税される役務**の対価
--     なので、「保証料」という名称は**名称と実態が食い違い、税務調査で
--     必ず論点になる。** 自ら誤って非課税処理をする事故も起こり得る。
--
--   弁護士(Q20-b):
--     「保証」は**損害を補填する約束と誤認**されるおそれがある。
--     実際には補償しないのに補償を期待させるため景表法の観点でも問題。
--
--   → 2026-07-30、利用者に見せる名称を「**あんしんサポート料**」に統一した。
--
-- ■ 変えないもの
--   **料率(5%)・金額・計算・徴収のしかたは一切変えていない。**
--   識別子(`safety_fee_rate` / `safety_fee_yen` / `safety_fee_for`)も
--   そのままにする。英語の "safety fee" は「保証」の語義を持たないので
--   今回の問題を含まず、列名・関数名を変えると Edge Function・型定義・
--   既存データの参照まで波及して、得るものがない。
--
-- ■ ここで変えるのはDBのコメント(メタデータ)だけ
--   0035 のファイル側も新名称に直してあるが、**すでに適用済みのDBには
--   古い名称のコメントが残る。** 言葉のゆれは実装のゆれになるので、
--   0067(推し→お気に入り)と同じやり方で当て直す。
--   テーブル・関数・ポリシー・権限・数値には触れない。
-- ============================================================

comment on table public.platform_pricing is
  'プラットフォームの価格設定(1行のみ)。あんしんサポート料の率など、改定しうる数値をここに集約する。';

comment on column public.coin_purchases.safety_fee_yen is
  'コイン代金に上乗せして預かったあんしんサポート料(円)。price_yen はコイン本体の価格で、請求総額は price_yen + safety_fee_yen。0071で「あんしん保証料」から改称(名称のみ。料率・計算は不変)。';

comment on function public.safety_fee_for(int) is
  'コイン価格に対するあんしんサポート料(円)。料率は platform_pricing に持つ。0071で「あんしん保証料」から改称。';
-- ============================================================
-- 0072: 検収期間の短縮設定を、既存の予約に遡って効かせない
-- ------------------------------------------------------------
-- ■ 弁護士の指摘(2026-07-30 回答 Q28)
--   「短縮設定の変更は既存の進行中予約には及ばず、**変更後に成立した予約に
--     適用される**旨を条文に明記してください。**遡って検収期間が縮むのは
--     利用者の不利益変更で、10条の議論を自ら招きます。**」
--
-- ■ 何が問題だったか
--   0062 は「判定を自動確定の実行時に読む」設計にしていた。外したときに
--   すぐ72時間へ戻る(利用者に有利)ことを狙ったものだが、**裏返しとして
--   設定をONにした瞬間、すでに進行中の予約の検収期間も縮んでいた。**
--   ゲストが自分で選んだ設定であっても、「予約したときの条件」が後から
--   短くなるのは不利益変更で、消費者契約法10条の議論を招く。
--
-- ■ 直し方
--   `fast_release_prefs.created_at` は設定・変更のたびに now() で更新される
--   (0062 の on conflict で created_at も更新している)ため、**「予約が
--   成立した時点で、その設定がすでに有効だったか」**をこれで判定できる。
--
--     設定の時刻 <= 予約の成立時刻  → 短縮を適用する
--     設定の時刻 >  予約の成立時刻  → 適用しない(既定の72時間)
--
--   これで:
--     ・ONにしても、**すでにある予約は72時間のまま**(不利益の遡及が消える)
--     ・24h→48h のように**延ばす変更**も、その時点で created_at が更新される
--       ので既存予約には及ばない(=72時間のまま。利用者に不利にならない)
--     ・**外した(行を消した)ときは即座に72時間へ戻る**(行が無いので
--       coalesce で既定値になる)。有利な方向は従来どおり即時
--
-- ■ 変えていないもの
--   下限24時間・3回以上遊んだ相手のみ・ゲストしか設定できない・保留(held_at)
--   優先、はすべて0062のまま。**関数の引数・戻り値も変えていない。**
-- ============================================================

create or replace function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_default_hours constant int := 72;
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select b.id, b.host_id, b.coins
    from public.bookings b
    where b.status = 'confirmed'
      -- 保留(通報・申し出)は従来どおり優先。短くしても確定しない
      and b.held_at is null
      -- 相関副問い合わせで引くこと。left join にすると
      -- 「FOR UPDATE cannot be applied to the nullable side of an outer join」で落ちる。
      and b.scheduled_at
          + make_interval(mins => b.duration_minutes)
          + make_interval(hours => coalesce(
              (select f.hours from public.fast_release_prefs f
               where f.guest_id = b.guest_id and f.host_id = b.host_id
                 -- 0072: **予約が成立した時点で有効だった設定にだけ従う。**
                 -- あとから短くしても、すでにある予約の検収期間は縮まない
                 -- (消費者契約法10条。弁護士Q28)。
                 and f.created_at <= b.created_at),
              c_default_hours)) < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  '終了から一定時間が過ぎた予約を自動確定する。既定72時間。ゲストが相手ごとに短縮できる(0062)が、0072で「予約成立時点で有効だった設定にだけ従う」ようにした(不利益の遡及を避ける)。';

revoke all on function public.auto_complete_bookings() from public;

comment on column public.fast_release_prefs.created_at is
  'この設定を最後に変更した時刻。0072で、予約成立時点でこの設定が有効だったかの判定に使う(設定・変更のたびに更新される)。';
-- ============================================================
-- 0073: 手数料の率を画面に出せるようにする
-- ------------------------------------------------------------
-- ■ なぜ必要か(条文と実装の食い違いを埋める)
--   弁護士の回答(Q22-a)に従い、可変性の高い料率の表を利用規約の本文から
--   外出しし、代わりに 第8条の2第3項に
--     「**具体的な率は本サービス上に表示します**」
--   と書いた。ところが**画面に料率を表示する仕組みが無かった。**
--   つまり条文が実装より進んでいる = 守れない約束を作ってしまっていた
--   (規約↔実装の突合表 G2。docs/legal/terms-implementation-matrix.md)。
--
--   弁護士:「条文が実装より進んでいる状態(＝守れない約束)は、施行後は
--            端的に債務不履行になります」
--
-- ■ 何を返すか
--   率は3か所に散らばっている:
--     ・段階制の率      … host_fee_tiers テーブル(0033)
--     ・リピート割引と下限 … _host_fee_for() の中の定数(0033)
--     ・ギフトの率      … _apply_gift_fee() の中の定数(0063で35%)
--   画面から3か所を別々に読むのは間違いのもとなので、**表示用の1つの口**に
--   まとめる。数値の権威は従来どおり各実装側に置き、ここは読み取り専用。
--
--   ⚠️ **定数を変えたらこの関数も直すこと。** 関数の中で同じ値を持って
--   いるため、ずれると画面の表示と実際の控除額が食い違う。
--   (テーブルに出すのが本来だが、率の変更は稀で、変更時は
--    「30日前の通知」「変更前に成立した予約には旧料率」の対応が必要になる
--    ため、いずれにせよ移行を書くことになる。そのときに揃える。)
--
-- ■ 誰が読めるか
--   **未ログインでも読める。** 手数料は「ピタメイトになるかどうか」を
--   判断する材料で、登録前に見えないと意味がない。
--   個人情報は含まないので anon に開放してよい。
-- ============================================================

create or replace function public.fee_rates()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    -- 予約の段階制。上限が null の段は「それ以上」
    'bookingTiers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'upperBound', t.upper_bound,
               'percent', round(t.rate * 100, 1)
             ) order by t.step), '[]'::jsonb)
      from public.host_fee_tiers t
    ),
    -- 同一ゲストからの2回目以降の引き下げ(pt)と、引き下げ後の下限
    'repeatDiscountPoints', 3,
    'floorPercent', 10,
    -- ありがとうギフトは一律(0063で30%から35%へ)
    'giftPercent', 35
  );
$$;

comment on function public.fee_rates() is
  '手数料の率(表示用)。規約 第8条の2第3項「具体的な率は本サービス上に表示します」を満たすための読み取り口。数値の権威は host_fee_tiers と各計算関数の定数にあり、変更時はここも揃えること。';

revoke all on function public.fee_rates() from public;
grant execute on function public.fee_rates() to anon, authenticated;
-- ============================================================
-- 0074: みまもり同意の撤回に実際の効果を持たせる(E-5)
-- ------------------------------------------------------------
-- ■ 経緯
--   0031 で同意の記録と撤回のRPCを用意したが、そこには
--     「撤回時のサービス提供の可否は運用・規約側の論点(Q19)。
--       ここでは記録のみを行い、機能の制限はしない。」
--   と書いてあるとおり、**撤回しても何も起きない**器だけの状態だった。
--   撤回条項をどう書くかが未確定で、どちらに倒すかで実装が変わるためである。
--
--   2026-07-30 の弁護士回答(Q16)で文言が確定した:
--
--     > ユーザーは、前項の同意を設定画面からいつでも撤回することができます。
--     > ただし、本項の確認は本サービスにおける安全確保の基盤であるため、
--     > 撤回された場合、当社はメッセージ機能その他の利用者間のやりとりに
--     > 関する機能の提供を停止します。この場合も、既に成立した予約の履行
--     > および換金の手続については、本規約の定めに従います。
--
--   理由(Q16):「撤回できるが撤回すれば退会」では任意性が空文化するが、
--   「撤回すれば当該機能が使えなくなる」は同意の対象と帰結が論理的に
--   対応している(= **監視できない通信は提供しない**)。
--
-- ■ なぜ相手側も止まるのか(Q19)
--   メッセージは**送信者と受信者の双方の通信**であるため、有効な同意は
--   両当事者から得られている必要がある。撤回者が現れた瞬間、その相手との
--   通信は「片方が未同意」になる。したがって撤回は本人の送信を止めるだけでは
--   足りず、**撤回者を相手とするやりとりを双方向で止める**必要がある。
--   これはQ19が「Q16の撤回条項を機能単位にすべき論理的な根拠そのもの」と
--   述べている点の実装である。
--
-- ■ 何を止め、何を止めないか
--   止める(= 新しく「やりとり」を発生させる操作):
--     ・メッセージの送信          … messages への insert(双方向)
--     ・誘いの送信・受領          … invites への insert(双方向)
--     ・募集の投稿・参加          … board_posts / board_participants への insert
--     ・**新規の**予約の成立      … bookings への insert(双方向)
--       予約は必ずトークルームを伴うため、止まっている機能を売ることになる。
--
--   止めない(規約の「既に成立した予約の履行および換金の手続」):
--     ・チェックイン・完了・延長・キャンセル・レビュー … いずれも既存行の update
--     ・コインの購入、換金の申請、口座の登録          … 通信ではない
--     ・ありがとうギフト … 完了済みプレイに対する謝礼で、通信ではない
--
-- ■ 「記録が無い」場合は撤回とみなさない
--   0031 より前に登録した利用者や、同意の記録に失敗した利用者
--   (recordMonitoringConsent は失敗を握りつぶす)には行が無い。
--   行が無いことを「未同意」として機能を止めると、**同意画面で同意した人を
--   記録の失敗という当社側の事情で締め出す**ことになる。
--   よって判定は「撤回した行があり、かつ有効な行が無い」= 明示的に撤回した
--   状態に限る。再同意すれば有効な行が入り、その瞬間に戻る。
-- ============================================================

-- ------------------------------------------------------------
-- _monitoring_consent_revoked: その利用者が「撤回した状態」か
-- ------------------------------------------------------------
create or replace function public._monitoring_consent_revoked(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null
     and exists (
       select 1 from public.monitoring_consents c
       where c.user_id = p_user and c.revoked_at is not null
     )
     and not exists (
       select 1 from public.monitoring_consents c
       where c.user_id = p_user and c.revoked_at is null
     );
$$;

comment on function public._monitoring_consent_revoked(uuid) is
  'みまもり同意を明示的に撤回した状態かどうか。記録が無い場合は false(撤回とみなさない)。';

revoke all on function public._monitoring_consent_revoked(uuid) from public;
-- 呼び出しは下のトリガ関数と my_monitoring_consent() の内部からのみ。
-- SECURITY DEFINER 同士の呼び出しには execute 権限は不要なので誰にも付与しない。

-- ------------------------------------------------------------
-- トリガ本体。二人組の関係(自分と相手)を引数で受けて判定する
-- ------------------------------------------------------------
create or replace function public._require_monitoring_consent(p_self uuid, p_other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public._monitoring_consent_revoked(p_self) then
    raise exception 'MONITORING_CONSENT_REVOKED';
  end if;
  if public._monitoring_consent_revoked(p_other) then
    raise exception 'PARTNER_MONITORING_CONSENT_REVOKED';
  end if;
end;
$$;

comment on function public._require_monitoring_consent(uuid, uuid) is
  'みまもり同意が撤回されていたら例外。メッセージは双方の通信なので相手側も見る(Q19)。';

revoke all on function public._require_monitoring_consent(uuid, uuid) from public;

-- ------------------------------------------------------------
-- messages: 送信を双方向で止める
-- ------------------------------------------------------------
create or replace function public._messages_require_consent()
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
    from public.promises pr
   where pr.id = new.promise_id;
  perform public._require_monitoring_consent(new.sender_id, v_other);
  return new;
end;
$$;

revoke all on function public._messages_require_consent() from public;

drop trigger if exists messages_require_consent on public.messages;
create trigger messages_require_consent
  before insert on public.messages
  for each row execute function public._messages_require_consent();

-- ------------------------------------------------------------
-- invites: 誘いの送信・受領を双方向で止める
-- ------------------------------------------------------------
create or replace function public._invites_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.from_user, new.to_user);
  return new;
end;
$$;

revoke all on function public._invites_require_consent() from public;

drop trigger if exists invites_require_consent on public.invites;
create trigger invites_require_consent
  before insert on public.invites
  for each row execute function public._invites_require_consent();

-- ------------------------------------------------------------
-- bookings: 新規の成立を双方向で止める(既存行の update は止めない)
-- ------------------------------------------------------------
create or replace function public._bookings_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.guest_id, new.host_id);
  return new;
end;
$$;

revoke all on function public._bookings_require_consent() from public;

drop trigger if exists bookings_require_consent on public.bookings;
create trigger bookings_require_consent
  before insert on public.bookings
  for each row execute function public._bookings_require_consent();

-- ------------------------------------------------------------
-- board_posts: 募集の投稿を止める(相手はまだ居ないので本人のみ)
-- ------------------------------------------------------------
create or replace function public._board_posts_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.creator_id, null);
  return new;
end;
$$;

revoke all on function public._board_posts_require_consent() from public;

drop trigger if exists board_posts_require_consent on public.board_posts;
create trigger board_posts_require_consent
  before insert on public.board_posts
  for each row execute function public._board_posts_require_consent();

-- ------------------------------------------------------------
-- board_participants: 募集への参加を双方向で止める
-- ------------------------------------------------------------
create or replace function public._board_participants_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_creator uuid;
begin
  select p.creator_id into v_creator
    from public.board_posts p where p.id = new.post_id;
  perform public._require_monitoring_consent(new.user_id, v_creator);
  return new;
end;
$$;

revoke all on function public._board_participants_require_consent() from public;

drop trigger if exists board_participants_require_consent on public.board_participants;
create trigger board_participants_require_consent
  before insert on public.board_participants
  for each row execute function public._board_participants_require_consent();

-- ------------------------------------------------------------
-- my_monitoring_consent: 自分の同意の現状(設定画面の表示用)
-- ------------------------------------------------------------
-- 撤回すると何が止まるのかを画面で正確に出すために、
-- 「今どちらの状態か」「いつ・どの版に同意したか」を返す。
-- 履歴そのものは monitoring_consents の select ポリシーで本人が読める。
-- ------------------------------------------------------------
create or replace function public.my_monitoring_consent()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    -- 有効な同意があるか。記録が無い場合も true(締め出さない。0074冒頭の注記)
    'active', not public._monitoring_consent_revoked(auth.uid()),
    -- 記録が1件も無い(0031より前の登録・記録の失敗)
    'unrecorded', not exists (
      select 1 from public.monitoring_consents c where c.user_id = auth.uid()
    ),
    'version', (
      select c.version from public.monitoring_consents c
      where c.user_id = auth.uid() and c.revoked_at is null
      order by c.agreed_at desc limit 1
    ),
    'agreedAt', (
      select c.agreed_at from public.monitoring_consents c
      where c.user_id = auth.uid() and c.revoked_at is null
      order by c.agreed_at desc limit 1
    ),
    'revokedAt', (
      select c.revoked_at from public.monitoring_consents c
      where c.user_id = auth.uid() and c.revoked_at is not null
      order by c.revoked_at desc limit 1
    )
  )
  where auth.uid() is not null;
$$;

comment on function public.my_monitoring_consent() is
  'みまもり同意の現状(設定画面の表示用)。未ログインでは null を返す。';

revoke all on function public.my_monitoring_consent() from public;
grant execute on function public.my_monitoring_consent() to authenticated;
-- ============================================================
-- 0075: 決済の異議申立て(チャージバック)を受けたら残高を凍結する
-- ------------------------------------------------------------
-- ■ なぜ最優先か
--   税理士の第2回回答(Q14)より:
--
--     「Stripeの異議申立てイベント(charge.dispute.created)を受け取って、
--       当該ユーザーのコイン残高を凍結する仕組みを、**リリース前に**
--       実装してください。これがないと、**チャージバックを申し立てながら、
--       その間にコインを使い切る**という極めて単純な不正が通ります。
--       会計処理をどう決めても、この穴が開いていれば損失は防げません。
--       **優先度は、本Q14の他のすべての論点より上です。**」
--
--   実際、異議申立てから決着まで数週間かかる。その間に使い切られると、
--   ①Stripeからの入金は取り消され ②PF利用料は売上に立ち
--   ③ホストへの預り金も発生している、という状態だけが残る。
--   **回収先が無い。**
--
-- ■ 何を止め、何を止めないか
--   止める(= コインを減らす操作):
--     ・新しい予約の成立(create_booking / create_booking_series)
--     ・ありがとうギフトの送信
--     ・プレイ時間の延長
--   止めない:
--     ・**既に成立した予約の履行**(チェックイン・完了・キャンセル・返還)
--       … 相手のピタメイトには何の落ち度も無い。ここを止めると
--         善意の第三者を巻き込む
--     ・トーク・通報・退会など、お金に関係しない操作
--     ・**ホストとしての換金**(凍結の理由はゲストとしての決済であり、
--       ピタメイトとして稼いだ報酬とは別。**ただし運営が個別に判断して
--       止める余地は admin 側に残す**)
--
-- ■ 誰を凍結するか
--   **決済を行った本人のみ。** 異議申立ては決済の当事者の申立てなので、
--   相手(ピタメイトやギフトの受領者)は凍結しない。
--
-- ■ 解除
--   Stripe の charge.dispute.closed で、
--     ・won(当社の主張が通った)  → 自動で解除する
--     ・lost(返金が確定した)     → **自動では解除しない。**
--       返金が確定した以上、残高の調整(取消)が必要で、その判断は運営が行う。
--       運営コンソールから解除する(admin_resolve_dispute)。
--
-- ■ 設計上の注意
--   凍結は**購入単位ではなく利用者単位**にする。異議申立てを受けた購入の
--   コインだけを特定して止める、という設計は一見きれいだが、コインは
--   ロットをまたいで混ざるため、**「どのコインが争われている購入由来か」を
--   後から追うのは実務上不可能**。利用者単位で止めるほうが確実で、
--   誤爆したときも解除できる。
-- ============================================================

-- ------------------------------------------------------------
-- payment_disputes: 異議申立ての記録
-- ------------------------------------------------------------
create table if not exists public.payment_disputes (
  id uuid primary key default gen_random_uuid(),
  -- 決済者が特定できない申立て(当社の購入と紐づかないもの)もあり得るので null 可。
  -- **握りつぶさずに残す** ため。null の行は誰も凍結しない。
  user_id uuid references auth.users (id) on delete cascade,
  -- Stripe の dispute id。同じ申立ての再送で二重に積まないための鍵
  stripe_dispute_id text not null unique,
  stripe_charge_id text,
  stripe_payment_intent text,
  -- 争われている金額(円)。Stripe の amount をそのまま入れる
  amount_yen int,
  reason text,
  -- open  … 申立て中(凍結の根拠)
  -- won   … 当社の主張が通った(自動解除)
  -- lost  … 返金が確定した(運営が残高を調整してから手動で解除)
  -- closed… その他の終了(warning_closed 等)
  status text not null default 'open'
    check (status in ('open', 'won', 'lost', 'closed')),
  -- 凍結を解除した時刻。**null の間は凍結中**(status ではなくこの列で判定する)
  resolved_at timestamptz,
  resolved_note text,
  created_at timestamptz not null default now()
);

comment on table public.payment_disputes is
  '決済の異議申立て(チャージバック)の記録。resolved_at が null の行があるユーザーはコインの消費を止める。税理士の第2回回答Q14(リリース前の必須実装)。';

alter table public.payment_disputes enable row level security;

-- 本人にも見せない。異議申立ての存否は運営とStripeの間の情報で、
-- 画面に出す必要が無い(出すと、凍結の回避方法を探る材料になる)。
-- select ポリシーを置かないことで既定の拒否になる。運営は service_role で見る。

create index if not exists payment_disputes_open_idx
  on public.payment_disputes (user_id)
  where resolved_at is null;

-- ------------------------------------------------------------
-- _coins_frozen: そのユーザーが凍結中か
-- ------------------------------------------------------------
create or replace function public._coins_frozen(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- **status ではなく resolved_at で判定する。**
  -- lost(返金が確定した)は自動解除してはいけない ── 残高の調整という
  -- 運営の作業が残っているため。status で見ると lost の瞬間に凍結が
  -- 解けてしまい、**最も止めたい場面で止まらない。**
  select p_user is not null and exists (
    select 1 from public.payment_disputes d
    where d.user_id = p_user and d.resolved_at is null
  );
$$;

comment on function public._coins_frozen(uuid) is
  '決済の異議申立て中でコインの消費を止めるべきユーザーか。';

revoke all on function public._coins_frozen(uuid) from public;

-- ------------------------------------------------------------
-- コインが減る操作を止める。
-- coin_wallets の UPDATE を直接見張るのではなく、**消費のたびに必ず通る
-- coin_transactions の INSERT** を見張る。返還(refund)や失効(expire)は
-- 止めない ── 止めると既存予約のキャンセルができなくなる。
-- ------------------------------------------------------------
create or replace function public._coin_tx_require_unfrozen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 減る向きの、利用者の意思による消費だけを見る。
  -- expire(失効)は当社側の処理、refund は返す向きなので対象外。
  if new.type in ('booking_spend', 'gift_sent')
     and public._coins_frozen(new.user_id) then
    raise exception 'COINS_FROZEN_DISPUTE';
  end if;
  return new;
end;
$$;

revoke all on function public._coin_tx_require_unfrozen() from public;

drop trigger if exists coin_transactions_require_unfrozen on public.coin_transactions;
create trigger coin_transactions_require_unfrozen
  before insert on public.coin_transactions
  for each row execute function public._coin_tx_require_unfrozen();

-- ------------------------------------------------------------
-- record_payment_dispute: Stripe webhook から呼ぶ(service_role のみ)
-- 同じ dispute の再送は状態を更新するだけで、二重に積まない。
-- ------------------------------------------------------------
create or replace function public.record_payment_dispute(
  p_stripe_dispute_id text,
  p_stripe_charge_id text,
  p_stripe_payment_intent text,
  p_amount_yen int,
  p_reason text,
  p_status text default 'open'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if p_stripe_dispute_id is null or p_status not in ('open','won','lost','closed') then
    raise exception 'INVALID_ARGS';
  end if;

  -- 決済者を購入履歴から引く(payment_intent が唯一の手掛かり)。
  select p.user_id into v_user
    from public.coin_purchases p
   where (p_stripe_payment_intent is not null
          and p.stripe_payment_intent = p_stripe_payment_intent)
   limit 1;

  -- 決済者が特定できない場合も user_id = null で記録する。
  -- **握りつぶさない。** 誰も凍結しないが、人が調べられる形で残す。
  insert into public.payment_disputes
    (user_id, stripe_dispute_id, stripe_charge_id, stripe_payment_intent,
     amount_yen, reason, status)
  values (v_user, p_stripe_dispute_id, p_stripe_charge_id, p_stripe_payment_intent,
          p_amount_yen, p_reason, p_status)
  on conflict (stripe_dispute_id) do update
    set status = excluded.status,
        amount_yen = coalesce(excluded.amount_yen, public.payment_disputes.amount_yen),
        reason = coalesce(excluded.reason, public.payment_disputes.reason);

  -- won は当社の主張が通った = 自動で解除してよい。
  -- lost は返金が確定した = **残高の調整が要る**ので自動解除しない
  -- (運営が admin_resolve_dispute で解除する)。
  if p_status = 'won' then
    update public.payment_disputes
       set resolved_at = now(),
           resolved_note = coalesce(resolved_note, 'Stripeで当社の主張が認められたため自動解除')
     where stripe_dispute_id = p_stripe_dispute_id and resolved_at is null;
  end if;
end;
$$;

revoke all on function public.record_payment_dispute(text, text, text, int, text, text) from public;
-- 呼ぶのは Stripe webhook(service_role)だけ。anon/authenticated には渡さない。

-- ------------------------------------------------------------
-- admin_open_disputes / admin_resolve_dispute: 運営コンソール用
-- ------------------------------------------------------------
create or replace function public.admin_open_disputes()
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  stripe_dispute_id text,
  amount_yen int,
  reason text,
  status text,
  created_at timestamptz,
  coin_balance int,
  earned_balance int
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  perform public._log_admin_action('view_disputes', null, null);
  return query
    select d.id, d.user_id, pr.nickname, d.stripe_dispute_id, d.amount_yen,
           d.reason, d.status, d.created_at,
           coalesce(w.balance, 0), coalesce(w.earned_balance, 0)
      from public.payment_disputes d
      left join public.profiles pr on pr.id = d.user_id
      left join public.coin_wallets w on w.user_id = d.user_id
     where d.resolved_at is null
     order by d.created_at desc;
end;
$$;

revoke all on function public.admin_open_disputes() from public;
grant execute on function public.admin_open_disputes() to authenticated;

create or replace function public.admin_resolve_dispute(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_note is null or char_length(btrim(p_note)) = 0 then
    -- 理由を必ず書かせる。凍結の解除は後から説明を求められる操作。
    raise exception 'NOTE_REQUIRED';
  end if;

  update public.payment_disputes
     set status = case when status = 'open' then 'closed' else status end,
         resolved_at = now(),
         resolved_note = p_note
   where id = p_id and resolved_at is null
  returning user_id into v_user;

  if v_user is null then
    raise exception 'DISPUTE_NOT_FOUND';
  end if;
  perform public._log_admin_action('resolve_dispute', v_user, p_note);
end;
$$;

revoke all on function public.admin_resolve_dispute(uuid, text) from public;
grant execute on function public.admin_resolve_dispute(uuid, text) to authenticated;
-- ============================================================
-- 0076: 会計集計を税理士の第2回回答(Q7)に合わせる
-- ------------------------------------------------------------
-- 0070 で作った集計に、税理士の第2回回答が3点の修正と4点の追加を求めた。
--
-- ■ 修正1: 「未払金(換金申請中)」という科目名をやめる (Q7-a)
--   「『未払金』は通常、費用の発生や資産の購入に対応する債務を指します。
--     ここで計上されるのは**預り金の一部が支払段階に進んだもの**であり、
--     性質が違います。推奨: **『預り金(ホスト報酬)』の下位に
--     『うち換金申請中』を持つ**。理由は、**『預り金(ホスト報酬)の合計＝
--     分別口座で守るべき額』という管理式が崩れないから**です。」
--
-- ■ 修正2: 換金手数料300コインの置き場所 (Q7-b) ★実際に穴が空いていた
--   「『未払金(換金申請中)』を手数料控除後の純額で計上すると、**申請時点で
--     手数料300コインがどの勘定にもいない状態**が生じます。負債合計が申請の
--     前後で300コイン減るので、分別管理で守るべき額の計算がずれます。」
--
--   実装を確認したところ、そのとおりだった:
--     request_bank_payout は earned_balance を **申請額の全額**(5,000)
--     減らし、payouts には **手数料控除後**(4,700)を入れる。
--     → 差額の300が、振込が完了するまでどの集計にも現れない。
--   税理士の推奨に従い **仮受金(換金手数料)** として明示的に積む。
--   (テーブルは変えない。payouts.fee_yen から集計できる。)
--
-- ■ 修正3: 「分別対象額の合計」を出す
--   運用規程 第4条「分別口座および支払口座の残高の合計額が、常時、
--   分別対象額以上」を確認するには、**足し算済みの1行**が要る。
--   毎月これを手で足すのは、月次照合の事故のもと。
--
-- ■ 追加(Q7): 残高だけでは月次仕訳を機械的に起こせない。フローを4つ足す
--   ①当期のコイン販売額(有償・総額) … 決済手数料の総額処理(Q10-c)の検算
--   ②当期の失効額(有償・無償の別)   … 無償分は雑収入に計上しないが内訳が要る
--   ③当期の返金・取消額              … チャージバック(Q14)の把握
--   ④期末をまたぐ予約エスクローの件数・金額 … 「決算で必ず聞かれます」
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 残高サマリー(0070を差し替え)
-- ------------------------------------------------------------
create or replace function public.accounting_balances()
returns table (
  区分 text,
  勘定科目 text,
  金額円 bigint,
  備考 text
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
  -- 未使用の有償コイン = 前受金。現金を受け取っている分だけを負債に立てる
  select '負債'::text, '前受金(コイン)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '未使用の有償コイン。1コイン=1円。照合式: 帳簿残高 = 有償ロットの残コイン数 × 1円'::text
  from public.coin_lots l
  where l.kind = 'paid' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 予約成立済み・完了未確定 = まだ誰の収益にもなっていない。
  -- **独立科目として持つ**(Q7-c)。コイン残高は失効の対象だが
  -- エスクローは失効せず、完了すれば売上になる。性質が違う。
  select '負債'::text, '前受金(予約エスクロー)'::text,
         coalesce(sum(b.coins), 0)::bigint,
         '予約成立済み・プレイ完了未確定(' || count(*) || '件)。確定時に利用料と報酬に分かれる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')

  union all
  -- 確定済み・未換金のホスト報酬。**換金申請済みの分はここから抜けている**
  -- (request_bank_payout が申請時に earned_balance を減らすため)。
  -- 下の2行と合わせて「預り金(ホスト報酬)」の全体になる。
  select '負債'::text, '預り金(ホスト報酬・未申請)'::text,
         coalesce(sum(w.earned_balance), 0)::bigint,
         '確定済み・換金未申請の報酬コイン。**失効しない**(0018)'::text
  from public.coin_wallets w

  union all
  -- 0070では「未払金(換金申請中)」としていた。税理士の指摘(Q7-a)により
  -- 預り金の下位に置き直す。金額の中身は変えていない。
  select '負債'::text, '預り金(ホスト報酬・うち換金申請中)'::text,
         coalesce(sum(p.amount_yen), 0)::bigint,
         '換金申請済み・未振込の振込予定額(手数料控除後)'::text
  from public.payouts p
  where p.status = 'pending'

  union all
  -- ★0076で追加。ここが無いと申請の前後で負債合計が300コイン減る(Q7-b)
  select '負債'::text, '仮受金(換金手数料)'::text,
         coalesce(sum(p.fee_yen), 0)::bigint,
         '換金申請時に控除済み・振込未完了。**振込完了時に売上へ振り替える**'::text
  from public.payouts p
  where p.status = 'pending'

  union all
  -- ★0076で追加。運用規程 第4条の確認に使う1行
  select '合計'::text, '分別対象額(第4条)'::text,
         (
           coalesce((select sum(l.remaining) from public.coin_lots l
                      where l.kind = 'paid' and l.remaining > 0 and l.expires_at > now()), 0)
         + coalesce((select sum(b.coins) from public.bookings b
                      where b.status in ('requested', 'confirmed')), 0)
         + coalesce((select sum(w.earned_balance) from public.coin_wallets w), 0)
         + coalesce((select sum(p.amount_yen) from public.payouts p where p.status = 'pending'), 0)
         + coalesce((select sum(p.fee_yen) from public.payouts p where p.status = 'pending'), 0)
         )::bigint,
         '**分別口座＋支払口座の残高が常時この額以上**であること。無償コインは含めない'::text

  union all
  -- ここから下は負債ではない参考値
  select '参考'::text, '無償コイン残(ボーナス)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '**前受金に含めない**(現金を受け取っていない)。将来の値引き原資'::text
  from public.coin_lots l
  where l.kind = 'bonus' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 期限切れで未処理のロット。ここが0でないと失効処理が追いついていない
  select '要確認'::text, '期限切れ・失効処理待ち'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '0でなければ expire_coins() が動いていない。雑収入の計上漏れになる'::text
  from public.coin_lots l
  where l.remaining > 0 and l.expires_at <= now();
end;
$$;

comment on function public.accounting_balances() is
  '月次の記帳・照合用の残高サマリー(運営のみ)。0076で「未払金」を預り金の下位に改め、仮受金(換金手数料)と分別対象額の合計を追加。読み取りのみ。';

revoke all on function public.accounting_balances() from public;
grant execute on function public.accounting_balances() to authenticated;

-- ------------------------------------------------------------
-- 2. 期間の損益サマリー(0070を差し替え)
-- ------------------------------------------------------------
create or replace function public.accounting_revenue(p_from date, p_to date)
returns table (
  区分 text,
  科目 text,
  金額円 bigint,
  消費税 text
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
  -- プラットフォーム利用料(予約) … 完了確定時に platform_fees へ記録される
  select '売上'::text, 'PF利用料(予約)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'booking'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  select '売上'::text, 'PF利用料(ギフト)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'gift'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  -- あんしんサポート料。購入時に売上計上する(税理士 §1-4)
  select '売上'::text, 'あんしんサポート料(購入時)'::text,
         coalesce(sum(cp.safety_fee_yen), 0)::bigint, '課税10%'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- 換金手数料。**振込完了時に売上計上**(Q7-b で時期を確認済み)。
  -- 申請時点では上の「仮受金(換金手数料)」に載っている。
  select '売上'::text, '換金手数料(振込完了分)'::text,
         coalesce(sum(p.fee_yen), 0)::bigint, '課税10%'::text
  from public.payouts p
  where p.status = 'paid'
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all
  -- コイン失効益。**有償分のみ**が雑収入になる(Q8-c)。
  -- expire_coins() は note に 'lot:<ロットID>' を書くだけで種別を持たないため、
  -- ロットに join して有償・無償を分ける。**失効した時点の取引で数える**
  -- (expires_at で数えると、期限は来たが処理が走っていない分まで入る)。
  select '雑収入'::text, 'コイン失効益(有償)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '不課税'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'paid'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- ★0076で追加。無償分の失効は**会計上は何も起きない**(負債を立てていない)。
  -- それでも内訳を出すのは、税務調査で「失効益が過少では」と問われたときに
  -- **有償と無償の内訳を即座に出せることが答えになる**から(Q8-c)。
  -- 「記録がないと、『無償分も本当は前受金だったのでは』という議論に
  --   発展しかねません」
  select '参考(売上でない)'::text, 'コイン失効額(無償・会計処理なし)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '—'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'bonus'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- ★0076で追加(Q7)。決済手数料の総額処理の検算に使う
  select '参考(売上でない)'::text, 'コイン販売額(有償・総額)'::text,
         coalesce(sum(cp.price_yen), 0)::bigint, '不課税'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- ★0076で追加(Q7)。**予約キャンセルによるコインの返還は含めない。**
  -- あれは前受金の中での移動であって、前受金の減少ではない。
  -- ここに出すのは現金が出ていく方向のもの(チャージバックの確定分)。
  select '参考(売上でない)'::text, '返金・チャージバック確定額'::text,
         coalesce(sum(d.amount_yen), 0)::bigint, '前受金の減少'::text
  from public.payment_disputes d
  where d.status = 'lost'
    and d.created_at >= p_from and d.created_at < (p_to + 1)

  union all
  -- ★0076で追加(Q7)。「期ずれの説明資料。決算で必ず聞かれます」
  select '参考(期ずれ)'::text,
         '期末をまたぐ予約エスクロー(' || count(*) || '件)'::text,
         coalesce(sum(b.coins), 0)::bigint, '翌期の売上になる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')
    and b.created_at < (p_to + 1);
end;
$$;

comment on function public.accounting_revenue(date, date) is
  '期間の売上サマリー(運営のみ)。0076でフロー4項目(販売額・失効の有償無償別・返金確定額・期末をまたぐエスクロー)を追加。読み取りのみ。';

revoke all on function public.accounting_revenue(date, date) from public;
grant execute on function public.accounting_revenue(date, date) to authenticated;
-- ============================================================
-- 0077: 係争中のチャージバックに紐づく報酬は換金保留にする
-- ------------------------------------------------------------
-- ■ 税理士の第3回回答(2026-07-30)より
--
--   「チャージバック時に『換金を停止しない』設計ですが、係争中に当該取引の
--     報酬コインが換金されて出ていくと、**回収不能が確定します。**
--     ホスト全体を止めるのは過剰なので、**当該チャージバックに直接紐づく
--     予約の報酬コインだけ決着まで換金保留**にできませんか。
--     技術的に困難なら、Q14-a③の規約条項が必須になります。」
--
--   0075 では「ホストとしての換金は止めない」と書いた。落ち度の無いホストを
--   巻き込まないためだが、**ホスト全体を止めるか / 何も止めないか**の
--   二択で考えていた。**紐づく分だけ止める**という第三の道があった。
--
-- ■ 追えるのか(0075では「実務上不可能」と書いていた)
--   0075 は**どのコインが争われている購入由来か**を追うのは不可能、と書いた。
--   これはコイン単位の話としては今も正しい。しかし**予約単位なら追える。**
--
--     異議申立て
--       → payment_intent
--       → coin_purchases(誰が・いつ買ったか)
--       → その購入**以後**にその人が入れた予約
--       → coin_transactions(type='booking_earned', related_booking_id)
--       → ホストごとの報酬額
--
--   `related_booking_id` は 0009 からある列で、報酬の付与時に必ず入る。
--   **購入日以後の予約に限る**ので、争われている購入より前の予約は巻き込まない。
--
--   ⚠️ これは**過大にも過小にもなりうる近似**である。コインは混ざるので、
--   争われた1万円が実際にどの予約に使われたかは特定できない。
--   購入以後の予約をすべて対象にするのは**保守的な側(過大)**に倒した判断。
--   決着したら解除されるので、過大でも一時的な保留にとどまる。
--
-- ■ 何を止め、何を止めないか
--   止める: **紐づく予約の報酬コインの額だけ**を換金可能額から差し引く
--   止めない: それを超える分の換金。ホストの他の稼ぎは自由に換金できる
--
--   「ホスト全体を止めるのは過剰」というご指摘のとおりの設計にした。
--
-- ■ それでも規約条項は必要
--   この保留で防げるのは「**申立て後に**換金されること」だけである。
--   **申立てより前に換金・振込まで終わっていた分は、取り戻せない。**
--   したがって Q14-a③(ホストの未払報酬からの相殺)の規約条項は依然として必要。
--   弁護士へは「**実装で完全には防げないので規約で担保したい**」と補足する
--   (`docs/legal/lawyer-questions-open.md` Q38)。
-- ============================================================

-- ------------------------------------------------------------
-- _dispute_payout_hold: そのホストの報酬のうち、係争中の購入に紐づく額
-- ------------------------------------------------------------
create or replace function public._dispute_payout_hold(p_host uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(t.amount), 0)::int
  from public.coin_transactions t
  join public.bookings b on b.id = t.related_booking_id
  join public.payment_disputes d on d.user_id = b.guest_id
  join public.coin_purchases cp
    on cp.stripe_payment_intent = d.stripe_payment_intent
  where t.user_id = p_host
    and t.type = 'booking_earned'
    and t.amount > 0
    and d.resolved_at is null
    -- **争われている購入より後に入った予約に限る。**
    -- それより前の予約は、その購入のコインでは払えないので無関係。
    and b.created_at >= cp.created_at;
$$;

comment on function public._dispute_payout_hold(uuid) is
  '係争中のチャージバックに紐づく予約の報酬額(換金保留額)。決着(resolved_at)で自動的に0に戻る。税理士の第3回回答。';

revoke all on function public._dispute_payout_hold(uuid) from public;

-- ------------------------------------------------------------
-- request_bank_payout: ギフト保留(0069)に加えて係争保留を差し引く
-- ------------------------------------------------------------
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 振込手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_coins is null or p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';

  -- 0077: 係争中のチャージバックに紐づく予約の報酬も保留。
  -- **ホスト全体を止めるのではなく、紐づく額だけを差し引く。**
  v_dispute_hold := public._dispute_payout_hold(v_uid);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、**どちらの保留かを分けて伝える**。
    -- 利用者から見ると原因も待つべき期間も違う(ギフトは7日で明ける／
    -- 係争は決着するまで分からない)ので、同じ文言にしてはいけない。
    if p_coins <= coalesce(v_balance, 0) then
      if v_dispute_hold > 0 and p_coins > coalesce(v_balance, 0) - v_dispute_hold then
        raise exception 'DISPUTE_ON_HOLD';
      end if;
      if v_gift_hold > 0 then
        raise exception 'GIFT_ON_HOLD';
      end if;
    end if;
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(int) is
  '報酬コインの換金申請。最低5,000コイン・手数料300コイン。直近7日のギフト受領分(0069)と、係争中のチャージバックに紐づく予約の報酬(0077)は換金保留。';

revoke all on function public.request_bank_payout(int) from public;
grant execute on function public.request_bank_payout(int) to authenticated;

-- ------------------------------------------------------------
-- my_payout_hold: 自分の換金保留額の内訳(ウォレット画面の表示用)
-- ------------------------------------------------------------
-- 保留があるのに理由が分からないのが最も困る。**額と理由を出す。**
-- ただし係争については「お支払いの確認中」以上のことは書かない
-- (0075と同じ理由。凍結の回避方法を探る材料にしない)。
-- ------------------------------------------------------------
create or replace function public.my_payout_hold()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'earnedBalance', coalesce((select earned_balance from public.coin_wallets
                                where user_id = auth.uid()), 0),
    'giftHold', coalesce((select sum(coins) from public.gifts
                           where receiver_id = auth.uid()
                             and created_at > now() - interval '7 days'), 0),
    'disputeHold', public._dispute_payout_hold(auth.uid()),
    'available', greatest(0,
        coalesce((select earned_balance from public.coin_wallets
                   where user_id = auth.uid()), 0)
      - coalesce((select sum(coins) from public.gifts
                   where receiver_id = auth.uid()
                     and created_at > now() - interval '7 days'), 0)
      - public._dispute_payout_hold(auth.uid()))
  )
  where auth.uid() is not null;
$$;

comment on function public.my_payout_hold() is
  '換金できる額と、保留の内訳(ギフト/係争)。ウォレット画面の表示用。';

revoke all on function public.my_payout_hold() from public;
grant execute on function public.my_payout_hold() to authenticated;
-- ============================================================
-- 0078: 「PF利用料のうち無償コイン起因の額」を集計に足す
-- ------------------------------------------------------------
-- ■ 税理士の第4回回答(2026-07-30・事業計画書の評価)より
--
--   「当職の説明不足を1件お詫びします。**無償コイン消費時の借方科目を、
--     第2回回答Q8-bで書いていませんでした。**『負債に立てない』『利用料は
--     通常どおり売上計上』だけだと**仕訳の借方が埋まりません。**
--     **推奨は純額処理(販売促進費82 / 預り金82)**で、両建てにすると
--     **課税売上高が水増しされ、免税判定と簡易課税判定が実態より早く到来
--     します。** Q7の集計に『**PF利用料のうち無償コイン起因の額**』を
--     1項目追加していただければ、どちらの処理も選べます。」
--
-- ■ 何が問題か(具体例)
--   無償100コインが単価100コインの予約に使われ、利用料が20%だったとき:
--
--   | 処理 | 仕訳 | 課税売上高への影響 |
--   |---|---|---|
--   | 両建て | 販売促進費100 / 売上20・預り金80 | **売上が20増える** |
--   | 純額(推奨) | 販売促進費80 / 預り金80 | 売上は増えない |
--
--   両建ては、現金を1円も受け取っていない取引で課税売上高を膨らませる。
--   **1,000万円の判定が実態より早く来る**ため、免税事業者でいられる期間が
--   短くなり、簡易課税の届出期限も前倒しになる。
--
-- ■ この集計の使い方
--   純額処理を採るなら、期間の「PF利用料」から**この行を差し引いた額**が
--   売上になる。両建てを採るなら差し引かない。
--   **どちらを採るかは会計ソフト側の運用で、この関数は素材を出すだけ。**
--
-- ■ 計算のしかた
--   予約は有償コインと無償コインが混ざって支払われる(bookings.paid_coins /
--   bonus_coins)。利用料は合計額に対してかかるので、**無償の割合で按分**する。
--
--       無償起因の利用料 = fee_coins × bonus_coins / coins
--
--   端数は切り捨てず round する(集計の用途なので1円の丸めは問題にならない)。
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
-- ============================================================

create or replace function public.accounting_revenue(p_from date, p_to date)
returns table (
  区分 text,
  科目 text,
  金額円 bigint,
  消費税 text
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
  -- プラットフォーム利用料(予約) … 完了確定時に platform_fees へ記録される
  select '売上'::text, 'PF利用料(予約)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'booking'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  select '売上'::text, 'PF利用料(ギフト)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'gift'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  -- あんしんサポート料。購入時に売上計上する(税理士 §1-4)
  select '売上'::text, 'あんしんサポート料(購入時)'::text,
         coalesce(sum(cp.safety_fee_yen), 0)::bigint, '課税10%'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- 換金手数料。**振込完了時に売上計上**(Q7-b で時期を確認済み)。
  -- 申請時点では「仮受金(換金手数料)」に載っている。
  select '売上'::text, '換金手数料(振込完了分)'::text,
         coalesce(sum(p.fee_yen), 0)::bigint, '課税10%'::text
  from public.payouts p
  where p.status = 'paid'
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all
  -- ★0078で追加。**上の「PF利用料(予約)」の内数。**
  -- 純額処理を採るなら、この額を差し引いた額が売上になる。
  -- 両建てにすると、現金を受け取っていない取引で課税売上高が膨らみ、
  -- **1,000万円の判定が実態より早く来る**(税理士の第4回回答)。
  select '内数(控除の候補)'::text, 'PF利用料のうち無償コイン起因'::text,
         coalesce(sum(round(f.fee_coins::numeric * b.bonus_coins / nullif(b.coins, 0))), 0)::bigint,
         '純額処理なら売上から控除'::text
  from public.platform_fees f
  join public.bookings b on b.id = f.booking_id
  where f.kind = 'booking'
    and coalesce(b.bonus_coins, 0) > 0
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  -- コイン失効益。**有償分のみ**が雑収入になる(Q8-c)。
  -- expire_coins() は note に 'lot:<ロットID>' を書くだけで種別を持たないため、
  -- ロットに join して有償・無償を分ける。**失効した時点の取引で数える**
  -- (expires_at で数えると、期限は来たが処理が走っていない分まで入る)。
  select '雑収入'::text, 'コイン失効益(有償)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '不課税'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'paid'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- 無償分の失効は**会計上は何も起きない**(負債を立てていない)。
  -- それでも内訳を出すのは、税務調査で「失効益が過少では」と問われたときに
  -- **有償と無償の内訳を即座に出せることが答えになる**から(Q8-c)。
  select '参考(売上でない)'::text, 'コイン失効額(無償・会計処理なし)'::text,
         coalesce(-sum(t.amount), 0)::bigint, '—'::text
  from public.coin_transactions t
  join public.coin_lots l on t.note = 'lot:' || l.id::text
  where t.type = 'expire' and l.kind = 'bonus'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- 決済手数料の総額処理(Q10-c)の検算に使う
  select '参考(売上でない)'::text, 'コイン販売額(有償・総額)'::text,
         coalesce(sum(cp.price_yen), 0)::bigint, '不課税'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- **予約キャンセルによるコインの返還は含めない。**
  -- あれは前受金の中での移動であって、前受金の減少ではない。
  select '参考(売上でない)'::text, '返金・チャージバック確定額'::text,
         coalesce(sum(d.amount_yen), 0)::bigint, '前受金の減少'::text
  from public.payment_disputes d
  where d.status = 'lost'
    and d.created_at >= p_from and d.created_at < (p_to + 1)

  union all
  -- 「期ずれの説明資料。決算で必ず聞かれます」
  select '参考(期ずれ)'::text,
         '期末をまたぐ予約エスクロー(' || count(*) || '件)'::text,
         coalesce(sum(b.coins), 0)::bigint, '翌期の売上になる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')
    and b.created_at < (p_to + 1);
end;
$$;

comment on function public.accounting_revenue(date, date) is
  '期間の売上サマリー(運営のみ)。0078で「PF利用料のうち無償コイン起因」を内数として追加(純額処理を採る場合の控除額)。読み取りのみ。';

revoke all on function public.accounting_revenue(date, date) from public;
grant execute on function public.accounting_revenue(date, date) to authenticated;
-- ============================================================
-- 0079: 仕訳の自動生成(accounting_journal)
--
-- ねらい:
--   0070→0076→0078 で「残高」と「損益」は出せるようになった。
--   だが**帳簿に入れるのは仕訳**であって、残高一覧ではない。
--   毎月これを手で起票するのは、件数が増えた時点で確実に破綻する。
--
--   この関数は、期間を渡すと**会計ソフトにそのまま取り込める仕訳**を返す。
--   運営コンソールの「会計」タブが呼び、CSVに落とす。
--
-- 設計の判断:
--   1. **単純仕訳しか出さない。** 1行 = 借方1・貸方1・金額1。
--      複合仕訳にすると取込形式がソフトごとに割れるうえ、
--      「1行ずつ貸借が合っている」ことが目視で確認できなくなる。
--      購入のように借方が2つに割れるものは、2行に分けて出す。
--   2. **元帳(coin_transactions / payouts / coin_lot_consumptions)から引く。**
--      集計値(coin_wallets 等)からは引かない。集計値は事故で狂うが、
--      元帳は 0044 で追記専用になっている。
--   3. **1コイン = 1円。** 全額を円で出す。
--   4. **税区分は会計ソフトの名称で出す**(弥生の名称に合わせる。
--      freee・マネーフォワードはいずれも弥生形式を取り込める)。
--      不課税取引は、会計ソフト上は「対象外」で入力する。
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
--
-- 無償コインの扱い(税理士の第4回回答):
--   無償コインで予約が成立すると、**現金は1円も受け取っていないのに
--   ピタメイトへの支払は発生する**。前受金を立てていない以上、
--   どこかで費用にしないと借方が埋まらない。科目は税理士の指定どおり
--   「販売促進費」。計上は**付与時ではなく消費時**にしている
--   (付与時にすると、使われずに失効したボーナスまで費用になる)。
--
--   税理士の推奨は**純額処理**(販売促進費82 / 預り金82)。両建てにすると
--   **課税売上高が水増しされ、免税判定と簡易課税判定が実態より早く来る**。
--   ただし取引ごとの仕訳を純額で作ると、利用料の売上が取引単位で
--   歯抜けになって追いにくい。そこで
--     ・取引ごとの仕訳は**両建てで素直に作る**
--     ・区分「純額調整」の行で、無償コイン起因の利用料を売上から落とす
--   の2段構えにした。純額処理を採らない場合は、この区分を外して出力する。
-- ============================================================

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

  order by 1, 2, 10;
end;
$$;

comment on function public.accounting_journal(date, date) is
  '期間内の取引を会計ソフト取込用の単純仕訳(1行=借方1・貸方1)にして返す(運営のみ)。1コイン=1円。読み取りのみ。Stripeの着金・決済手数料と、経費・按分はここには出ない(明細から別途起票する)。';

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;

-- ------------------------------------------------------------
-- accounting_journal_check: 仕訳の自己検証
--
-- **合わないことに気づけない自動化は、手作業より危ない。**
-- 生成した仕訳を科目ごとに集計し、元帳の残高と突き合わせる。
-- 期首から当期末までの全期間で呼ぶ前提(累計で比べるため)。
-- ------------------------------------------------------------
create or replace function public.accounting_journal_check(p_from date, p_to date)
returns table (
  項目 text,
  仕訳から円 bigint,
  元帳から円 bigint,
  差額円 bigint,
  判定 text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_j_zen_coin bigint;      -- 前受金(コイン)の仕訳純増
  v_j_escrow bigint;        -- 前受金(予約エスクロー)の仕訳純増
  v_j_azukari bigint;       -- 預り金(ピタメイト報酬)の仕訳純増
  v_l_zen_coin bigint;
  v_l_escrow bigint;
  v_l_azukari bigint;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  -- 仕訳側: 貸方に立った額 − 借方に立った額(負債なので貸方が増加)
  select
    coalesce(sum(case when j.貸方科目 = '前受金' and j.貸方補助 = 'コイン' then j.金額円 else 0 end), 0)
      - coalesce(sum(case when j.借方科目 = '前受金' and j.借方補助 = 'コイン' then j.金額円 else 0 end), 0),
    coalesce(sum(case when j.貸方科目 = '前受金' and j.貸方補助 = '予約エスクロー' then j.金額円 else 0 end), 0)
      - coalesce(sum(case when j.借方科目 = '前受金' and j.借方補助 = '予約エスクロー' then j.金額円 else 0 end), 0),
    coalesce(sum(case when j.貸方科目 = '預り金' and j.貸方補助 = 'ピタメイト報酬' then j.金額円 else 0 end), 0)
      - coalesce(sum(case when j.借方科目 = '預り金' and j.借方補助 = 'ピタメイト報酬' then j.金額円 else 0 end), 0)
  into v_j_zen_coin, v_j_escrow, v_j_azukari
  from public.accounting_journal(p_from, p_to) j;

  -- 元帳側
  -- **expires_at で絞らない。** 仕訳の側は expire_coins() が走って
  -- 初めて前受金を取り崩す(J16)。期限は過ぎたが処理待ちのロットを
  -- ここで除くと、失効処理の遅れが「仕訳の誤り」に見えてしまう。
  -- 貸借対照表の金額(accounting_balances)とは目的が違う。
  select coalesce(sum(l.remaining), 0)::bigint into v_l_zen_coin
  from public.coin_lots l
  where l.kind = 'paid' and l.remaining > 0;

  select coalesce(sum(b.coins), 0)::bigint into v_l_escrow
  from public.bookings b
  where b.status in ('requested', 'confirmed');

  select coalesce(sum(w.earned_balance), 0)::bigint into v_l_azukari
  from public.coin_wallets w;

  return query
  select '前受金(コイン)'::text, v_j_zen_coin, v_l_zen_coin,
         v_j_zen_coin - v_l_zen_coin,
         case when v_j_zen_coin = v_l_zen_coin then 'OK' else 'NG' end
  union all
  select '前受金(予約エスクロー)'::text, v_j_escrow, v_l_escrow,
         v_j_escrow - v_l_escrow,
         case when v_j_escrow = v_l_escrow then 'OK' else 'NG' end
  union all
  select '預り金(ピタメイト報酬)'::text, v_j_azukari, v_l_azukari,
         v_j_azukari - v_l_azukari,
         case when v_j_azukari = v_l_azukari then 'OK' else 'NG' end;
end;
$$;

comment on function public.accounting_journal_check(date, date) is
  '生成した仕訳を科目ごとに積み上げ、元帳の残高と突き合わせる(運営のみ)。**開業日から当日まで**の全期間で呼ぶこと。差額が出たら仕訳生成側の漏れを疑う。';

revoke all on function public.accounting_journal_check(date, date) from public;
grant execute on function public.accounting_journal_check(date, date) to authenticated;
-- ============================================================
-- 0080: カード(決済手段)フィンガープリントの監視  ★E-9
--
-- 弁護士 Q11(c) の推奨「同一IP/端末/カードを監視」のうち、
-- **カードだけが未実装のまま残っていた**(0021が端末、0022がIP)。
-- 換金を解禁する前に埋めておく必要がある項目。
--
-- なぜカードが要るのか:
--   端末IDは localStorage を消せば変わる。IPは回線を変えれば変わる。
--   **カードのフィンガープリントは、同じ実カードである限り変わらない。**
--   Stripe が発行する値で、番号そのものではないので当社は番号を持たない。
--   自作自演(自分のカードで買ったコインを、別アカウントの自分に
--   ギフトで渡して換金する)を見つける手段としては、3つの中で最も強い。
--
-- 3つの信号の扱いを揃えていない理由:
--   ・端末が同じ  → **遮断**(0021)。ほぼ同一人物
--   ・IPが同じ    → **フラグ**(0022)。同居・同じWi-Fi・キャリアNATで正当に一致する
--   ・カードが同じ → **フラグ**(本migration)。家族カード・同一世帯で正当に一致しうる
--
--   カードを遮断にしないのは、**夫婦や親子が同じカードを使っている**という
--   ごく普通の状況を、送金の完全遮断で潰してしまうため。
--   代わりに**換金の直前に必ず目に入る**ようにする(下記 admin_pending_payouts)。
--   資金が外へ出る瞬間に判断できれば足りる。
-- ============================================================

-- ------------------------------------------------------------
-- user_payment_cards: 利用者が使った決済手段の記録
--
-- **カード番号は保存しない。** Stripe のフィンガープリント(同一カードなら
-- 同じ値になる不可逆な識別子)と、ブランド・下4桁だけを持つ。
-- 下4桁は運営が目視で照合するときの手がかりで、これ単体では特定できない。
-- ------------------------------------------------------------
create table if not exists public.user_payment_cards (
  user_id uuid not null references auth.users (id) on delete cascade,
  fingerprint text not null check (char_length(fingerprint) between 4 and 128),
  brand text,
  last4 text check (last4 is null or char_length(last4) <= 4),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  uses int not null default 1,
  primary key (user_id, fingerprint)
);

comment on table public.user_payment_cards is
  '利用者が使った決済カードの記録(Stripeのフィンガープリント。カード番号は保存しない)。自作自演の検知に用いる。家族カードで正当に一致しうるため遮断ではなくフラグに使う。';

alter table public.user_payment_cards enable row level security;

-- 本人は自分の分だけ見える。他人のカード共有は見せない
create policy "user_payment_cards_select_own"
  on public.user_payment_cards for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは record_payment_card(service_role)経由のみ。ポリシーは作らない。

create index if not exists user_payment_cards_fp_idx
  on public.user_payment_cards (fingerprint);

-- ------------------------------------------------------------
-- record_payment_card: 購入が成立したカードを記録する
--
-- **stripe-webhook からのみ呼ぶ(service_role)。** クライアントに開けると、
-- 他人のフィンガープリントを詐称して共有関係を捏造できてしまう。
-- ------------------------------------------------------------
create or replace function public.record_payment_card(
  p_user_id uuid,
  p_fingerprint text,
  p_brand text default null,
  p_last4 text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fp text := btrim(coalesce(p_fingerprint, ''));
begin
  if p_user_id is null or char_length(v_fp) < 4 or char_length(v_fp) > 128 then
    return;
  end if;

  insert into public.user_payment_cards (user_id, fingerprint, brand, last4)
  values (p_user_id, v_fp, nullif(btrim(coalesce(p_brand, '')), ''),
          nullif(btrim(coalesce(p_last4, '')), ''))
  on conflict (user_id, fingerprint) do update
    set last_seen_at = now(),
        uses = public.user_payment_cards.uses + 1,
        -- 初回に取れなかった場合だけ埋める(上書きはしない)
        brand = coalesce(public.user_payment_cards.brand, excluded.brand),
        last4 = coalesce(public.user_payment_cards.last4, excluded.last4);
end;
$$;

comment on function public.record_payment_card(uuid, text, text, text) is
  '購入が成立した決済カードのフィンガープリントを記録する。stripe-webhook(service_role)専用。';

revoke all on function public.record_payment_card(uuid, text, text, text) from public;
-- authenticated には**あえて grant しない**(詐称を防ぐため)

-- ------------------------------------------------------------
-- _shares_payment_card: 2人が同じカードを使った履歴があるか
-- ------------------------------------------------------------
create or replace function public._shares_payment_card(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_a is not null and p_b is not null and p_a <> p_b
     and exists (
       select 1
       from public.user_payment_cards a
       join public.user_payment_cards b on b.fingerprint = a.fingerprint
       where a.user_id = p_a and b.user_id = p_b
     );
$$;

revoke all on function public._shares_payment_card(uuid, uuid) from public;

-- ------------------------------------------------------------
-- gifts.card_flagged: 送り主と受け手がカードを共有していた
--
-- **send_gift 本体は書き換えない。** 送金の本流を触らずにトリガで足す。
-- 0022 の ip_flagged と同じ扱い(遮断しない・換金前の目視対象)。
-- ------------------------------------------------------------
alter table public.gifts
  add column if not exists card_flagged boolean not null default false;

comment on column public.gifts.card_flagged is
  '送り主と受け手が同じ決済カードを使った履歴がある場合にtrue。遮断はしないが、換金前の目視確認対象。';

create or replace function public._flag_gift_shared_card()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.card_flagged := public._shares_payment_card(new.sender_id, new.receiver_id);
  return new;
end;
$$;

revoke all on function public._flag_gift_shared_card() from public;

drop trigger if exists gifts_flag_shared_card on public.gifts;
create trigger gifts_flag_shared_card
  before insert on public.gifts
  for each row execute function public._flag_gift_shared_card();

-- ------------------------------------------------------------
-- admin_shared_cards: カードを共有しているアカウントの組(調査の入口)
-- ------------------------------------------------------------
create or replace function public.admin_shared_cards()
returns table (
  fingerprint text,
  brand text,
  last4 text,
  user_a uuid,
  name_a text,
  user_b uuid,
  name_b text,
  last_seen_at timestamptz
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
  select a.fingerprint,
         coalesce(a.brand, b.brand),
         coalesce(a.last4, b.last4),
         a.user_id, coalesce(nullif(pa.nickname, ''), '(不明)'),
         b.user_id, coalesce(nullif(pb.nickname, ''), '(不明)'),
         greatest(a.last_seen_at, b.last_seen_at)
  from public.user_payment_cards a
  join public.user_payment_cards b
    on b.fingerprint = a.fingerprint and a.user_id < b.user_id
  left join public.profiles pa on pa.id = a.user_id
  left join public.profiles pb on pb.id = b.user_id
  order by greatest(a.last_seen_at, b.last_seen_at) desc;
end;
$$;

comment on function public.admin_shared_cards() is
  '同じ決済カードを使ったアカウントの組(運営のみ)。振込前の確認に使う。一致だけでは不正と断定しないこと(家族カード)。';

revoke all on function public.admin_shared_cards() from public;
grant execute on function public.admin_shared_cards() to authenticated;

-- ------------------------------------------------------------
-- admin_pending_payouts を作り直し、**共有の件数を並べて出す**
--
-- 別画面に置くと見に行かない。**資金が外へ出る瞬間に目に入る**ことが
-- この機能の値打ちなので、振込リストの各行に出す。
-- ------------------------------------------------------------
-- 返す列が増えるので、create or replace では差し替えられない
drop function if exists public.admin_pending_payouts(int);

create function public.admin_pending_payouts(p_limit int default 100)
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  coins int,
  amount_yen int,
  fee_yen int,
  created_at timestamptz,
  bank_name text,
  bank_code text,
  branch_name text,
  branch_code text,
  account_type text,
  account_number text,
  account_holder_kana text,
  is_verified boolean,
  shared_card_count int,
  flagged_gift_count int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*) into v_n from public.payouts p where p.status = 'pending';
  perform public._log_admin_action('view_pending_payouts', null, v_n || '件の口座情報を表示');

  return query
  select p.id, p.user_id,
         coalesce(nullif(pf.nickname, ''), '(不明)'),
         p.coins, p.amount_yen, p.fee_yen, p.created_at,
         p.bank_name, p.bank_code, p.branch_name, p.branch_code,
         p.account_type, p.account_number, p.account_holder_kana,
         coalesce(ts.is_verified, false),
         -- このピタメイトとカードを共有している**他の**アカウントの数
         (select count(distinct b.user_id)::int
            from public.user_payment_cards a
            join public.user_payment_cards b
              on b.fingerprint = a.fingerprint and b.user_id <> a.user_id
           where a.user_id = p.user_id),
         -- 受け取ったギフトのうち、IPまたはカードの共有で印が付いたもの
         (select count(*)::int from public.gifts g
           where g.receiver_id = p.user_id
             and (g.ip_flagged or g.card_flagged))
  from public.payouts p
  left join public.profiles pf on pf.id = p.user_id
  left join public.profile_trust_stats ts on ts.user_id = p.user_id
  where p.status = 'pending'
  order by p.created_at
  limit greatest(1, least(p_limit, 500));
end;
$$;

comment on function public.admin_pending_payouts(int) is
  '未振込の換金申請と振込先(運営のみ)。0080でカード共有件数と要確認ギフト件数を追加した(資金が出る瞬間に目に入るようにするため)。閲覧は操作記録に残る。';

revoke all on function public.admin_pending_payouts(int) from public;
grant execute on function public.admin_pending_payouts(int) to authenticated;
-- ============================================================
-- 0081: 居住地の自己申告  ★突合表 G4
--
-- 規約 第3条3項は「本サービスは、**日本国内に居住する個人**に限り
-- ご利用いただけます」と定めているのに、**申告欄も確認も無かった。**
-- 突合表(`docs/legal/terms-implementation-matrix.md`)で見つかった不一致。
--
-- 弁護士の整理:「**自己申告で足りる。**居住地の実質的な審査は求められない。
-- 重要なのは、①利用条件として明示していること ②申告を求め、その事実を
-- 記録していること ③虚偽が判明したときの措置を定めていること。」
-- ③は既に第3条4項にある。ここで①②を埋める。
--
-- なぜ「記録」まで要るのか:
--   E-4(みまもり同意)と同じ失敗を繰り返さないため。あのときは同意の
--   チェックボックスは出していたのに、**同意した事実がどこにも保存されて
--   おらず、後から証明できなかった。** 画面のチェックだけでは、
--   「利用条件として提示した」ことの証跡が残らない。
--
-- なぜトリガで止めるのか:
--   画面のチェックボックスだけにすると、規約に書いた条件が画面の実装に
--   依存する。**G4の指摘そのものが「条文はあるのに実装が無い」**だった
--   ので、DB側で本人確認の提出を止める。0074(みまもり撤回)と同じ考え方。
--
-- ⚠️ **国籍では区別しない。** 条文どおり居住地だけを尋ねる。
--    国籍を尋ねると、目的外の要配慮情報に近づくうえ、条文とも食い違う。
-- ============================================================

-- ------------------------------------------------------------
-- residency_declarations: 申告の履歴(上書きせず積む)
--
-- 引っ越しで変わりうるので、最新の1件ではなく履歴として持つ。
-- monitoring_consents と同じ形にしてある。
-- ------------------------------------------------------------
create table if not exists public.residency_declarations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 日本国内に居住していると申告したか。false も記録する
  -- (「尋ねたが、いいえと答えた」ことも証跡として意味がある)
  declared_japan boolean not null,
  -- 申告時に提示していた条文のバージョン
  version text not null check (char_length(version) between 1 and 40),
  declared_at timestamptz not null default now()
);

comment on table public.residency_declarations is
  '居住地の自己申告の履歴(規約第3条3項)。弁護士の整理により実質的な審査は行わず、申告を求めた事実と回答を記録する。国籍は取得しない。';

alter table public.residency_declarations enable row level security;

create policy "residency_declarations_select_own"
  on public.residency_declarations for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは declare_residency 経由のみ(ポリシーは作らない)。

create index if not exists residency_declarations_user_idx
  on public.residency_declarations (user_id, declared_at desc);

-- ------------------------------------------------------------
-- declare_residency: 申告を記録する
-- ------------------------------------------------------------
create or replace function public.declare_residency(
  p_declared_japan boolean,
  p_version text default 'v1'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_declared_japan is null then
    raise exception 'DECLARATION_REQUIRED';
  end if;

  insert into public.residency_declarations (user_id, declared_japan, version)
  values (v_uid, p_declared_japan,
          coalesce(nullif(btrim(p_version), ''), 'v1'));
end;
$$;

comment on function public.declare_residency(boolean, text) is
  '居住地の自己申告を記録する(規約第3条3項)。上書きせず履歴として積む。';

revoke all on function public.declare_residency(boolean, text) from public;
grant execute on function public.declare_residency(boolean, text) to authenticated;

-- ------------------------------------------------------------
-- my_residency_declaration: 画面が状態を出すための読み取り
-- ------------------------------------------------------------
create or replace function public.my_residency_declaration()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object(
              'declaredJapan', d.declared_japan,
              'version', d.version,
              'declaredAt', d.declared_at)
       from public.residency_declarations d
      where d.user_id = auth.uid()
      order by d.declared_at desc
      limit 1),
    jsonb_build_object('declaredJapan', null, 'version', null, 'declaredAt', null));
$$;

revoke all on function public.my_residency_declaration() from public;
grant execute on function public.my_residency_declaration() to authenticated;

-- ------------------------------------------------------------
-- 本人確認の提出を、申告が済むまで止める
--
-- **「はい」と答えていない限り通さない。** 未申告と「いいえ」を
-- 別のエラーにしているのは、画面で出す文言が違うため
-- (未申告は「チェックしてください」、いいえは「ご利用いただけません」)。
-- ------------------------------------------------------------
create or replace function public._require_residency_declaration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_latest boolean;
begin
  select d.declared_japan into v_latest
  from public.residency_declarations d
  where d.user_id = new.user_id
  order by d.declared_at desc
  limit 1;

  if v_latest is null then
    raise exception 'RESIDENCY_NOT_DECLARED';
  end if;
  if not v_latest then
    raise exception 'RESIDENCY_OUTSIDE_JAPAN';
  end if;
  return new;
end;
$$;

revoke all on function public._require_residency_declaration() from public;

drop trigger if exists identity_verifications_require_residency on public.identity_verifications;
create trigger identity_verifications_require_residency
  before insert on public.identity_verifications
  for each row execute function public._require_residency_declaration();

comment on function public._require_residency_declaration() is
  '本人確認の提出前に、居住地の自己申告(規約第3条3項)が済んでいることを求める。既存の申請には影響しない(INSERTのみ)。';
-- ============================================================
-- 0082: コインの消費順序を「有効期限の早いもの優先」に改める
--       ★弁護士 第3回回答 論点4
--
-- これまでの順序:
--   ①有償を先に使い切る ②各種別の中では期限の早いロットから
--
-- 何が起きていたか:
--   複数回購入すると、**期限順なら失効しなかったはずの無償コインが
--   失効する**場面が構造的に生じていた。
--
--     | ロット   | 種別 | 期限   |
--     | A-有償   | 有償 | 6月末  |
--     | A-無償   | 無償 | 6月末  |
--     | B-有償   | 有償 | 12月末 |
--
--   旧: A-有償 → **B-有償** → A-無償  ⇒ 6月末に A-無償 が未使用で失効
--   新: A-有償 → A-無償 → B-有償      ⇒ 失効しない
--
-- 弁護士の指摘(要旨):
--   「無償付与分の失効が直ちに消費者契約法10条違反となる可能性は高くないが、
--    問題はむしろ**景品表示法**の方向にある。『ボーナス+100』と表示して
--    購入を誘引しながら、消費順序の仕組み上ボーナスが失効しやすいのであれば、
--    **有利誤認(5条2号)** の議論を招き得る。
--    **避けられる不利益を仕組みが作っている**状態は、どの法枠組みでも
--    説明しづらい。」
--
--   採るべきは二者択一ではなく両者の組み合わせ:
--     **①有効期限の早い順 → ②同一期限内では有償が先**
--   これが利用者にとって支配的に有利になる。失効総額を最小化しつつ、
--   同一期限内では(購入取消し等の場面で意味を持つ)有償分を先に減らす。
--   「期限順・種別問わず」だけにすると、同一期限内で無償を先に使った結果
--   **有償分が失効する**という逆の不利益を作るため劣る。
--
-- 変えていないもの:
--   ・ギフトの原資は有償コインのみ(規約 第7条の2)。send_gift は
--     _consume_coin_lots(..., 'paid', ...) しか呼ばないので影響しない
--   ・ロット内の消費は従来どおり期限の早い順
--
-- ============================================================

-- ------------------------------------------------------------
-- _split_coins_by_expiry: 期限順に見て、有償・無償それぞれ何枚使うかを決める
--
-- **実際に消費はしない。** 枚数を返すだけの純粋な計算。
-- 呼び出し側はこの枚数で _consume_coin_lots_tracked を種別ごとに呼ぶ。
--
-- 種別ごとに分けて消費しても結果が同じになる理由:
--   期限順に並べた列から取るのは、有償列の**先頭からの連続**と
--   無償列の**先頭からの連続**である。したがって
--   「有償をP枚・期限の早い順」「無償をB枚・期限の早い順」と
--   分けて取っても、選ばれるロットは完全に一致する。
-- ------------------------------------------------------------
create or replace function public._split_coins_by_expiry(
  p_user_id uuid,
  p_amount int
)
returns table (paid int, bonus int)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_left int := greatest(0, coalesce(p_amount, 0));
  v_lot record;
  v_take int;
  v_paid int := 0;
  v_bonus int := 0;
begin
  for v_lot in
    select l.kind, l.remaining
    from public.coin_lots l
    where l.user_id = p_user_id and l.remaining > 0 and l.expires_at > now()
    -- ①期限の早い順 ②同じ期限なら有償が先
    order by l.expires_at asc, (l.kind = 'paid') desc, l.id
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.remaining, v_left);
    if v_lot.kind = 'paid' then
      v_paid := v_paid + v_take;
    else
      v_bonus := v_bonus + v_take;
    end if;
    v_left := v_left - v_take;
  end loop;

  -- ロットが足りない場合(0030より前の予約など、ロット記録が無い利用者)は
  -- 残りを有償に寄せる。**残高の判定は呼び出し側で済んでいる**ので、
  -- ここで例外にはしない(判定の二重化は、片方だけ直したときに壊れる)。
  if v_left > 0 then
    v_paid := v_paid + v_left;
  end if;

  paid := v_paid;
  bonus := v_bonus;
  return next;
end;
$fn$;

comment on function public._split_coins_by_expiry(uuid, int) is
  'コインを消費するとき、有償・無償それぞれ何枚使うかを期限順に決める(同一期限内は有償が先)。0082・弁護士 第3回回答 論点4。計算のみで消費はしない。';

revoke all on function public._split_coins_by_expiry(uuid, int) from public;

-- ------------------------------------------------------------
-- create_booking / extend_booking を、上の関数を使うように差し替える
-- **本体のロジックは変えていない。** 充当の内訳を決める2行だけを置き換えた。
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_scheduled_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
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
$fn$;

create or replace function public.extend_booking(
  p_booking_id uuid,
  p_additional_minutes int
)
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_max int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
  end if;

  -- 延長は終了時刻を後ろにずらすので、次の予約に食い込まないか確かめる。
  -- ここも成立済みだけを見る。まだ承諾されていない後続のリクエストのために
  -- 進行中のプレイの延長を止めるのは、優先順位が逆。
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(
       v_booking.guest_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 期限の早いロットから充当する(同一期限内は有償が先)
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_uid, v_add_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
  values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$fn$;

comment on function public.create_booking(uuid, int, text, timestamptz) is
  '予約の作成。0082で、コインの充当を「有効期限の早いロット優先(同一期限内は有償が先)」に改めた。';
comment on function public.extend_booking(uuid, int) is
  'プレイ時間の延長。0082で、コインの充当を「有効期限の早いロット優先(同一期限内は有償が先)」に改めた。';
-- ============================================================
-- 0083: 購入ボーナス(上乗せコイン)を廃止する
--
-- 事業判断による廃止。**法務・税務・会計の3方向で、無償コインだけを
-- 原因とする論点が同時に消える。**
--
--   法務: 弁護士 第3回回答 論点4(景品表示法5条2号・有利誤認)
--         「ボーナス+100」と表示して購入を誘引しながら、消費順序の
--         仕組み上ボーナスが失効しやすいのは説明しづらい、という指摘。
--         **表示自体をやめれば論点が成立しない。**
--   税務: 無償コイン起因のPF利用料の純額処理(税理士 第4回回答)。
--         現金を受け取っていない取引で課税売上高が膨らむ問題が消える。
--   資金: 分別管理規程 第7条2号の「無償コイン起因のピタメイト報酬」=
--         **回収されない真の持ち出し**。上乗せ率1.5%の分岐点も消える。
--
-- ■ 何を消して、何を残すか
--
-- 消す:   coin_packs.bonus_coins を全て0にし、**0以外を入れられなくする**
-- 残す:   coin_lots.kind='bonus' / bookings.bonus_coins /
--         coin_transactions.type='bonus' の**列と値の定義**
--
--   残す理由は2つ。
--   ①これらは追記専用の台帳(0044)であり、**過去の行を消せない**。
--     未公開で実データは無いが、列を落とすと復元の経路まで壊れる。
--   ②将来ボーナスを再開する判断があったとき、**器を作り直すより
--     この migration を1本戻すほうが安全**。0082の消費順序
--     (期限の早い順・同一期限内は有償が先)もそのまま効く。
--
-- ■ 表示の建付けは変えない
--   購入は「コイン代金 + あんしんサポート料」の2行のまま。
--   ボーナスが0になるだけで、決済額の計算は変わらない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 全パックのボーナスを0にする
-- ------------------------------------------------------------
update public.coin_packs set bonus_coins = 0 where bonus_coins <> 0;

-- ------------------------------------------------------------
-- 2. **0以外を入れられなくする**
--
-- データを0にするだけだと、管理画面やSQLから戻せてしまう。
-- 廃止は事業判断なので、**戻すときは migration を書く**という形にする。
-- 「なぜ0なのか」がスキーマに残るのが要点。
-- ------------------------------------------------------------
alter table public.coin_packs drop constraint if exists coin_packs_no_bonus_check;
alter table public.coin_packs
  add constraint coin_packs_no_bonus_check check (bonus_coins = 0);

comment on column public.coin_packs.bonus_coins is
  '購入時の上乗せコイン。**0083で廃止し、0以外を入れられない。**再開する場合は制約を外す migration を書くこと(法務: 景表法の有利誤認 / 税務: 無償コイン起因の純額処理 / 資金: 分別口座への補填が同時に復活する)。';

-- ------------------------------------------------------------
-- 3. 付与側でも止める(多層で防ぐ)
--
-- Webhook はパックの bonus_coins をメタデータ経由で渡してくる。
-- 上の制約でパック側は0になるが、**メタデータは決済時点の値が
-- そのまま残る**ので、廃止をまたいだ決済が届く可能性がある。
--
-- ⚠️ **例外にはしない。** ここで失敗させると、代金を受け取ったのに
-- コインが付与されない事故になる。**有償分だけを付与して先へ進む。**
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
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets
    set balance = balance + p_coins
    where user_id = p_user_id;

  insert into public.coin_lots (user_id, kind, remaining, expires_at)
    values (p_user_id, 'paid', p_coins, v_expires);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$fn$;

comment on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) is
  'Webhook から呼ぶ冪等なコイン付与(service_role専用)。0083で購入ボーナスを廃止したため、p_bonus_coins は無視する(引数は互換のために残している)。';

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;
-- ============================================================
-- 0084: 通知設定の行が無いユーザーを救済する
--
-- ■ 何が起きていたか
--   設定画面の「通知」3つのトグルが、押しても何も起きない。
--   画面には「取得に失敗しました」とだけ出る。
--
--   原因は notification_prefs の**行が無い**こと。この表(0012)は
--   auth.users への INSERT トリガでしか行を作らないので、
--   **0012 を当てる前に登録したユーザーには行が存在しない。**
--
--   フロントは .single() で1行を取りに行くため、行が無いと
--   PGRST116 で失敗し、状態が null のままになる。トグルの押下は
--   `if (!prefs) return` で捨てられる。だから「押しても無反応」。
--
--   さらに悪いことに、更新は update … where user_id = auth.uid() で、
--   **行が無ければ0行更新でエラーにならない。** 仮に読み取りだけ
--   直しても、書き込みが静かに消える経路が残っていた。
--
-- ■ どう直すか
--   ①既存ユーザー全員に行を作る(取りこぼしの解消)
--   ②**読み書きを「無ければ作る」関数に寄せる。**
--     トリガに依存する作りだと、今後もどこかの経路で行が無いユーザーが
--     生まれたときに同じ壊れ方をする。**行の有無を呼び出し側の
--     関心事から外す。**
--
--   INSERT ポリシーは 0012 の判断どおり作らない。行の作成は
--   SECURITY DEFINER のこの2本だけが行い、user_id は必ず
--   auth.uid() で固定する(他人の行は作れない)。
--
-- ■ 既定値をここに書かない
--   insert … on conflict do nothing → update の2段にしてある。
--   coalesce(p_invites, true) のように既定値を関数側へ写すと、
--   表の default と二重管理になり、片方だけ変えたときに食い違う。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 取りこぼしを埋める
-- ------------------------------------------------------------
insert into public.notification_prefs (user_id)
select u.id from auth.users u
left join public.notification_prefs p on p.user_id = u.id
where p.user_id is null;

-- ------------------------------------------------------------
-- 2. 読み取り: 無ければ作ってから返す
-- ------------------------------------------------------------
-- 戻り値は jsonb。1行だけを返す設定系は 0062 my_fast_release と同じ形に揃える
create or replace function public.get_notification_prefs()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into public.notification_prefs (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  select jsonb_build_object(
    'notify_invites', p.notify_invites,
    'notify_online_friends', p.notify_online_friends,
    'notify_recommendations', p.notify_recommendations)
  into v_out
  from public.notification_prefs p
  where p.user_id = v_uid;

  return v_out;
end;
$$;

comment on function public.get_notification_prefs() is
  '自分の通知設定。行が無ければ既定値で作ってから返す。';

-- ------------------------------------------------------------
-- 3. 更新: null は「変更しない」
-- ------------------------------------------------------------
-- 画面はトグル1つだけを送ってくる。3つまとめて送る形にすると、
-- 別の端末で先に変えた設定を**知らないうちに上書きする。**
create or replace function public.set_notification_prefs(
  p_invites boolean default null,
  p_online_friends boolean default null,
  p_recommendations boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into public.notification_prefs (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  update public.notification_prefs p set
    notify_invites         = coalesce(p_invites,         p.notify_invites),
    notify_online_friends  = coalesce(p_online_friends,  p.notify_online_friends),
    notify_recommendations = coalesce(p_recommendations, p.notify_recommendations)
  where p.user_id = v_uid;

  -- **更新後の値を返す。** 画面は返ってきた値で状態を作り直すので、
  -- 送った値と保存された値がずれたままにならない
  select jsonb_build_object(
    'notify_invites', p.notify_invites,
    'notify_online_friends', p.notify_online_friends,
    'notify_recommendations', p.notify_recommendations)
  into v_out
  from public.notification_prefs p
  where p.user_id = v_uid;

  return v_out;
end;
$$;

comment on function public.set_notification_prefs(boolean, boolean, boolean) is
  '自分の通知設定を変更する。null の項目は変更しない。保存後の値を返す。';

-- ------------------------------------------------------------
-- 4. 権限。SECURITY DEFINER なので PUBLIC から必ず剥がす(74_anon_surface)
-- ------------------------------------------------------------
revoke all on function public.get_notification_prefs() from public, anon;
revoke all on function public.set_notification_prefs(boolean, boolean, boolean) from public, anon;
grant execute on function public.get_notification_prefs() to authenticated;
grant execute on function public.set_notification_prefs(boolean, boolean, boolean) to authenticated;
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
-- ============================================================
-- 0086: 退会(G6)
--
-- 規約 第6条の2(2026-07-31 新設):
--   1. ユーザーは、いつでも当社所定の方法により退会することができる
--   2. **成立済みの予約は、履行またはキャンセルを完了させてから**退会する
--   3. 退会の時点で保有するコインは消滅し、返金しない。
--      **当社は、退会の手続を行う画面において、消滅するコインの数を
--      事前に表示する**
--   4. **退会後も、退会日から90日間に限り、報酬コインの換金を申請できる。**
--      本人確認および振込先口座の状態は退会時のものによる。
--      当該期間の経過後、報酬コインは消滅する
--   5. 退会後も、法令に基づく記録の保存その他必要な範囲で記録を保持する
--
-- ■ なぜこれが要るか
--   退会条項そのものが規約に無かった。弁護士(総評3・論点3(c))の指摘:
--   「**換金できない残高を人質に離脱を妨げる外形は、優越的地位の濫用の
--   評価において最も分の悪い事実になる**」。
--
--   したがってこの実装の核心は「退会できること」ではなく、
--   **「辞めた後も、稼いだ分を回収できること」**にある。
--
-- ■ 退会 ≠ アカウント削除
--   90日間は換金を申請できなければならないので、**ログインは残す。**
--   削除の請求は従来どおり account_requests で別に受ける。
--
-- ■ 消すもの / 残すもの
--   消す: 有償・無償コイン(第7条3項により返金しない)、掲載
--   残す: 報酬コイン(90日)、取引の記録、プロフィール(記録保持のため)
-- ============================================================

-- ------------------------------------------------------------
-- 1. 退会の状態
-- ------------------------------------------------------------
alter table public.profiles
  add column if not exists withdrawn_at timestamptz;

create index if not exists profiles_withdrawn_idx
  on public.profiles (withdrawn_at) where withdrawn_at is not null;

comment on column public.profiles.withdrawn_at is
  '規約第6条の2の退会日時。null は在籍中。退会後90日は換金のみ可能。';

-- 退会の記録。**あとから「何が消えたか」を説明できるようにする**
create table if not exists public.account_withdrawals (
  user_id uuid primary key references auth.users (id) on delete cascade,
  withdrawn_at timestamptz not null default now(),
  -- 退会時に消滅させたコイン
  expired_paid_coins int not null default 0,
  expired_bonus_coins int not null default 0,
  -- 退会時に残した報酬コインと、換金できる期限
  earned_balance int not null default 0,
  payout_deadline timestamptz not null,
  -- 期限到来で報酬コインを消滅させた日時
  earned_expired_at timestamptz,
  reason text
);

comment on table public.account_withdrawals is
  '規約第6条の2の退会記録。消滅させたコインの数と、換金できる期限(退会日+90日)。';

alter table public.account_withdrawals enable row level security;

create policy "account_withdrawals_select_own"
  on public.account_withdrawals for select
  to authenticated
  using (user_id = auth.uid());

create policy "account_withdrawals_select_admin"
  on public.account_withdrawals for select
  to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- ------------------------------------------------------------
-- 1-b. 通知の種別に 'system' を足す
--
-- 退会の完了と換金期限の到来は、既存のどの種別にも当てはまらない。
-- **既存の種別に無理に寄せると、通知一覧の見出しが実態と食い違う。**
-- ------------------------------------------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed', 'booking_requested',
    'booking_approved', 'gift_received', 'booking_extended',
    'board_cancelled', 'integrity_alert', 'booking_no_show',
    'host_slots_opened', 'system'));

-- ------------------------------------------------------------
-- 2. 退会できるか / 何が消えるか(**画面に出すための材料**)
--
-- 規約第6条の2第3項は「消滅するコインの数を事前に表示する」と
-- **約束している。** 表示できなければ条文違反になるので、
-- 数を返すのは実装の一部であって付け足しではない。
-- ------------------------------------------------------------
create or replace function public.withdrawal_preview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_verified boolean;
  v_has_bank boolean;
  v_withdrawn timestamptz;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  select p.withdrawn_at into v_withdrawn from public.profiles p where p.id = v_uid;

  -- 履行もキャンセルも済んでいない予約(第6条の2第2項)
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');

  select coalesce(w.balance, 0), coalesce(w.bonus_balance, 0), coalesce(w.earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets w where w.user_id = v_uid;

  select coalesce(s.is_verified, false) into v_verified
  from public.profile_trust_stats s where s.user_id = v_uid;

  select exists (select 1 from public.host_bank_accounts a where a.user_id = v_uid)
    into v_has_bank;

  return jsonb_build_object(
    'withdrawn_at', v_withdrawn,
    'blocking_bookings', coalesce(v_blocking, 0),
    'can_withdraw', v_withdrawn is null and coalesce(v_blocking, 0) = 0,
    -- 消滅するコイン(第7条3項により返金しない)
    'expiring_paid', coalesce(v_paid, 0),
    'expiring_bonus', coalesce(v_bonus, 0),
    -- 退会後も90日間は換金できる報酬コイン
    'earned_balance', coalesce(v_earned, 0),
    'payout_days', 90,
    'payout_deadline', coalesce(v_withdrawn, now()) + interval '90 days',
    -- 換金の条件が退会時に揃っているか。**退会後は本人確認をやり直せない**
    'verified', coalesce(v_verified, false),
    'has_bank_account', coalesce(v_has_bank, false)
  );
end;
$$;

comment on function public.withdrawal_preview() is
  '退会の画面に出す材料。消滅するコインの数と、退会後に換金できる期限(規約第6条の2第3項・第4項)。';

revoke all on function public.withdrawal_preview() from public, anon;
grant execute on function public.withdrawal_preview() to authenticated;

-- ------------------------------------------------------------
-- 3. 退会の実行
-- ------------------------------------------------------------
create or replace function public.withdraw_account(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  if exists (select 1 from public.profiles p
              where p.id = v_uid and p.withdrawn_at is not null) then
    raise exception 'ALREADY_WITHDRAWN';
  end if;

  -- 第6条の2第2項。**成立済みの予約を残したまま辞めさせない。**
  -- 相手のあることなので、片方が黙って消えると相手が救済されない
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');
  if coalesce(v_blocking, 0) > 0 then
    raise exception 'HAS_ACTIVE_BOOKINGS';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = v_uid for update;

  -- ----------------------------------------------------------
  -- コインを消滅させる(第7条3項・第6条の2第3項)
  --
  -- **報酬コイン(earned_balance)には手を付けない。** 換金の対象であり、
  -- ここで消すと弁護士の指摘した「人質」そのものになる
  -- ----------------------------------------------------------
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots
      set remaining = 0
      where user_id = v_uid and remaining > 0;
    update public.coin_wallets
      set balance = 0, bonus_balance = 0
      where user_id = v_uid;
    if coalesce(v_paid, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_paid, 'expire', 'withdraw_paid');
    end if;
    if coalesce(v_bonus, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_bonus, 'expire', 'withdraw_bonus');
    end if;
  end if;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**ので、
  -- ここを落とすことで退会者が誰の目にも触れなくなる
  update public.host_settings set is_host = false where user_id = v_uid;
  update public.profiles
    set withdrawn_at = now(), presence_status = 'busy'
    where id = v_uid;

  insert into public.account_withdrawals
    (user_id, expired_paid_coins, expired_bonus_coins, earned_balance, payout_deadline, reason)
  values (v_uid, coalesce(v_paid, 0), coalesce(v_bonus, 0), coalesce(v_earned, 0),
          v_deadline, p_reason);

  -- 期限を本人に残す。画面を閉じても分かるように通知にも書く
  insert into public.notifications (user_id, type, title, body)
  values (v_uid, 'system', '退会の手続が完了しました',
    case when coalesce(v_earned, 0) > 0
      then '報酬コイン' || v_earned || '枚の換金は、'
             || to_char(v_deadline, 'YYYY年MM月DD日') || 'まで申請できます。'
             || '期限を過ぎると消滅します。'
      else 'ご利用ありがとうございました。' end);

  return jsonb_build_object(
    'withdrawn_at', now(),
    'expired_paid', coalesce(v_paid, 0),
    'expired_bonus', coalesce(v_bonus, 0),
    'earned_balance', coalesce(v_earned, 0),
    'payout_deadline', v_deadline
  );
end;
$$;

comment on function public.withdraw_account(text) is
  '規約第6条の2の退会。有償・無償コインを消滅させ、報酬コインは90日間だけ換金できる状態で残す。';

revoke all on function public.withdraw_account(text) from public, anon;
grant execute on function public.withdraw_account(text) to authenticated;

-- ------------------------------------------------------------
-- 4. 退会したアカウントを、サービスから締め出す
--
-- 0074 が既にメッセージ・誘い・予約・募集の4経路にトリガを張っており、
-- そのすべてが `_require_monitoring_consent` を通る。
-- **同じ入口に退会の判定を足すのが、漏れが最も少ない。**
-- トリガを5本作り直すより、通る場所を1つにしておくほうが安全。
-- ------------------------------------------------------------
create or replace function public._is_withdrawn(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = p_user and p.withdrawn_at is not null)
$$;

revoke all on function public._is_withdrawn(uuid) from public, anon;

create or replace function public._require_monitoring_consent(p_self uuid, p_other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 0086: 退会したアカウントは、みまもり同意の有無以前に利用できない
  if public._is_withdrawn(p_self) then
    raise exception 'ACCOUNT_WITHDRAWN';
  end if;
  if public._is_withdrawn(p_other) then
    raise exception 'PARTNER_ACCOUNT_WITHDRAWN';
  end if;

  if public._monitoring_consent_revoked(p_self) then
    raise exception 'MONITORING_CONSENT_REVOKED';
  end if;
  if public._monitoring_consent_revoked(p_other) then
    raise exception 'PARTNER_MONITORING_CONSENT_REVOKED';
  end if;
end;
$$;

comment on function public._require_monitoring_consent(uuid, uuid) is
  '利用できる状態かをまとめて確かめる。①退会していないこと(0086・第6条の2)②みまもり同意が撤回されていないこと(0074・Q19)。メッセージは双方の通信なので相手側も見る。';

revoke all on function public._require_monitoring_consent(uuid, uuid) from public, anon;

-- ------------------------------------------------------------
-- 5. 換金は退会後90日まで(第6条の2第4項)
--
-- request_bank_payout 本体は触らない。**入口の payouts に条件を張る**
-- ほうが、条件の置き場所が1か所で済み、将来の経路追加にも効く。
-- ------------------------------------------------------------
create or replace function public._payouts_check_withdrawal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deadline timestamptz;
begin
  -- **期限は account_withdrawals.payout_deadline が唯一の権威。**
  -- profiles.withdrawn_at から都度計算すると、記録側と判定側で
  -- 二重の真実になり、片方だけ直したときに食い違う
  select aw.payout_deadline into v_deadline
  from public.account_withdrawals aw where aw.user_id = new.user_id;

  if v_deadline is not null and now() > v_deadline then
    raise exception 'PAYOUT_WINDOW_CLOSED';
  end if;
  return new;
end;
$$;

revoke all on function public._payouts_check_withdrawal() from public, anon;

drop trigger if exists payouts_check_withdrawal on public.payouts;
create trigger payouts_check_withdrawal
  before insert on public.payouts
  for each row execute function public._payouts_check_withdrawal();

-- ------------------------------------------------------------
-- 6. 90日を過ぎた報酬コインを消滅させる(第6条の2第4項の後段)
--
-- **申請中(pending)の換金があるうちは消さない。** 申請したのに
-- 振込前に消えるのは、条文のどこにも書いていない。
-- ------------------------------------------------------------
create or replace function public.expire_withdrawn_earned()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_count int := 0;
begin
  for v_rec in
    select aw.user_id, coalesce(w.earned_balance, 0) as earned
    from public.account_withdrawals aw
    join public.coin_wallets w on w.user_id = aw.user_id
    where aw.earned_expired_at is null
      and aw.payout_deadline < now()
      and coalesce(w.earned_balance, 0) > 0
      and not exists (
        select 1 from public.payouts p
        where p.user_id = aw.user_id and p.status = 'pending')
    for update of aw skip locked
  loop
    update public.coin_wallets set earned_balance = 0 where user_id = v_rec.user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (v_rec.user_id, -v_rec.earned, 'expire', 'withdraw_earned_expired');
    update public.account_withdrawals
      set earned_expired_at = now() where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system', '報酬コインの換金期限が過ぎました',
      '退会から90日が経過したため、報酬コイン' || v_rec.earned || '枚は消滅しました。');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.expire_withdrawn_earned() is
  '退会から90日を過ぎた報酬コインを消滅させる(規約第6条の2第4項)。申請中の換金があるうちは消さない。';

revoke all on function public.expire_withdrawn_earned() from public, anon;

select cron.schedule('expire-withdrawn-earned', '31 3 * * *',
  $$select public.expire_withdrawn_earned()$$);

-- ------------------------------------------------------------
-- 7. 会計仕訳: 退会で消滅したコイン
--
-- **J16 は expire_coins() が付ける note='lot:...' しか拾わない。**
-- 退会による消滅は別の note なので、足さないと前受金が過大に残る
-- (0085 の J18 と同じ形の取りこぼし)。
-- ------------------------------------------------------------
-- accounting_journal は 0085 で J18〜J21 まで足してある。
-- ここでは退会分(J22)を足すために作り直す。
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

  order by 1, 2, 10;
end;
$$;

comment on function public.accounting_journal(date, date) is
  '期間内の取引を会計ソフト取込用の単純仕訳(1行=借方1・貸方1)にして返す(運営のみ)。1コイン=1円。読み取りのみ。Stripeの着金・決済手数料と、経費・按分はここには出ない(明細から別途起票する)。';

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;
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
-- ============================================================
-- 0090: 購入の取消しと、あんしんサポート料の返還(G5)
--
-- 規約 第7条の3第5項:
--   購入の効力が失われた場合、当社は**あんしんサポート料も返還**する。
--
-- 税理士 第2回回答 Q14(c):
--   「**サポート料も含めて全額返金することを推奨。**
--     ①未成年者取消し(民法5条2項)は契約全体を取り消すもので、コイン購入
--       契約が取り消されるならサポート料の法的根拠も失われるのが自然な帰結。
--       『サポート料だけ返さない』は法的に維持しにくい
--     ②金額が小さいのに紛争時のコストが桁違い
--     ③税務上は不利益がない」
--   あわせて「**一切の例外を認めない不返金条項は、無効と判断される
--   リスクがあります**」(消費者契約法10条)。
--
-- ■ ここで扱うのは「チャージバック以外」の取消し
--   チャージバックはカード会社が決済ごと戻すので、サポート料も一緒に
--   戻っている。**別に返金すると二重返金になる。**
--   この関数が要るのは、**当社が自ら購入を取り消す場面**
--   (未成年者取消しの申出を受けた、誤課金 等)。
--
-- ■ 3つを1つの操作にまとめる
--   ①未使用のコインを取り消す(第8条の6第2項「遡って付与されなかった
--     ものとして取り扱う」と同じ扱い)
--   ②コイン代金とサポート料を**金銭返金の債務**として立てる
--   ③本人に通知する
--   バラバラに手作業でやると、必ずどれかが抜ける。
--
-- ■ 消費済みのコインは追いかけない
--   Q14(a)のとおり、消費済み分は**回収不能の損失**として処理する。
--   ピタメイトからの回収は第8条の6(0088)の相殺で、**異議が成立した
--   購入に限って**行う。ここから自動では起こさない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 取消しの記録
--
-- **coin_purchases に列を足して更新しない。** 購入履歴は追記専用の
-- 台帳(0044)で、UPDATE は原則禁止。取消しは「後から起きた別の事実」
-- なので、**行を1本足す**形にする。台帳の原則を曲げずに済む。
-- ------------------------------------------------------------
create table if not exists public.purchase_voids (
  purchase_id uuid primary key references public.coin_purchases (id),
  voided_at timestamptz not null default now(),
  voided_by uuid references auth.users (id),
  reason text not null,
  voided_coins int not null default 0,
  refund_yen int not null default 0
);

comment on table public.purchase_voids is
  '当社が購入を取り消した記録(規約第7条の3第5項)。チャージバックによる失効はここには入らない(カード会社が決済ごと戻すため)。';

alter table public.purchase_voids enable row level security;

create policy "purchase_voids_select_own"
  on public.purchase_voids for select
  to authenticated
  using (exists (select 1 from public.coin_purchases cp
                 where cp.id = purchase_id and cp.user_id = auth.uid()));

create policy "purchase_voids_select_admin"
  on public.purchase_voids for select
  to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

-- 返金の事由を増やす。**科目が違うので1つにまとめない**
alter table public.cash_refunds drop constraint if exists cash_refunds_cause_check;
alter table public.cash_refunds add constraint cash_refunds_cause_check
  check (cause in (
    -- 0085: 無帰責の返還で消滅した分(規約第9条5の3)
    'host_fault', 'host_no_show', 'support', 'system',
    -- 0090: 購入の取消し(規約第7条の3第5項)。**コイン代金とサポート料を分ける**
    'purchase_void_coins', 'purchase_void_fee'));

-- ------------------------------------------------------------
-- 2. 取消しの下見(押す前に何が起きるかを出す)
-- ------------------------------------------------------------
create or replace function public.void_purchase_preview(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.coin_purchases;
  v_unused int;
  v_consumed int;
  v_disputed boolean;
  v_voided timestamptz;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.coin_purchases where id = p_purchase_id;
  if v_p.id is null then raise exception 'NOT_FOUND'; end if;

  select v.voided_at into v_voided from public.purchase_voids v
   where v.purchase_id = p_purchase_id;

  select coalesce(sum(l.remaining), 0)::int into v_unused
  from public.coin_lots l where l.purchase_id = p_purchase_id;

  v_consumed := greatest(0, coalesce(v_p.coins_credited, 0) - coalesce(v_unused, 0));

  select exists (
    select 1 from public.payment_disputes d
    where d.stripe_payment_intent = v_p.stripe_payment_intent
  ) into v_disputed;

  return jsonb_build_object(
    'purchase_id', v_p.id,
    'user_id', v_p.user_id,
    'voided_at', v_voided,
    'price_yen', coalesce(v_p.price_yen, 0),
    'safety_fee_yen', coalesce(v_p.safety_fee_yen, 0),
    'refund_total_yen', coalesce(v_p.price_yen, 0) + coalesce(v_p.safety_fee_yen, 0),
    'unused_coins', coalesce(v_unused, 0),
    -- **消費済みは回収不能の損失。**相殺は第8条の6の場面に限る
    'consumed_coins', v_consumed,
    -- チャージバックがある購入は、カード会社が決済ごと戻している。
    -- ここで返金債務を立てると**二重返金**になる
    'has_dispute', coalesce(v_disputed, false),
    'can_void', v_voided is null and not coalesce(v_disputed, false)
  );
end;
$$;

revoke all on function public.void_purchase_preview(uuid) from public, anon;
grant execute on function public.void_purchase_preview(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. 取消しの実行
-- ------------------------------------------------------------
create or replace function public.admin_void_purchase(p_purchase_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p public.coin_purchases;
  v_unused int;
  v_fee int;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  -- **理由なしに購入を取り消させない。** 返金を伴う操作なので、
  -- 後から「なぜ取り消したか」を説明できる必要がある
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_p from public.coin_purchases where id = p_purchase_id;
  if v_p.id is null then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.purchase_voids v where v.purchase_id = p_purchase_id) then
    raise exception 'ALREADY_VOIDED';
  end if;

  -- チャージバックがある購入は、カード会社が決済ごと戻している。
  -- **ここで返金債務を立てると二重返金になる**
  if exists (
    select 1 from public.payment_disputes d
    where d.stripe_payment_intent = v_p.stripe_payment_intent
  ) then
    raise exception 'HAS_DISPUTE';
  end if;

  -- ① 未使用のコインを取り消す(遡って付与されなかった扱い)
  select coalesce(sum(l.remaining), 0)::int into v_unused
  from public.coin_lots l where l.purchase_id = p_purchase_id;

  if coalesce(v_unused, 0) > 0 then
    update public.coin_lots set remaining = 0 where purchase_id = p_purchase_id;
    update public.coin_wallets
      set balance = greatest(0, balance - v_unused)
      where user_id = v_p.user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (v_p.user_id, -v_unused, 'expire', 'purchase_void:' || p_purchase_id::text);
  end if;

  -- ② 金銭返金の債務を立てる。**コイン代金とサポート料を分ける**
  --    (前受金の取崩しと売上の取消しで、会計科目が違う)
  if coalesce(v_p.price_yen, 0) > 0 then
    insert into public.cash_refunds
      (user_id, booking_id, coins, amount_yen, cause)
    values (v_p.user_id, null, coalesce(v_p.coins_credited, v_p.price_yen),
            v_p.price_yen, 'purchase_void_coins');
  end if;

  v_fee := coalesce(v_p.safety_fee_yen, 0);
  if v_fee > 0 then
    insert into public.cash_refunds
      (user_id, booking_id, coins, amount_yen, cause)
    values (v_p.user_id, null, v_fee, v_fee, 'purchase_void_fee');
  end if;

  insert into public.purchase_voids
    (purchase_id, voided_by, reason, voided_coins, refund_yen)
  values (p_purchase_id, auth.uid(), p_reason, coalesce(v_unused, 0),
          coalesce(v_p.price_yen, 0) + v_fee);

  -- ③ 本人に伝える。**黙って残高を減らさない**
  insert into public.notifications (user_id, type, title, body)
  values (v_p.user_id, 'system', 'コインのご購入を取り消しました',
    'ご購入(' || coalesce(v_p.coins_credited, 0) || 'コイン)を取り消しました。'
      || case when coalesce(v_unused, 0) > 0
              then '未使用の' || v_unused || 'コインは残高から取り消しています。' else '' end
      || 'お支払いいただいた' || (coalesce(v_p.price_yen, 0) + v_fee)
      || '円(あんしんサポート料を含みます)は、ご登録の方法で返金します。');

  perform public._log_admin_action('void_purchase', p_purchase_id, p_reason);

  return jsonb_build_object(
    'voided_coins', coalesce(v_unused, 0),
    'refund_yen', coalesce(v_p.price_yen, 0) + v_fee,
    'fee_yen', v_fee
  );
end;
$$;

comment on function public.admin_void_purchase(uuid, text) is
  '購入を取り消し、未使用コインを消して、コイン代金とサポート料を金銭返金の債務にする(規約第7条の3第5項・税理士Q14(c))。';

revoke all on function public.admin_void_purchase(uuid, text) from public, anon;
grant execute on function public.admin_void_purchase(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 4. 運営コンソール用: 直近の購入を引く
-- ------------------------------------------------------------
create or replace function public.admin_recent_purchases(p_limit int default 30)
returns table (
  purchase_id uuid,
  user_id uuid,
  nickname text,
  coins int,
  price_yen int,
  safety_fee_yen int,
  created_at timestamptz,
  voided_at timestamptz,
  has_dispute boolean,
  unused_coins int
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
  select cp.id, cp.user_id, p.nickname,
         coalesce(cp.coins_credited, 0), coalesce(cp.price_yen, 0),
         coalesce(cp.safety_fee_yen, 0),
         cp.created_at, pv.voided_at,
         exists (select 1 from public.payment_disputes d
                 where d.stripe_payment_intent = cp.stripe_payment_intent),
         coalesce((select sum(l.remaining)::int from public.coin_lots l
                   where l.purchase_id = cp.id), 0)
  from public.coin_purchases cp
  left join public.profiles p on p.id = cp.user_id
  left join public.purchase_voids pv on pv.purchase_id = cp.id
  order by cp.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$$;

revoke all on function public.admin_recent_purchases(int) from public, anon;
grant execute on function public.admin_recent_purchases(int) to authenticated;

-- ------------------------------------------------------------
-- 5. 会計仕訳に購入取消しを足す(J25〜J27)
--
-- **科目が違うので J19 とは分ける。**
--   ・コイン代金 … 前受金の取崩し(受け取った代金を返すだけ)
--   ・サポート料 … **売上のマイナス**(税理士 Q14(b))
--   ・未使用コインの取消し … 前受金を落とす側の相手科目を仮受金にして、
--     J25 と二重に落とさないようにする
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
    -- 0090: 購入の取消しによる返金は科目が違う(J25/J26)ので除く
    and r.cause in ('host_fault', 'host_no_show', 'support', 'system')
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

  union all

  -- ------------------------------------------------------------
  -- J25 購入の取消し(コイン代金) — 0090
  --   規約第7条の3第5項。前受金を取り崩して、返す約束(未払金)に振り替える。
  --   **失効益ではない。** 受け取った代金をそのまま返すだけ。
  -- ------------------------------------------------------------
  select r.created_at::date, '購入取消'::text,
         '前受金'::text, 'コイン'::text,
         '未払金'::text, '返金(購入取消)'::text,
         r.amount_yen::bigint, '対象外'::text,
         ('購入の取消しによる返金(コイン代金) ' || left(r.id::text, 8))::text,
         r.id::text
  from public.cash_refunds r
  where r.status in ('pending', 'paid') and r.cause = 'purchase_void_coins'
    and r.created_at >= p_from and r.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J26 購入の取消し(あんしんサポート料) — 0090
  --   **売上のマイナス**(税理士 第2回回答 Q14(b))。
  --   免税事業者である間は単に売上の減少として扱う。
  -- ------------------------------------------------------------
  select r.created_at::date, '購入取消'::text,
         '売上高'::text, 'あんしんサポート料'::text,
         '未払金'::text, '返金(購入取消)'::text,
         r.amount_yen::bigint, '課対売上込10%'::text,
         ('購入の取消しによる返金(サポート料) ' || left(r.id::text, 8))::text,
         r.id::text
  from public.cash_refunds r
  where r.status in ('pending', 'paid') and r.cause = 'purchase_void_fee'
    and r.created_at >= p_from and r.created_at < (p_to + 1)

  union all

  -- ------------------------------------------------------------
  -- J27 購入取消しによる未使用コインの取消し — 0090
  --   ロットを0にした分。**J25 で前受金を落としているので、
  --   ここで二重に落とさない**ように、相手科目は前受金ではなく
  --   仮受金(取消しの受け皿)にする。
  --   ※ purchase_void の expire は、J16(lot:...)にも
  --     J18(refund_lapsed_paid)にも当たらないため、ここで拾う。
  -- ------------------------------------------------------------
  select t.created_at::date, '購入取消'::text,
         '仮受金'::text, '購入取消の調整'::text,
         '前受金'::text, 'コイン'::text,
         (-t.amount)::bigint, '対象外'::text,
         '購入取消による未使用コインの取消'::text,
         t.id::text
  from public.coin_transactions t
  where t.type = 'expire' and t.note like 'purchase_void:%' and t.amount < 0
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  order by 1, 2, 10;
end;
$$;

revoke all on function public.accounting_journal(date, date) from public;
grant execute on function public.accounting_journal(date, date) to authenticated;
-- ============================================================
-- 0091: 料率の遡及適用を止める(G3)
--
-- 規約 第8条の2:
--   3の2 予約は**30%**、ギフトは**40%**を超えない
--   4項   変更は**30日前まで**に、**理由を明らかにして**通知する。
--         不利益となる変更は**あわせて個別に通知**する
--   5項   **変更前に成立した予約およびギフトには、変更前の率を適用する**
--   5の2  通知後に離脱しても、変更前に成立した分は従前の条件で確定・換金
--
-- ■ 何が合っていなかったか
--   料率(host_fee_tiers)は**現在値が1組あるだけ**で、「いつからの率か」
--   を持っていなかった。しかも手数料は**予約の成立時ではなく、報酬の
--   確定時に現在値を読む。** したがって料率を変えると、
--   **変更前に成立していた予約にも新料率がかかる**(5項違反)。
--   30日前通知の仕組みも無く、上限(3の2)も紳士協定だった。
--
--   ここまで顕在化していないのは、**料率を一度も変えていないから**。
--   変える日が来た瞬間に債務不履行になる。
--
-- ■ 直しかた
--   ①料率に **effective_from** を持たせ、**成立日時で引く**
--   ②上限を**制約**にする(規約が画した数値を運用で越えられなくする)
--   ③変更は**30日以上先の日付でしか予約できない**関数に寄せ、
--     予約と同時にピタメイト全員へ**個別通知**する
--
--   ②③は 0083(ボーナス0)・0087(換金保留は最長30日)と同じ手口。
--   **条文の数値は、コードではなく制約で守る。**
--
-- ■ 弁護士の指摘(論点3)
--   「**上限のない変更権は『青天井』と評価される最大の弱点**」
--   「**実質的な離脱の自由は『辞めても、稼いだ分は従前の条件で
--     回収できる』ことで初めて担保される**」
-- ============================================================

-- ------------------------------------------------------------
-- 1. 料率に「いつからの率か」を持たせる
-- ------------------------------------------------------------
alter table public.host_fee_tiers
  add column if not exists effective_from timestamptz not null default '2000-01-01T00:00:00Z';

alter table public.host_fee_tiers drop constraint if exists host_fee_tiers_pkey;
alter table public.host_fee_tiers
  add constraint host_fee_tiers_pkey primary key (effective_from, step);

-- 規約 第8条の2第3の2項。**30%を超える率を入れられなくする**
alter table public.host_fee_tiers drop constraint if exists host_fee_tiers_cap_check;
alter table public.host_fee_tiers
  add constraint host_fee_tiers_cap_check check (rate >= 0 and rate <= 0.30);

comment on column public.host_fee_tiers.effective_from is
  '規約第8条の2第5項。この日時以降に成立した予約に適用する。過去の組は消さない(旧料率の適用に要る)。';

-- ギフトの率も表に出す。**関数の中の定数のままでは effective_from を持てない**
create table if not exists public.gift_fee_rates (
  effective_from timestamptz primary key,
  -- 規約 第8条の2第3の2項
  rate numeric(4, 3) not null check (rate >= 0 and rate <= 0.40)
);

comment on table public.gift_fee_rates is
  'ありがとうギフトの利用料の率(規約第8条の2)。上限40%は第3の2項。';

insert into public.gift_fee_rates (effective_from, rate)
values ('2000-01-01T00:00:00Z', 0.350)
on conflict (effective_from) do nothing;

alter table public.gift_fee_rates enable row level security;

-- 料率は開示する情報なので誰でも読める(第3項「本サービス上に表示します」)
create policy "gift_fee_rates_select_all"
  on public.gift_fee_rates for select
  to anon, authenticated
  using (true);

-- 変更の理由を残す。**4項が「理由を明らかにして」と約束している**
create table if not exists public.fee_change_notices (
  effective_from timestamptz primary key,
  announced_at timestamptz not null default now(),
  announced_by uuid references auth.users (id),
  reason text not null,
  notified_hosts int not null default 0
);

comment on table public.fee_change_notices is
  '料率変更の予告(規約第8条の2第4項)。30日前までの通知と、理由の記録。';

alter table public.fee_change_notices enable row level security;

create policy "fee_change_notices_select_all"
  on public.fee_change_notices for select
  to anon, authenticated
  using (true);

-- ------------------------------------------------------------
-- 2. 「その時点で適用される料率の組」を引く
-- ------------------------------------------------------------
create or replace function public.fee_effective_from(p_at timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public
as $$
  select max(t.effective_from) from public.host_fee_tiers t
  where t.effective_from <= p_at
$$;

comment on function public.fee_effective_from(timestamptz) is
  'その時点で適用される料率の組(規約第8条の2第5項)。';

-- ------------------------------------------------------------
-- 3. 累進手数料を「成立日時の料率」で計算する
--
-- ⚠️ 1引数版は**落としてから**2引数版を作る。既定値つきで増やすと
--    1引数の呼び出しが両方に一致して「function is not unique」になる。
-- ------------------------------------------------------------
drop function if exists public.host_progressive_fee(int);

create function public.host_progressive_fee(p_gmv int, p_at timestamptz default now())
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_fee numeric := 0;
  v_prev int := 0;
  v_tier record;
  v_eff timestamptz;
begin
  if p_gmv is null or p_gmv <= 0 then
    return 0;
  end if;

  -- **p_at の時点で有効だった組を使う。** 現在値ではない
  v_eff := public.fee_effective_from(p_at);

  for v_tier in
    select upper_bound, rate from public.host_fee_tiers
    where effective_from = v_eff
    order by step
  loop
    exit when p_gmv <= v_prev;
    v_fee := v_fee + (least(p_gmv, coalesce(v_tier.upper_bound, p_gmv)) - v_prev) * v_tier.rate;
    v_prev := coalesce(v_tier.upper_bound, p_gmv);
  end loop;
  return v_fee;
end;
$$;

comment on function public.host_progressive_fee(int, timestamptz) is
  '月間の予約売上に対する累進手数料の累計額。p_at の時点で有効な料率の組を使う(規約第8条の2第5項)。';

-- ------------------------------------------------------------
-- 4. ギフトの率
-- ------------------------------------------------------------
create or replace function public.gift_fee_rate(p_at timestamptz default now())
returns numeric
language sql
stable
set search_path = public
as $$
  select r.rate from public.gift_fee_rates r
  where r.effective_from <= p_at
  order by r.effective_from desc
  limit 1
$$;

comment on function public.gift_fee_rate(timestamptz) is
  'ありがとうギフトの利用料の率。p_at の時点で有効な値(規約第8条の2第5項)。';

-- ------------------------------------------------------------
-- 5. 予約の手数料: **成立日時**の料率で引く
--
-- 本文は 0033 のままで、料率を引く時点を渡すようにしただけ。
-- 成立日時は confirmed_at(承諾された時刻)。まだ無ければ作成時刻。
-- ------------------------------------------------------------
create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
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
  -- 0091: **予約が「成立」した時点。**確定した時点ではない(規約第8条の2第5項)
  v_agreed timestamptz;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  v_agreed := coalesce(new.confirmed_at, new.created_at, now());

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(new.host_id, new.scheduled_at, new.id);
  v_gmv_after := v_gmv_before + new.coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after, v_agreed)
              - public.host_progressive_fee(v_gmv_before, v_agreed);
  v_rate := v_base_fee / new.coins;

  -- 指名リピート: 同じゲストと過去に完了した予約があるか
  select exists (
    select 1 from public.bookings b
    where b.host_id = new.host_id
      and b.guest_id = new.guest_id
      and b.status = 'completed'
      and b.id <> new.id
      and b.scheduled_at < new.scheduled_at
  ) into v_is_repeat;

  if v_is_repeat then
    v_discount := least(c_repeat_discount, greatest(0, v_rate - c_rate_floor)) * new.coins;
  end if;

  v_fee := least(greatest(0, round(v_base_fee - v_discount))::int, new.coins);

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
    round(v_fee::numeric / new.coins, 4), v_is_repeat);

  return new;
end;
$$;

revoke all on function public._apply_booking_fee() from public, anon;

-- ------------------------------------------------------------
-- 6. ギフトの手数料: 表から引く(定数をやめる)
-- ------------------------------------------------------------
create or replace function public._apply_gift_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 0091: 定数をやめて表から引く。ギフトは成立=作成なので now() でよい
  v_rate numeric := public.gift_fee_rate(now());
  v_fee int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;
  v_fee := least(greatest(round(new.coins * v_rate)::int, 0), new.coins);

  if v_fee > 0 then
    update public.coin_wallets
      set earned_balance = greatest(0, earned_balance - v_fee)
      where user_id = new.receiver_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (new.receiver_id, -v_fee, 'platform_fee', 'gift_fee:' || new.id);
  end if;

  insert into public.platform_fees (
    host_id, kind, gift_id, gross_coins, fee_coins, net_coins, applied_rate)
  values (new.receiver_id, 'gift', new.id, new.coins, v_fee, new.coins - v_fee, v_rate);

  return new;
end;
$$;

revoke all on function public._apply_gift_fee() from public, anon;

-- ------------------------------------------------------------
-- 7. 表示(第3項)は「いま有効な組」を出す
-- ------------------------------------------------------------
create or replace function public.fee_rates()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'bookingTiers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'upperBound', t.upper_bound,
               'percent', round(t.rate * 100, 1)
             ) order by t.step), '[]'::jsonb)
      from public.host_fee_tiers t
      where t.effective_from = public.fee_effective_from(now())
    ),
    'repeatDiscountPoints', 3,
    'floorPercent', 10,
    -- 0091: 定数をやめて表から引く
    'giftPercent', round(public.gift_fee_rate(now()) * 100, 1),
    -- 規約 第8条の2第3の2項の上限。**画面に出せる形で返す**
    'bookingCapPercent', 30,
    'giftCapPercent', 40,
    -- 予定されている変更(第4項の予告)。無ければ null
    'scheduledChange', (
      select jsonb_build_object(
               'effectiveFrom', n.effective_from,
               'reason', n.reason,
               'bookingTiers', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'upperBound', t2.upper_bound,
                          'percent', round(t2.rate * 100, 1)
                        ) order by t2.step), '[]'::jsonb)
                 from public.host_fee_tiers t2
                 where t2.effective_from = n.effective_from
               ),
               'giftPercent', (
                 select round(r.rate * 100, 1) from public.gift_fee_rates r
                 where r.effective_from = n.effective_from
               )
             )
      from public.fee_change_notices n
      where n.effective_from > now()
      order by n.effective_from
      limit 1
    )
  );
$$;

comment on function public.fee_rates() is
  '手数料の率(表示用)。規約 第8条の2第3項の「本サービス上に表示します」を満たす。いま有効な組と、予告されている変更を返す。';

revoke all on function public.fee_rates() from public;
grant execute on function public.fee_rates() to anon, authenticated;

-- ------------------------------------------------------------
-- 8. 料率の変更は「30日以上先」でしか予約できない(第4項)
--
-- **即時に変えられる経路を残さない。** UPDATE で今の行を書き換えれば
-- 30日前通知を飛ばせてしまうので、変更はこの関数だけを通す。
-- ------------------------------------------------------------
create or replace function public.admin_schedule_fee_change(
  p_effective_from timestamptz,
  p_reason text,
  -- [{"upperBound": 30000, "percent": 20.0}, ...] 上限 null は「それ以上」
  p_booking_tiers jsonb,
  p_gift_percent numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_step smallint := 0;
  v_n int := 0;
  v_hosts int := 0;
  v_min_days int := 30;
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  -- 4項「変更の内容および理由を明らかにして」
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  -- 4項「変更の30日前までに」
  if p_effective_from < now() + make_interval(days => v_min_days) then
    raise exception 'NOTICE_PERIOD_TOO_SHORT';
  end if;
  if exists (select 1 from public.fee_change_notices n
             where n.effective_from = p_effective_from) then
    raise exception 'ALREADY_SCHEDULED';
  end if;
  if p_booking_tiers is null or jsonb_array_length(p_booking_tiers) = 0 then
    raise exception 'TIERS_REQUIRED';
  end if;

  for v_row in select * from jsonb_array_elements(p_booking_tiers)
  loop
    v_step := v_step + 1;
    -- 上限(3の2)は制約が最終的に止めるが、ここでも分かりやすい名前で落とす
    if (v_row ->> 'percent')::numeric > 30 then
      raise exception 'BOOKING_RATE_OVER_CAP';
    end if;
    insert into public.host_fee_tiers (effective_from, step, upper_bound, rate)
    values (p_effective_from, v_step,
            nullif(v_row ->> 'upperBound', '')::int,
            round((v_row ->> 'percent')::numeric / 100, 3));
    v_n := v_n + 1;
  end loop;

  if p_gift_percent > 40 then
    raise exception 'GIFT_RATE_OVER_CAP';
  end if;
  insert into public.gift_fee_rates (effective_from, rate)
  values (p_effective_from, round(p_gift_percent / 100, 3));

  -- 4項「不利益となる変更については、あわせて**個別に**通知します」
  -- 有利・不利の判定は率の組み合わせで一概に言えないので、**全員に個別通知**する。
  -- 送りすぎて困ることはないが、送り漏れると条文違反になる
  insert into public.notifications (user_id, type, title, body)
  select h.user_id, 'system',
    'プラットフォーム利用料の率が変わります('
      || to_char(p_effective_from, 'YYYY年MM月DD日') || 'から)',
    '理由: ' || p_reason
      || ' / **' || to_char(p_effective_from, 'YYYY年MM月DD日')
      || 'より前に成立した予約・ギフトには、変更前の率をそのまま適用します**'
      || '(利用規約 第8条の2第5項)。新しい率はコインウォレットの料率表示で'
      || 'ご確認いただけます。'
  from public.host_settings h
  join public.profiles p on p.id = h.user_id
  where h.is_host and p.withdrawn_at is null;
  get diagnostics v_hosts = row_count;

  insert into public.fee_change_notices
    (effective_from, announced_by, reason, notified_hosts)
  values (p_effective_from, auth.uid(), p_reason, v_hosts);

  perform public._log_admin_action('schedule_fee_change', null,
    to_char(p_effective_from, 'YYYY-MM-DD') || ' ' || p_reason
      || ' / ' || v_hosts || '名へ通知');

  return jsonb_build_object(
    'effective_from', p_effective_from,
    'tiers', v_n,
    'notified_hosts', v_hosts
  );
end;
$$;

comment on function public.admin_schedule_fee_change(timestamptz, text, jsonb, numeric) is
  '料率の変更を予約する(規約第8条の2第4項)。30日以上先の日付でしか登録できず、ピタメイト全員へ個別に通知する。';

revoke all on function public.admin_schedule_fee_change(timestamptz, text, jsonb, numeric) from public, anon;
grant execute on function public.admin_schedule_fee_change(timestamptz, text, jsonb, numeric) to authenticated;

-- ------------------------------------------------------------
-- 9. 運営コンソール用の一覧
-- ------------------------------------------------------------
create or replace function public.admin_fee_schedules()
returns table (
  effective_from timestamptz,
  is_current boolean,
  is_future boolean,
  reason text,
  announced_at timestamptz,
  notified_hosts int,
  booking_tiers jsonb,
  gift_percent numeric
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
  select s.eff,
         s.eff = public.fee_effective_from(now()),
         s.eff > now(),
         n.reason,
         n.announced_at,
         n.notified_hosts,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'upperBound', t.upper_bound,
                   'percent', round(t.rate * 100, 1)) order by t.step), '[]'::jsonb)
          from public.host_fee_tiers t where t.effective_from = s.eff),
         (select round(r.rate * 100, 1) from public.gift_fee_rates r
          where r.effective_from = s.eff)
  from (
    select distinct effective_from as eff from public.host_fee_tiers
    union
    select distinct effective_from from public.gift_fee_rates
  ) s
  left join public.fee_change_notices n on n.effective_from = s.eff
  order by s.eff desc;
end;
$$;

revoke all on function public.admin_fee_schedules() from public, anon;
grant execute on function public.admin_fee_schedules() to authenticated;

-- ------------------------------------------------------------
-- 10. ダッシュボードの見込み表示も、いま有効な組を見る
-- ------------------------------------------------------------
-- 0034 の host_dashboard は host_fee_tiers を直接読んでいる。
-- effective_from を足したので、**組を絞らないと過去と未来の行が混ざる。**
-- 影響するのは「次のティア」の表示だけだが、混ざれば数字が狂う。
create or replace view public.host_fee_tiers_current
  with (security_invoker = true) as
  select t.step, t.upper_bound, t.rate
  from public.host_fee_tiers t
  where t.effective_from = public.fee_effective_from(now());

comment on view public.host_fee_tiers_current is
  'いま有効な料率の組だけ。0034のダッシュボードなど「現在の率」を見る側はこちらを使う。';

-- **anon には開けない。** 未ログインへの公開は fee_rates()(SECURITY DEFINER)
-- だけを窓口にしている(74_anon_surface が固定している面)
grant select on public.host_fee_tiers_current to authenticated;

-- ------------------------------------------------------------
-- 11. ダッシュボードを差し替える
--
-- 本文は 0034 のままで、host_fee_tiers の参照を
-- host_fee_tiers_current(いま有効な組)に向けただけ。
-- **絞らないと過去と未来の組が混ざり、次のティアの表示が狂う。**
-- ------------------------------------------------------------
create or replace function public.host_dashboard(p_at timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_ticket int;
  v_gift int;
  v_fee int;
  v_next_bound int;
  v_cur_rate numeric;
  v_next_rate numeric;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- JSTの当月[start, end)
  v_start := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) at time zone 'Asia/Tokyo');
  v_end   := (date_trunc('month', (p_at at time zone 'Asia/Tokyo')) + interval '1 month')
             at time zone 'Asia/Tokyo';

  v_ticket := public.host_monthly_ticket_gmv(v_uid, p_at);

  select coalesce(sum(pf.gross_coins), 0)::int into v_gift
  from public.platform_fees pf
  where pf.host_id = v_uid and pf.kind = 'gift'
    and pf.created_at >= v_start and pf.created_at < v_end;

  select coalesce(sum(pf.fee_coins), 0)::int into v_fee
  from public.platform_fees pf
  where pf.host_id = v_uid
    and pf.created_at >= v_start and pf.created_at < v_end;

  -- 次のティア(超過累進の次の段)
  select t.upper_bound, t.rate into v_next_bound, v_cur_rate
  from public.host_fee_tiers_current t
  where t.upper_bound is null or v_ticket < t.upper_bound
  order by t.step
  limit 1;

  select t.rate into v_next_rate
  from public.host_fee_tiers_current t
  where t.step = (
    select min(step) + 1 from public.host_fee_tiers_current
    where upper_bound is null or v_ticket < upper_bound
  );

  v_result := jsonb_build_object(
    'month_start', v_start,
    'ticket_coins', v_ticket,
    'gift_coins', v_gift,
    'gross_coins', v_ticket + v_gift,
    'fee_coins', v_fee,
    'net_coins', (v_ticket + v_gift) - v_fee,
    'effective_rate', case when (v_ticket + v_gift) > 0
                           then round(v_fee::numeric / (v_ticket + v_gift), 4) else 0 end,
    'tier', jsonb_build_object(
      'current_rate', v_cur_rate,
      'next_bound', v_next_bound,
      'next_rate', v_next_rate,
      'remaining_coins', case when v_next_bound is null then null
                              else greatest(0, v_next_bound - v_ticket) end
    )
  );

  -- 日別の売上(予約の確定額)
  v_result := v_result || jsonb_build_object('daily', coalesce((
    select jsonb_agg(jsonb_build_object('day', d.day, 'coins', d.coins) order by d.day)
    from (
      select extract(day from (b.scheduled_at at time zone 'Asia/Tokyo'))::int as day,
             sum(b.coins)::int as coins
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
      group by 1
    ) d
  ), '[]'::jsonb));

  -- 指名リピート(金額ベース)と人数
  v_result := v_result || (
    select jsonb_build_object(
      'repeat', jsonb_build_object(
        'repeat_coins', coalesce(sum(x.coins) filter (where x.is_repeat), 0)::int,
        'total_coins', coalesce(sum(x.coins), 0)::int,
        'repeat_rate', case when coalesce(sum(x.coins), 0) > 0
          then round(coalesce(sum(x.coins) filter (where x.is_repeat), 0)::numeric / sum(x.coins), 4)
          else 0 end,
        -- 「リピーター」は当月に2回目以降の予約が1件でもあるゲスト。
        -- 「新規」は残り。初回と2回目が同じ月にあるゲストを両方に数えないよう、
        -- 差し引きで出す(単純に filter で数えると二重計上になる)。
        'repeater_guests', count(distinct x.guest_id) filter (where x.is_repeat),
        'new_guests', count(distinct x.guest_id)
                      - count(distinct x.guest_id) filter (where x.is_repeat)
      ))
    from (
      select b.guest_id, b.coins,
             exists (
               select 1 from public.bookings p
               where p.host_id = b.host_id and p.guest_id = b.guest_id
                 and p.status = 'completed' and p.scheduled_at < b.scheduled_at
             ) as is_repeat
      from public.bookings b
      where b.host_id = v_uid and b.status = 'completed'
        and b.scheduled_at >= v_start and b.scheduled_at < v_end
    ) x
  );

  -- 成約率と初回応答の速さ
  -- 承諾されたかどうかは promises の有無で判定する(promiseは approve_booking でしか作られない)
  v_result := v_result || (
    select jsonb_build_object(
      'response', jsonb_build_object(
        'requests', count(*),
        'approved', count(*) filter (where pr.id is not null),
        'approval_rate', case when count(*) > 0
          then round(count(*) filter (where pr.id is not null)::numeric / count(*), 4) else 0 end,
        'median_reply_seconds', percentile_cont(0.5) within group (
          order by extract(epoch from (b.scheduled_at - b.created_at))
        ) filter (where pr.id is not null)
      ))
    from public.bookings b
    left join public.promises pr on pr.booking_id = b.id
    where b.host_id = v_uid
      and b.created_at >= v_start and b.created_at < v_end
  );

  -- 埋まりやすい時間帯(直近4週に自分へ届いたリクエストの 曜日×時間)
  v_result := v_result || jsonb_build_object('heatmap', coalesce((
    select jsonb_agg(jsonb_build_object('dow', h.dow, 'hour', h.hour, 'count', h.c))
    from (
      select extract(isodow from (b.created_at at time zone 'Asia/Tokyo'))::int as dow,
             extract(hour   from (b.created_at at time zone 'Asia/Tokyo'))::int as hour,
             count(*)::int as c
      from public.bookings b
      where b.host_id = v_uid
        and b.created_at >= p_at - interval '28 days'
      group by 1, 2
    ) h
  ), '[]'::jsonb));

  return v_result;
end;
$$;

revoke all on function public.host_dashboard(timestamptz) from public, anon;
grant execute on function public.host_dashboard(timestamptz) to authenticated;
-- ============================================================
-- 0092: 退会で投稿等の表示を止める(規約 第10条の2第4項)
--
-- 2026-08-01、同種サービス(GameRoom)の規約と突合して、当社に
-- **投稿物に関する条文が1つも無い**ことが分かり、第10条の2を新設した。
--
--   4項「前項の許諾は、ユーザーが投稿等を削除し、または退会した後は、
--        **将来に向かって終了します**」
--
-- ■ 条文を書いたら、その場で実装まで持っていく
--   07-31の条文改訂では、条文だけ先に整えて実装が6件遅れた(G6〜G11)。
--   **同じことを繰り返さない。** 第10条の2第4項は、退会後も
--   自己紹介・音声プロフィール・アバターへの参照が残っていると
--   守れないので、退会の処理でそこを落とす。
--
-- ■ 落とさないもの
--   第10条の2第4項1号・2号の例外にあたるもの。
--   ・**レビューとマナースコアの算定根拠**(取引の正確性を保つために要る)
--   ・法令に基づく記録
--   ニックネームも残す。**取引履歴の相手が「(削除済み)」になると、
--   相手側が自分の履歴を確認できなくなる。**
--
-- ■ ここで消せないもの
--   ストレージ上の実体(音声・アバターのファイル)。**参照を切るだけ。**
--   実体の削除は avatar-delete / voice-delete を運営が回す。
-- ============================================================

create or replace function public.withdraw_account(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  if exists (select 1 from public.profiles p
              where p.id = v_uid and p.withdrawn_at is not null) then
    raise exception 'ALREADY_WITHDRAWN';
  end if;

  -- 第6条の2第2項。**成立済みの予約を残したまま辞めさせない。**
  -- 相手のあることなので、片方が黙って消えると相手が救済されない
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');
  if coalesce(v_blocking, 0) > 0 then
    raise exception 'HAS_ACTIVE_BOOKINGS';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = v_uid for update;

  -- ----------------------------------------------------------
  -- コインを消滅させる(第7条3項・第6条の2第3項)
  --
  -- **報酬コイン(earned_balance)には手を付けない。** 換金の対象であり、
  -- ここで消すと弁護士の指摘した「人質」そのものになる
  -- ----------------------------------------------------------
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots
      set remaining = 0
      where user_id = v_uid and remaining > 0;
    update public.coin_wallets
      set balance = 0, bonus_balance = 0
      where user_id = v_uid;
    if coalesce(v_paid, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_paid, 'expire', 'withdraw_paid');
    end if;
    if coalesce(v_bonus, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_bonus, 'expire', 'withdraw_bonus');
    end if;
  end if;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**ので、
  -- ここを落とすことで退会者が誰の目にも触れなくなる
  update public.host_settings set is_host = false where user_id = v_uid;

  -- 0092: 規約 第10条の2第4項。**投稿等の利用許諾は退会で将来に向かって終わる。**
  -- 条文でそう約束した以上、表示に使う投稿物への参照はここで落とす。
  -- 落とさないものは第10条の2第4項1号・2号の例外(レビューと、
  -- マナースコアの算定根拠、法令に基づく記録)だけ。
  --
  -- ⚠️ ストレージ上の実体(音声・アバターのファイル)はここでは消せない。
  --    参照を切ったうえで、運営が avatar-delete / voice-delete を回す。
  --    **参照だけ切って安心しないこと。**
  update public.profiles
    set withdrawn_at = now(),
        presence_status = 'busy',
        bio = '',
        voice_path = null,
        voice_seconds = null,
        avatar_path = null,
        favorite_games = '{}'
    where id = v_uid;

  insert into public.account_withdrawals
    (user_id, expired_paid_coins, expired_bonus_coins, earned_balance, payout_deadline, reason)
  values (v_uid, coalesce(v_paid, 0), coalesce(v_bonus, 0), coalesce(v_earned, 0),
          v_deadline, p_reason);

  -- 期限を本人に残す。画面を閉じても分かるように通知にも書く
  insert into public.notifications (user_id, type, title, body)
  values (v_uid, 'system', '退会の手続が完了しました',
    case when coalesce(v_earned, 0) > 0
      then '報酬コイン' || v_earned || '枚の換金は、'
             || to_char(v_deadline, 'YYYY年MM月DD日') || 'まで申請できます。'
             || '期限を過ぎると消滅します。'
      else 'ご利用ありがとうございました。' end);

  return jsonb_build_object(
    'withdrawn_at', now(),
    'expired_paid', coalesce(v_paid, 0),
    'expired_bonus', coalesce(v_bonus, 0),
    'earned_balance', coalesce(v_earned, 0),
    'payout_deadline', v_deadline
  );
end;
$$;

revoke all on function public.withdraw_account(text) from public, anon;
grant execute on function public.withdraw_account(text) to authenticated;
-- ============================================================
-- 0093_relock_function_grants.sql
-- 0065 の当て漏れを回収する（セキュリティ修正の再適用）
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   本番で **0065 だけが当たっていなかった。** 0064 まで当て、0066 以降を
--   当てたため、`docs/check-migrations.sql` が「順番が飛んでいます」を
--   出していた（2026-08-03 に発覚）。
--
--   0065 は「関数を作ると PostgreSQL が既定で PUBLIC に EXECUTE を与える」
--   という性質への対処で、**未ログインから内部用の補助関数を呼べる穴**を
--   閉じるものだった。当たっていないので、その穴が本番に残っていた。
--   とくに次の2つ（0065 の記述より）:
--
--     (1) `_booking_slot_conflict` … 掲載中のピタメイト全員の稼働予定が
--         未ログインで復元できる
--     (2) `_ledger_record_bypass`  … 追記専用の台帳に嘘の記録を積める
--
-- ■ なぜ 0065 をそのまま流せないか
--   `0091` が `host_progressive_fee` の引数を `(int)` から
--   `(int, timestamptz)` に変えている。0065 は古い署名で revoke するので、
--   いま流すと **`function public.host_progressive_fee(integer) does not exist`**
--   で止まる。手元で 0065 以外を当てた DB に 0065 を流して確認した。
--
-- ■ 方針
--   **署名ではなく関数名で引く。** 引数が変わっても、名前が同じなら
--   すべての多重定義から PUBLIC を取り上げる。これで今後の署名変更で
--   同じことが起きない。何度流しても結果は同じ（冪等）。
--
--   `revoke ... from public` は `authenticated` / `anon` への明示的な
--   grant には触れない。未ログインに見せてよいもの（public_host_cards /
--   host_ranking / fee_rates など）は 0065 と同じくそのまま残る。
--
--   固定した一覧は `supabase/tests/74_anon_surface.sql` が検証している。
-- ============================================================

do $$
declare
  v_names text[] := array[
    '_booking_slot_conflict',
    '_lock_booking_slots',
    '_ledger_record_bypass',
    'create_booking',
    '_apply_booking_fee',
    '_apply_gift_fee',
    '_checkin_on_message',
    '_consumption_restore_only',
    '_enqueue_push',
    '_hold_bookings_on_report',
    '_ledger_immutable',
    '_ledger_no_delete',
    '_payout_amount_immutable',
    'check_host_requires_verification',
    'clear_last_seen_on_hide',
    'handle_new_user',
    'handle_new_user_notification_prefs',
    'handle_new_user_wallet',
    'notify_board_joined',
    'notify_invite_approved',
    'notify_invite_received',
    'notify_message_received',
    'reviews_after_insert_recompute',
    'set_report_severity',
    'set_updated_at',
    '_push_is_casual',
    '_push_lockscreen_body',
    '_push_in_quiet_hours',
    '_ledger_override_on',
    'host_progressive_fee',
    'host_monthly_ticket_gmv',
    'safety_fee_for',
    'coin_expiry_from',
    'is_valid_booking_duration',
    'booking_refund_percent',
    'booking_refund_coins',
    'fresh_host_status',
    'booking_fits_availability',
    'host_has_availability',
    'host_is_open_at'
  ];
  r record;
  n int := 0;
  v_left text;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname = any (v_names)
  loop
    execute format('revoke all on function %s from public', r.sig);
    n := n + 1;
  end loop;

  raise notice '0093: % 個の関数から PUBLIC の EXECUTE を取り上げました', n;

  -- **1つも取り上げられなかったら、名前の書き間違いを疑う。**
  -- 静かに何もしないのが一番まずい（穴が開いたままになる）
  if n = 0 then
    raise exception '0093: 対象の関数が1つも見つかりません。関数名の一覧を確認してください';
  end if;

  -- ------------------------------------------------------------
  -- ★ここが本体。**revoke が通ったかを、結果で確かめる。**
  -- ------------------------------------------------------------
  -- 関数の所有者でない役割が revoke すると、PostgreSQL は
  -- 「WARNING: no privileges could be revoked」を出すだけで**成功扱い**にする。
  -- Supabase の SQL Editor は NOTICE も WARNING も表示しないので、
  -- 「成功と出たのに穴が開いたまま」になりうる（2026-08-03 に実際に起きた）。
  -- 取りこぼしがあれば、ここで止める。
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_left
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = any (v_names)
     and has_function_privilege('public', p.oid, 'execute');

  if v_left is not null then
    raise exception E'0093: 取り上げられなかった関数があります。\n'
      '関数の所有者を確認してください（所有者でないと revoke は警告だけで何もしません）。\n'
      '残り: %', v_left;
  end if;

  raise notice '0093: 取りこぼしなし。すべて閉じました';
end $$;
-- ============================================================
-- 0094_close_anon_function_grants.sql
-- 未ログイン(anon)に開いていた関数を、一覧で決めた5本だけに絞る
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   0065 も 0093 も `revoke all on function ... from public` で閉じていた。
--   素の PostgreSQL ではこれで十分だが、**Supabase は public スキーマに
--   作られた関数を anon / authenticated / service_role へ「直接」GRANT する
--   既定権限を設定している。** 直接の付与は PUBLIC からの revoke では外れない。
--
--   その結果、本番では **163本の関数が「PUBLIC からは閉じているのに
--   anon からは呼べる」** 状態だった（2026-08-03 に計測）。
--   0065 が塞いだつもりだった2件も開いたままだった。
--
--     ・_booking_slot_conflict … 掲載中のピタメイト全員の稼働予定が復元できる
--     ・_ledger_record_bypass  … 追記専用の台帳に嘘の記録を積める
--
--   手元の検証環境がこの既定権限を再現していなかったため、
--   `74_anon_surface` が通ってしまい、気づけなかった。
--   シム(`supabase/tests/00_supabase_shim.sql`)に既定権限を足して
--   本番と同じ形にしたところ、同テストは落ちるようになった。
--
-- ■ 方針
--   **列挙ではなく、除外にする。** 未ログインに見せてよいものだけを
--   一覧で持ち、それ以外の public スキーマの関数からは anon の EXECUTE を
--   すべて取り上げる。関数を足し忘れても穴が開かない。
--
--   一覧は `supabase/tests/74_anon_surface.sql` と同じ5本。
--   増やすときは、**個人情報を返さないこと**と**登録前に見える必要があること**
--   の2つを説明できるものだけにする。
--
--   あわせて既定権限そのものを止める。以後、新しく作った関数が
--   自動で anon に開くことはない。
--
--   `authenticated` は**内部用のものだけ**閉じる。予約や購入は authenticated が
--   呼ぶので、同じやり方で全部閉じるとアプリが止まる。内部用の判定は
--   「名前が `_` で始まる」か「トリガー関数」。フロントが呼ぶ87本の RPC に
--   `_` 始まりは1つも無く、トリガー関数も呼んでいないことを確認した。
--   `service_role` は触らない（Edge Function が使う）。
-- ============================================================

-- ------------------------------------------------------------
-- (1) 以後に作る関数を、自動で anon に開かない
-- ------------------------------------------------------------
alter default privileges in schema public revoke execute on functions from anon;

-- ------------------------------------------------------------
-- (2) いま開いているものを、一覧の5本だけに絞る
-- ------------------------------------------------------------
do $$
declare
  -- 未ログインに見せてよいもの。74_anon_surface.sql と同じ内容。
  --   fee_rates          … 手数料の率。規約 第8条の2第3項で表示を約束している
  --   host_ranking       … 掲載一覧(0052)の材料
  --   host_repeat_guests … 同上
  --   host_repeat_stats  … 同上
  --   public_host_cards  … 同上。閉じるとトップが空になる
  c_allowed constant text[] := array[
    'fee_rates()',
    'host_ranking(p_period text, p_limit integer)',
    'host_repeat_guests(p_host_id uuid)',
    'host_repeat_stats(p_host_ids uuid[])',
    'public_host_cards(p_limit integer)'
  ];
  -- 運営(SQL/コンソール)か Edge Function だけが呼ぶもの。
  -- **利用者に開いていてはいけない**とテストが固定している一覧
  -- (73_admin_console / 75_web_push / 77_fast_release /
  --  93_payment_dispute_freeze / 96_card_and_residency)。
  -- `_` 始まりとトリガー関数は別途まとめて閉じるので、ここには書かない。
  c_backend constant text[] := array[
    'mark_payout_paid',            -- 振込の消込(運営)
    'mark_payout_failed',          -- 同上
    'resolve_report',              -- 通報の処理(運営)
    'auto_complete_bookings',      -- 自動確定(定期ジョブ)
    'claim_push_batch',            -- 送信待ちの取り出し(送信側)
    'mark_push_result',            -- 送信結果の記録(送信側)
    'disable_push_subscription',   -- 無効な購読の停止(送信側)
    'prune_push',                  -- 送信済みの片付け(定期ジョブ)
    'record_payment_card',         -- カード指紋の記録(Edge Function)
    'record_payment_dispute'       -- 異議の記録(同上)
  ];
  r record;
  n int := 0;
  m int := 0;
  v_left text;
  v_missing text;
begin
  for r in
    select p.oid,
           p.oid::regprocedure as sig,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as ident,
           p.proname,
           (p.proname like '\_%' or p.prorettype = 'trigger'::regtype) as is_internal
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prokind = 'f'
       -- **拡張が入れた関数は触らない。** pgcrypto の digest / gen_random_uuid 等が
       -- public スキーマに入っており、所有者も違う。暗号の計算をするだけで
       -- 当方のデータには触れないので、閉じる対象ではない
       and not exists (
         select 1 from pg_depend d
          where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
  loop
    if r.ident <> all (c_allowed)
       and (has_function_privilege('anon', r.oid, 'execute')
            or has_function_privilege('public', r.oid, 'execute')) then
      -- **PUBLIC と anon の両方から取り上げる。**
      -- Supabase は anon へ直接 GRANT するので PUBLIC だけでは外れず、
      -- 逆に新しい関数は PUBLIC 経由でも開くため、両方が要る
      execute format('revoke all on function %s from public, anon', r.sig);
      n := n + 1;
    end if;

    -- 内部用の補助関数とトリガー関数は、ログイン済みの利用者からも閉じる。
    -- SECURITY DEFINER 関数の中から呼ばれるだけで、そのときは定義者の
    -- 権限で動くので、利用者側の EXECUTE は要らない
    if (r.is_internal or r.proname = any (c_backend))
       and has_function_privilege('authenticated', r.oid, 'execute') then
      execute format('revoke all on function %s from authenticated', r.sig);
      m := m + 1;
    end if;
  end loop;

  raise notice '0094: PUBLIC/anon から % 本、authenticated から % 本(内部用)を取り上げました', n, m;

  -- ------------------------------------------------------------
  -- 結果で確かめる。**Supabase の SQL Editor は NOTICE も WARNING も
  -- 表示しない**ので、「成功したのに効いていない」を作らせない。
  -- ------------------------------------------------------------
  select string_agg(x, ', ' order by x) into v_left
    from (
      select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as x
        from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.prokind = 'f'
         and not exists (
           select 1 from pg_depend d
            where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
         and has_function_privilege('anon', p.oid, 'execute')
    ) t
   where x <> all (c_allowed);

  if v_left is not null then
    raise exception E'0094: 未ログインに開いたままの関数があります。\n'
      '関数の所有者を確認してください（所有者でないと revoke は警告だけで何もしません）。\n'
      '残り: %', v_left;
  end if;

  -- 閉じすぎていないか。**トップページが空になるほうが気づきにくい。**
  select string_agg(x, ', ' order by x) into v_missing
    from unnest(c_allowed) x
   where not exists (
     select 1
       from pg_proc p
       join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public'
        and p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' = x
        and has_function_privilege('anon', p.oid, 'execute'));

  if v_missing is not null then
    raise exception '0094: 未ログインに見せる前提の関数が閉じています(トップが空になります): %', v_missing;
  end if;

  -- 内部用がログイン済みに開いたままなら止める
  select string_agg(x, ', ' order by x) into v_left
    from (
      select p.oid::regprocedure::text as x
        from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.prokind = 'f'
         and not exists (
           select 1 from pg_depend d
            where d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e')
         and (p.proname like '\_%' or p.prorettype = 'trigger'::regtype
              or p.proname = any (c_backend))
         and has_function_privilege('authenticated', p.oid, 'execute')
    ) t;

  if v_left is not null then
    raise exception '0094: 内部用・運営用の関数がログイン済み利用者に開いたままです: %', v_left;
  end if;

  raise notice '0094: 未ログインに開いているのは一覧の5本だけになりました';
end $$;
-- ============================================================
-- 0095_close_server_only_functions.sql
-- Edge Function だけが呼ぶ関数を、利用者から閉じる
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   `docs/check-cron.sql` が、0094 適用後の本番で1件を赤にした。
--
--     public.credit_coins_for_purchase(...)  ❌ authenticated に開いている
--
--   **これはコインを付与する関数で、security definer なのに中に権限チェックが
--   無い。** 引数で「誰に」「何コインを」渡せるため、ログインさえしていれば
--   自分に無制限にコインを付与できた。
--   本来 stripe-webhook が service_role で呼ぶだけのもの。
--
--   0094 は「`_` 始まり・トリガー関数・テストが名指しした運営用」を閉じたが、
--   **この関数はどれにも当てはまらなかった。** 名前で見分ける方式の穴。
--
-- ■ 方針
--   **Edge Function だけが呼ぶ関数**を明示して閉じる。
--   `supabase/functions/` の中で呼ばれ、かつ `src/` からは呼ばれないもの
--   （フロントの87本の RPC と突き合わせて確認済み）。
--   `service_role` は触らないので、Edge Function からは今までどおり動く。
--
--   再発防止として `supabase/tests/74_anon_surface.sql` に固定した。
-- ============================================================

do $$
declare
  -- Edge Function(service_role)だけが呼ぶもの。
  --   credit_coins_for_purchase … コインの付与(stripe-webhook)★最重要
  --   check_purchase_allowed    … 購入上限の判定(create-checkout-session)
  --   safety_fee_for            … あんしんサポート料の計算(同上)
  --   record_ip                 … IPの記録(record-ip)
  -- 送信側・カード/異議の記録は 0094 で閉じ済み。
  c_server_only constant text[] := array[
    'credit_coins_for_purchase',
    'check_purchase_allowed',
    'safety_fee_for',
    'record_ip'
  ];
  r record;
  n int := 0;
  v_left text;
begin
  for r in
    select p.oid, p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prokind = 'f'
       and p.proname = any (c_server_only)
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    n := n + 1;
  end loop;

  raise notice '0095: % 本の関数を利用者から閉じました', n;

  if n = 0 then
    raise exception '0095: 対象の関数が1つも見つかりません。関数名を確認してください';
  end if;

  -- 結果で確かめる。SQL Editor は NOTICE も WARNING も表示しないため
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_left
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = any (c_server_only)
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('anon', p.oid, 'execute'));

  if v_left is not null then
    raise exception '0095: まだ利用者に開いています: %', v_left;
  end if;

  -- **閉じすぎていないか。** service_role が失うと決済が丸ごと止まる
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_left
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = any (c_server_only)
     and not has_function_privilege('service_role', p.oid, 'execute');

  if v_left is not null then
    raise exception '0095: service_role が実行できなくなっています(決済が止まります): %', v_left;
  end if;

  raise notice '0095: service_role からは今までどおり呼べます';
end $$;
-- ============================================================
-- 0096: コイン購入の決済手段を記録する（PayPay導入に伴う）
-- ------------------------------------------------------------
-- PayPay を決済手段に追加すると、**0080(E-9)のカード共有検知が効かない
-- 購入が生まれる。**
--
-- 0080 でカードのフィンガープリントを最重要の手掛かりに据えたのは、
-- 「端末IDは消せる、IPは変わる、カードは同じ実カードである限り変わらない」
-- という理由だった。PayPay 払いにはカードが無いので、その手掛かりが無い。
--
-- 厄介なのは**検知が弱くなること自体ではなく、弱くなったことが見えないこと**。
-- 換金画面に「カード共有 0件」と出ていると、運営は「調べた結果シロだった」と
-- 読む。実際には「調べようがなかった」かもしれない。この2つは意味が違う。
--
-- そこで購入ごとに決済手段を残し、換金画面で
-- 「この人の購入にはカードで判定できないものが N 件ある」と出せるようにする。
-- 遮断はしない。PayPay で買うこと自体は正当なので、目視の材料にとどめる
-- （0080・0022 と同じ扱い）。
--
-- 会計上も効く。カードと PayPay で決済手数料の料率が違うため、
-- 手数料の内訳を後から説明できる。
-- ============================================================

-- ------------------------------------------------------------
-- 1) coin_purchases.payment_method
-- ------------------------------------------------------------
-- **null を許す。** 0096 より前の購入には決済手段が入らないが、
-- 当時はカードしか有効化していなかったので、null は「カード」と読んでよい。
-- 遡って 'card' で埋めない——「記録が無い」と「カードだった」は別の事実で、
-- 埋めてしまうと後から区別がつかなくなる。
alter table public.coin_purchases
  add column if not exists payment_method text;

comment on column public.coin_purchases.payment_method is
  'Stripe の payment_method_details.type（card / paypay 等）。0096より前の購入は null（当時はカードのみ有効）。stripe-webhook が決済成立後に書き込む。';

-- ------------------------------------------------------------
-- 2) admin_pending_payouts に「カードで判定できない購入の件数」を足す
-- ------------------------------------------------------------
-- 返す列が増えるので create or replace では差し替えられない
drop function if exists public.admin_pending_payouts(int);

create function public.admin_pending_payouts(p_limit int default 100)
returns table (
  id uuid,
  user_id uuid,
  nickname text,
  coins int,
  amount_yen int,
  fee_yen int,
  created_at timestamptz,
  bank_name text,
  bank_code text,
  branch_name text,
  branch_code text,
  account_type text,
  account_number text,
  account_holder_kana text,
  is_verified boolean,
  shared_card_count int,
  flagged_gift_count int,
  non_card_purchase_count int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*) into v_n from public.payouts p where p.status = 'pending';
  perform public._log_admin_action('view_pending_payouts', null, v_n || '件の口座情報を表示');

  return query
  select p.id, p.user_id,
         coalesce(nullif(pf.nickname, ''), '(不明)'),
         p.coins, p.amount_yen, p.fee_yen, p.created_at,
         p.bank_name, p.bank_code, p.branch_name, p.branch_code,
         p.account_type, p.account_number, p.account_holder_kana,
         coalesce(ts.is_verified, false),
         -- このピタメイトとカードを共有している**他の**アカウントの数
         (select count(distinct b.user_id)::int
            from public.user_payment_cards a
            join public.user_payment_cards b
              on b.fingerprint = a.fingerprint and b.user_id <> a.user_id
           where a.user_id = p.user_id),
         -- 受け取ったギフトのうち、IPまたはカードの共有で印が付いたもの
         (select count(*)::int from public.gifts g
           where g.receiver_id = p.user_id
             and (g.ip_flagged or g.card_flagged)),
         -- カードのフィンガープリントで判定できない購入(PayPay等)の件数。
         -- null は 0096 以前＝当時カードのみなので数えない。
         (select count(*)::int from public.coin_purchases cp
           where cp.user_id = p.user_id
             and cp.payment_method is not null
             and cp.payment_method <> 'card')
  from public.payouts p
  left join public.profiles pf on pf.id = p.user_id
  left join public.profile_trust_stats ts on ts.user_id = p.user_id
  where p.status = 'pending'
  order by p.created_at
  limit greatest(1, least(p_limit, 500));
end;
$$;

comment on function public.admin_pending_payouts(int) is
  '未振込の換金申請と振込先(運営のみ)。0080でカード共有件数と要確認ギフト件数、0096でカード判定できない購入の件数を追加した(資金が出る瞬間に目に入るようにするため)。閲覧は操作記録に残る。';

revoke all on function public.admin_pending_payouts(int) from public;
grant execute on function public.admin_pending_payouts(int) to authenticated;
-- ============================================================
-- 0097: ギフトを「二本の債権債務関係」として実装し直す（A-1）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答（論点B）。**規約だけ直しても足りない。**
--
--   「行政の実質判断では、**規約の文言と実装・表示の一貫性が重視されます**」
--   「構成を書き換えても、機能の実質が『誰にでも送金でき、受け手が自由に
--     現金化できる』ものであれば、**実質論で為替に引き寄せられます**」
--
-- 規約 第7条の2 は、ゲスト→当社（コインの消費・消滅）と
-- 当社→ピタメイト（自己の報酬債務としての報酬コインの付与）という
-- 二本の独立した債権債務関係に書き換えた。ここではその実装側を揃える。
--
-- ■ 1) 言い方を変える（トーク本文・通知）
--   「贈りました」「受け取りました」は A→B の移転を表す言い方。
--   **画面の言い方が食い違うと、条文の構成が崩れる。**
--   既に流れたメッセージは書き換えない（過去の事実の改変になる）。
--   表示側（`src/lib/giftSticker.ts`）が新旧どちらの本文も読めるようにしてある。
--
-- ■ 2) 通知の金額を実額にする
--   従前は利用料を引く**前**の額を「受け取りました」と通知していた。
--   実際に付与されるのは 35% 控除後なので、**通知のほうが大きい**数字だった。
--   `platform_fees.net_coins` から実額を読む。
--
-- ■ 3) 制限を3つ足す（論点B(b)）
--   いずれも「役務との牽連性」と「送金網化の防止」を強める方向。
--   ・受領側の30日上限（特定の受け手への資金集中は転用の典型）
--   ・同一の相手への30日累計上限（二者間の反復は原因関係のない資金移動と
--     **最も見分けがつきにくい**）
--   ・完了確定から30日を過ぎたらギフトできない（役務との時間的な牽連）
--
--   ⚠️ **数値を緩める方向の変更は、弁護士に相談してから。**
--   制限は「不特定者間の資金移動機能ではない」ことを示す実質そのものであり、
--   緩めると該当性評価の前提が崩れる（恒久的な制約）。
-- ============================================================

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
  -- 0097: 受領側の上限・同一相手への累計・完了からの経過日数
  c_max_recv_month  constant int := 1000000;  -- 受領側 30日
  c_max_pair_month  constant int := 100000;   -- 同一の相手へ 30日
  c_gift_window_days constant int := 30;      -- 完了確定からギフトできる期間
  v_recv_month int;
  v_pair_month int;
  v_last_completed timestamptz;
  v_net int;
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

  -- 【付随謝礼】実際に一緒に遊んだ相手(=完了した予約がある相手)にのみ、
  -- かつ**完了確定から c_gift_window_days 以内**に限る(0097)。
  -- 期間で画すことで「完了した役務への謝礼」という性格が強まる。
  -- 無期限にすると、役務との牽連性が切れた資金移動と見分けがつかなくなる。
  -- **完了確定の時刻は bookings に無い**(completed_at 相当の列が存在しない)。
  -- 報酬の付与が完了確定そのものなので、その記録の時刻を使う。
  select max(t.created_at) into v_last_completed
    from public.bookings b
    join public.coin_transactions t
      on t.related_booking_id = b.id and t.type = 'booking_earned'
    where b.status = 'completed'
      and ((b.guest_id = v_sender and b.host_id = v_receiver)
        or (b.guest_id = v_receiver and b.host_id = v_sender));
  if v_last_completed is null then
    raise exception 'NO_COMPLETED_PLAY';
  end if;
  if v_last_completed < now() - make_interval(days => c_gift_window_days) then
    raise exception 'GIFT_WINDOW_CLOSED';
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

  -- 【上限・0097】受領側の集中と、二者間の反復を止める。
  -- 特定の受け手への資金集中はギフティングが送金に転用される典型で、
  -- 二者間の反復は**原因関係のない資金移動と最も見分けがつきにくい**。
  select coalesce(sum(coins), 0) into v_recv_month
    from public.gifts where receiver_id = v_receiver and created_at > now() - interval '30 days';
  if v_recv_month + p_coins > c_max_recv_month then
    raise exception 'RECEIVER_MONTHLY_LIMIT';
  end if;
  select coalesce(sum(coins), 0) into v_pair_month
    from public.gifts
    where sender_id = v_sender and receiver_id = v_receiver
      and created_at > now() - interval '30 days';
  if v_pair_month + p_coins > c_max_pair_month then
    raise exception 'PAIR_MONTHLY_LIMIT';
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

  -- 0097: 「贈りました」= A→B の移転を表す言い方をやめる。
  -- 規約(第7条の2)はコインの消費と報酬コインの付与という二本の構成に
  -- 書き換えており、**画面の言い方が食い違うと構成が崩れる。**
  v_body := '🎁 ありがとうギフト ' || p_coins || 'コイン';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 付与された**実額**(利用料控除後)を通知する。
  -- 従前は控除前の額を「受け取りました」と書いており、実際より大きい数字が出ていた。
  select net_coins into v_net from public.platform_fees where gift_id = v_gift_id;

  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんがありがとうギフトをしました',
    '報酬コイン' || coalesce(v_net, p_coins) || 'コインが付与されました(付与から7日間は換金できません)'
      || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

revoke all on function public.send_gift(uuid, int, text, text) from public;

comment on function public.send_gift(uuid, int, text, text) is
  'ギフト。0097で「AがBに贈る」から「コインの消費＋当社の報酬債務としての報酬コイン付与」の構成に合わせ、文言と制限を改めた（規約第7条の2・2026-08-04の弁護士回答 論点B）。';

revoke all on function public.send_gift(uuid, int, text, text) from public, anon;
grant execute on function public.send_gift(uuid, int, text, text) to authenticated;
-- ============================================================
-- 0098: 退会後の換金に最低申請額を適用しない（A-2）と、
--       利用停止・強制退会時のコインの取扱い（A-3）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答。**どちらも「稼得済みの報酬を没収している」
-- と読まれる形**になっていた。
--
-- ■ A-2（第1の1(1)）
--   「報酬コインが5,000未満のまま退会したピタメイトは、**換金の機会を
--     一度も与えられないまま90日で権利を失う**ことになります。……
--     報酬コインは……**既に稼得した報酬債権の残高表示**ですから、その消滅は
--     購入コインの失効とは質的に異なり、**実質は稼得済み報酬の没収**です。
--     民法の任意規定によれば報酬債権は5年の消滅時効に服するにすぎない
--     ところ、これを90日かつ最低額未満は行使不能という形で消滅させる条項は、
--     **消費者契約法10条による無効の主張に対して脆弱**です。」
--
--   第13条4項がサービス終了時には最低申請額を外していることとの均衡からも、
--   揃える必要があった。**手数料300コインの控除自体は実費相当として維持**
--   （弁護士も「維持して構いません」）。
--
-- ■ A-3（第1の3①）
--   「第6条の措置が取られた場合に、購入コイン・報酬コインがどうなるかが
--     **規約全体のどこにも書かれていません**。無定めのまま運用で失効させれば、
--     まさに消費者契約法9条・10条の争点です。」
--
--   規約に第6条の3を新設した。ここではその実装を置く。
--   **違反の内容と、既に提供された役務の対価とは別の事柄。**
--   役務は現に提供されており、その対価まで一律に没収すれば、
--   違反に対する制裁ではなく**利得**になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1) 退会後の換金は最低申請額を適用しない（A-2）
-- ------------------------------------------------------------
-- 退会済みかどうかは profiles.withdrawn_at で判る（0086）。
-- 退会後は**残額の全部を1回で**申請する前提なので、最低額の意味がない。
create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 換金事務手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
  v_withdrawn timestamptz;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 0098: **退会後の最終換金には最低申請額を適用しない。**
  -- 5,000未満のまま退会した人が、一度も換金できないまま90日で失うのを防ぐ
  -- (規約 第6条の2第4項)。手数料の控除は退会後も同じ。
  select p.withdrawn_at into v_withdrawn from public.profiles p where p.id = v_uid;

  if p_coins is null or p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;
  if v_withdrawn is null and p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;
  -- 手数料以下では振込が成り立たない(手取りが0以下になる)
  if p_coins <= c_fee then
    raise exception 'BELOW_PAYOUT_FEE';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';

  -- 0077: 係争中のチャージバックに紐づく予約の報酬も保留。
  -- **ホスト全体を止めるのではなく、紐づく額だけを差し引く。**
  v_dispute_hold := public._dispute_payout_hold(v_uid);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、**どちらの保留かを分けて伝える**。
    -- 利用者から見ると原因も待つべき期間も違う(ギフトは7日で明ける／
    -- 係争は決着するまで分からない)ので、同じ文言にしてはいけない。
    if p_coins <= coalesce(v_balance, 0) then
      if v_dispute_hold > 0 and p_coins > coalesce(v_balance, 0) - v_dispute_hold then
        raise exception 'DISPUTE_ON_HOLD';
      end if;
      if v_gift_hold > 0 then
        raise exception 'GIFT_ON_HOLD';
      end if;
    end if;
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(int) is
  '換金申請。0098で、退会済み(profiles.withdrawn_at)の場合は最低申請額を適用しないようにした(規約 第6条の2第4項・2026-08-04の弁護士回答)。手数料は退会後も控除する。';

revoke all on function public.request_bank_payout(int) from public, anon;
grant execute on function public.request_bank_payout(int) to authenticated;

-- ------------------------------------------------------------
-- 2) 利用停止・強制退会時のコインの取扱い（A-3・規約 第6条の3）
-- ------------------------------------------------------------
-- 運営が実行する。**cron では走らせない。**
-- 他人の稼得済みの報酬を消す操作なので、必ず人が理由を書いて実行する。
alter table public.profiles
  add column if not exists suspended_at timestamptz,
  add column if not exists payout_claim_deadline timestamptz;

comment on column public.profiles.suspended_at is
  '規約第6条の3。利用停止・強制退会の時刻。';
comment on column public.profiles.payout_claim_deadline is
  '規約第6条の3第2項。この日時まで換金の申請ができる（退会後の90日枠と同じ扱い）。';

create or replace function public.admin_suspend_account(
  p_user_id uuid,
  p_reason text,
  p_forfeit_earned boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;
  -- **理由は必須。** 第6条の3第6項の再審査に応じられない措置は取らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = p_user_id for update;

  -- 第6条の3第5項: 購入コインは消滅する
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots set remaining = 0 where user_id = p_user_id and remaining > 0;
    update public.coin_wallets set balance = 0, bonus_balance = 0 where user_id = p_user_id;
    if v_paid > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_paid, 'expire', 'suspend_paid');
    end if;
    if v_bonus > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_bonus, 'expire', 'suspend_bonus');
    end if;
  end if;

  -- 第6条の3第2項/第3項: **報酬コインは原則として残す。**
  -- 没収するのは、違反行為により取得されたものに限る（運営が個別に判断）。
  if p_forfeit_earned and coalesce(v_earned, 0) > 0 then
    update public.coin_wallets set earned_balance = 0 where user_id = p_user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, -v_earned, 'expire', 'suspend_earned_forfeit');
    v_deadline := null;
  end if;

  update public.profiles
    set suspended_at = now(),
        payout_claim_deadline = v_deadline
    where id = p_user_id;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**
  update public.host_settings set is_host = false where user_id = p_user_id;

  perform public._log_admin_action(
    'suspend_account', p_user_id,
    case when p_forfeit_earned then '報酬コインも没収: ' else '報酬コインは残す: ' end || p_reason);

  return jsonb_build_object(
    'user_id', p_user_id,
    'paid_expired', v_paid,
    'bonus_expired', v_bonus,
    'earned_forfeited', case when p_forfeit_earned then v_earned else 0 end,
    'payout_claim_deadline', v_deadline
  );
end;
$$;

comment on function public.admin_suspend_account(uuid, text, boolean) is
  '規約第6条の3。利用停止・強制退会時のコインの取扱い。購入コインは消滅、報酬コインは原則として残し90日の換金枠を与える。没収は p_forfeit_earned=true を明示したときだけ(違反行為により取得されたものに限る)。理由は必須で、操作記録に残る。';

revoke all on function public.admin_suspend_account(uuid, text, boolean) from public, anon;
grant execute on function public.admin_suspend_account(uuid, text, boolean) to authenticated;
-- ============================================================
-- 0099: 相殺の時的限界と、不正関与者の扱い（C-2）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答（第1の1(4)）。第8条の6は四重の限定を置いていて
-- 「抑制の効いた設計」と評価されたが、微修正が2点あった。
--
-- ■ 控除の時的限界（実装するのはこちら）
--   「**控除の時的限界が無限定**です。国際ブランドのチャージバック申立期間
--     （概ね120日）を踏まえ、報酬確定から一定期間（例えば180日）を経過した
--     取引は控除の対象としない旨の限定を置くと、**ピタメイト側の予見可能性が
--     高まり、条項の許容性がさらに強固になります**。」
--
--   期限を切らないと、ピタメイトは**いつまで取り返されうるのか分からない**。
--   規約 第8条の6第4項2の2号に条文を置き、ここで候補の抽出から外す。
--
-- ■ 不正関与者への請求（条文のみ・実装なし）
--   「第4項2号（支払済み金銭の返還を請求しない）は、**ピタメイト自身が不正に
--     関与していた場合**……にまで請求権を放棄する趣旨ではないはずですから、
--     ただし書を付すべきです。」
--
--   こちらは**支払済みの金銭を請求する**話で、システムの操作ではない
--   （訴訟・交渉の世界）。規約 第8条の6第4項2号のただし書だけを置いた。
--   実装で自動化するものではない。
-- ============================================================

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
           ), 0) as earned,
           -- 報酬が確定した時刻。bookings に完了時刻の列が無いので、
           -- 報酬付与の記録の時刻を使う(0097 の send_gift と同じ考え方)
           (select max(t.created_at) from public.coin_transactions t
             where t.related_booking_id = b.id and t.type = 'booking_earned') as earned_at
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
           ), 0) as earned,
           g.created_at as earned_at
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
    -- 0099(規約 第8条の6第4項2の2号): **報酬確定から180日を過ぎた取引は対象外。**
    -- 国際ブランドの申立期間(概ね120日)を踏まえた時的限界。
    -- 期限を切らないと、ピタメイトは**いつまで取り返されうるのか分からない**。
    -- 弁護士:「ピタメイト側の予見可能性が高まり、条項の許容性がさらに強固になります」
    and r.earned_at is not null
    and r.earned_at > now() - interval '180 days'
  order by r.host_id;
end;
$$;

comment on function public.chargeback_offset_preview(uuid) is
  '相殺の対象候補。0099で「報酬確定から180日超は対象外」の時的限界を入れた(規約 第8条の6第4項2の2号)。';

revoke all on function public.chargeback_offset_preview(uuid) from public, anon;
grant execute on function public.chargeback_offset_preview(uuid) to authenticated;
-- ============================================================
-- 0100: 退会・利用停止後の換金は「換金可能な全額を一括」に限る
-- ------------------------------------------------------------
-- 0098(A-2)で最低申請額の適用を外したところ、**条文が書いていることを
-- 実装していない**箇所が2つ残っていた。
--
-- ■ 1) 分割して何回でも申請できた
--   規約 第6条の2第4項は「保有する報酬コインの**全額を一括して**申請する
--   ことができます」と書いてあるのに、実装は回数も額も見ていなかった。
--
--   実測: 1,600コインを 400 × 3回 に分けて申請できた。
--   結果は **振込3件で合計300円、手数料は900円**。
--
--   **これは利用者が得をする穴ではなく、利用者が損をする落とし穴。**
--   1回で申請していれば手取り1,300円だったものが300円になる。
--   運営から見ても、¥100の振込を3件、目視と消し込みで扱うことになる。
--
-- ■ 2) 利用停止された人には最低額の免除が効いていなかった
--   規約 第6条の3第2項は「第6条の2第4項に**準じて**換金の申請を行うことが
--   できます」と定めたのに、実装は `withdrawn_at` しか見ていなかった。
--
--   実測: 1,600コインを持ったまま利用停止された人は `MIN_PAYOUT_COINS` で
--   弾かれ、90日後に消える。**弁護士が指摘した「稼得済み報酬の没収」が、
--   停止の側にそのまま残っていた。**
--
-- ■ なぜ「全額を一括」で足りるのか
--   額を全額に縛ると、1回目で残高が0になるので**2回目は自然に起きない**。
--   回数を数える必要がない。
--
--   ただし保留(ギフトの7日・係争中)がある場合は全額を出せないので、
--   縛るのは「**その時点で換金可能な全額**」。保留が明けたら改めて申請できる。
--   これは分割ではなく、保留の仕組みが働いた結果なので妨げない。
-- ============================================================

create or replace function public.request_bank_payout(p_coins int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;        -- 換金事務手数料(コイン=円)。変更したらUI(Wallet)の表記も更新すること
  c_min_coins constant int := 5000; -- 最低申請コイン(0063で1,000から変更)
  v_uid uuid := auth.uid();
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_verified boolean;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
  v_final boolean;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  -- 0098/0100: **退会または利用停止の後は「最終換金」として扱う。**
  -- 最低申請額を外す代わりに、換金可能な全額を1回で出してもらう
  -- (規約 第6条の2第4項・第6条の3第2項)。
  select (p.withdrawn_at is not null or p.suspended_at is not null)
    into v_final from public.profiles p where p.id = v_uid;
  v_final := coalesce(v_final, false);

  if p_coins is null or p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;
  if not v_final and p_coins < c_min_coins then
    raise exception 'MIN_PAYOUT_COINS';
  end if;
  -- 手数料以下では振込が成り立たない(手取りが0以下になる)
  if p_coins <= c_fee then
    raise exception 'BELOW_PAYOUT_FEE';
  end if;

  select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'NOT_VERIFIED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = v_uid;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets where user_id = v_uid for update;

  -- 0069(0020から復活): 直近7日に受領したギフトは換金保留。
  -- 予約の報酬は検収(プレイ完了の確定)を経ているので即時に換金できるが、
  -- ギフトは検収を伴わない一方向の移転なので、様子を見る時間を置く。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = v_uid and created_at > now() - interval '7 days';

  -- 0077: 係争中のチャージバックに紐づく予約の報酬も保留。
  -- **ホスト全体を止めるのではなく、紐づく額だけを差し引く。**
  v_dispute_hold := public._dispute_payout_hold(v_uid);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if p_coins > v_available then
    -- 残高自体は足りているのに保留で足りない場合は、**どちらの保留かを分けて伝える**。
    -- 利用者から見ると原因も待つべき期間も違う(ギフトは7日で明ける／
    -- 係争は決着するまで分からない)ので、同じ文言にしてはいけない。
    if p_coins <= coalesce(v_balance, 0) then
      if v_dispute_hold > 0 and p_coins > coalesce(v_balance, 0) - v_dispute_hold then
        raise exception 'DISPUTE_ON_HOLD';
      end if;
      if v_gift_hold > 0 then
        raise exception 'GIFT_ON_HOLD';
      end if;
    end if;
    raise exception 'INSUFFICIENT_EARNED_BALANCE';
  end if;

  -- 0100: **最終換金は分割できない。** 額を全額に縛ると、1回目で残高が0に
  -- なるので2回目は自然に起きない。回数を数える必要がない。
  -- 保留がある場合に「換金可能な全額」で足りるのは、保留が明けてからの
  -- 申請は分割ではなく保留の仕組みが働いた結果だから。
  if v_final and p_coins <> v_available then
    raise exception 'FINAL_PAYOUT_MUST_BE_WHOLE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - p_coins where user_id = v_uid;

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    v_uid, p_coins, p_coins - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (v_uid, -p_coins, 'payout', 'request_bank_payout:' || v_payout_id);

  return v_payout_id;
end;
$$;

comment on function public.request_bank_payout(int) is
  '換金申請。退会(withdrawn_at)または利用停止(suspended_at)の後は最終換金として扱い、最低申請額を外す代わりに**換金可能な全額を一括**でのみ申請できる(規約 第6条の2第4項・第6条の3第2項。0098・0100)。手数料は最終換金でも控除する。';

revoke all on function public.request_bank_payout(int) from public, anon;
grant execute on function public.request_bank_payout(int) to authenticated;
-- ============================================================
-- 0101: 制限値を「運営が動かせる場所」へ集約する
-- ------------------------------------------------------------
-- ■ なぜ
--   条文は幅で書いてある(「一定期間」「最長30日」)のに、実装が数値を
--   ハードコードしているせいで、**運営が動かせなくなっていた**箇所がある。
--
--     ・新規ユーザーの購入上限   … platform_pricing にあるが**画面が無い**
--     ・ギフトの上限(6種)       … send_gift の中の `constant` で埋まっている
--
--   前者は SQL Editor を開かないと変えられず、後者は
--   `create or replace function` を書かないと変えられない。どちらも
--   「運営作業は運営コンソールから」という方針から外れている。
--
-- ■ 設計: 条文には上限と手続だけを書き、数値は運営が動かす
--   料率(0091 の admin_schedule_fee_change)がすでにこの形になっている。
--   条文が定めるのは「30%を超えない」「30日前に理由をつけて告知する」だけで、
--   実際の段構成は運営が自由に組める。**上限があるから、上限内では
--   確実に動かせる。**
--
--   同じ形をギフトと新規ユーザー制限にも広げる:
--     ・CHECK 制約が「これ以上は動かせない天井」を持つ
--     ・変更には**理由が必須**で、admin_actions に前後の値ごと残る
--
-- ■ 天井をどこに置いたか(ギフト)
--   ギフトの為替取引該当性を否定している事情のうち、**質的なもの**は
--   ここでは動かせない(相手方の限定・相互送金の禁止・原資は購入コインのみ・
--   チャージ直後の禁止・受領から7日の換金保留)。これらは数値ではないので
--   そもそもこの表に無い。
--
--   動かせるのは「いくらまで」「いつまで」だけで、それにも天井を置く。
--   天井は現在値の2倍前後、期間は90日(3か月)。**付随謝礼として説明できる
--   範囲**を超えないための線で、緩めきっても構成が変わらない幅に収めてある。
--
-- ■ ここに入れなかったもの
--   換金の最低申請額(5,000)と換金事務手数料(300)は入れていない。
--   特商法表記・ウォレット画面・利用規約に**数値そのものが書かれている**ため、
--   変えるなら書面の改定とセットになる。表だけ動かせるようにすると、
--   画面の数字と実際の挙動がずれる事故になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. ギフトの上限を platform_pricing へ移す
--
-- 既定値は 0097 時点の `constant` と同じ。**この migration では挙動を
-- 変えない。** 動かせる場所に移すだけ。
-- ------------------------------------------------------------
alter table public.platform_pricing
  add column if not exists gift_max_per_tx int not null default 50000,
  add column if not exists gift_max_per_day int not null default 50000,
  add column if not exists gift_max_per_month int not null default 200000,
  add column if not exists gift_max_recv_month int not null default 1000000,
  add column if not exists gift_max_pair_month int not null default 100000,
  add column if not exists gift_window_days int not null default 30;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'platform_pricing_gift_limits_check') then
    alter table public.platform_pricing
      add constraint platform_pricing_gift_limits_check
      check (
        -- 天井。ここを超える値は入れられない(規約 第7条の2の建て付けを保つ)
            gift_max_per_tx     between 10 and 100000
        and gift_max_per_day    between 10 and 100000
        and gift_max_per_month  between 10 and 500000
        and gift_max_recv_month between 10 and 2000000
        and gift_max_pair_month between 10 and 200000
        -- 完了確定からギフトできる期間。3か月を超えると、
        -- 「完了した役務への謝礼」という牽連性の説明が苦しくなる
        and gift_window_days    between 1 and 90
        -- 順序。1回 <= 1日 <= 30日、同一相手 <= 受領側 でないと
        -- 内側の上限が意味を失う
        and gift_max_per_day    >= gift_max_per_tx
        and gift_max_per_month  >= gift_max_per_day
        and gift_max_recv_month >= gift_max_pair_month
      );
  end if;
end $$;

comment on column public.platform_pricing.gift_max_per_tx is
  'ギフト1回あたりの上限(コイン)。天井 100,000。';
comment on column public.platform_pricing.gift_max_per_day is
  '送り主の直近24時間の合計上限(コイン)。天井 100,000。';
comment on column public.platform_pricing.gift_max_per_month is
  '送り主の直近30日の合計上限(コイン)。天井 500,000。';
comment on column public.platform_pricing.gift_max_recv_month is
  '受領側の直近30日の合計上限(コイン)。特定の受け手への資金集中を止める。天井 2,000,000。';
comment on column public.platform_pricing.gift_max_pair_month is
  '同一の相手への直近30日の合計上限(コイン)。二者間の反復を止める。天井 200,000。';
comment on column public.platform_pricing.gift_window_days is
  'プレイ完了の確定からギフトできる期間(日)。規約第7条の2は「一定期間」としか書いていないので数値は動かせる。天井 90。';

-- ------------------------------------------------------------
-- 2. send_gift を表から読むようにする
--
-- 0097 の定義を出発点にして、`constant` の6つを select に置き換えただけ。
-- **それ以外の判定・順序・文言は 0097 のまま。**
-- (関数を作り直すときは最新の定義から始めること)
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
  -- 0101: 上限は platform_pricing から読む(運営コンソールで変えられる)
  v_max_per_tx int;
  v_max_per_day int;
  v_max_per_month int;
  v_max_recv_month int;
  v_max_pair_month int;
  v_window_days int;
  v_sender uuid := auth.uid();
  v_promise public.promises;
  v_receiver uuid;
  v_paid int;
  v_last_purchase timestamptz;
  v_sum_day int;
  v_sum_month int;
  v_recv_month int;
  v_pair_month int;
  v_last_completed timestamptz;
  v_net int;
  v_ip_flag boolean;
  v_gift_id uuid;
  v_sender_name text;
  v_msg text;
  v_body text;
begin
  if v_sender is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select gift_max_per_tx, gift_max_per_day, gift_max_per_month,
         gift_max_recv_month, gift_max_pair_month, gift_window_days
    into v_max_per_tx, v_max_per_day, v_max_per_month,
         v_max_recv_month, v_max_pair_month, v_window_days
    from public.platform_pricing where id = 1;

  if p_coins is null or p_coins < 10 or p_coins > v_max_per_tx then
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

  -- 【付随謝礼】実際に一緒に遊んだ相手(=完了した予約がある相手)にのみ、
  -- かつ**完了確定から gift_window_days 以内**に限る(0097)。
  -- 期間で画すことで「完了した役務への謝礼」という性格が強まる。
  -- 無期限にすると、役務との牽連性が切れた資金移動と見分けがつかなくなる。
  -- **完了確定の時刻は bookings に無い**(completed_at 相当の列が存在しない)。
  -- 報酬の付与が完了確定そのものなので、その記録の時刻を使う。
  select max(t.created_at) into v_last_completed
    from public.bookings b
    join public.coin_transactions t
      on t.related_booking_id = b.id and t.type = 'booking_earned'
    where b.status = 'completed'
      and ((b.guest_id = v_sender and b.host_id = v_receiver)
        or (b.guest_id = v_receiver and b.host_id = v_sender));
  if v_last_completed is null then
    raise exception 'NO_COMPLETED_PLAY';
  end if;
  if v_last_completed < now() - make_interval(days => v_window_days) then
    raise exception 'GIFT_WINDOW_CLOSED';
  end if;

  -- 【相互送金禁止】
  if exists (
    select 1 from public.gifts where sender_id = v_receiver and receiver_id = v_sender
  ) then
    raise exception 'MUTUAL_GIFT_FORBIDDEN';
  end if;

  -- 【チャージ直後禁止】最後のコイン購入から24時間は送金不可。
  -- **これは数値の調整ではなく質的な遮断なので、表に出していない。**
  select max(created_at) into v_last_purchase from public.coin_purchases where user_id = v_sender;
  if v_last_purchase is not null and v_last_purchase > now() - interval '24 hours' then
    raise exception 'RECENT_PURCHASE_COOLDOWN';
  end if;

  -- 【上限】直近24時間・直近30日の送金合計
  select coalesce(sum(coins), 0) into v_sum_day
    from public.gifts where sender_id = v_sender and created_at > now() - interval '1 day';
  select coalesce(sum(coins), 0) into v_sum_month
    from public.gifts where sender_id = v_sender and created_at > now() - interval '30 days';
  if v_sum_day + p_coins > v_max_per_day then
    raise exception 'DAILY_LIMIT';
  end if;
  if v_sum_month + p_coins > v_max_per_month then
    raise exception 'MONTHLY_LIMIT';
  end if;

  -- 【上限・0097】受領側の集中と、二者間の反復を止める。
  -- 特定の受け手への資金集中はギフティングが送金に転用される典型で、
  -- 二者間の反復は**原因関係のない資金移動と最も見分けがつきにくい**。
  select coalesce(sum(coins), 0) into v_recv_month
    from public.gifts where receiver_id = v_receiver and created_at > now() - interval '30 days';
  if v_recv_month + p_coins > v_max_recv_month then
    raise exception 'RECEIVER_MONTHLY_LIMIT';
  end if;
  select coalesce(sum(coins), 0) into v_pair_month
    from public.gifts
    where sender_id = v_sender and receiver_id = v_receiver
      and created_at > now() - interval '30 days';
  if v_pair_month + p_coins > v_max_pair_month then
    raise exception 'PAIR_MONTHLY_LIMIT';
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

  -- 0097: 「贈りました」= A→B の移転を表す言い方をやめる。
  -- 規約(第7条の2)はコインの消費と報酬コインの付与という二本の構成に
  -- 書き換えており、**画面の言い方が食い違うと構成が崩れる。**
  v_body := '🎁 ありがとうギフト ' || p_coins || 'コイン';
  if v_msg is not null then
    v_body := v_body || '「' || v_msg || '」';
  end if;
  insert into public.messages (promise_id, sender_id, body)
    values (p_promise_id, v_sender, v_body);

  -- 付与された**実額**(利用料控除後)を通知する。
  -- 従前は控除前の額を「受け取りました」と書いており、実際より大きい数字が出ていた。
  select net_coins into v_net from public.platform_fees where gift_id = v_gift_id;

  select nickname into v_sender_name from public.profiles where id = v_sender;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_receiver, 'gift_received',
    coalesce(nullif(v_sender_name, ''), '誰か') || 'さんがありがとうギフトをしました',
    '報酬コイン' || coalesce(v_net, p_coins) || 'コインが付与されました(付与から7日間は換金できません)'
      || coalesce('「' || v_msg || '」', ''),
    p_promise_id
  );

  return v_gift_id;
end;
$$;

comment on function public.send_gift(uuid, int, text, text) is
  'ギフト。0097で「AがBに贈る」から「コインの消費＋当社の報酬債務としての報酬コイン付与」の構成に合わせ、文言と制限を改めた（規約第7条の2・2026-08-04の弁護士回答 論点B）。0101で上限値を platform_pricing から読むようにした。';

revoke all on function public.send_gift(uuid, int, text, text) from public, anon;
grant execute on function public.send_gift(uuid, int, text, text) to authenticated;

-- ------------------------------------------------------------
-- 3. 運営コンソールから読む
--
-- **天井も一緒に返す。** 画面側に数字を書き写すと、CHECK 制約を緩めた
-- ときに画面だけ古い天井を出し続ける。出典は制約のあるこちら側に置く。
-- ------------------------------------------------------------
create or replace function public.admin_platform_limits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.platform_pricing;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.platform_pricing where id = 1;

  return jsonb_build_object(
    'newUser', jsonb_build_object(
      'days', v_p.new_user_days,
      'purchaseMaxYen', v_p.new_user_purchase_max_yen,
      'periodPurchaseMaxYen', v_p.new_user_period_purchase_max_yen,
      'payoutHoldDays', v_p.new_user_payout_hold_days
    ),
    'gift', jsonb_build_object(
      'maxPerTx', v_p.gift_max_per_tx,
      'maxPerDay', v_p.gift_max_per_day,
      'maxPerMonth', v_p.gift_max_per_month,
      'maxRecvMonth', v_p.gift_max_recv_month,
      'maxPairMonth', v_p.gift_max_pair_month,
      'windowDays', v_p.gift_window_days
    ),
    -- 天井(CHECK 制約と同じ値。片方だけ直すと画面が嘘をつく)
    'caps', jsonb_build_object(
      'newUserPayoutHoldDays', 30,
      'giftMaxPerTx', 100000,
      'giftMaxPerDay', 100000,
      'giftMaxPerMonth', 500000,
      'giftMaxRecvMonth', 2000000,
      'giftMaxPairMonth', 200000,
      'giftWindowDays', 90
    ),
    'updatedAt', v_p.updated_at
  );
end;
$$;

comment on function public.admin_platform_limits() is
  '運営コンソールの「制限値」タブ。現在値と、CHECK 制約が定める天井を返す。';

revoke all on function public.admin_platform_limits() from public, anon;
grant execute on function public.admin_platform_limits() to authenticated;

-- ------------------------------------------------------------
-- 4. 運営コンソールから変える
--
-- ■ 理由を必須にしているのは、運営を縛るためではなく守るため
--   料率変更(第8条の2第4項)と同じ。後から「理由なく上限を下げて
--   換金させなかった」と言われたときに、反証できる記録がこれしかない。
--
-- ■ 部分更新
--   p_values に入っているキーだけを更新する。画面が1項目ずつ直せる。
--   入っていないキーは現在値のまま(coalesce)。
--
-- ■ 通知は出さない
--   料率と違い、これらは**不正防止の措置**で、規約第8条の6第5項が
--   「具体的な数値は変更することがあります」と定めている。個別通知の
--   義務が無い代わりに、admin_actions への記録を必ず残す。
-- ------------------------------------------------------------
create or replace function public.admin_update_platform_limits(
  p_reason text,
  p_values jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_diff text := '';
  v_key text;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object'
     or p_values = '{}'::jsonb then
    raise exception 'NO_CHANGES';
  end if;

  -- 知らないキーは黙って捨てない。**綴り間違いで「変えたつもり」に
  -- なるのが一番まずい**ので、その場で落とす
  for v_key in select jsonb_object_keys(p_values)
  loop
    if v_key not in (
      'newUserDays', 'newUserPurchaseMaxYen', 'newUserPeriodPurchaseMaxYen',
      'newUserPayoutHoldDays', 'giftMaxPerTx', 'giftMaxPerDay',
      'giftMaxPerMonth', 'giftMaxRecvMonth', 'giftMaxPairMonth',
      'giftWindowDays'
    ) then
      raise exception 'UNKNOWN_KEY:%', v_key;
    end if;
  end loop;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days
  ) into v_before
  from public.platform_pricing where id = 1;

  -- 天井を超えた値は CHECK 制約が落とす。**ここで先回りして
  -- 個別のエラー名にしない** — 制約が唯一の出典であるほうが、
  -- 制約を直したときに漏れない
  update public.platform_pricing set
    new_user_days = coalesce((p_values ->> 'newUserDays')::int, new_user_days),
    new_user_purchase_max_yen =
      coalesce((p_values ->> 'newUserPurchaseMaxYen')::int, new_user_purchase_max_yen),
    new_user_period_purchase_max_yen =
      coalesce((p_values ->> 'newUserPeriodPurchaseMaxYen')::int, new_user_period_purchase_max_yen),
    new_user_payout_hold_days =
      coalesce((p_values ->> 'newUserPayoutHoldDays')::int, new_user_payout_hold_days),
    gift_max_per_tx = coalesce((p_values ->> 'giftMaxPerTx')::int, gift_max_per_tx),
    gift_max_per_day = coalesce((p_values ->> 'giftMaxPerDay')::int, gift_max_per_day),
    gift_max_per_month = coalesce((p_values ->> 'giftMaxPerMonth')::int, gift_max_per_month),
    gift_max_recv_month = coalesce((p_values ->> 'giftMaxRecvMonth')::int, gift_max_recv_month),
    gift_max_pair_month = coalesce((p_values ->> 'giftMaxPairMonth')::int, gift_max_pair_month),
    gift_window_days = coalesce((p_values ->> 'giftWindowDays')::int, gift_window_days),
    updated_at = now()
  where id = 1;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days
  ) into v_after
  from public.platform_pricing where id = 1;

  -- 「何を いくつから いくつへ」を記録に残す。
  -- 前後の値が無いと、記録があっても後から説明できない
  for v_key in select jsonb_object_keys(v_after)
  loop
    if (v_before ->> v_key) is distinct from (v_after ->> v_key) then
      v_diff := v_diff || case when v_diff = '' then '' else ' / ' end
        || v_key || ': ' || (v_before ->> v_key) || '→' || (v_after ->> v_key);
    end if;
  end loop;

  if v_diff = '' then
    raise exception 'NO_CHANGES';
  end if;

  perform public._log_admin_action('update_platform_limits', null,
    v_diff || ' 理由: ' || p_reason);

  return jsonb_build_object('changed', v_diff, 'values', v_after);
end;
$$;

comment on function public.admin_update_platform_limits(text, jsonb) is
  '制限値の変更。天井は platform_pricing の CHECK 制約が持つ。理由は必須で、前後の値とともに admin_actions に残る(0101)。';

revoke all on function public.admin_update_platform_limits(text, jsonb) from public, anon;
grant execute on function public.admin_update_platform_limits(text, jsonb) to authenticated;
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
-- ============================================================
-- 0103: 利用料は「実際に受け取った額」から引く(保留解除の過大控除を直す)
-- ------------------------------------------------------------
-- ■ 見つかった穴(0102 の逆向き)
--   完了時の利用料トリガー(0033/0091)は **new.coins = 予約の全額** を
--   基準に控除する。ところが、申し出の保留を一部返還で解除する
--   `release_hold_and_refund`(0042/0085)も status を 'completed' に
--   するので同じトリガーが走り、**ホストが受け取っていない分にまで
--   利用料がかかっていた。**
--
--   実測(2,000コインの予約・20%ティア):
--     50%返還  → ホストの受取 1,000。控除 400(2,000×20%)。**実効40%**
--     100%返還 → ホストの受取 **0**。それでも 340 が控除され、
--                **別の予約で稼いだ残高 5,000 が 4,660 に減った**
--
--   0102 が「運営の取り漏れ」だったのに対し、こちらは**運営の取りすぎ**。
--   規約 第8条の2第2項は「ピタメイトが受け取った対価から控除する」と
--   定めているので、受け取っていない額からの控除は**規約違反そのもの**。
--   個人のピタメイト相手なので、優越的地位の濫用の評価でも最も分が悪い。
--   platform_fees の明細も net 1,600 と記録され、実際の受取 600 と
--   食い違っていた(会計の突合も狂う)。
--
-- ■ 直し方: 基準額を「予約の全額」ではなく「この予約でホストに
--   実際に付与された額」にする
--
--   付与は必ず coin_transactions に type='booking_earned' で記録される
--   (complete_booking / auto_complete_bookings / release_hold_and_*)。
--   トリガーは deferrable initially deferred なので、**同じ
--   トランザクションで挿入された付与の行が必ず見える**。
--
--     通常の完了・自動確定・保留解除(全額) → 付与 = 予約額。挙動は従来どおり
--     保留解除(一部返還)                   → 付与 = ホストへ渡る分だけ
--     保留解除(全額返還)                   → 付与 = 0。**控除も明細も作らない**
--
--   関数を1本ずつ直すのではなくトリガー側で吸収するのは、
--   付与する関数が今後増えても取りこぼさないため(0033 が手数料を
--   トリガーにした理由と同じ)。
--
-- ■ 直さないことにしたもの(意図的)
--   `host_monthly_ticket_gmv`(料率ティアの当月累計)は、一部返還があっても
--   予約の全額を数える。累計が実受取より少し大きく出て、**以後の限界料率が
--   下がりやすくなる = ピタメイト有利**の側にしか働かないので、複雑にして
--   まで直さない。ティアは「その月に取り扱った規模」への割引であり、
--   予約の全額が一度は流通しているという説明も立つ。
-- ============================================================

create or replace function public._apply_booking_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r jsonb;
  v_fee int;
  v_base int;
begin
  if new.coins is null or new.coins <= 0 then
    return new;
  end if;

  -- 0103: この予約でホストに実際に付与された額。
  -- 一部返還つきの保留解除では予約額より小さく、全額返還では0になる
  select coalesce(sum(t.amount), 0) into v_base
    from public.coin_transactions t
    where t.related_booking_id = new.id
      and t.user_id = new.host_id
      and t.type = 'booking_earned';

  -- 受け取っていないものからは引かない(規約 第8条の2第2項)。
  -- 明細も作らない(gross 0 の行は applied_rate が計算できない)
  if v_base <= 0 then
    return new;
  end if;

  v_r := public._booking_fee_coins(
    new.host_id, new.guest_id, new.id, v_base, new.scheduled_at,
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
    new.host_id, 'booking', new.id, v_base, v_fee, v_base - v_fee,
    round(v_fee::numeric / v_base, 4), (v_r ->> 'repeat')::boolean);

  return new;
end;
$$;

comment on function public._apply_booking_fee() is
  '予約が completed になったときに利用料を引く。0103で基準額を「予約の全額」から'
  '「この予約でホストに実際に付与された額(booking_earned の合計)」に改めた。'
  '一部返還つきの保留解除で、受け取っていない分にまで課金していたため(規約 第8条の2第2項)。';

revoke all on function public._apply_booking_fee() from public, anon, authenticated;
-- ============================================================
-- 0104: webhook の購入記録(サポート料・決済手段)が0044に弾かれていた
-- ------------------------------------------------------------
-- ■ 見つかった穴(決済まわりのセキュリティ点検で発見)
--   stripe-webhook はコイン付与のあと、coin_purchases に対して
--     ・safety_fee_yen(あんしんサポート料)      … 素の UPDATE
--     ・payment_method(card / paypay。0096)     … 素の UPDATE
--   を書き込む。ところが 0044 が coin_purchases を**追記専用**にした
--   (UPDATE は app.ledger_override 無しでは常に例外)ため、この2つは
--   **本番で毎回失敗していた。**
--
--   実測: credit_coins_for_purchase → UPDATE safety_fee_yen で
--   `LEDGER_IMMUTABLE: coin_purchases は追記専用です` が出る。
--
-- ■ なぜ誰も気づかなかったか
--   ①webhook は記録の失敗をログに書くだけで 200 を返す(仕様として正しい:
--     ここで 5xx を返すと付与済みなのに Stripe が再送し続ける)。
--     コイン付与は成功するので、画面上は何も欠けて見えない。
--   ②テスト(90)は INSERT 時に safety_fee_yen を直接入れており、
--     webhook と同じ「あとから UPDATE」の経路を通っていなかった。
--
-- ■ 実害
--   ・サポート料の売上が記録されない(会計・税務の集計から欠ける。
--     2026-08-03 のテスト購入 ¥5,250 の ¥250 も記録されていない)
--   ・payment_method が永遠に null → 0096 の「カードの共有では判定
--     できません」警告が一度も出ない。運営コンソールの「非カード購入 0件」が
--     **「調べた結果シロ」ではなく「記録が無かった」**を意味してしまう
--
-- ■ 直し方: coin_purchases 専用の不変トリガーに差し替える
--   payouts が既に同じ形をとっている(0044 の _payout_amount_immutable:
--   「status/振込結果の更新は通常運用なので通す」)。同じ考え方で、
--   coin_purchases も**この2列だけ・書き込みは1回だけ**を通す:
--
--     safety_fee_yen  … 既定値 0 からの変更のみ(上書き不可)
--     payment_method  … null からの変更のみ(上書き不可)
--     それ以外の列    … 従来どおり変更禁止(金額・ユーザー・セッションID)
--     DELETE          … 従来どおり禁止
--     同値の再書き込み … 通す(Stripe の再送で同じ値がもう一度来る)
--
--   関数側(webhook)は**1文字も変えない**。デプロイ済みのコードが
--   このマイグレーションだけで意図どおり動き始める。マイグレーションと
--   関数デプロイの順序事故を避ける(0096 の safety_fee と同じ理由)。
--
-- ■ 適用後の運用メモ
--   既存の本番データ(テスト購入)の safety_fee_yen=0 は、公開前の
--   リセット(docs/reset-before-launch.sql)で消える予定なのでそのまま。
--   残す場合は override を宣言して1回だけ訂正する(ledger_audit に残る)。
-- ============================================================

create or replace function public._purchase_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rest_old jsonb;
  v_rest_new jsonb;
begin
  -- 明示的な解除は従来どおり通す(記録つき)
  if public._ledger_override_on() then
    perform public._ledger_record_bypass(
      TG_TABLE_NAME, TG_OP,
      to_jsonb(OLD),
      case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);
    if TG_OP = 'DELETE' then return OLD; end if;
    return NEW;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases の行は削除できません。訂正が必要な場合は打ち消しの行を追加してください。';
  end if;

  -- webhook が決済成立後に書く2列だけを、書き込み1回に限って通す。
  -- 「同値の再書き込み」を許すのは、Stripe が同じイベントを再送するため
  -- (冪等な再実行を例外にしない)。
  v_rest_old := to_jsonb(OLD) - 'safety_fee_yen' - 'payment_method';
  v_rest_new := to_jsonb(NEW) - 'safety_fee_yen' - 'payment_method';
  if v_rest_old <> v_rest_new then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases は追記専用です(変更できるのは safety_fee_yen と payment_method の初回書き込みだけ)。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。';
  end if;
  if NEW.safety_fee_yen is distinct from OLD.safety_fee_yen
     and OLD.safety_fee_yen <> 0 then
    raise exception 'LEDGER_IMMUTABLE: safety_fee_yen は一度しか書き込めません(現在値 %)', OLD.safety_fee_yen;
  end if;
  if NEW.payment_method is distinct from OLD.payment_method
     and OLD.payment_method is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_method は一度しか書き込めません(現在値 %)', OLD.payment_method;
  end if;

  return NEW;
end;
$$;

comment on function public._purchase_immutable() is
  'coin_purchases の不変トリガー。0044 の全面禁止から、webhook が決済成立後に書く safety_fee_yen / payment_method の初回書き込みだけを通す形に緩めた(0104)。金額・ユーザー・セッションIDは従来どおり変更できない。';

revoke all on function public._purchase_immutable() from public, anon, authenticated;

drop trigger if exists coin_purchases_immutable on public.coin_purchases;
create trigger coin_purchases_immutable
  before update or delete on public.coin_purchases
  for each row execute function public._purchase_immutable();
-- ============================================================
-- 0105: 収益構造を見張る3つの指標(運営コンソール「経営」タブ)
-- ------------------------------------------------------------
-- 事業計画書(docs/business-plan-2026-08.md)の収益構造は、平常時は堅い。
-- 崩れるとしたら**構造の欠陥ではなく、前提が実績とずれたとき**なので、
-- ずれを早く見つけるための数字だけをここに集める。
--
-- ■ ① 混合実効率 … 計画は「実効利用料率18%」を置いている
--   利用料は超過累進なので、**稼ぐピタメイトほど率が下がる。**
--   マーケットプレイスのGMVは上位に集中する(べき分布になる)のが通例なので、
--   全体をならした実効率は計画の18%より**下振れしうる**。
--   16%を切ったら段の見直しを検討する(変更の予約は0091で実装済み・30日前告知)。
--
-- ■ ② 上位集中 … 上位5人のGMVシェア
--   実効率が下がる原因であり、同時に**チャーンリスク**でもある。
--   1人が抜けると売上の何割が消えるのかを、数字で見えるようにしておく。
--
-- ■ ③ チャージバック … 件数・金額・GMV比
--   平常時の収支は堅いが、**一撃で月次を壊せる唯一の項目**。
--   税理士の第3回回答が「支払手数料(チャージバック)」を独立科目にして
--   早期警戒指標に使うよう設計した、その画面側。
--
-- ■ おまけ: 決済手段の内訳
--   PayPay はカードより手数料が低いので、比率が上がるほど貢献利益率
--   (計画では19.4%)が改善する。0096で payment_method を記録しているので
--   ここで一緒に出す。**0096より前の購入は null**(当時はカードのみ)。
--
-- ■ この関数は数えるだけで、何も書き換えない
--   運営が読む用。stable + 管理者チェックのみ。
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_gross bigint;
  v_fee bigint;
  v_booking_gross bigint;
  v_booking_fee bigint;
  v_gift_gross bigint;
  v_gift_fee bigint;
  v_hosts int;
  v_top5 bigint;
  v_top1 bigint;
  v_purchase_yen bigint;
  v_safety_yen bigint;
  v_cb_count int;
  v_cb_yen bigint;
  v_cb_open int;
  v_cb_lost int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;

  -- JSTの[p_from 00:00, p_to+1日 00:00)。会計タブ(0086)と同じ切り方にする
  v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
  v_to := ((p_to + 1)::timestamp at time zone 'Asia/Tokyo');

  -- ------------------------------------------------------------
  -- ① 混合実効率
  --
  -- **platform_fees が唯一の出典。** 予約とギフトで率がまったく違う
  -- (予約20〜12% / ギフト35%)ので、合算した「混合」と、内訳の両方を出す。
  -- 合算だけ見ていると、ギフトが増えただけで実効率が上がったように見える。
  -- ------------------------------------------------------------
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins)   filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins)   filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ------------------------------------------------------------
  -- ② 上位集中(予約のGMVで見る。ギフトは母数が別物なので混ぜない)
  -- ------------------------------------------------------------
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where created_at >= v_from and created_at < v_to and kind = 'booking'
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ------------------------------------------------------------
  -- ③ チャージバック
  --
  -- **GMVではなく購入額(円)に対する比で見る。** 申立ては購入に対して
  -- 起きるので、分母は売った額でなければ意味が合わない。
  -- ------------------------------------------------------------
  select
    coalesce(sum(price_yen), 0),
    coalesce(sum(safety_fee_yen), 0)
  into v_purchase_yen, v_safety_yen
  from public.coin_purchases
  where created_at >= v_from and created_at < v_to;

  select
    count(*),
    coalesce(sum(amount_yen), 0),
    count(*) filter (where resolved_at is null),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'fees', jsonb_build_object(
      'grossCoins', v_gross,
      'feeCoins', v_fee,
      -- 混合実効率(%)。母数0なら null を返す。**0%と区別する**
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end
    ),
    'concentration', jsonb_build_object(
      'activeHosts', v_hosts,
      'top5Coins', v_top5,
      'top5Percent', case when v_booking_gross > 0
        then round(v_top5::numeric * 100 / v_booking_gross, 1) else null end,
      'top1Percent', case when v_booking_gross > 0
        then round(v_top1::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'chargebacks', jsonb_build_object(
      'count', v_cb_count,
      'amountYen', v_cb_yen,
      'openCount', v_cb_open,
      'lostCount', v_cb_lost,
      'purchaseYen', v_purchase_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    ),
    'safetyFeeYen', v_safety_yen
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営指標(運営)。混合実効率・上位集中・チャージバック比率を返す。'
  '事業計画書の前提(実効18%・貢献利益率19.4%)が実績とずれていないかを見張るためのもの。0105。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;

-- ------------------------------------------------------------
-- 決済手段の内訳(0096)
--
-- **別の関数にしてある。** 上のKPIは「構造がずれていないか」で、
-- こちらは「原価が下がる余地があるか」。混ぜると読む目的がぼやける。
-- ------------------------------------------------------------
create or replace function public.admin_payment_method_mix(
  p_from date,
  p_to date
)
returns table (
  method text,
  purchases int,
  amount_yen bigint,
  share_percent numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;

  v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
  v_to := ((p_to + 1)::timestamp at time zone 'Asia/Tokyo');

  return query
  with p as (
    select
      -- 0096より前の購入は null。**'card' に丸めない。**
      -- 「カードだった」と「記録が無い」は別のことで、
      -- 丸めると 0104 で直した記録漏れが見えなくなる
      coalesce(cp.payment_method, '(記録なし)') as m,
      cp.price_yen + cp.safety_fee_yen as yen
    from public.coin_purchases cp
    where cp.created_at >= v_from and cp.created_at < v_to
  ),
  total as (select coalesce(sum(yen), 0) as t from p)
  select
    p.m,
    count(*)::int,
    coalesce(sum(p.yen), 0)::bigint,
    case when (select t from total) > 0
      then round(sum(p.yen)::numeric * 100 / (select t from total), 1)
      else null end
  from p
  group by p.m
  order by 3 desc;
end;
$$;

comment on function public.admin_payment_method_mix(date, date) is
  '決済手段の内訳(運営)。PayPayはカードより手数料が低いので、比率が上がるほど貢献利益率が改善する。0096で記録した payment_method を集計する。0105。';

revoke all on function public.admin_payment_method_mix(date, date) from public, anon;
grant execute on function public.admin_payment_method_mix(date, date) to authenticated;
-- ============================================================
-- 0106: 異議申立てに出す証跡を、集めて・束ねて・取り出せるようにする
-- ------------------------------------------------------------
-- ■ 何が足りなかったか
--   争うのに要る材料を1つずつ確認したところ、5つは既にあった。
--
--     購入時刻          coin_purchases.created_at            ✓
--     本人確認の結果    identity_verifications               ✓
--     チャット          messages                             ✓
--     予約・ギフト      bookings / gifts / coin_transactions ✓
--     提供完了の記録    guest/host_checked_in_at + completed ✓
--
--   足りないのは4つ。
--
--     ① **購入時点の**IP・端末      user_ips / user_devices は「最初と最後に
--                                    見た時刻」しか持たない。**どの購入のときに
--                                    どのIPだったか**が分からない。Stripe の
--                                    異議申立てフォームが最初に聞くのがこれ
--     ② User-Agent                   まったく記録していない
--     ③ **返金ポリシーへの同意**     弁護士が「①予約確定前の画面でキャンセル
--                                    ポリシーを明示し**同意の痕跡(ログ)を残す**」
--                                    と挙げていた項目。実装済み一覧でも⬜だった
--     ④ ログイン(アプリ起動)の記録   「本人が使っていた」ことの土台
--
--   そして**いちばん大きい穴は、束ねて取り出す口が無いこと。**
--   材料が全部あっても、Stripeの反論期限(7〜21日)の中で1枚にまとめられ
--   なければ使えない。SQL Editor で5テーブルを手で引くのは、期限のある
--   作業としては成立しない。
--
-- ■ 記録の範囲について
--   プライバシーポリシーは弁護士(Q26)の指摘で「**参照そのものの全件記録は
--   行っていません**」と狭めてある。ここで足すのは**購入・同意・ログインの
--   3つだけ**で、閲覧の記録ではない。同じ注記の「重要な操作の記録を保存する」
--   の範囲に収まる。
--
-- ■ メッセージの本文は束に入れない(意図的)
--   本文にはピタメイト(第三者)の発言が混ざる。カード会社へ渡すのは
--   第三者提供の判断が要るので、**束には「いつ・何通・どちらから」までを
--   入れ、本文は別の操作で出す。** みまもりを「原則は自動処理、担当者が
--   読むのは通報時だけ」としているのと同じ線。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 購入時点の環境(①②)
--
-- **決済ページを作った時点**で記録する。決済が完了しなくても残す
-- (「試したが完了していない」ことも、それはそれで証跡になる)。
-- 鍵は stripe_session_id。webhook が付与に使うのと同じ鍵なので、
-- 購入と1対1でつながる。
-- ------------------------------------------------------------
create table if not exists public.purchase_evidence (
  stripe_session_id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- Edge Function が X-Forwarded-For から読む実IP。クライアント申告は使わない
  ip text,
  -- localStorage の端末ID(0021と同じもの)
  device_id text,
  -- 生の User-Agent。長さだけ制限して中身は加工しない
  user_agent text check (user_agent is null or char_length(user_agent) <= 512),
  -- 請求額の内訳。**あとから coin_packs を変えても、当時の額が残る**
  price_yen int,
  safety_fee_yen int,
  created_at timestamptz not null default now()
);

comment on table public.purchase_evidence is
  '決済ページを作った時点の環境(IP・端末・UA)。異議申立てのときに「誰がどこから買ったか」を示す(0106)。決済が完了しなかったセッションの行も残す。';

create index if not exists purchase_evidence_user_idx
  on public.purchase_evidence (user_id, created_at desc);

alter table public.purchase_evidence enable row level security;
-- **本人にも見せない。** 調査のための記録で、本人が確認する用途が無い。
-- 運営は SECURITY DEFINER の関数経由でだけ読む
create policy "purchase_evidence_select_admin"
  on public.purchase_evidence for select
  to authenticated
  using (public._is_admin());

-- ------------------------------------------------------------
-- 2. ポリシーへの同意(③)
--
-- 弁護士の条件:
--   「①予約確定前の画面でキャンセルポリシーを明示し**同意の痕跡(ログ)を
--     残す**(特商法の表示義務の観点からも必要)」
--
-- **何に同意したかを、そのとき表示していた文面ごと残す。**
-- 版番号だけだと、後から文面を差し替えたときに何を見せたのか
-- 証明できない。文面を丸ごと持つのがいちばん強い。
-- ------------------------------------------------------------
create table if not exists public.policy_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 'cancellation' … 予約確定前のキャンセル・返金ポリシー
  -- 'purchase'     … 購入手続前の「返品不可」の確認
  -- 'terms'        … 利用規約(登録時)
  kind text not null check (kind in ('cancellation', 'purchase', 'terms')),
  -- 表示していた文面そのもの。**要約ではなく、画面に出したまま**
  shown_text text not null check (char_length(shown_text) between 1 and 4000),
  -- 紐づく対象(予約ID・Checkoutセッション等)。無い場合もある
  related_id text,
  ip text,
  device_id text,
  created_at timestamptz not null default now()
);

comment on table public.policy_consents is
  'キャンセル・返金ポリシー等への同意の記録。**そのとき表示していた文面ごと**残す(2026-07-30の弁護士回答Q14の条件①)。0106。';

create index if not exists policy_consents_user_idx
  on public.policy_consents (user_id, kind, created_at desc);
create index if not exists policy_consents_related_idx
  on public.policy_consents (related_id) where related_id is not null;

alter table public.policy_consents enable row level security;
-- **本人は自分の同意記録を見られる。** 「いつ何に同意したか」は
-- 本人に開示されて当然の情報で、隠す理由が無い
create policy "policy_consents_select_own"
  on public.policy_consents for select
  to authenticated
  using (user_id = auth.uid() or public._is_admin());

/**
 * 同意を記録する。**表示した文面を呼び出し側が渡す。**
 * サーバで文面を組み立てないのは、画面に実際に出たものと
 * records が食い違うのを避けるため(食い違えば証跡にならない)。
 */
create or replace function public.record_policy_consent(
  p_kind text,
  p_shown_text text,
  p_related_id text default null,
  p_device_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_kind not in ('cancellation', 'purchase', 'terms') then
    raise exception 'INVALID_KIND';
  end if;
  if coalesce(btrim(p_shown_text), '') = '' then
    raise exception 'TEXT_REQUIRED';
  end if;

  insert into public.policy_consents (user_id, kind, shown_text, related_id, device_id)
  values (v_uid, p_kind, left(p_shown_text, 4000), p_related_id,
          nullif(btrim(coalesce(p_device_id, '')), ''))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.record_policy_consent(text, text, text, text) is
  'ポリシーへの同意を、表示した文面ごと記録する。IPはEdge Function側でしか取れないのでここでは入れない(0106)。';

revoke all on function public.record_policy_consent(text, text, text, text) from public, anon;
grant execute on function public.record_policy_consent(text, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 3. ログイン(アプリ起動)の記録(④)
--
-- ⚠️ **閲覧の記録ではない。** プライバシーポリシーは
-- 「参照そのものの全件記録は行っていません」と書いてあり、これは守る。
-- ここで残すのは**セッションの開始**だけで、どの画面を見たかは残さない。
--
-- record-ip(アプリ起動時に1回呼ばれる)から書く。同じIP・端末の連続で
-- 行が増え続けないよう、**直近30分以内の同じ組み合わせはまとめる。**
-- ------------------------------------------------------------
create table if not exists public.access_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ip text,
  device_id text,
  user_agent text check (user_agent is null or char_length(user_agent) <= 512),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  hits int not null default 1
);

comment on table public.access_events is
  'ログイン(アプリ起動)の記録。**閲覧の記録ではない**(プライバシーポリシーの「参照そのものの全件記録は行っていません」を守る)。異議申立てで「本人が継続的に使っていた」ことを示すのに使う。0106。';

create index if not exists access_events_user_idx
  on public.access_events (user_id, last_at desc);

alter table public.access_events enable row level security;
create policy "access_events_select_own"
  on public.access_events for select
  to authenticated
  using (user_id = auth.uid() or public._is_admin());

/**
 * アプリ起動の記録。record-ip から service_role で呼ぶ。
 * **30分以内の同じ(IP, 端末)はまとめる。** 起動のたびに行を作ると、
 * 証跡としてはノイズが増えるだけで読めなくなる。
 */
create or replace function public.record_access_event(
  p_user_id uuid,
  p_ip text,
  p_device_id text default null,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_user_id is null then
    return;
  end if;

  select id into v_id from public.access_events
  where user_id = p_user_id
    and ip is not distinct from nullif(btrim(coalesce(p_ip, '')), '')
    and device_id is not distinct from nullif(btrim(coalesce(p_device_id, '')), '')
    and last_at > now() - interval '30 minutes'
  order by last_at desc limit 1;

  if v_id is not null then
    update public.access_events
      set last_at = now(), hits = hits + 1
      where id = v_id;
    return;
  end if;

  insert into public.access_events (user_id, ip, device_id, user_agent)
  values (p_user_id,
          nullif(btrim(coalesce(p_ip, '')), ''),
          nullif(btrim(coalesce(p_device_id, '')), ''),
          left(nullif(btrim(coalesce(p_user_agent, '')), ''), 512));
end;
$$;

comment on function public.record_access_event(uuid, text, text, text) is
  'アプリ起動の記録(service_role専用)。30分以内の同じIP・端末はまとめる。0106。';

revoke all on function public.record_access_event(uuid, text, text, text) from public, anon, authenticated;

/** 購入時点の環境を記録する。create-checkout-session から service_role で呼ぶ。 */
create or replace function public.record_purchase_evidence(
  p_session_id text,
  p_user_id uuid,
  p_ip text,
  p_device_id text,
  p_user_agent text,
  p_price_yen int,
  p_safety_fee_yen int
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.purchase_evidence
    (stripe_session_id, user_id, ip, device_id, user_agent, price_yen, safety_fee_yen)
  values (
    p_session_id, p_user_id,
    nullif(btrim(coalesce(p_ip, '')), ''),
    nullif(btrim(coalesce(p_device_id, '')), ''),
    left(nullif(btrim(coalesce(p_user_agent, '')), ''), 512),
    p_price_yen, p_safety_fee_yen)
  on conflict (stripe_session_id) do nothing;
$$;

comment on function public.record_purchase_evidence(text, uuid, text, text, text, int, int) is
  '決済ページ作成時の環境を記録する(service_role専用)。0106。';

revoke all on function public.record_purchase_evidence(text, uuid, text, text, text, int, int)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. ★ 証跡を1つに束ねる
--
-- **これがこの migration の本体。** 材料が全部あっても、期限の中で
-- 1枚にまとめられなければ争えない。
--
-- 出力は Stripe の異議申立てフォームの欄立てに合わせてある:
--   customer / purchase_ip / receipt / service_documentation /
--   service_date / activity / refund_policy
-- そのまま写せる形にしておかないと、結局その場で組み直すことになる。
-- ------------------------------------------------------------
create or replace function public.admin_purchase_evidence(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.coin_purchases;
  v_prof public.profiles;
  v_email text;
  v_ev public.purchase_evidence;
  v_verified boolean;
  v_verified_at timestamptz;
  v_access jsonb;
  v_consents jsonb;
  v_bookings jsonb;
  v_gifts jsonb;
  v_msgs jsonb;
  v_card jsonb;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.coin_purchases where id = p_purchase_id;
  if v_p.id is null then
    raise exception 'PURCHASE_NOT_FOUND';
  end if;

  select * into v_prof from public.profiles where id = v_p.user_id;
  select email into v_email from auth.users where id = v_p.user_id;
  select * into v_ev from public.purchase_evidence
    where stripe_session_id = v_p.stripe_session_id;

  select ts.is_verified, iv.verified_at into v_verified, v_verified_at
    from public.profile_trust_stats ts
    left join lateral (
      select verified_at from public.identity_verifications
      where user_id = v_p.user_id and status = 'verified'
      order by verified_at desc nulls last limit 1
    ) iv on true
    where ts.user_id = v_p.user_id;

  -- ログイン記録(購入の前後30日)。**購入の前にも後にも使っている**ことが、
  -- 「乗っ取られた」「身に覚えがない」への最も素直な反証になる
  select coalesce(jsonb_agg(jsonb_build_object(
           'firstAt', a.first_at, 'lastAt', a.last_at,
           'ip', a.ip, 'deviceId', a.device_id, 'hits', a.hits
         ) order by a.last_at desc), '[]'::jsonb)
    into v_access
    from (
      select * from public.access_events
      where user_id = v_p.user_id
        and last_at between v_p.created_at - interval '30 days'
                        and v_p.created_at + interval '30 days'
      order by last_at desc limit 50
    ) a;

  -- 同意の記録
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', c.kind, 'at', c.created_at,
           'relatedId', c.related_id, 'shownText', c.shown_text
         ) order by c.created_at), '[]'::jsonb)
    into v_consents
    from public.policy_consents c
    where c.user_id = v_p.user_id;

  -- **役務が提供されたことの中心的な証拠。**
  -- 購入の後に成立し完了した予約と、その双方のチェックイン時刻
  select coalesce(jsonb_agg(jsonb_build_object(
           'bookingId', b.id, 'hostNickname', hp.nickname,
           'scheduledAt', b.scheduled_at, 'durationMinutes', b.duration_minutes,
           'coins', b.coins, 'status', b.status,
           'guestCheckedInAt', b.guest_checked_in_at,
           'hostCheckedInAt', b.host_checked_in_at,
           'completedAt', (select max(t.created_at) from public.coin_transactions t
                           where t.related_booking_id = b.id and t.type = 'booking_earned')
         ) order by b.scheduled_at), '[]'::jsonb)
    into v_bookings
    from public.bookings b
    left join public.profiles hp on hp.id = b.host_id
    where b.guest_id = v_p.user_id and b.created_at >= v_p.created_at;

  select coalesce(jsonb_agg(jsonb_build_object(
           'giftId', g.id, 'to', rp.nickname, 'coins', g.coins, 'at', g.created_at
         ) order by g.created_at), '[]'::jsonb)
    into v_gifts
    from public.gifts g
    left join public.profiles rp on rp.id = g.receiver_id
    where g.sender_id = v_p.user_id and g.created_at >= v_p.created_at;

  -- **本文は入れない。** 第三者(ピタメイト)の発言が混ざるので、
  -- カード会社へ渡すかは別の判断。ここでは「やりとりがあった事実」まで
  select coalesce(jsonb_agg(jsonb_build_object(
           'promiseId', m.promise_id, 'messages', m.n,
           'firstAt', m.first_at, 'lastAt', m.last_at,
           'fromGuest', m.from_guest, 'fromOther', m.n - m.from_guest
         ) order by m.last_at desc), '[]'::jsonb)
    into v_msgs
    from (
      select msg.promise_id, count(*) as n,
             min(msg.created_at) as first_at, max(msg.created_at) as last_at,
             count(*) filter (where msg.sender_id = v_p.user_id) as from_guest
      from public.messages msg
      join public.promises pr on pr.id = msg.promise_id
      where (pr.user_a = v_p.user_id or pr.user_b = v_p.user_id)
        and msg.created_at >= v_p.created_at
      group by msg.promise_id
    ) m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'brand', pc.brand, 'last4', pc.last4, 'firstSeenAt', pc.first_seen_at
         )), '[]'::jsonb)
    into v_card
    from public.user_payment_cards pc
    where pc.user_id = v_p.user_id;

  return jsonb_build_object(
    -- Stripe「Customer details」欄
    'customer', jsonb_build_object(
      'userId', v_p.user_id,
      'nickname', v_prof.nickname,
      'email', v_email,
      'registeredAt', v_prof.created_at,
      'identityVerified', coalesce(v_verified, false),
      'identityVerifiedAt', v_verified_at,
      'paymentCards', v_card
    ),
    -- Stripe「Customer IP address」欄
    'purchaseEnvironment', jsonb_build_object(
      'ip', v_ev.ip,
      'deviceId', v_ev.device_id,
      'userAgent', v_ev.user_agent,
      'recordedAt', v_ev.created_at,
      -- **記録が無いことを黙って隠さない。** 0106より前の購入は環境が無い
      'available', v_ev.stripe_session_id is not null
    ),
    -- Stripe「Receipt」欄
    'purchase', jsonb_build_object(
      'purchaseId', v_p.id,
      'at', v_p.created_at,
      'packId', v_p.pack_id,
      'coinsCredited', v_p.coins_credited,
      'priceYen', v_p.price_yen,
      'safetyFeeYen', v_p.safety_fee_yen,
      'totalYen', v_p.price_yen + v_p.safety_fee_yen,
      'paymentMethod', v_p.payment_method,
      'stripeSessionId', v_p.stripe_session_id,
      'stripePaymentIntent', v_p.stripe_payment_intent
    ),
    -- Stripe「Refund policy」欄
    'consents', v_consents,
    -- Stripe「Service documentation / Service date」欄
    'service', jsonb_build_object(
      'bookings', v_bookings,
      'gifts', v_gifts,
      'messageThreads', v_msgs
    ),
    -- Stripe「Activity log」欄
    'accessLog', v_access,
    'generatedAt', now(),
    'note', 'メッセージの本文は含めていません（第三者の発言が混ざるため、'
         || '提出は個人情報の第三者提供として別に判断してください）。'
  );
end;
$$;

comment on function public.admin_purchase_evidence(uuid) is
  '異議申立てに出す証跡を1つに束ねる(運営)。Stripeの申立てフォームの欄立てに合わせてある。メッセージ本文は含めない(0106)。';

revoke all on function public.admin_purchase_evidence(uuid) from public, anon;
grant execute on function public.admin_purchase_evidence(uuid) to authenticated;

/**
 * 異議申立てのIDから証跡を出す。**運営が実際に使う入口はこちら。**
 * 申立てから購入をたどる手間を画面に持たせない。
 */
create or replace function public.admin_dispute_evidence(p_dispute_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_d public.payment_disputes;
  v_purchase_id uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_d from public.payment_disputes where id = p_dispute_id;
  if v_d.id is null then
    raise exception 'DISPUTE_NOT_FOUND';
  end if;

  -- payment_intent で購入を引く。0075のコメントどおり、購入と紐づかない
  -- 申立てもあり得るので**無いことを明示して返す**(例外にしない)
  select id into v_purchase_id from public.coin_purchases
    where stripe_payment_intent = v_d.stripe_payment_intent
    order by created_at limit 1;

  if v_purchase_id is null then
    return jsonb_build_object(
      'dispute', to_jsonb(v_d),
      'purchaseFound', false,
      'note', 'この申立てに対応する購入が見つかりません（当社の購入と紐づかない申立て）。'
    );
  end if;

  return jsonb_build_object(
    'dispute', jsonb_build_object(
      'id', v_d.id,
      'stripeDisputeId', v_d.stripe_dispute_id,
      'amountYen', v_d.amount_yen,
      'reason', v_d.reason,
      'status', v_d.status,
      'createdAt', v_d.created_at
    ),
    'purchaseFound', true,
    'evidence', public.admin_purchase_evidence(v_purchase_id)
  );
end;
$$;

comment on function public.admin_dispute_evidence(uuid) is
  '異議申立てから証跡一式を出す(運営)。購入と紐づかない申立ては purchaseFound=false で返す(0106)。';

revoke all on function public.admin_dispute_evidence(uuid) from public, anon;
grant execute on function public.admin_dispute_evidence(uuid) to authenticated;
-- ============================================================
-- 0107: 退会後90日で報酬コインを「消滅させる」のをやめる
--
-- 2026-08-05の弁護士回答（論点A-1）による。**今回の回答で最も重い指摘。**
--
--   「報酬コインは、購入コインと法的性質が根本的に異なります。これは役務提供の
--    対価としてユーザーが既に取得した金銭債権……の計数的表示です。90日の経過に
--    より債権そのものを消滅させる条項は、法定の消滅時効（民法166条1項・5年）を
--    約款で90日に短縮するに等しく、消費者契約法10条により無効と判断される
--    リスクが高い類型です。」
--
-- 直すのは条文だけではない。`expire_withdrawn_earned()` が cron で毎日走り、
-- **実際に earned_balance = 0 にしていた**（0086）。条文を直しても実装が
-- 消していれば、約束と動作が食い違う。
--
-- ■ 新しい建付け（弁護士が示した方向。論点F(b)と同じ整理に揃える）
--
--   債権は消滅しない。閉じるのは**セルフサービスの換金申請の窓口だけ**。
--   期間の経過後は、運営の窓口への個別の申出により換金する。
--
--   | | 従前 | 0107 |
--   |---|---|---|
--   | 90日経過時 | 残高を0にする | **窓口を閉じるだけ。残高は残る** |
--   | 経過後の換金 | 不可能（残高が無い） | 個別の申出 → 運営コンソールから起票 |
--   | 通知の文面 | 「消滅しました」 | 「受付を終了しました。**残高は残っています**」 |
--
-- ■ 期限の判定は増やさない
--   0086 が `payouts` の INSERT トリガー（`_payouts_check_withdrawal`）で
--   止めている。**「条件の置き場所が1か所で済む」というのが 0086 の設計判断**
--   なので、request_bank_payout 側に同じ判定を足さない。
--   運営の起票だけを通すために、0044 の ledger_override と同じ形の
--   セッション変数を1つ用意する。
--
-- ■ 会計への影響
--   J23（退会から90日経過した報酬コインの消滅）は note='withdraw_earned_expired'
--   を拾うが、**この note は今後発生しない**。購入コインの失効（退会時・0092）は
--   別の経路なので J22 はそのまま。預り金（ホスト報酬）が消えずに残るのが
--   正しい姿になる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 窓口を閉じた時刻を持つ
--
-- earned_expired_at（消滅した時刻）は**残すが、もう書かない**。
-- 0044 の追記専用台帳と同じ考え方で、過去の記録を壊さないため。
-- ------------------------------------------------------------
alter table public.account_withdrawals
  add column if not exists payout_window_closed_at timestamptz;

comment on column public.account_withdrawals.payout_window_closed_at is
  'セルフサービスの換金申請の受付を終了した時刻(0107)。**報酬コインは消えていない。**個別の申出があれば admin_payout_on_request() で換金する。';

comment on column public.account_withdrawals.earned_expired_at is
  '【廃止】退会後90日で報酬コインを消滅させていた時刻(0086)。0107で消滅をやめたため、今後は書き込まれない。過去の記録のために列は残す。';

-- ------------------------------------------------------------
-- 2. 消す処理を、窓口を閉じる処理に置き換える
-- ------------------------------------------------------------
create or replace function public.close_withdrawn_payout_window()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_count int := 0;
begin
  for v_rec in
    select aw.user_id, coalesce(w.earned_balance, 0) as earned
    from public.account_withdrawals aw
    join public.coin_wallets w on w.user_id = aw.user_id
    where aw.payout_window_closed_at is null
      and aw.payout_deadline < now()
      and coalesce(w.earned_balance, 0) > 0
      and not exists (
        select 1 from public.payouts p
        where p.user_id = aw.user_id and p.status = 'pending')
    for update of aw skip locked
  loop
    -- ⚠️ **残高には触れない。** ここで earned_balance を動かすと、
    -- 0107 が直そうとしたものをそのまま作り直すことになる。
    update public.account_withdrawals
      set payout_window_closed_at = now() where user_id = v_rec.user_id;

    insert into public.notifications (user_id, type, title, body)
    values (v_rec.user_id, 'system', '換金申請の受付期間が終了しました',
      '退会から90日が経過したため、アプリからの換金申請の受付を終了しました。'
      || 'なお報酬コイン' || v_rec.earned || '枚は消えていません。'
      || 'お問い合わせいただければ、個別に換金の手続を行います。');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.close_withdrawn_payout_window() is
  '退会から90日を過ぎたアカウントの、セルフサービスの換金申請の受付を終了する(規約 第6条の2第4項・0107)。**報酬コインは消さない。**個別の申出は admin_payout_on_request() で処理する。';

revoke all on function public.close_withdrawn_payout_window() from public, anon;

-- cron から外してから落とす。順序を逆にするとジョブが毎日失敗し続ける。
select cron.unschedule('expire-withdrawn-earned')
  where exists (select 1 from cron.job where jobname = 'expire-withdrawn-earned');

drop function if exists public.expire_withdrawn_earned();

select cron.schedule('close-withdrawn-payout-window', '31 3 * * *',
  $$select public.close_withdrawn_payout_window()$$);

-- ------------------------------------------------------------
-- 3. 期限のトリガーに、運営の起票だけを通す抜け道を作る
--
-- 0086 の `_payouts_check_withdrawal` は payouts への INSERT を
-- 一律に止める。**残高を残す以上、運営が個別の申出を処理する経路が要る。**
--
-- 0044 の ledger_override と同じ形にした:
--   ・セッション変数（set local）でのみ開く
--   ・開けられるのは SECURITY DEFINER の運営関数の中だけ
--   ・admin_actions に必ず記録が残る（呼び出し側で perform している）
-- ------------------------------------------------------------
create or replace function public._payouts_check_withdrawal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deadline timestamptz;
begin
  -- 0107: 運営が個別の申出を処理するときだけ通す。
  -- **利用者からは開けられない**（set local を挟めるのは運営関数の中だけ）。
  if coalesce(current_setting('app.payout_window_override', true), 'off') = 'on' then
    return new;
  end if;

  -- **期限は account_withdrawals.payout_deadline が唯一の権威。**
  select aw.payout_deadline into v_deadline
  from public.account_withdrawals aw where aw.user_id = new.user_id;

  if v_deadline is not null and now() > v_deadline then
    raise exception 'PAYOUT_WINDOW_CLOSED';
  end if;
  return new;
end;
$$;

comment on function public._payouts_check_withdrawal() is
  '退会後90日(payout_deadline)を過ぎた換金の起票を止める(規約 第6条の2第4項・0086)。0107で、運営の個別処理(app.payout_window_override)だけ通すようにした。';

revoke all on function public._payouts_check_withdrawal() from public, anon;

-- ------------------------------------------------------------
-- 4. 運営コンソール: 窓口が閉じた後の個別の申出を処理する
-- ------------------------------------------------------------
create or replace function public.admin_closed_window_balances(p_limit int default 200)
returns table (
  user_id uuid,
  nickname text,
  withdrawn_at timestamptz,
  payout_deadline timestamptz,
  window_closed_at timestamptz,
  earned_balance int,
  has_bank_account boolean,
  is_verified boolean
)
language sql
security definer
set search_path = public
as $$
  select aw.user_id,
         p.nickname,
         p.withdrawn_at,
         aw.payout_deadline,
         aw.payout_window_closed_at,
         coalesce(w.earned_balance, 0)::int,
         (b.user_id is not null),
         coalesce(t.is_verified, false)
  from public.account_withdrawals aw
  join public.coin_wallets w on w.user_id = aw.user_id
  left join public.profiles p on p.id = aw.user_id
  left join public.host_bank_accounts b on b.user_id = aw.user_id
  left join public.profile_trust_stats t on t.user_id = aw.user_id
  where public._is_admin()
    and aw.payout_deadline < now()
    and coalesce(w.earned_balance, 0) > 0
  order by coalesce(w.earned_balance, 0) desc
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$$;

comment on function public.admin_closed_window_balances(int) is
  '換金申請の受付が終了した後も残っている報酬コインの一覧(0107)。**残高は消していない**ので、個別の申出があればここから admin_payout_on_request() で起票する。';

revoke all on function public.admin_closed_window_balances(int) from public, anon;
grant execute on function public.admin_closed_window_balances(int) to authenticated;

create or replace function public.admin_payout_on_request(
  p_user_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c_fee constant int := 300;
  v_balance int;
  v_gift_hold int;
  v_dispute_hold int;
  v_available int;
  v_account public.host_bank_accounts;
  v_payout_id uuid;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_account from public.host_bank_accounts where user_id = p_user_id;
  if v_account.user_id is null then
    raise exception 'BANK_ACCOUNT_NOT_REGISTERED';
  end if;

  select earned_balance into v_balance from public.coin_wallets
    where user_id = p_user_id for update;

  -- 保留は運営の起票でも外さない。**保留の理由は窓口の開閉と無関係**で、
  -- ギフトの様子見(7日)も係争中の凍結も、そのまま効いている必要がある。
  select coalesce(sum(coins), 0) into v_gift_hold
    from public.gifts where receiver_id = p_user_id and created_at > now() - interval '7 days';
  v_dispute_hold := public._dispute_payout_hold(p_user_id);

  v_available := coalesce(v_balance, 0) - v_gift_hold - v_dispute_hold;

  if v_available <= c_fee then
    -- 手取りが0以下。**勝手に手数料を引いて振り込まない**
    -- (サービス終了の手順書と同じ考え方。本人に確認してから決める)。
    raise exception 'BELOW_PAYOUT_FEE';
  end if;

  update public.coin_wallets set earned_balance = earned_balance - v_available
    where user_id = p_user_id;

  -- 期限を過ぎているので、0086 のトリガーをここだけ開ける
  set local app.payout_window_override = 'on';

  insert into public.payouts (
    user_id, coins, amount_yen, fee_yen, status,
    bank_name, bank_code, branch_name, branch_code,
    account_type, account_number, account_holder_kana
  ) values (
    p_user_id, v_available, v_available - c_fee, c_fee, 'pending',
    v_account.bank_name, v_account.bank_code, v_account.branch_name, v_account.branch_code,
    v_account.account_type, v_account.account_number, v_account.account_holder_kana
  ) returning id into v_payout_id;

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, -v_available, 'payout', 'admin_payout_on_request:' || v_payout_id);

  perform public._log_admin_action('payout_on_request', v_payout_id,
    v_available || 'コイン / ' || p_reason);

  insert into public.notifications (user_id, type, title, body)
  values (p_user_id, 'system', '換金の手続を行いました',
    'お申し出により、報酬コイン' || v_available || '枚の換金を受け付けました。'
    || '振込手数料を含む事務手数料' || c_fee || '円を差し引いた'
    || (v_available - c_fee) || '円をお振込みします。');

  return v_payout_id;
end;
$$;

comment on function public.admin_payout_on_request(uuid, text) is
  '換金申請の受付が終了した後の個別の申出を、運営が起票する(規約 第6条の2第4項・0107)。**換金可能な全額**を1回で出す(最終換金と同じ扱い)。ギフト・係争の保留はそのまま効く。';

revoke all on function public.admin_payout_on_request(uuid, text) from public, anon;
grant execute on function public.admin_payout_on_request(uuid, text) to authenticated;
-- ============================================================
-- 0108: 利用停止のときに、購入コインを一律で消さないようにする
--
-- 2026-08-05の弁護士回答（論点A-2）による。
--
--   「利用停止等の**原因・程度を問わず**購入コインを一律に消滅させる定めは、
--    違約金・損害賠償額の予定の性質を帯び、消費者契約法9条1号（平均的な損害を
--    超える部分の無効）・10条の攻撃対象になります。軽微な違反（例: マナー違反の
--    累積）でも数万円分の残高が没収される帰結は、**平均的損害との均衡を欠く**と
--    評価されやすい。」
--
-- 報酬コインは 0098 の時点で既に「原則残す・没収は個別判断」になっていた
-- （p_forfeit_earned）。**購入コインだけが無条件に消えていた。**
--
-- ■ 新しい建付け（規約 第6条の3第5項）
--
--   不正な取得・利用が認められる場合に限り消滅させる。
--   それ以外は**消さない**。停止が解除されれば使えるし、解除されなければ
--   第7条5項の有効期限（6か月）で通常どおり失効する。
--
--   **有効期限に委ねるのが要点。** 失効の根拠が「制裁」ではなく
--   「もともとの期限」になるので、平均的損害の議論から外れる。
--
-- ■ 既定値を「消さない」にする
--   p_forfeit_paid の既定は false。**うっかり消えるより、うっかり残るほうが安全。**
--   消すときは運営が明示的に選ぶ（理由は admin_actions に残る）。
-- ============================================================

create or replace function public.admin_suspend_account(
  p_user_id uuid,
  p_reason text,
  p_forfeit_earned boolean default false,
  p_forfeit_paid boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;
  -- **理由は必須。** 第6条の3第6項の再審査に応じられない措置は取らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = p_user_id for update;

  -- 第6条の3第5項（0108で改訂）:
  -- **不正な取得・利用が認められる場合に限り**購入コインを消滅させる。
  -- それ以外は触らない。停止が解除されれば使えるし、解除されなければ
  -- 第7条5項の有効期限で通常どおり失効する。
  if p_forfeit_paid and (coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0) then
    update public.coin_lots set remaining = 0 where user_id = p_user_id and remaining > 0;
    update public.coin_wallets set balance = 0, bonus_balance = 0 where user_id = p_user_id;
    if v_paid > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_paid, 'expire', 'suspend_paid');
    end if;
    if v_bonus > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_bonus, 'expire', 'suspend_bonus');
    end if;
  end if;

  -- 第6条の3第2項/第3項: **報酬コインは原則として残す。**
  -- 没収するのは、違反行為により取得されたものに限る（運営が個別に判断）。
  if p_forfeit_earned and coalesce(v_earned, 0) > 0 then
    update public.coin_wallets set earned_balance = 0 where user_id = p_user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, -v_earned, 'expire', 'suspend_earned_forfeit');
    v_deadline := null;
  end if;

  update public.profiles
    set suspended_at = now(),
        payout_claim_deadline = v_deadline
    where id = p_user_id;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**
  update public.host_settings set is_host = false where user_id = p_user_id;

  perform public._log_admin_action(
    'suspend_account', p_user_id,
    case when p_forfeit_paid then '購入コイン没収 / ' else '購入コインは残す / ' end
    || case when p_forfeit_earned then '報酬コインも没収: ' else '報酬コインは残す: ' end
    || p_reason);

  return jsonb_build_object(
    'user_id', p_user_id,
    'paid_expired', case when p_forfeit_paid then v_paid else 0 end,
    'bonus_expired', case when p_forfeit_paid then v_bonus else 0 end,
    'paid_kept', case when p_forfeit_paid then 0 else v_paid end,
    'earned_forfeited', case when p_forfeit_earned then v_earned else 0 end,
    'payout_claim_deadline', v_deadline
  );
end;
$$;

comment on function public.admin_suspend_account(uuid, text, boolean, boolean) is
  '利用停止(規約 第6条の3)。**購入コインも報酬コインも、既定では消さない。**消すのは違反行為による不正な取得・利用が認められる場合だけで、運営が明示的に選ぶ(0108・2026-08-05の弁護士回答 論点A-2)。消さなかった購入コインは第7条5項の有効期限で通常どおり失効する。';

revoke all on function public.admin_suspend_account(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.admin_suspend_account(uuid, text, boolean, boolean) to authenticated;

-- 3引数の旧シグネチャは残さない。**既定値が変わったのに古い版が残っていると、
-- どちらが呼ばれたかで結果が変わる。**
drop function if exists public.admin_suspend_account(uuid, text, boolean);
-- ============================================================
-- 0109: キャンセルの前に、戻るコインの有効期限を知らせる
--
-- 規約 第9条5の2 後段（2026-07-31 新設）:
--
--   「当社は、キャンセルの手続を行う画面において、**返還されるコインの
--    有効期限が近い場合はその旨を事前に表示します。**」
--
-- **書いたが、実装していなかった。** 2026-08-05 の横断点検（G18）で判明。
-- `my_booking_refund_quote()` は枚数と率しか返しておらず、期限を返していない。
--
-- ■ なぜ「守れない約束」の中でも重いのか
--
--   コインの返還は、**消費したときの期限をそのまま引き継ぐ**（同項前段）。
--   したがって、
--     ・当初の期限を**既に過ぎている分は、戻らずに消える**
--     ・戻っても**残りわずかで、使い切れずに失効する**
--   という事態が現に起こる。
--
--   ゲスト都合のキャンセルでは、消えた分の金銭返金もない
--   （第9条5の3の対象は**ゲスト無帰責**の場合だけ）。
--   **押す前に知らせないと「知らされずに消えた」という話になる。**
--
-- ■ 何を返すか
--
--   `_refund_coin_lots_for_booking()` の割当てを**書き込まずに**なぞる。
--   実際に戻す処理と同じ順序（期限の早い順）・同じ有償/無償の配分で数え、
--     ・lapsed_coins … 既に期限切れで**戻らない**枚数（うち有償分も）
--     ・soon_coins   … 戻るが**期限が近い**枚数（既定14日以内）
--     ・soonest_expires_at … 戻る分のうち最も早い期限
--     ・cash_refund_coins  … 消えた分のうち**金銭で返す**枚数
--   を返す。
--
--   ⚠️ **画面で計算し直さないこと。** 割当ての規則が2か所になると、
--   表示と実際がずれる（0048 で率から実額が出せなくなったのと同じ轍）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 割当てのなぞり（書き込みなし）
--
-- _refund_coin_lots_for_booking と**同じループ**にしてある。
-- どちらかを直すときは、必ず両方を直すこと。
-- ------------------------------------------------------------
create or replace function public._refund_lot_forecast(
  p_booking_id uuid,
  p_paid int,
  p_bonus int,
  p_soon_days int default 14
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_booking public.bookings;
  v_rec record;
  v_found boolean := false;
  v_left_paid int;
  v_left_bonus int;
  v_take int;
  v_lapsed_paid int := 0;
  v_lapsed_bonus int := 0;
  v_soon int := 0;
  v_soonest timestamptz;
  v_expiry timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null then
    return jsonb_build_object('lapsed_coins', 0, 'lapsed_paid_coins', 0,
                              'soon_coins', 0, 'soonest_expires_at', null);
  end if;

  v_left_paid := coalesce(p_paid, v_booking.paid_coins);
  v_left_bonus := coalesce(p_bonus, v_booking.bonus_coins);

  for v_rec in
    select kind, expires_at, coins
    from public.coin_lot_consumptions
    where booking_id = p_booking_id and restored_at is null
    order by expires_at
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
        if v_soonest is null or v_rec.expires_at < v_soonest then
          v_soonest := v_rec.expires_at;
        end if;
        if v_rec.expires_at < now() + make_interval(days => p_soon_days) then
          v_soon := v_soon + v_take;
        end if;
      elsif v_rec.kind = 'paid' then
        v_lapsed_paid := v_lapsed_paid + v_take;
      else
        v_lapsed_bonus := v_lapsed_bonus + v_take;
      end if;
    end if;
  end loop;

  -- 0030 より前の予約(消費記録なし)。本体と同じく作成時刻から引き直す。
  if not v_found then
    v_expiry := public.coin_expiry_from(v_booking.created_at);
    if v_expiry > now() then
      v_soonest := v_expiry;
      if v_expiry < now() + make_interval(days => p_soon_days) then
        v_soon := v_left_paid + v_left_bonus;
      end if;
    else
      v_lapsed_paid := v_left_paid;
      v_lapsed_bonus := v_left_bonus;
    end if;
  end if;

  return jsonb_build_object(
    'lapsed_coins', v_lapsed_paid + v_lapsed_bonus,
    'lapsed_paid_coins', v_lapsed_paid,
    'soon_coins', v_soon,
    'soonest_expires_at', v_soonest
  );
end;
$$;

comment on function public._refund_lot_forecast(uuid, int, int, int) is
  'キャンセルで戻るコインの期限を、書き込まずに見積もる(規約 第9条5の2後段・0109)。_refund_coin_lots_for_booking と同じ順序・同じ配分でなぞる。**片方だけ直さないこと。**';

revoke all on function public._refund_lot_forecast(uuid, int, int, int) from public, anon;

-- ------------------------------------------------------------
-- 2. 見積りに期限を足す
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
  v_refund_paid int;
  v_refund_bonus int;
  v_fc jsonb;
  v_soon_days int;
  v_guest_fault boolean;
  v_cash int;
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

  -- cancel_booking と同じ配分(有償から先に戻す)
  v_refund_paid := least(v_b.paid_coins, v_refund);
  v_refund_bonus := v_refund - v_refund_paid;

  -- 「期限が近い」の目安は、失効の事前通知(0089)と同じ日数を使う。
  -- **2か所に別の数字があると、通知が来ない期間に警告だけ出る**ような
  -- ちぐはぐが起きる
  select coalesce(expiry_notice_days, 14) into v_soon_days
    from public.platform_pricing where id = 1;

  v_fc := public._refund_lot_forecast(
    p_booking_id, v_refund_paid, v_refund_bonus, coalesce(v_soon_days, 14));

  -- いま押そうとしているのがゲストなら guest_fault。
  -- **ゲスト都合だと、消えた分の金銭返金は無い**(第9条5の3はゲスト無帰責のみ)。
  -- ここを取り違えると、消える話を「返金されます」と伝えてしまう
  v_guest_fault := auth.uid() = v_b.guest_id;
  v_cash := case when v_guest_fault then 0
                 else (v_fc ->> 'lapsed_paid_coins')::int end;

  return jsonb_build_object(
    'coins', v_b.coins,
    'refund_coins', v_refund,
    'forfeit_coins', v_b.coins - v_refund,
    'base_percent', v_pct,
    'capped', v_refund > round(v_b.coins * v_pct / 100.0),
    'played', v_b.guest_checked_in_at is not null and v_b.host_checked_in_at is not null,
    -- 0109(規約 第9条5の2後段)
    'lapsed_coins', (v_fc ->> 'lapsed_coins')::int,
    'soon_coins', (v_fc ->> 'soon_coins')::int,
    'soonest_expires_at', v_fc ->> 'soonest_expires_at',
    'soon_days', coalesce(v_soon_days, 14),
    'cash_refund_coins', v_cash
  );
end;
$$;

comment on function public.my_booking_refund_quote(uuid) is
  'いまキャンセルしたら何コイン戻るか。0109で、戻るコインの有効期限(既に切れて戻らない分・期限が近い分・最も早い期限)と、消えた分の金銭返金の有無を足した(規約 第9条5の2後段・5の3)。';

revoke all on function public.my_booking_refund_quote(uuid) from public, anon;
grant execute on function public.my_booking_refund_quote(uuid) to authenticated;
-- ============================================================
-- 0110: ギフトが「従たる地位」に留まっていることを、月次で残す
--
-- 2026-08-05 の弁護士回答（論点B(b)2）:
--
--   「**月次モニタリング指標の設定** — ギフト流通総額／予約対価総額の比率を
--    継続的に記録し、**ギフトが従たる地位に留まることを事後的に立証できる**
--    ようにする（分析メモの実証パート）。」
--
-- ■ なぜ数字が要るのか
--
--   ギフトを「為替取引に当たらない」と整理する根拠のひとつは、
--   **ギフトが主たる収益源ではなく、役務提供に付随する任意の追加対価に
--   すぎない**ことにある。これは条文で宣言するだけでは足りず、
--   **実績で示せなければ、財務局への照会でも紛争でも通らない。**
--
--   逆に、この比率が上がり続けているのに放置していると、
--   「実態としては送金の仕組みだった」という評価を自ら裏づけることになる。
--
-- ■ どこに出すか
--   運営コンソールの「経営」タブ（`admin_business_kpis`）に1行足す。
--   混合実効率・上位集中・チャージバック率と同じ場所で毎月見る。
--   **別画面にすると見なくなる。**
--
-- ■ 母数が0のときは null
--   0105 と同じ扱い。**「0%」と「まだ取引が無い」を区別する。**
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_gross bigint := 0;
  v_fee bigint := 0;
  v_booking_gross bigint := 0;
  v_booking_fee bigint := 0;
  v_gift_gross bigint := 0;
  v_gift_fee bigint := 0;
  v_hosts int := 0;
  v_top5 bigint := 0;
  v_top1 bigint := 0;
  v_purchase_yen bigint := 0;
  v_safety_yen bigint := 0;
  v_cb_count int := 0;
  v_cb_yen bigint := 0;
  v_cb_open int := 0;
  v_cb_lost int := 0;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  v_from := coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - 30)::timestamptz;
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date) + 1)::timestamptz;

  -- ① 利用料の実効率
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ② 上位集中(予約の対価で見る)
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where kind = 'booking' and created_at >= v_from and created_at < v_to
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ③ チャージバック
  select
    coalesce(sum(price_yen), 0),
    coalesce(sum(safety_fee_yen), 0)
  into v_purchase_yen, v_safety_yen
  from public.coin_purchases
  where created_at >= v_from and created_at < v_to;

  select
    count(*),
    coalesce(sum(amount_yen), 0),
    count(*) filter (where resolved_at is null),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'fees', jsonb_build_object(
      'grossCoins', v_gross,
      'feeCoins', v_fee,
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end,
      -- 0110: **ギフトが従たる地位に留まっているか。**
      -- 為替取引に当たらないという整理の実証パート
      -- (2026-08-05の弁護士回答 論点B(b)2)。
      -- 分母は予約の対価。**上がり続けているのに放置しない。**
      'giftToBookingPercent', case when v_booking_gross > 0
        then round(v_gift_gross::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'concentration', jsonb_build_object(
      'activeHosts', v_hosts,
      'top5Coins', v_top5,
      'top5Percent', case when v_booking_gross > 0
        then round(v_top5::numeric * 100 / v_booking_gross, 1) else null end,
      'top1Percent', case when v_booking_gross > 0
        then round(v_top1::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'chargebacks', jsonb_build_object(
      'count', v_cb_count,
      'amountYen', v_cb_yen,
      'openCount', v_cb_open,
      'lostCount', v_cb_lost,
      'purchaseYen', v_purchase_yen,
      'safetyFeeYen', v_safety_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    )
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営の要点(運営)。利用料の混合実効率・上位集中・チャージバック率。0110で「ギフト流通総額／予約対価総額」を追加(ギフトが従たる地位に留まることを事後的に立証するため。2026-08-05の弁護士回答 論点B(b)2)。母数0は null で返し、0%と区別する。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;
-- ============================================================
-- 0111: 経営指標の集計期間が JST になっていなかったのを直す
--
-- ■ 何が起きていたか
--   `0110` が `admin_business_kpis` を書き直したとき（ギフト比率の追加）、
--   集計期間の作り方が `0105` から変わっていた。
--
--     0105（正）: v_from := (p_from::timestamp at time zone 'Asia/Tokyo');
--     0110（誤）: v_from := coalesce(p_from, ...)::timestamptz;
--
--   `date::timestamptz` は**セッションのタイムゾーン**で解釈される。
--   Supabase のセッションは UTC なので、日本時間の日付を渡しても
--   UTC の 00:00 として扱われ、**集計の窓が9時間ずれる**。
--
--   結果として、日本時間の 00:00〜09:00 に発生した手数料が、
--   その日の集計から落ちて前日に入る。日次で見れば毎日ずれ、
--   月次でも月初・月末の境界がずれる。
--
-- ■ なぜ気づきにくかったか
--   母数が0になると各指標は `null` を返す設計になっている。
--   `29_business_kpis.sql` の判定は `(... ->> 'blendedPercent')::numeric <> 17.73`
--   の形で、値が null だと比較結果も null になり、`if null then` は
--   発火しない。**窓がずれて空になっても、テストは黙って通っていた。**
--   落ちたのは activeHosts だけで、これは count(*) が 0 を返すため
--   null にならず、比較が成立したから。
--
--   → 検知できるように、テスト側も「値が入っていること」を先に確かめる形へ
--     直した（`supabase/tests/29_business_kpis.sql`）。
--
-- ■ なぜ直す価値があるか
--   この関数の `giftToBookingPercent` は、**ギフトが従たる地位に留まることを
--   事後的に示すために置いた指標**（`0110`／2026-08-05 の弁護士回答 論点B(b)2）。
--   財務局への説明に使う数字がずれたままなのは、いちばん困る。
--
-- ■ 引数の既定値（null）は 0110 のまま残す
--   運営コンソールが期間を指定せずに呼ぶ経路があるため。
--   ただし既定値の算出も JST の日付から作り、変換も JST で行う。
-- ============================================================

create or replace function public.admin_business_kpis(
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_from_d date;
  v_to_d date;
  v_gross bigint := 0;
  v_fee bigint := 0;
  v_booking_gross bigint := 0;
  v_booking_fee bigint := 0;
  v_gift_gross bigint := 0;
  v_gift_fee bigint := 0;
  v_hosts int := 0;
  v_top5 bigint := 0;
  v_top1 bigint := 0;
  v_purchase_yen bigint := 0;
  v_safety_yen bigint := 0;
  v_cb_count int := 0;
  v_cb_yen bigint := 0;
  v_cb_open int := 0;
  v_cb_lost int := 0;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  -- 既定は「JSTの今日から遡って30日」。
  -- **日付は JST で決め、timestamptz への変換も JST で行う。**
  -- `date::timestamptz` はセッションのタイムゾーン(UTC)で解釈されるため使わない。
  v_from_d := coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - 30);
  v_to_d := coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date);
  if v_to_d < v_from_d then
    raise exception 'INVALID_RANGE';
  end if;

  -- JSTの [v_from_d 00:00, v_to_d+1日 00:00)。会計タブ(0086)と同じ切り方
  v_from := (v_from_d::timestamp at time zone 'Asia/Tokyo');
  v_to := ((v_to_d + 1)::timestamp at time zone 'Asia/Tokyo');

  -- ① 利用料の実効率
  select
    coalesce(sum(gross_coins), 0),
    coalesce(sum(fee_coins), 0),
    coalesce(sum(gross_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'booking'), 0),
    coalesce(sum(gross_coins) filter (where kind = 'gift'), 0),
    coalesce(sum(fee_coins) filter (where kind = 'gift'), 0)
  into v_gross, v_fee, v_booking_gross, v_booking_fee, v_gift_gross, v_gift_fee
  from public.platform_fees
  where created_at >= v_from and created_at < v_to;

  -- ② 上位集中(予約の対価で見る)
  with per_host as (
    select host_id, sum(gross_coins) as g
    from public.platform_fees
    where kind = 'booking' and created_at >= v_from and created_at < v_to
    group by host_id
    order by 2 desc
  )
  select
    (select count(*) from per_host),
    (select coalesce(sum(g), 0) from (select g from per_host limit 5) t5),
    (select coalesce(max(g), 0) from per_host)
  into v_hosts, v_top5, v_top1;

  -- ③ チャージバック
  select
    coalesce(sum(price_yen), 0),
    coalesce(sum(safety_fee_yen), 0)
  into v_purchase_yen, v_safety_yen
  from public.coin_purchases
  where created_at >= v_from and created_at < v_to;

  select
    count(*),
    coalesce(sum(amount_yen), 0),
    count(*) filter (where status = 'open'),
    count(*) filter (where status = 'lost')
  into v_cb_count, v_cb_yen, v_cb_open, v_cb_lost
  from public.payment_disputes
  where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'from', v_from_d,
    'to', v_to_d,
    'fees', jsonb_build_object(
      'grossCoins', v_gross,
      'feeCoins', v_fee,
      'blendedPercent', case when v_gross > 0
        then round(v_fee::numeric * 100 / v_gross, 2) else null end,
      'bookingGrossCoins', v_booking_gross,
      'bookingPercent', case when v_booking_gross > 0
        then round(v_booking_fee::numeric * 100 / v_booking_gross, 2) else null end,
      'giftGrossCoins', v_gift_gross,
      'giftPercent', case when v_gift_gross > 0
        then round(v_gift_fee::numeric * 100 / v_gift_gross, 2) else null end,
      -- 0110: ギフトが従たる地位に留まることを事後的に示すための比率
      'giftToBookingPercent', case when v_booking_gross > 0
        then round(v_gift_gross::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'concentration', jsonb_build_object(
      'activeHosts', v_hosts,
      'top5Coins', v_top5,
      'top5Percent', case when v_booking_gross > 0
        then round(v_top5::numeric * 100 / v_booking_gross, 1) else null end,
      'top1Percent', case when v_booking_gross > 0
        then round(v_top1::numeric * 100 / v_booking_gross, 1) else null end
    ),
    'chargebacks', jsonb_build_object(
      'count', v_cb_count,
      'amountYen', v_cb_yen,
      'openCount', v_cb_open,
      'lostCount', v_cb_lost,
      'purchaseYen', v_purchase_yen,
      'safetyFeeYen', v_safety_yen,
      'ratePercent', case when v_purchase_yen > 0
        then round(v_cb_yen::numeric * 100 / v_purchase_yen, 2) else null end
    )
  );
end;
$$;

comment on function public.admin_business_kpis(date, date) is
  '経営の要点(運営)。利用料の混合実効率・上位集中・チャージバック率・ギフト比率。0111で集計期間をJSTに直した(0110がセッションのタイムゾーンで日付を変換しており、窓が9時間ずれていた)。母数0は null で返し、0%と区別する。';

revoke all on function public.admin_business_kpis(date, date) from public, anon;
grant execute on function public.admin_business_kpis(date, date) to authenticated;
-- ============================================================
-- 0112: 募集投稿を運営コンソールから取り下げられるようにする  ★突合表 G21
--
-- ■ 何が無かったか
--   募集掲示板（`board_posts`）に不適切な投稿が出たとき、
--   **運営に消す手段が無かった。**
--     ・`cancel_board_post` は `creator_id <> auth.uid()` で弾くので投稿者専用
--     ・通報（`reports`）は**人**に対するもので、投稿を指せない
--     ・運営コンソールに募集を見るタブが無い
--   つまり「見つけても消せない」状態だった。
--   規約 第13条は当社が投稿を削除できると定めているのに、実装が無い。
--
-- ■ なぜ運営の裁量に寄せるか
--   「今後は運営作業は運営コンソールから操作できるようにして下さい」という
--   方針に従う。SQL Editor で `update board_posts set status='cancelled'` を
--   打つ運用にすると、**誰がいつ何を消したかが残らない。**
--
-- ■ 消さずに取り下げる
--   行は削除せず `status = 'cancelled'` にする。投稿者専用の取り消しと
--   同じ状態にそろえる。**証跡を消さない**ためで、通報の裏取りにも要る。
--   区別は `cancel_reason` の頭に「運営による取り下げ：」を付けて残す。
--
-- ■ 投稿者にも必ず知らせる
--   投稿者専用の `cancel_board_post` は、参加表明した人にだけ通知する
--   （投稿者は自分で消しているので知らせる必要が無い）。
--   運営が取り下げる場合は逆で、**投稿者が知らないと何が起きたか分からない。**
--   両方に通知する。
-- ============================================================

-- ------------------------------------------------------------
-- 一覧（運営コンソールの「募集」タブ）
--
-- 掲示板の公開クエリと違い、**取り下げ済みも見える**ようにする。
-- 「消したはずのものが本当に消えているか」を確かめる場所でもあるため。
-- ------------------------------------------------------------
create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  capacity int,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  participants int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.capacity,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.board_participants bp where bp.post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0112。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;

-- ------------------------------------------------------------
-- 取り下げ
-- ------------------------------------------------------------
create or replace function public.admin_remove_board_post(
  p_post_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_reason text;
  v_participant record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須。** 記録の要らない削除は、あとから説明できない。
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_post_id;

  -- 投稿者に知らせる。**理由も渡す。**
  -- 何が引っかかったのか分からないと、同じ投稿をもう一度出してくる
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_cancelled',
    '募集を取り下げました',
    v_post.game || '・' || v_post.when_text || '（理由：' || v_reason || '）',
    p_post_id
  );

  -- 参加表明していた人にも知らせる。
  -- 待っている側からすると、理由より「無くなった」ことのほうが要る情報なので、
  -- 理由は載せない（運営の判断の内容を第三者に配らない）
  for v_participant in
    select user_id from public.board_participants where post_id = p_post_id
  loop
    if v_participant.user_id <> v_post.creator_id then
      insert into public.notifications (user_id, type, title, body, related_id)
      values (
        v_participant.user_id,
        'board_cancelled',
        '参加予定だった募集が取り下げられました',
        v_post.game || '・' || v_post.when_text,
        p_post_id
      );
    end if;
  end loop;

  perform public._log_admin_action('board_post_removed', p_post_id, v_reason);
end;
$$;

comment on function public.admin_remove_board_post(uuid, text) is
  '募集投稿を運営が取り下げる(0112・突合表G21)。行は消さず status=cancelled にし、cancel_reason に「運営による取り下げ：」を付けて残す。理由は必須。投稿者と参加者の双方に通知し、admin_actions に記録する。';

revoke all on function public.admin_remove_board_post(uuid, text) from public, anon;
grant execute on function public.admin_remove_board_post(uuid, text) to authenticated;
-- ============================================================
-- 0113: 募集板を「ピタメイトがゲストを呼ぶ場」に作り直す
--
-- ■ これまで
--   `0011` の募集板は**誰でも投稿でき、誰でも無料で参加表明できる**掲示板だった。
--   「今夜Apexを一緒に」を出して、定員まで人が集まったら締め切る、という形。
--   コインは一切動かない。
--
-- ■ これから
--   **掲載中のピタメイトだけが投稿でき、ゲストは予約の申込みに進む。**
--   募集は「この条件で空いています」という告知で、入口は予約に繋がる。
--
-- ■ ★なぜ「参加表明」を残さないか（ここがいちばん大事）
--   投稿をピタメイトに限ったうえで無料の参加表明を残すと、
--   **板の上に「ピタメイトと無料で遊べる経路」ができる。**
--   ピタフレの役務は予約＝有償で成り立っており、
--     ・税務（対価を得て提供する役務）
--     ・規約 第8条（役務提供契約はゲストとピタメイトの間に成立し、対価が発生する）
--     ・プラットフォーム利用料の徴収
--   のすべてがその前提に乗っている。無料の抜け道を board に作ると、
--   **いちばん使われる導線がその抜け道になる。**
--   なので `join_board_post` は廃止し、`board_participants` ごと落とす。
--
-- ■ capacity を落とす理由
--   予約は1対1（`create_booking(p_host_id, ...)`）。定員3の募集に3人来たら
--   「同時に3人と遊ぶ」のか「3人ぶんの別々の枠」なのか、誰にも分からない。
--   **1募集＝1つの空き枠**にそろえる。
--
-- ■ 料金を投稿に持たせない
--   `host_settings.hourly_rate` から出す。投稿に写すと、料金を変えたときに
--   板だけ古い額を出し続ける。申込前の価格表示なので、ずれると景表法の問題になる。
--
-- ■ 日時は自由記述のまま
--   `when_text`（「今夜 22:00〜」等）は目安として残す。実際の日時は
--   予約画面で選び、`create_booking` の側でリードタイム・枠・重複が検証される。
--   **検証の責任を1か所に集めておく**ため、板では持たない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 参加表明を落とす
-- ------------------------------------------------------------
drop function if exists public.join_board_post(uuid);
-- テーブルを落とせば、それに付いていたトリガーも一緒に落ちる
--   ・`0012` の board_participants_notify_joined（参加の通知）
--   ・`0074` の board_participants_require_consent（みまもり撤回で参加を止める）
drop table if exists public.board_participants;
-- トリガーが消えても関数は残るので、使われなくなったものを片付ける
drop function if exists public._board_participants_require_consent();
drop function if exists public.notify_board_joined();

-- ⚠️ **募集の投稿を止める側（`0074` の board_posts_require_consent）は残す。**
-- みまもりの同意を撤回した人が募集を出せてしまうと、撤回の意味が無くなる。

-- ------------------------------------------------------------
-- 2. 列の入れ替え
-- ------------------------------------------------------------
alter table public.board_posts drop column if exists capacity;

alter table public.board_posts
  add column if not exists duration_minutes int not null default 60;

-- 予約できる長さと同じ集合に縛る。板で選べる長さが予約で通らない、を防ぐ
alter table public.board_posts
  drop constraint if exists board_posts_duration_ok;
alter table public.board_posts
  add constraint board_posts_duration_ok
  check (public.is_valid_booking_duration(duration_minutes));

comment on column public.board_posts.duration_minutes is
  '募集している1枠の長さ(分)。予約画面の初期値になる。0113。';
comment on table public.board_posts is
  'ピタメイトが空き枠を告知する板(0113)。**投稿できるのは掲載中のピタメイトだけ。**ゲストは予約の申込みに進む。無料で参加する経路は持たない。';

-- ------------------------------------------------------------
-- 3. 投稿できるのは掲載中のピタメイトだけ
--
--    RLS の with check ではなくトリガーにする。理由は 0081（居住地）と同じで、
--    **条件を画面の実装に依存させない**ため。エラー名で理由も返せる。
-- ------------------------------------------------------------
create or replace function public._board_posts_require_host()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_host boolean;
  v_rate int;
begin
  select hs.is_host, hs.hourly_rate into v_is_host, v_rate
  from public.host_settings hs where hs.user_id = new.creator_id;

  if not coalesce(v_is_host, false) then
    raise exception 'HOST_ONLY';
  end if;
  -- 料金が無いと、見た人が予約に進んだ先で詰まる
  if coalesce(v_rate, 0) <= 0 then
    raise exception 'HOURLY_RATE_REQUIRED';
  end if;
  return new;
end;
$$;

revoke all on function public._board_posts_require_host() from public, anon;

drop trigger if exists board_posts_require_host on public.board_posts;
create trigger board_posts_require_host
  before insert on public.board_posts
  for each row execute function public._board_posts_require_host();

-- ------------------------------------------------------------
-- 4. 取り消しの通知先を変える
--
--    参加者がいなくなったので、代わりに**この募集から予約を申し込んだゲスト**へ知らせる。
--    予約は板を経由しなくても作れるので、板から来たものだけを結びつける列を持つ。
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_board_post_id uuid references public.board_posts (id) on delete set null;

comment on column public.bookings.from_board_post_id is
  '募集板から申し込まれた予約は、その募集を指す(0113)。募集が取り消されたときに、申込者へ知らせるために使う。';

create index if not exists bookings_from_board_post_idx
  on public.bookings (from_board_post_id) where from_board_post_id is not null;

create or replace function public.cancel_board_post(
  p_post_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_name text;
  v_reason text;
  v_guest record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.creator_id <> v_uid then
    raise exception 'ONLY_CREATOR_CAN_CANCEL';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り消しは何もしない(連打対策)
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left(v_reason, 200)
    where id = p_post_id;

  select nickname into v_name from public.profiles where id = v_uid;

  -- この募集から予約を申し込んでいて、まだ終わっていないゲストに知らせる。
  -- **予約そのものは取り消さない。** 予約のキャンセルは返金の規定
  -- （規約 第9条・`cancel_booking`）に乗るので、板の都合で勝手に消さない。
  for v_guest in
    select distinct b.guest_id
    from public.bookings b
    where b.from_board_post_id = p_post_id
      and b.status in ('requested', 'approved')
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_guest.guest_id,
      'board_cancelled',
      coalesce(nullif(v_name, ''), '相手') || 'さんが募集を取り下げました',
      v_post.game || '・' || v_post.when_text
        || case when v_reason is null then '' else '（' || v_reason || '）' end
        || ' ※お申し込み済みの予約はそのままです',
      p_post_id
    );
  end loop;
end;
$$;

comment on function public.cancel_board_post(uuid, text) is
  '自分の募集を取り下げる。0113で通知先を「参加表明した人」から「この募集から予約を申し込んだゲスト」に変えた。予約自体は取り消さない(キャンセルは第9条の規定に乗せる)。';

revoke all on function public.cancel_board_post(uuid, text) from public, anon;
grant execute on function public.cancel_board_post(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 5. 募集から予約する
--
--    `create_booking` をそのまま呼ぶ。**検証をここで作り直さない。**
--    リードタイム・枠・重複・残高・本人確認は、すべて向こうが見ている。
--    ここがやるのは「板の条件を満たしているか」と「紐づけ」だけ。
-- ------------------------------------------------------------
create or replace function public.create_booking_from_board(
  p_post_id uuid,
  p_policy_version text,
  p_scheduled_at timestamptz default null,
  p_duration_minutes int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_verified boolean;
  v_my_gender text;
  v_creator_gender text;
  v_booking_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_uid then
    raise exception 'CANNOT_BOOK_OWN_POST';
  end if;

  -- 板の側の条件（0011 から引き継ぐ）
  if v_post.verified_only then
    select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
    if not coalesce(v_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_my_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  -- ブロック関係は create_booking 側でも見るが、
  -- ここで止めたほうが「なぜ押せないか」を板の文脈で返せる
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  v_booking_id := public.create_booking(
    v_post.creator_id,
    coalesce(p_duration_minutes, v_post.duration_minutes),
    p_policy_version,
    p_scheduled_at
  );

  update public.bookings set from_board_post_id = p_post_id where id = v_booking_id;

  -- **1募集＝1枠。** 申込みが入った時点で板から下ろす。
  -- 断られた場合に開き直さないのは、開け直しの判断を投稿者に委ねるため
  -- （辞退した相手の申込みで枠が消えたままになるより、自分で出し直せるほうが分かりやすい）
  update public.board_posts set status = 'closed' where id = p_post_id;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_board(uuid, text, timestamptz, int) is
  '募集板から予約を申し込む(0113)。板の条件(本人確認・対象・ブロック)を見たうえで create_booking をそのまま呼ぶ。検証は create_booking 側に集約する。申込みが入ったら募集は closed にする(1募集=1枠)。';

revoke all on function public.create_booking_from_board(uuid, text, timestamptz, int) from public, anon;
grant execute on function public.create_booking_from_board(uuid, text, timestamptz, int) to authenticated;

-- ------------------------------------------------------------
-- 5-2. 運営の取り下げも通知先を変える（0112 の作り直し）
--
--      0112 は参加表明した人に通知していた。参加表明が無くなったので、
--      **この募集から予約を申し込んだゲスト**に切り替える。
-- ------------------------------------------------------------
create or replace function public.admin_remove_board_post(
  p_post_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_reason text;
  v_guest record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須。** 記録の要らない削除は、あとから説明できない。
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id for update;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status = 'cancelled' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.board_posts
    set status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_post_id;

  -- 投稿者に知らせる。**理由も渡す。**
  -- 規約 第10条の2 6項が「削除の理由をユーザーに通知します」と定めている。
  -- 何が引っかかったのか分からないと、同じ投稿をもう一度出してくる
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_post.creator_id,
    'board_cancelled',
    '募集を取り下げました',
    v_post.game || '・' || v_post.when_text || '（理由：' || v_reason || '）',
    p_post_id
  );

  -- この募集から申し込んでいたゲストにも知らせる。
  -- **理由は載せない**（運営の判断の内容を第三者に配らない）。
  -- **予約は取り消さない**（キャンセルは規約 第9条の規定に乗せる）。
  for v_guest in
    select distinct b.guest_id
    from public.bookings b
    where b.from_board_post_id = p_post_id
      and b.status in ('requested', 'approved')
      and b.guest_id <> v_post.creator_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_guest.guest_id,
      'board_cancelled',
      '申し込んだ募集が取り下げられました',
      v_post.game || '・' || v_post.when_text || ' ※お申し込み済みの予約はそのままです',
      p_post_id
    );
  end loop;

  perform public._log_admin_action('board_post_removed', p_post_id, v_reason);
end;
$$;

comment on function public.admin_remove_board_post(uuid, text) is
  '募集投稿を運営が取り下げる(0112・突合表G21。0113で通知先を予約の申込者に変更)。行は消さず status=cancelled にし、cancel_reason に「運営による取り下げ：」を付けて残す。理由は必須。投稿者には理由つき、申込者には理由なしで通知し、admin_actions に記録する。予約は取り消さない。';

revoke all on function public.admin_remove_board_post(uuid, text) from public, anon;
grant execute on function public.admin_remove_board_post(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 6. 運営の一覧から capacity / participants を外す（0112 の作り直し）
-- ------------------------------------------------------------
drop function if exists public.admin_board_posts(text, int);

create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  duration_minutes int,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  bookings int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.duration_minutes,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.bookings bk where bk.from_board_post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0113で参加人数を「この募集から入った予約の件数」に置き換えた。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;
-- ============================================================
-- 0114: 募集に「受付の範囲」を持たせる
--
-- ■ 直前の状態
--   `0113` で募集板をピタメイト専用にしたが、日時は `when_text` の自由記述
--   （画面では3択 `WHENS = ['今夜 22:00〜', '明日 21:00〜', '日時を指定']`）
--   のままだった。
--
--   ここには2つ問題があった。
--     ① **「日時を指定」を選んでも、日時を入れる欄が無い。** 投稿にそのまま
--        「日時を指定」という文字列が入る
--     ② **書いた内容と予約画面が無関係。** 「今夜22時〜」と書いてあっても、
--        ゲストは翌日の昼を選べてしまう
--
-- ■ 1点の日時ではなく「範囲」にする理由
--   1点固定だと硬すぎる。22:00ちょうどしか取れないと、少しズレただけで
--   成立せず、1件の募集で1人しか拾えない。
--   範囲なら、**広く取れば「相談で」・狭く取れば「この時間だけ」**になり、
--   柔軟さの度合いをピタメイト自身が決められる。
--
--     window_start / window_end がどちらも null … 日時は相談で
--     8/12 20:00 〜 8/12 24:00               … その日の夜のあいだで
--     8/15 00:00 〜 8/17 24:00               … その週末のどこかで
--
-- ■ 遊べる時間帯の枠（`set_host_availability`）とは別物
--   枠は「毎週この曜日のこの時間」。募集の範囲は「今回この日程で募集します」。
--   **予約は両方を満たす必要がある**（枠は `create_booking` が見ている）。
--   枠の外に範囲を書くと予約画面で全部弾かれるので、画面側で警告を出す。
--   ただし**ここでは弾かない**——枠を後から足す運用があるため。
--
-- ■ 期限切れを自動で下ろす
--   いまは「今夜」と書いた募集が1週間残る。`window_end` があれば過ぎたものを
--   閉じられる。**板が死んだ投稿で埋まるのは、公開直後にいちばん効く問題。**
-- ============================================================

alter table public.board_posts
  add column if not exists window_start timestamptz,
  add column if not exists window_end timestamptz;

-- 片方だけ入っている状態を作らない。範囲として意味を成さない
alter table public.board_posts
  drop constraint if exists board_posts_window_pair;
alter table public.board_posts
  add constraint board_posts_window_pair
  check (
    (window_start is null and window_end is null)
    or (window_start is not null and window_end is not null and window_end > window_start)
  );

comment on column public.board_posts.window_start is
  '受付を開始する日時。null なら「相談で」(0114)。';
comment on column public.board_posts.window_end is
  '受付を締め切る日時。null なら「相談で」(0114)。過ぎた募集は close_expired_board_posts が閉じる。';

create index if not exists board_posts_window_end_idx
  on public.board_posts (window_end) where status = 'open' and window_end is not null;

-- ------------------------------------------------------------
-- 範囲の中でしか申し込めないようにする
-- ------------------------------------------------------------
create or replace function public.create_booking_from_board(
  p_post_id uuid,
  p_policy_version text,
  p_scheduled_at timestamptz default null,
  p_duration_minutes int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_post public.board_posts;
  v_verified boolean;
  v_my_gender text;
  v_creator_gender text;
  v_booking_id uuid;
  v_minutes int;
  v_end timestamptz;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_post from public.board_posts where id = p_post_id;
  if v_post.id is null then
    raise exception 'POST_NOT_FOUND';
  end if;
  if v_post.status <> 'open' then
    raise exception 'POST_NOT_OPEN';
  end if;
  if v_post.creator_id = v_uid then
    raise exception 'CANNOT_BOOK_OWN_POST';
  end if;

  -- 板の側の条件（0011 から引き継ぐ）
  if v_post.verified_only then
    select is_verified into v_verified from public.profile_trust_stats where user_id = v_uid;
    if not coalesce(v_verified, false) then
      raise exception 'VERIFICATION_REQUIRED';
    end if;
  end if;

  if v_post.audience = '同性のみ' then
    select gender into v_my_gender from public.profiles where id = v_uid;
    select gender into v_creator_gender from public.profiles where id = v_post.creator_id;
    if v_my_gender is distinct from v_creator_gender then
      raise exception 'AUDIENCE_RESTRICTED';
    end if;
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_post.creator_id)
       or (b.blocker_id = v_post.creator_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  v_minutes := coalesce(p_duration_minutes, v_post.duration_minutes);

  -- 0114: 範囲が指定されている募集は、その中に**収まる**こと。
  -- 開始だけ範囲内で終わりがはみ出す申込みは、告知した時間を超えるので通さない
  if v_post.window_start is not null then
    if p_scheduled_at is null then
      raise exception 'START_TIME_REQUIRED';
    end if;
    v_end := p_scheduled_at + make_interval(mins => v_minutes);
    if p_scheduled_at < v_post.window_start or v_end > v_post.window_end then
      raise exception 'OUTSIDE_BOARD_WINDOW';
    end if;
    -- 締め切りを過ぎた募集は、cron が閉じる前でも受け付けない
    if now() >= v_post.window_end then
      raise exception 'BOARD_WINDOW_PASSED';
    end if;
  end if;

  v_booking_id := public.create_booking(
    v_post.creator_id,
    v_minutes,
    p_policy_version,
    p_scheduled_at
  );

  update public.bookings set from_board_post_id = p_post_id where id = v_booking_id;
  update public.board_posts set status = 'closed' where id = p_post_id;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_board(uuid, text, timestamptz, int) is
  '募集板から予約を申し込む(0113、0114で受付の範囲を追加)。範囲が指定されている募集は、開始から終了まで範囲に収まる申込みだけを通す。板の条件を見たうえで create_booking をそのまま呼ぶ(リードタイム・枠・重複・残高の検証は向こうに集約)。申込みが入ったら募集は closed。';

revoke all on function public.create_booking_from_board(uuid, text, timestamptz, int) from public, anon;
grant execute on function public.create_booking_from_board(uuid, text, timestamptz, int) to authenticated;

-- ------------------------------------------------------------
-- 締め切りを過ぎた募集を閉じる
--
-- **取り消し(cancelled)ではなく closed。** 投稿者が下ろしたわけではないので、
-- 取り消しと同じ状態にすると、あとから「なぜ消えたか」が読めなくなる。
-- 申込みが入って締まったのと同じ扱いにする。
-- ------------------------------------------------------------
create or replace function public.close_expired_board_posts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update public.board_posts
    set status = 'closed'
    where status = 'open'
      and window_end is not null
      and window_end <= now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.close_expired_board_posts() is
  '受付の締め切りを過ぎた募集を閉じる(0114)。cancelled ではなく closed にする(投稿者が下ろしたわけではないため)。';

revoke all on function public.close_expired_board_posts() from public, anon, authenticated;

select cron.unschedule('close-expired-board-posts')
  where exists (select 1 from cron.job where jobname = 'close-expired-board-posts');

-- 15分おき。締め切りちょうどに消える必要は無いが、
-- 1時間も残ると「もう終わった募集」を押させてしまう
select cron.schedule('close-expired-board-posts', '*/15 * * * *',
  $cron$select public.close_expired_board_posts();$cron$);

-- ------------------------------------------------------------
-- 運営の一覧にも範囲を出す
-- ------------------------------------------------------------
drop function if exists public.admin_board_posts(text, int);

create or replace function public.admin_board_posts(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  creator_id uuid,
  creator_nickname text,
  game text,
  mood text,
  when_text text,
  duration_minutes int,
  window_start timestamptz,
  window_end timestamptz,
  vc text,
  audience text,
  verified_only boolean,
  note text,
  status text,
  bookings int,
  created_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.creator_id,
    p.nickname,
    b.game,
    b.mood,
    b.when_text,
    b.duration_minutes,
    b.window_start,
    b.window_end,
    b.vc,
    b.audience,
    b.verified_only,
    b.note,
    b.status,
    (select count(*)::int from public.bookings bk where bk.from_board_post_id = b.id),
    b.created_at,
    b.cancelled_at,
    b.cancel_reason
  from public.board_posts b
  left join public.profiles p on p.id = b.creator_id
  where public._is_admin()
    and (p_status = 'all' or b.status = p_status)
  order by b.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_board_posts(text, int) is
  '募集投稿の一覧(運営)。p_status に ''all'' を渡すと取り下げ済みも含む。0114で受付の範囲を追加。';

revoke all on function public.admin_board_posts(text, int) from public, anon;
grant execute on function public.admin_board_posts(text, int) to authenticated;
-- ============================================================
-- 0115: 「その時間に遊べるピタメイト」を一度に引く
--
-- ■ なぜ要るか
--   ゲストが金を払って買っているのは「今夜21時に、確実に、気楽に遊べる状態」
--   であって、人そのものではない。ところが探す画面は**時間を検索条件として
--   持っていなかった**。
--
--     ・`fetchDiscoverableHosts` は host_availability を見ていない
--     ・空き枠が見えるのはプロフィールを開いてから(0051 の host_schedule)
--     ・並びは「また呼ばれているか」順。今夜遊びたい人には無関係
--
--   結果、良さそうな人を一人ずつ開いて、空きを見て、閉じる、の繰り返しになる。
--   一番強い動機が、一番手間のかかる作業に変換されていた。
--
-- ■ 既存の host_schedule との違い
--   あちらは**1人ぶん**を1時間ごとに返す(プロフィールのタイル用)。
--   こちらは**範囲を渡して、その中で予約できる人を全員**返す。
--   人ごとに host_schedule を呼ぶと、一覧の人数だけ往復が増える。
--
-- ■ create_booking と判定を必ず揃えること
--   ここに出したのに申し込むと弾かれる、が最悪の体験になる。
--   `create_booking`(0082) が見ているものと同じものを、同じ順で見る:
--     ・is_host / hourly_rate があること・本人確認済みであること
--     ・min_lead_minutes / max_lead_days(platform_pricing)
--     ・booking_fits_availability 相当(プレイ時間の全体が枠に収まる)
--     ・slot_open_to(0057 の常連への先行予約)
--     ・ピタメイト側とゲスト側、どちらの予約とも重ならないこと
--   **判定を足したり緩めたりしない。** 片方だけ直すとズレる。
--
-- ■ 出さないもの
--   在席(オンライン)は返さない。ここは「予約できる時間」を返す関数で、
--   「いま誰が居るか」を配る関数ではない(0052 が未ログインに在席を出さない
--   と決めたのと同じ理由)。
--
-- ■ 走査量
--   ピタメイト数 × 時間数。範囲は 14 日で頭打ちにする。
--   1時間刻みで見るのは、探す画面の表示が「今夜 21:00〜空き」で足りるから。
--   30分刻みの選択は予約画面(startTimeOptionsInRange)の担当。
-- ============================================================

create or replace function public.hosts_open_at(
  p_from timestamptz,
  p_to timestamptz,
  p_minutes int default 60
)
returns table (host_id uuid, next_open_at timestamptz, open_starts int)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_minutes int;
  v_span int;
  v_from timestamptz;
  v_to timestamptz;
  v_min_lead int;
  v_max_lead int;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  v_minutes := greatest(30, least(coalesce(p_minutes, 60), 720));
  -- 1時間刻みの開始なので、必要な「開いている時間」の数は切り上げでよい
  -- (21:00 から90分なら 21時と22時の2つ)
  v_span := ceil(v_minutes / 60.0)::int;

  select p.min_lead_minutes, p.max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing p where p.id = 1;
  v_min_lead := coalesce(v_min_lead, 30);
  v_max_lead := coalesce(v_max_lead, 35);

  -- 受け付けられない時刻は最初から候補にしない。
  -- **切り上げる。** 切り下げると START_TOO_SOON で弾かれる枠を出してしまう
  v_from := greatest(
    date_trunc('hour', coalesce(p_from, now())),
    date_trunc('hour', now() + make_interval(mins => v_min_lead)) + interval '1 hour'
  );
  v_to := least(
    coalesce(p_to, v_from + interval '1 day'),
    now() + make_interval(days => v_max_lead),
    v_from + interval '14 days'
  );

  if v_to <= v_from then
    return;
  end if;

  return query
  with hosts as (
    select hs.user_id
    from public.host_settings hs
    join public.profile_trust_stats ts
      on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
    where hs.is_host
      and hs.hourly_rate is not null
      and hs.user_id <> v_uid
  ),
  slots as (
    select generate_series(v_from, v_to - make_interval(mins => v_minutes), interval '1 hour') as slot_at
  ),
  grid as (
    select
      h.user_id as gh_host_id,
      s.slot_at,
      case
        -- 予約が入っている時間(申請中も含む。booking_slots の定義どおり)
        when exists (
          select 1 from public.booking_slots b
          where (b.host_id = h.user_id or b.guest_id = h.user_id)
            and b.starts_at < s.slot_at + interval '1 hour'
            and s.slot_at < b.ends_at
        ) then 0
        -- 遊べる時間帯の外。枠を1つも設定していない人は常に開いている扱い(0051)
        when not public.host_is_open_at(h.user_id, s.slot_at) then 0
        else 1
      end as ok
    from hosts h cross join slots s
  ),
  runs as (
    select
      g.gh_host_id,
      g.slot_at,
      sum(g.ok) over w as span_ok,
      count(*) over w as span_rows
    from grid g
    window w as (
      partition by g.gh_host_id order by g.slot_at
      rows between current row and v_span - 1 following
    )
  ),
  bookable as (
    select r.gh_host_id, r.slot_at
    from runs r
    where r.span_rows = v_span      -- 範囲の末尾で足りなくなった分は候補にしない
      and r.span_ok = v_span        -- 触るすべての時間が開いていること
      -- 常連への先行予約(0057)。判定はあちらに任せる(写すとズレる)
      and public.slot_open_to(r.gh_host_id, v_uid, r.slot_at)
      -- ゲスト自身の予約と重ならないこと(_booking_slot_conflict と同じ範囲の見方)
      and not exists (
        select 1 from public.booking_slots b
        where (b.host_id = v_uid or b.guest_id = v_uid)
          and b.starts_at < r.slot_at + make_interval(mins => v_minutes)
          and r.slot_at < b.ends_at
      )
  )
  select b.gh_host_id, min(b.slot_at), count(*)::int
  from bookable b
  group by b.gh_host_id;
end;
$$;

comment on function public.hosts_open_at(timestamptz, timestamptz, int) is
  '指定した範囲で、その長さの予約を受けられるピタメイトと、その最初の開始時刻・候補数を返す(0115)。'
  '判定は create_booking(0082) と同じものを同じ順で見る——出したのに申し込めない、を作らないため。'
  '在席(オンライン)は返さない。1時間刻み(30分刻みの選択は予約画面の担当)。';

revoke all on function public.hosts_open_at(timestamptz, timestamptz, int) from public, anon;
grant execute on function public.hosts_open_at(timestamptz, timestamptz, int) to authenticated;
-- ============================================================
-- 0116: 「この人は検索に出さない」(ブロックより軽い出口)
--
-- ■ なぜ要るか
--   いまある出口は通報とブロックの2つで、どちらも**相手に非がある**ことを
--   前提にした重い操作。「悪くはないが、自分には合わない」に当たる出口が無い。
--
--   出口が重すぎると2つのことが起きる。
--     ① 使われない。合わない相手が一覧に出続け、探すのが面倒になって離れる
--     ② 誤用される。相性の問題を通報やブロックで処理する人が出て、
--        通報の中身が薄まり、本当に危ない通報が埋もれる
--
--   **通報の精度を保つためにも、軽い出口が要る。**
--
-- ■ ブロックとの違い(混ぜないこと)
--                     ブロック(0008)        非表示(ここ)
--     相手への影響     予約もトークも不可     何も変わらない
--     自分の見え方     相手が見えない         検索に出ないだけ
--     相手に伝わるか   実質伝わる             伝わらない
--     運営の扱い       トラブルの記録         **何もしない**
--
--   非表示は**運営の判断材料にしない。** 好みの問題を安全の指標に混ぜると、
--   「この人は非表示にされやすい」といった評価が生まれてしまう。
--   だから件数の集計も、運営コンソールへの表示も作らない。
--
-- ■ 相手からは見えない
--   誰に非表示にされているかが分かると、それ自体が攻撃の材料になる。
--   RLS は自分の行だけ。集計する関数も置かない。
-- ============================================================

create table if not exists public.hidden_hosts (
  user_id uuid not null references auth.users (id) on delete cascade,
  hidden_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, hidden_id),
  constraint hidden_hosts_not_self check (user_id <> hidden_id)
);

comment on table public.hidden_hosts is
  '自分の検索結果に出したくない相手(0116)。ブロックと違い相手には何の影響も無く、'
  '相手からも見えない。運営の判断材料にしない(好みの問題を安全の指標に混ぜないため)。';

alter table public.hidden_hosts enable row level security;

-- 自分の行だけ。**相手からは一切見えない**
create policy "hidden_hosts_own"
  on public.hidden_hosts for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists hidden_hosts_user_idx on public.hidden_hosts (user_id);

-- ------------------------------------------------------------
-- 付け外し
-- ------------------------------------------------------------
create or replace function public.set_host_hidden(p_host_id uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if v_uid = p_host_id then
    raise exception 'CANNOT_HIDE_SELF';
  end if;

  if p_on then
    insert into public.hidden_hosts (user_id, hidden_id)
    values (v_uid, p_host_id)
    on conflict do nothing;
  else
    delete from public.hidden_hosts
    where user_id = v_uid and hidden_id = p_host_id;
  end if;
end;
$$;

comment on function public.set_host_hidden(uuid, boolean) is
  '検索結果に出さない相手の付け外し(0116)。相手には何も起きず、通知も行かない。';

revoke all on function public.set_host_hidden(uuid, boolean) from public, anon;
grant execute on function public.set_host_hidden(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 自分が非表示にしている相手の一覧(解除できるように名前も返す)
--
-- 解除する画面が無いと「間違えて押した」を取り戻せない。
-- 軽い操作ほど誤タップされるので、取り消せることのほうが大事。
-- ------------------------------------------------------------
create or replace function public.my_hidden_hosts()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    h.hidden_id,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    p.avatar_path,
    h.created_at
  from public.hidden_hosts h
  left join public.profiles p on p.id = h.hidden_id
  where h.user_id = auth.uid()
  order by h.created_at desc;
$$;

comment on function public.my_hidden_hosts() is
  '自分が検索に出さないようにしている相手(0116)。解除の画面で使う。';

revoke all on function public.my_hidden_hosts() from public, anon;
grant execute on function public.my_hidden_hosts() to authenticated;
-- ============================================================
-- 0117: 未ログインの画面に「賑わい」を、個人を出さずに見せる
--
-- ■ なぜ
--   `public_host_cards`(0052)は在席・ボイス・空き枠を返さない。
--   **これは正しい設計**——未ログインの相手に「いま誰が居るか」を教えるのは
--   付きまといの材料になる。
--
--   ただし副作用として、初めて来た人には**誰も動いていないサイト**に見える。
--   ゲストが買いに来ているのは「確実性」なので、動いている形跡が
--   まったく見えないと、料金を見る前に引き返す。
--
-- ■ 出すもの / 出さないもの
--   出すのは**個人を特定できない集計だけ。**
--     ・対応タイトル数         … 掲載中のピタメイトが挙げているゲームの種類
--     ・掲載中のピタメイト数
--     ・今週成立した同行の件数
--     ・いま募集中の枠の数
--
--   出さないもの(0052 の判断をここで崩さない):
--     ・誰が居るか・誰が空いているか
--     ・特定の個人に紐づく数(この人は何件、など)
--     ・時間帯の分布(「深夜に何件」は在席の推定に使える)
--
-- ■ 数字が小さいうちは出さない
--   「今週2件」と出すのは、出さないより悪い。**信頼を作るつもりが
--   逆に働く。** そこで下限を置き、下回る項目は null を返す。
--   画面は null の項目を描かない。
--
--   下限は**運営コンソールから動かせる**(platform_pricing)。公開直後は
--   高めに置いて何も出さず、伸びてきたら下げる、という運用ができる。
--   ハードコードすると、その判断のたびに migration が要る。
--
-- ■ 対応タイトル数だけは下限をかけない
--   これは賑わいではなく**サービスの守備範囲**で、/about にも書いてある事実。
--   少なくても嘘にならない。
-- ============================================================

alter table public.platform_pricing
  add column if not exists activity_stats_min_plays int not null default 20,
  add column if not exists activity_stats_min_hosts int not null default 10;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'platform_pricing_activity_stats_check') then
    alter table public.platform_pricing
      add constraint platform_pricing_activity_stats_check check (
        activity_stats_min_plays between 0 and 1000
        and activity_stats_min_hosts between 0 and 1000
      );
  end if;
end $$;

comment on column public.platform_pricing.activity_stats_min_plays is
  '今週の同行件数を公開する下限(0117)。下回るあいだは出さない。0で常に出す。';
comment on column public.platform_pricing.activity_stats_min_hosts is
  'ピタメイト数・募集中の枠を公開する下限(0117)。下回るあいだは出さない。0で常に出す。';

-- ------------------------------------------------------------
-- 集計本体
--
-- **未ログインから呼べる。** 返すのは数だけで、行は一切返さない。
-- ------------------------------------------------------------
create or replace function public.public_activity_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_min_plays int;
  v_min_hosts int;
  v_games int;
  v_hosts int;
  v_plays int;
  v_slots int;
begin
  select coalesce(activity_stats_min_plays, 20), coalesce(activity_stats_min_hosts, 10)
    into v_min_plays, v_min_hosts
  from public.platform_pricing where id = 1;
  v_min_plays := coalesce(v_min_plays, 20);
  v_min_hosts := coalesce(v_min_hosts, 10);

  -- 掲載中で本人確認済みのピタメイトだけを母数にする。
  -- 掲載していない人を数に含めると、探しても出てこない人を数えることになる
  select count(*)::int into v_hosts
  from public.host_settings hs
  join public.profile_trust_stats ts
    on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
  where hs.is_host;

  select count(distinct g)::int into v_games
  from public.host_settings hs
  join public.profile_trust_stats ts
    on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
  cross join lateral unnest(hs.games) as g
  where hs.is_host;

  -- 「成立した同行」= 完了した予約。申請中・キャンセルは数えない
  -- (**申し込みの数を実績として出すと、実態より多く見える**)
  --
  -- 日付は `booking_slots`(0049)と同じ「実際に遊んだ時刻」で取る。
  -- ⚠️ `host_dashboard`(0034)は素の scheduled_at で期間を切っており、
  --    時間指定の予約を**申し込んだ日**で数えている。別物なので揃えていない
  --    (docs/open-issues.md に記録)。
  select count(*)::int into v_plays
  from public.bookings
  where status = 'completed'
    and coalesce(requested_start_at, scheduled_at) >= now() - interval '7 days'
    and coalesce(requested_start_at, scheduled_at) < now();

  select count(*)::int into v_slots
  from public.board_posts
  where status = 'open';

  return jsonb_build_object(
    'gameCount', v_games,
    'hostCount', case when v_hosts >= v_min_hosts then v_hosts end,
    'playsThisWeek', case when v_plays >= v_min_plays then v_plays end,
    'openSlots', case when v_hosts >= v_min_hosts then v_slots end
  );
end;
$$;

comment on function public.public_activity_stats() is
  '未ログインにも出せる集計(0117)。個人を特定できる情報は返さない(在席・空き枠は 0052 の判断どおり出さない)。'
  '下限を下回る項目は null。下限は platform_pricing で運営が動かす。';

revoke all on function public.public_activity_stats() from public;
grant execute on function public.public_activity_stats() to anon, authenticated;

-- ------------------------------------------------------------
-- 運営コンソールから下限を動かせるようにする
-- (0101 の「制限値」タブに2項目足すだけ)
-- ------------------------------------------------------------
create or replace function public.admin_platform_limits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.platform_pricing;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.platform_pricing where id = 1;

  return jsonb_build_object(
    'newUser', jsonb_build_object(
      'days', v_p.new_user_days,
      'purchaseMaxYen', v_p.new_user_purchase_max_yen,
      'periodPurchaseMaxYen', v_p.new_user_period_purchase_max_yen,
      'payoutHoldDays', v_p.new_user_payout_hold_days
    ),
    'gift', jsonb_build_object(
      'maxPerTx', v_p.gift_max_per_tx,
      'maxPerDay', v_p.gift_max_per_day,
      'maxPerMonth', v_p.gift_max_per_month,
      'maxRecvMonth', v_p.gift_max_recv_month,
      'maxPairMonth', v_p.gift_max_pair_month,
      'windowDays', v_p.gift_window_days
    ),
    -- 0117: 未ログインに出す集計の下限
    'activityStats', jsonb_build_object(
      'minPlays', v_p.activity_stats_min_plays,
      'minHosts', v_p.activity_stats_min_hosts
    ),
    -- 天井(CHECK 制約と同じ値。片方だけ直すと画面が嘘をつく)
    'caps', jsonb_build_object(
      'newUserPayoutHoldDays', 30,
      'giftMaxPerTx', 100000,
      'giftMaxPerDay', 100000,
      'giftMaxPerMonth', 500000,
      'giftMaxRecvMonth', 2000000,
      'giftMaxPairMonth', 200000,
      'giftWindowDays', 90,
      'activityStatsMinPlays', 1000,
      'activityStatsMinHosts', 1000
    ),
    'updatedAt', v_p.updated_at
  );
end;
$$;

comment on function public.admin_platform_limits() is
  '運営コンソールの「制限値」タブ。現在値と、CHECK 制約が定める天井を返す。0117で公開集計の下限を追加。';

revoke all on function public.admin_platform_limits() from public, anon;
grant execute on function public.admin_platform_limits() to authenticated;

create or replace function public.admin_update_platform_limits(
  p_reason text,
  p_values jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_diff text := '';
  v_key text;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object'
     or p_values = '{}'::jsonb then
    raise exception 'NO_CHANGES';
  end if;

  -- 知らないキーは黙って捨てない。**綴り間違いで「変えたつもり」に
  -- なるのが一番まずい**ので、その場で落とす
  for v_key in select jsonb_object_keys(p_values)
  loop
    if v_key not in (
      'newUserDays', 'newUserPurchaseMaxYen', 'newUserPeriodPurchaseMaxYen',
      'newUserPayoutHoldDays', 'giftMaxPerTx', 'giftMaxPerDay',
      'giftMaxPerMonth', 'giftMaxRecvMonth', 'giftMaxPairMonth',
      'giftWindowDays',
      'activityStatsMinPlays', 'activityStatsMinHosts'
    ) then
      raise exception 'UNKNOWN_KEY:%', v_key;
    end if;
  end loop;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days,
    'activityStatsMinPlays', activity_stats_min_plays,
    'activityStatsMinHosts', activity_stats_min_hosts
  ) into v_before
  from public.platform_pricing where id = 1;

  update public.platform_pricing set
    new_user_days = coalesce((p_values ->> 'newUserDays')::int, new_user_days),
    new_user_purchase_max_yen =
      coalesce((p_values ->> 'newUserPurchaseMaxYen')::int, new_user_purchase_max_yen),
    new_user_period_purchase_max_yen =
      coalesce((p_values ->> 'newUserPeriodPurchaseMaxYen')::int, new_user_period_purchase_max_yen),
    new_user_payout_hold_days =
      coalesce((p_values ->> 'newUserPayoutHoldDays')::int, new_user_payout_hold_days),
    gift_max_per_tx = coalesce((p_values ->> 'giftMaxPerTx')::int, gift_max_per_tx),
    gift_max_per_day = coalesce((p_values ->> 'giftMaxPerDay')::int, gift_max_per_day),
    gift_max_per_month = coalesce((p_values ->> 'giftMaxPerMonth')::int, gift_max_per_month),
    gift_max_recv_month = coalesce((p_values ->> 'giftMaxRecvMonth')::int, gift_max_recv_month),
    gift_max_pair_month = coalesce((p_values ->> 'giftMaxPairMonth')::int, gift_max_pair_month),
    gift_window_days = coalesce((p_values ->> 'giftWindowDays')::int, gift_window_days),
    activity_stats_min_plays =
      coalesce((p_values ->> 'activityStatsMinPlays')::int, activity_stats_min_plays),
    activity_stats_min_hosts =
      coalesce((p_values ->> 'activityStatsMinHosts')::int, activity_stats_min_hosts),
    updated_at = now()
  where id = 1;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days,
    'activityStatsMinPlays', activity_stats_min_plays,
    'activityStatsMinHosts', activity_stats_min_hosts
  ) into v_after
  from public.platform_pricing where id = 1;

  for v_key in select jsonb_object_keys(v_after)
  loop
    if (v_before ->> v_key) is distinct from (v_after ->> v_key) then
      v_diff := v_diff || case when v_diff = '' then '' else ' / ' end
        || v_key || ': ' || (v_before ->> v_key) || '→' || (v_after ->> v_key);
    end if;
  end loop;

  if v_diff = '' then
    raise exception 'NO_CHANGES';
  end if;

  perform public._log_admin_action('update_platform_limits', null,
    v_diff || ' 理由: ' || p_reason);

  return jsonb_build_object('changed', v_diff, 'values', v_after);
end;
$$;

comment on function public.admin_update_platform_limits(text, jsonb) is
  '制限値の変更。天井は platform_pricing の CHECK 制約が持つ。理由は必須で、前後の値とともに admin_actions に残る(0101、0117で公開集計の下限を追加)。';

revoke all on function public.admin_update_platform_limits(text, jsonb) from public, anon;
grant execute on function public.admin_update_platform_limits(text, jsonb) to authenticated;
-- ============================================================
-- 0118: トークのメッセージを運営が削除できるようにする
--
-- ■ なぜ
--   通報は受け取れる（`admin_reports` が `message_snapshot` を返す）のに、
--   **その中身を消す手段が無かった。** `docs/admin-console.md` の
--   「まだ画面が無いもの」に、唯一「手段がありません」と書いてある項目。
--
--   募集は 0112 で取り下げられるようになったが、トークは残っていた。
--   外部への誘導・金銭の要求・嫌がらせの文言が通報されても、運営にできるのは
--   利用停止だけで、**相手の画面に残った文言はそのまま**になる。
--
-- ■ 行は消さない（0112 と同じ）
--   通報の裏取り・異議申立て・チャージバックの立証に要る。
--   `deleted_at` を立てて「消えた事実」を残す。
--
-- ■ ★本文はDBから消し、証跡は運営しか読めない場所へ移す
--   `deleted_at` を立てるだけだと、**本文は messages に残ったまま**で、
--   相手のクライアントにも普通に届く（画面が読み込む select は
--   `body` をそのまま取っている）。画面側で隠す実装にすると、
--   「隠しているだけで送信はしている」状態になる。
--
--   そこで本文は `message_deletions`（運営のみ）へ移し、
--   `messages.body` は空にする。**CHECK 制約で、削除済みなら本文が
--   空であることを強制する**ので、実装の抜けで本文が残ることがない。
--
-- ■ 消えたことは相手にも見せる（黙って消さない）
--   黙って消すと、受け取った側は会話の流れが飛んで混乱し、
--   送った側は何が悪かったのか分からないまま同じことを繰り返す。
--   画面には「運営が削除しました」を出し、**送信者には理由つきで通知**する
--   （規約 第10条の2 6項。0112 の板の取り下げと同じ扱い）。
--
-- ■ 読むこと自体を記録する
--   スレッドを開く関数は、**中身を見た事実を admin_actions に残す**。
--   0068 が `admin_reports` に入れた仕組みと同じ。
--   運営がトークを自由に読める仕組みを作る以上、記録が無い状態にはしない。
-- ============================================================

alter table public.messages
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_reason text,
  add column if not exists deleted_by uuid references auth.users (id) on delete set null;

comment on column public.messages.deleted_at is
  '運営が削除した日時(0118)。入っていると本文は空で、原文は message_deletions にある。';

-- ★削除済みなら本文が残っていないことを、制約で保証する。
--   画面側の実装に依存させない
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages
  add constraint messages_body_check check (
    (deleted_at is null and char_length(body) between 1 and 2000)
    or (deleted_at is not null and char_length(body) = 0)
  );

create index if not exists messages_deleted_idx
  on public.messages (promise_id) where deleted_at is not null;

-- ------------------------------------------------------------
-- 原文の保管（運営のみ）
-- ------------------------------------------------------------
create table if not exists public.message_deletions (
  message_id uuid primary key references public.messages (id) on delete cascade,
  promise_id uuid not null,
  sender_id uuid,
  body text not null,
  reason text not null,
  deleted_by uuid references auth.users (id) on delete set null,
  deleted_at timestamptz not null default now()
);

comment on table public.message_deletions is
  '運営が削除したメッセージの原文(0118)。通報の裏取り・異議申立ての立証に使う。'
  '当事者には見せない(消したものを別の場所から読めては、消した意味が無い)。';

alter table public.message_deletions enable row level security;
-- ポリシーを1つも作らない = 運営の security definer 関数からしか読めない

-- ------------------------------------------------------------
-- 通報された相手のトークを探す
-- ------------------------------------------------------------
-- reports は promise_id を持たないので、通報から直接スレッドへ辿れない。
-- 相手のIDから、その人が参加しているスレッドを引けるようにする。
create or replace function public.admin_user_threads(
  p_user_id uuid,
  p_limit int default 30
)
returns table (
  promise_id uuid,
  other_id uuid,
  other_nickname text,
  message_count int,
  last_message_at timestamptz,
  status text
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
  select pr.id,
         case when pr.user_a = p_user_id then pr.user_b else pr.user_a end,
         coalesce(nullif(p.nickname, ''), '(不明)'),
         (select count(*)::int from public.messages m where m.promise_id = pr.id),
         (select max(m.created_at) from public.messages m where m.promise_id = pr.id),
         pr.status
  from public.promises pr
  left join public.profiles p
    on p.id = case when pr.user_a = p_user_id then pr.user_b else pr.user_a end
  where pr.user_a = p_user_id or pr.user_b = p_user_id
  order by (select max(m.created_at) from public.messages m where m.promise_id = pr.id) desc nulls last
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$$;

comment on function public.admin_user_threads(uuid, int) is
  'その人が参加しているトークの一覧(0118)。中身は返さない(件数と最終発言だけ)ので、ここでは閲覧記録を残さない。';

revoke all on function public.admin_user_threads(uuid, int) from public, anon;
grant execute on function public.admin_user_threads(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- スレッドの中身を読む ★閲覧を記録する
-- ------------------------------------------------------------
create or replace function public.admin_thread_messages(
  p_promise_id uuid,
  p_limit int default 200
)
returns table (
  id uuid,
  sender_id uuid,
  sender_nickname text,
  body text,
  created_at timestamptz,
  deleted_at timestamptz,
  deleted_reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select count(*)::int into v_n from public.messages m where m.promise_id = p_promise_id;

  -- 0068 と同じ。**中身を見た事実を残す。**
  perform public._log_admin_action(
    'view_thread', p_promise_id,
    '該当' || v_n || '件のメッセージを表示');

  return query
  select m.id,
         m.sender_id,
         coalesce(nullif(p.nickname, ''), '(不明)'),
         -- 削除済みは原文を返さない。運営でも、消したものは一覧では読まない
         -- (立証で要るときは message_deletions を直接見る)
         case when m.deleted_at is null then m.body else '' end,
         m.created_at,
         m.deleted_at,
         m.deleted_reason
  from public.messages m
  left join public.profiles p on p.id = m.sender_id
  where m.promise_id = p_promise_id
  order by m.created_at
  limit greatest(1, least(coalesce(p_limit, 200), 500));
end;
$$;

comment on function public.admin_thread_messages(uuid, int) is
  'トークの中身(運営)。**閲覧すると admin_actions に記録が残る**(0068と同じ)。削除済みの原文は返さない。';

revoke all on function public.admin_thread_messages(uuid, int) from public, anon;
grant execute on function public.admin_thread_messages(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 削除する
-- ------------------------------------------------------------
create or replace function public.admin_remove_message(
  p_message_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m public.messages;
begin
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;
  -- 理由は必須。あとから「なぜ消したか」を説明できない削除を作らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_m from public.messages where id = p_message_id for update;
  if v_m.id is null then
    raise exception 'MESSAGE_NOT_FOUND';
  end if;

  -- 連打しても2度目は何もしない(通知が増えない)
  if v_m.deleted_at is not null then
    return;
  end if;

  insert into public.message_deletions
    (message_id, promise_id, sender_id, body, reason, deleted_by)
  values
    (v_m.id, v_m.promise_id, v_m.sender_id, v_m.body, btrim(p_reason), auth.uid());

  update public.messages
    set body = '',
        deleted_at = now(),
        deleted_reason = btrim(p_reason),
        deleted_by = auth.uid()
    where id = p_message_id;

  -- ★送信者には理由を渡す。渡さないと同じことをもう一度書く
  insert into public.notifications (user_id, type, title, body)
  values (v_m.sender_id, 'system', 'メッセージを削除しました',
          '送信したメッセージを運営が削除しました。理由：' || btrim(p_reason)
          || E'\n利用規約に反する内容が続く場合、アカウントの利用を停止することがあります。');

  perform public._log_admin_action('message_removed', p_message_id,
    btrim(p_reason));
end;
$$;

comment on function public.admin_remove_message(uuid, text) is
  'トークのメッセージを運営が削除する(0118)。行は残し、本文は message_deletions へ移す。理由必須。送信者に理由つきで通知(規約 第10条の2 6項)。';

revoke all on function public.admin_remove_message(uuid, text) from public, anon;
grant execute on function public.admin_remove_message(uuid, text) to authenticated;
