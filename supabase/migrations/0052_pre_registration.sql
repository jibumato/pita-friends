-- ============================================================
-- 0052_pre_registration.sql
-- 公開前の事前登録(メールアドレスの predeposit)
-- ------------------------------------------------------------
-- SNSでの事前告知から来た人に、公開時のお知らせを送るための名簿。
-- アカウント登録(auth.users)とは**別物**で、この時点では本人確認も
-- 規約同意も取っていない。ここに入っただけでは何の権利も発生しない。
--
-- 設計上のポイント:
--   ・テーブルには anon/authenticated 向けのポリシーを**一切作らない**。
--     読み出す手段が無い = メールアドレスの一覧を外から抜けない。
--   ・登録は SECURITY DEFINER の pre_register() 経由でのみ行う。
--     直接 insert させると、RLS を緩める必要が出て名簿の漏れ口になる。
--   ・すでに登録済みでも**成功として返す**。「このアドレスは登録済み」と
--     判る作りにすると、アドレスの存否を試せてしまう(列挙攻撃)。
--
-- 連投対策はここでは持たない。DBで捌くより Cloudflare 側(レート制限)の
-- 仕事なので、実際に荒らされたらそちらで絞る。
-- ============================================================

-- ------------------------------------------------------------
-- pre_registrations: 事前登録の名簿
-- ------------------------------------------------------------
create table if not exists public.pre_registrations (
  id uuid primary key default gen_random_uuid(),
  -- 小文字・前後空白を落とした形で入れる(pre_register()が正規化する)
  email text not null unique,
  -- どの導線から来たか。SNS別の効き目を見るのに使う(例: 'x', 'landing')
  source text,
  created_at timestamptz not null default now(),
  -- 公開のお知らせを送ったら埋める。二重送信を防ぐための印
  notified_at timestamptz
);

comment on table public.pre_registrations is
  '公開前の事前登録名簿。アカウント登録とは別。読み出しは管理者のみで、登録は pre_register() 経由。';
comment on column public.pre_registrations.source is
  '流入元の目印。SNSごとの効果を見るためのもので、無くても登録は成立する。';
comment on column public.pre_registrations.notified_at is
  '公開のお知らせを送った時刻。二重送信を防ぐ印。';

create index if not exists pre_registrations_pending_idx
  on public.pre_registrations (created_at) where notified_at is null;

alter table public.pre_registrations enable row level security;

-- 閲覧は管理者だけ。**書き込みポリシーは作らない**
-- (誰でも insert できるようにすると、名簿の中身を条件付きで探れる余地が出る)。
drop policy if exists "pre_registrations_select_admin" on public.pre_registrations;
create policy "pre_registrations_select_admin"
  on public.pre_registrations for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

-- 送信済みの印だけは管理者が付けられるようにする
drop policy if exists "pre_registrations_update_admin" on public.pre_registrations;
create policy "pre_registrations_update_admin"
  on public.pre_registrations for update
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()))
  with check (exists (select 1 from public.admins where user_id = auth.uid()));

-- ------------------------------------------------------------
-- pre_register(): 事前登録を受け付ける
-- ------------------------------------------------------------
-- 未ログインから呼ぶので anon にも実行権を渡す。
-- **戻り値は void**。登録済みかどうかを呼び出し側に伝えない。
drop function if exists public.pre_register(text, text);

create or replace function public.pre_register(p_email text, p_source text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  v_email := lower(btrim(coalesce(p_email, '')));

  -- 明らかな異常値だけ弾く。厳密な検証はしない
  -- (通らないアドレスは、公開時のお知らせが届かないだけで害が無い)。
  if v_email = '' or length(v_email) > 254 then
    raise exception 'INVALID_EMAIL' using errcode = '22023';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'INVALID_EMAIL' using errcode = '22023';
  end if;

  insert into public.pre_registrations (email, source)
  values (v_email, nullif(btrim(coalesce(p_source, '')), ''))
  on conflict (email) do nothing;
  -- 既に居ても何もしない。呼び出し側からは新規と区別が付かない。
end;
$$;

comment on function public.pre_register(text, text) is
  '公開前の事前登録を受け付ける。登録済みでも成功として返す(アドレスの存否を漏らさないため)。';

revoke all on function public.pre_register(text, text) from public;
grant execute on function public.pre_register(text, text) to anon, authenticated;
