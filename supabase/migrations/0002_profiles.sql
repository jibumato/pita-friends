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
