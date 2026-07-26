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
