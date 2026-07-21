-- ピタフレ 全スキーマ結合版 (0001〜0015)
-- Supabase ダッシュボードの SQL Editor に、このファイルの中身をそのまま貼り付けて一括実行できます。
-- (個別ファイルは supabase/migrations/ にあります。CLIを使う場合は supabase db push でも可)
-- 既に0001〜0014を適用済みの場合は、追加分の 0015 だけを実行すればOKです。


-- ============================================================================
-- 0001_extensions.sql
-- ============================================================================
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

-- ============================================================================
-- 0002_profiles.sql
-- ============================================================================
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

-- ============================================================================
-- 0003_coins_and_hosting.sql
-- ============================================================================
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

-- ============================================================================
-- 0004_matching.sql
-- ============================================================================
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

-- ============================================================================
-- 0005_trust_safety.sql
-- ============================================================================
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

-- ============================================================================
-- 0006_manual_verification.sql
-- ============================================================================
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

-- ============================================================================
-- 0007_admin_verification_review.sql
-- ============================================================================
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

-- ============================================================================
-- 0008_fix_verification_review.sql
-- ============================================================================
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

-- ============================================================================
-- 0009_payments.sql
-- ============================================================================
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

-- ============================================================================
-- 0010_messaging.sql
-- ============================================================================
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

-- ============================================================================
-- 0011_board.sql
-- ============================================================================
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

-- ============================================================================
-- 0012_notifications.sql
-- ============================================================================
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

-- ============================================================================
-- 0013_escrow_payouts.sql
-- ============================================================================
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

-- ============================================================================
-- 0014_bank_payouts.sql
-- ============================================================================
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

-- ============================================================================
-- 0015_booking_lifecycle.sql
-- ============================================================================
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
