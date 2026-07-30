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
