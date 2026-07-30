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
