-- ピタフレ 全スキーマ結合版 (0001〜0040)
-- Supabase ダッシュボードの SQL Editor に、このファイルの中身をそのまま貼り付けて一括実行できます。
-- 既に途中まで適用済みの場合は、未適用の番号のファイルだけを番号順に実行してください。
-- 注意: 適用済みのDBにこのファイル全体を流すと "already exists" で途中中断します。
-- 追加分は supabase/migrations/ の該当ファイルだけを番号順に流してください。


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

-- ============================================================================
-- 0016_bonus_coin_separation.sql
-- ============================================================================
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

-- ============================================================================
-- 0017_booking_approval.sql
-- ============================================================================
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

-- ============================================================================
-- 0018_coin_expiry.sql
-- ============================================================================
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

-- ============================================================================
-- 0019_gifts.sql
-- ============================================================================
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

-- ============================================================================
-- 0020_gift_guardrails.sql
-- ============================================================================
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

-- ============================================================================
-- 0021_gift_device_monitoring.sql
-- ============================================================================
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

-- ============================================================================
-- 0022_gift_ip_monitoring.sql
-- ============================================================================
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

-- ============================================================================
-- 0023_host_rankings.sql
-- ============================================================================
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

-- ============================================================================
-- 0024_voice_greeting.sql
-- ============================================================================
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


-- ============================================================================
-- 0025_avatar_image.sql
-- ============================================================================
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


-- ============================================================================
-- 0026_presence_status.sql
-- ============================================================================
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


-- ============================================================================
-- 0027_avatar_policies_repair.sql
-- ============================================================================
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


-- ============================================================================
-- 0028_content_flags.sql
-- ============================================================================
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


-- ============================================================================
-- 0029_manner_score_v2.sql
-- ============================================================================
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


-- ============================================================================
-- 0030_refund_lot_expiry.sql
-- ============================================================================
-- ============================================================
-- 返金コインの有効期限を「当初の発行日」基準に改める
-- 論点: docs/legal/lawyer-review-round2-request.md Q18
-- 記録: docs/legal/lawyer-review-answers-round2-draft.md 「未対応の実装課題」
-- ------------------------------------------------------------
-- 【適用しないこと】このマイグレーションは弁護士Q18の回答を待って適用する。
--   回答前に適用してはいけない(修正方法の妥当性が未確認のため)。
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


-- ============================================================================
-- 0031_monitoring_consent.sql
-- ============================================================================
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


-- ============================================================================
-- 0032_cancellation_evidence.sql
-- ============================================================================
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


-- ============================================================================
-- 0033_host_fee_tiers.sql
-- ============================================================================
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


-- ============================================================================
-- 0034_host_dashboard.sql
-- ============================================================================
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


-- ============================================================================
-- 0035_safety_fee_and_extension.sql
-- ============================================================================
-- ============================================================
-- 収益施策: (1) あんしん保証料  (3) 延長課金
-- ------------------------------------------------------------
-- ■ あんしん保証料
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
  -- コイン購入時に上乗せする「あんしん保証料」の率
  safety_fee_rate numeric(4, 3) not null default 0.050
    check (safety_fee_rate >= 0 and safety_fee_rate <= 0.5),
  updated_at timestamptz not null default now()
);

comment on table public.platform_pricing is
  'プラットフォームの価格設定(1行のみ)。あんしん保証料の率など、改定しうる数値をここに集約する。';

insert into public.platform_pricing (id) values (1);

alter table public.platform_pricing enable row level security;

-- 料率は購入前に利用者へ示す情報なので誰でも読める
create policy "platform_pricing_select_all"
  on public.platform_pricing for select
  to authenticated
  using (true);

-- 購入履歴に、預かった保証料を残す
alter table public.coin_purchases
  add column safety_fee_yen int not null default 0 check (safety_fee_yen >= 0);

comment on column public.coin_purchases.safety_fee_yen is
  'コイン代金に上乗せして預かったあんしん保証料(円)。price_yen はコイン本体の価格で、請求総額は price_yen + safety_fee_yen。';

-- ------------------------------------------------------------
-- safety_fee_for: 指定価格に対する保証料(円)。Edge Function から使う
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
  'コイン価格に対するあんしん保証料(円)。料率は platform_pricing に持つ。';

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


-- ============================================================================
-- 0036_cancel_board_post.sql
-- ============================================================================
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


-- ============================================================================
-- 0037_ranking_avatar.sql
-- ============================================================================
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


-- ============================================================================
-- 0038_host_trial_discount.sql
-- ============================================================================
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


-- ============================================================================
-- 0039_extension_full_price.sql
-- ============================================================================
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


-- ============================================================================
-- 0040_scheduled_booking.sql
-- ============================================================================
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
drop function if exists public._refund_coin_lots_for_booking(uuid);

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
