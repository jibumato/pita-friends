-- ピタフレ 全スキーマ結合版 (0001〜0051)
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


-- ============================================================================
-- 0041_longer_bookings.sql
-- ============================================================================
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


-- ============================================================================
-- 0042_booking_hold.sql
-- ============================================================================
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


-- ============================================================================
-- 0043_integrity_checks.sql
-- ============================================================================
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


-- ============================================================================
-- 0044_ledger_immutable.sql
-- ============================================================================
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


-- ============================================================================
-- 0045_evidence_refund_percent.sql
-- ============================================================================
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


-- ============================================================================
-- 0046_account_anonymize.sql
-- ============================================================================
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


-- ============================================================================
-- 0047_ledger_export_heartbeat.sql
-- ============================================================================
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


-- ============================================================================
-- 0048_longer_play_12h.sql
-- ============================================================================
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


-- ============================================================================
-- 0049_booking_slot_conflict.sql
-- ============================================================================
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


-- ============================================================================
-- 0050_no_show_auto.sql
-- ============================================================================
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


-- ============================================================================
-- 0051_host_availability.sql
-- ============================================================================
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


-- ============================================================================
-- 0052_public_host_listing.sql
-- ============================================================================
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


-- ============================================================================
-- 0053_favorites.sql
-- ============================================================================
-- ============================================================
-- 0053_favorites.sql
-- お気に入り(推し登録)
-- ------------------------------------------------------------
-- これまで「気になるピタメイトを見つけた」あと、その人にたどり着く手段が
-- 予約するか名前を覚えて検索し直すかしかなかった。
-- 「見つける → 気に留める → 予約する」の真ん中が無い状態。
--
-- プライバシーの方針(ここが設計の中心):
--   ・**誰が誰を推しているかは、本人以外に見えない。** 推しの一覧が他人に
--     見えると、行動の追跡や付きまといの材料になる。
--   ・推された側には**人数だけ**返す。励みにはなるが、誰かは分からない。
--   ・ブロック関係があれば、どちら向きでも一覧から外す。
--
-- 相手が掲載をやめた場合は、一覧から黙って消さずに「いまは募集していない」
-- と分かる形で残す。黙って消えると、推していた人には理由が分からない。
-- ============================================================

create table if not exists public.favorites (
  -- 推している人(この行を作った本人)
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 推されているピタメイト
  host_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, host_id),
  constraint favorites_no_self check (user_id <> host_id)
);

comment on table public.favorites is
  'お気に入り(推し登録)。誰が誰を推しているかは本人以外に見えない。推された側には人数のみ返す。';

-- 「自分を推している人数」を数えるための索引
create index if not exists favorites_host_idx on public.favorites (host_id);

alter table public.favorites enable row level security;

-- 自分の推しだけを読み書きできる。他人の推しは一切見えない。
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
-- set_favorite(): 推し登録の追加・解除
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
  -- 「ブロックしたが推しには残っている」状態は作れない。
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
  '推し登録の追加(p_on=true)と解除(false)。ブロック関係があると登録できない。';

