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
