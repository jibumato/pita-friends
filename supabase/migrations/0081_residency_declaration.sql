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