revoke all on function public.set_favorite(uuid, boolean) from public;
grant execute on function public.set_favorite(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- my_favorites(): 自分が推しているピタメイトの一覧
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
  '自分が推しているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からないため)。';

revoke all on function public.my_favorites() from public;
grant execute on function public.my_favorites() to authenticated;

-- ------------------------------------------------------------
-- my_favorite_count(): 自分を推している人数
-- ------------------------------------------------------------
-- **人数だけ**を返す。誰が推しているかは返さない。
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
  '自分を推している人数。誰かは返さない(推している側の行動を相手に知らせない)。';

revoke all on function public.my_favorite_count() from public;
grant execute on function public.my_favorite_count() to authenticated;


-- ============================================================================
-- 0054_favorite_slot_notify.sql
-- ============================================================================
-- ============================================================
-- 0054_favorite_slot_notify.sql
-- 推しているピタメイトが枠を開けたら知らせる
-- ------------------------------------------------------------
-- 0051で週間の募集枠を持てるようにしたが、**枠を開けても誰にも伝わらなかった**。
-- ファンが毎日スケジュールを見に来ることはないので、開けた枠が埋まらないまま
-- 終わる。0053の推し登録と繋いで、開けたときに知らせる。
--
-- 設計で気をつけたこと:
--   ・**増えた枠だけ**を対象にする。減らしただけで通知が飛ぶのはおかしい。
--   ・**24時間に1回まで**に絞る。編集は続けて何度も行われるので、
--     素直に流すと推し1人あたり1日に何通も届く。
--   ・**誰が推しているかはピタメイトに伝えない。** 通知は各ファンの行として
--     入るだけで、関数は件数も返さない(0053の方針をここでも守る)。
--   ・通知を止めたい人は推しを解除すればよい。細かい設定は今は持たない
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
  '推しへ「枠を開けました」を最後に送った時刻。24時間に1回までに絞るために使う。';

-- ------------------------------------------------------------
-- set_host_availability(): 枠の保存時に、増えた分があれば推しへ知らせる
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

  -- **件数は返さない。** 誰が推しているかに繋がる情報を渡さない(0053の方針)。
  return v_count;
end;
$$;

comment on function public.set_host_availability(jsonb) is
  '週間の募集枠を丸ごと入れ替える。0054で、枠が増えたときに推しているファンへ通知する(24時間に1回まで・増えた分のみ)。';

revoke all on function public.set_host_availability(jsonb) from public;
grant execute on function public.set_host_availability(jsonb) to authenticated;


-- ============================================================================
-- 0055_play_history_with.sql
-- ============================================================================
-- ============================================================
-- 0055_play_history_with.sql
-- 「この人とは何回遊んだか」を返す
-- ------------------------------------------------------------
-- プロフィールに出ている「一緒に遊んだ」はその人の**通算**の回数で、
-- 見ている自分との関係は何も表していない。3回一緒に遊んだ相手も、
-- 今日はじめて見た相手も、同じ画面に見える。
--
-- 推してもらうには、積み上がっているものが本人に見えている必要がある。
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


-- ============================================================================
-- 0056_host_status.sql
-- ============================================================================
-- ============================================================
-- 0056_host_status.sql
-- ピタメイトの「ひとこと」(近況)
-- ------------------------------------------------------------
-- 推しがいる人がホームに来る目的は「その人の様子を見ること」なのに、
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
-- 掲載カード・推し一覧にひとことを載せる
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
  '自分が推しているピタメイトの一覧。掲載を休んでいる相手も is_active=false で残す(黙って消えると理由が分からない)。0056でひとことを追加。';

revoke all on function public.my_favorites() from public;
grant execute on function public.my_favorites() to authenticated;


-- ============================================================================
-- 0057_regulars_first.sql
-- ============================================================================
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


-- ============================================================================
-- 0058_repeat_proof.sql
-- ============================================================================
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


-- ============================================================================
-- 0059_last_play_shape.sql
-- ============================================================================
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


-- ============================================================================
-- 0060_discovery_repeat_rank.sql
-- ============================================================================
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


-- ============================================================================
-- 0061_booking_series.sql
-- ============================================================================
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


-- ============================================================================
-- 0062_fast_release.sql
-- ============================================================================
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


-- ============================================================================
-- 0063_align_payout_terms.sql
-- ============================================================================
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
--       推しのサービスなのでギフトの比重は大きい。ここを5pt低く保つと
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


-- ============================================================================
-- 0064_web_push.sql
-- ============================================================================
-- ============================================================
-- 0064_web_push.sql
-- ブラウザへのプッシュ通知(Web Push)
-- ------------------------------------------------------------
-- これまで notifications は**アプリを開いたときにしか見えなかった**。
-- 0054の「推しが枠を開けました」も、開いてくれなければ意味がない。
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
