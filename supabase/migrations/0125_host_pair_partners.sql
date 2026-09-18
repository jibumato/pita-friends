-- ============================================================
-- 0125: ペア相手（ピタメイト同士が「一緒に組める」関係を持つ）
--
-- ■ 背景
--   ゲームは人数単位（Apex 3人、Valorant 5人、マリカー4人）で、
--   ゲスト1人＋ピタメイト1人では卓が埋まらない。紹介キャンペーンの
--   検討から出てきた案で、**割引ではなく「予約が入りやすくなる」**方の
--   施策として位置づける。
--
--   紹介した側・された側の2人を、ゲストが**まとめて1回で予約できる**
--   ようにする。土台になるのが、この「ペア相手」関係——
--   ゲストが誰とでも組ませられるわけではなく、**両方のピタメイトが
--   合意した組**だけを対象にする。
--
-- ■ 決めたこと（ユーザーとの確認事項）
--   ・ゲスト1人 × ホスト2人（N対Mではない。まずは2人固定）
--   ・2人目（誘われた側）も承認が必要。片方の合意だけで自動成立させない
--   ・最初のリリースは新規予約のみ。既存の1対1予約(create_booking等)の
--     動作は変えない（このファイルはその土台だけ。実際の予約は0126）
--
-- ■ この関係が要ること
--   ・双方がピタメイトであること（掲載条件はここでは見ない。予約時に見る）
--   ・ブロック関係が無いこと
--   ・**同じ2人の組は1つだけ**。順序に依らず一意にするため、
--     host_lo < host_hi の正規順で持つ
-- ============================================================

create table if not exists public.host_pair_partners (
  id uuid primary key default gen_random_uuid(),
  -- 正規順（小さいUUIDをlo・大きいUUIDをhi）。順序を固定することで
  -- 「AがBを誘う」も「BがAを誘う」も同じ1行に収束させる
  host_lo uuid not null references auth.users (id) on delete cascade,
  host_hi uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'active')),
  requested_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint host_pair_partners_order check (host_lo < host_hi),
  constraint host_pair_partners_requester check (requested_by in (host_lo, host_hi)),
  unique (host_lo, host_hi)
);

comment on table public.host_pair_partners is
  '0125: ピタメイト同士の「一緒に組める」関係。両方の承認で active になる。'
  'ゲストが2人まとめて予約できるのは、ここが active の組だけ(0126)。';

create index if not exists host_pair_partners_hi_idx
  on public.host_pair_partners (host_hi) where status = 'active';

alter table public.host_pair_partners enable row level security;

-- 見えるのは当事者だけ。一覧は関数(my_pair_partners)で配る
create policy "host_pair_partners_select_own"
  on public.host_pair_partners for select
  to authenticated
  using (auth.uid() in (host_lo, host_hi));

-- insert / update のポリシーは置かない。**RPCが唯一の入口**
-- （掲載条件・ブロック・承認の検査を画面の実装に依存させない）

-- ------------------------------------------------------------
-- 1. 申請する
-- ------------------------------------------------------------
create or replace function public.propose_pair_partner(p_partner_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lo uuid;
  v_hi uuid;
  v_is_host boolean;
  v_partner_is_host boolean;
  v_existing public.host_pair_partners;
  v_id uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_partner_id is null or p_partner_id = v_uid then
    raise exception 'INVALID_PARTNER';
  end if;

  select coalesce(is_host, false) into v_is_host
  from public.host_settings where user_id = v_uid;
  if not v_is_host then
    raise exception 'HOST_ONLY';
  end if;
  select coalesce(is_host, false) into v_partner_is_host
  from public.host_settings where user_id = p_partner_id;
  if not v_partner_is_host then
    raise exception 'PARTNER_NOT_HOST';
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = p_partner_id)
       or (b.blocker_id = p_partner_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  if v_uid < p_partner_id then
    v_lo := v_uid; v_hi := p_partner_id;
  else
    v_lo := p_partner_id; v_hi := v_uid;
  end if;

  select * into v_existing from public.host_pair_partners
    where host_lo = v_lo and host_hi = v_hi for update;

  if v_existing.id is not null then
    if v_existing.status = 'active' then
      raise exception 'ALREADY_PARTNERS';
    end if;
    -- 既に相手からの申請が来ている場合は、新規に作らず**その場で成立させる**。
    -- 両方が「申請」を押した=両方の意思が揃っている
    if v_existing.requested_by <> v_uid then
      update public.host_pair_partners
        set status = 'active', responded_at = now()
        where id = v_existing.id;
      select nickname into v_name from public.profiles where id = v_uid;
      insert into public.notifications (user_id, type, title, body, related_id)
      values (v_existing.requested_by, 'system',
        coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんとペア相手になりました',
        '2人まとめて予約を受けられるようになりました', v_existing.id);
      return v_existing.id;
    end if;
    -- 自分がすでに出した申請の再送。**同じ行を返すだけ**(重複は作らない)
    return v_existing.id;
  end if;

  insert into public.host_pair_partners (host_lo, host_hi, requested_by)
  values (v_lo, v_hi, v_uid)
  returning id into v_id;

  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (p_partner_id, 'system',
    coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんからペア相手の申請が届きました',
    '承認すると、2人まとめての予約を受けられるようになります', v_id);

  return v_id;
end;
$$;

comment on function public.propose_pair_partner(uuid) is
  '0125: ペア相手を申請する。相手からの申請が既にあれば、その場で成立させる'
  '(両方が押した時点で両方の意思が揃っているため、二重に待たせない)。';

revoke all on function public.propose_pair_partner(uuid) from public, anon;
grant execute on function public.propose_pair_partner(uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. 応じる（申請された側だけ）
-- ------------------------------------------------------------
create or replace function public.respond_pair_partner(p_partner_row_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.host_pair_partners;
  v_other uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_row from public.host_pair_partners where id = p_partner_row_id for update;
  if v_row.id is null then
    raise exception 'PARTNER_REQUEST_NOT_FOUND';
  end if;
  if v_uid not in (v_row.host_lo, v_row.host_hi) then
    raise exception 'FORBIDDEN';
  end if;
  -- **申請した本人は応じられない。** 自分の申請を自分で承認する経路を作らない
  if v_row.requested_by = v_uid then
    raise exception 'CANNOT_RESPOND_OWN_REQUEST';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'PARTNER_REQUEST_NOT_PENDING';
  end if;

  v_other := case when v_row.host_lo = v_uid then v_row.host_hi else v_row.host_lo end;

  if not p_accept then
    delete from public.host_pair_partners where id = p_partner_row_id;
    return;
  end if;

  update public.host_pair_partners
    set status = 'active', responded_at = now()
    where id = p_partner_row_id;

  select nickname into v_name from public.profiles where id = v_uid;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_other, 'system',
    coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんがペア相手の申請を承認しました',
    '2人まとめて予約を受けられるようになりました', p_partner_row_id);
end;
$$;

comment on function public.respond_pair_partner(uuid, boolean) is
  '0125: ペア相手の申請に応じる。断ったときは行ごと消す(履歴を持つ理由が無い)。';

revoke all on function public.respond_pair_partner(uuid, boolean) from public, anon;
grant execute on function public.respond_pair_partner(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 3. 解消する（成立後に、どちらからでも）
-- ------------------------------------------------------------
create or replace function public.end_pair_partner(p_partner_row_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.host_pair_partners;
  v_other uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  select * into v_row from public.host_pair_partners where id = p_partner_row_id for update;
  if v_row.id is null then
    raise exception 'PARTNER_REQUEST_NOT_FOUND';
  end if;
  if v_uid not in (v_row.host_lo, v_row.host_hi) then
    raise exception 'FORBIDDEN';
  end if;

  v_other := case when v_row.host_lo = v_uid then v_row.host_hi else v_row.host_lo end;
  delete from public.host_pair_partners where id = p_partner_row_id;

  -- 成立済みを解消したときだけ知らせる。申請の取り下げは静かに消える
  if v_row.status = 'active' then
    select nickname into v_name from public.profiles where id = v_uid;
    insert into public.notifications (user_id, type, title, body, related_id)
    values (v_other, 'system',
      coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんとのペア相手を解消しました',
      '今後、2人まとめての予約は届きません', null);
  end if;
end;
$$;

comment on function public.end_pair_partner(uuid) is
  '0125: ペア相手を解消する(申請中の取り下げにも使う)。どちらからでもできる。';

revoke all on function public.end_pair_partner(uuid) from public, anon;
grant execute on function public.end_pair_partner(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4. 一覧（自分の分だけ）
-- ------------------------------------------------------------
create or replace function public.my_pair_partners()
returns table (
  id uuid,
  partner_id uuid,
  partner_nickname text,
  partner_avatar_initial text,
  partner_avatar_color text,
  status text,
  -- true なら自分が申請した側(取り下げはできるが承認はできない)
  requested_by_me boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.id,
    case when r.host_lo = auth.uid() then r.host_hi else r.host_lo end,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    r.status,
    (r.requested_by = auth.uid()),
    r.created_at
  from public.host_pair_partners r
  join public.profiles p
    on p.id = case when r.host_lo = auth.uid() then r.host_hi else r.host_lo end
  where auth.uid() in (r.host_lo, r.host_hi)
  order by r.status = 'pending' desc, r.created_at desc;
$$;

comment on function public.my_pair_partners() is
  '0125: 自分のペア相手(申請中・成立済み)の一覧。';

revoke all on function public.my_pair_partners() from public, anon;
grant execute on function public.my_pair_partners() to authenticated;

-- ------------------------------------------------------------
-- 5. その2人が active なペア相手か（0126がゲストの予約時に使う）
-- ------------------------------------------------------------
create or replace function public.are_pair_partners(p_host_a uuid, p_host_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.host_pair_partners
    where status = 'active'
      and host_lo = least(p_host_a, p_host_b)
      and host_hi = greatest(p_host_a, p_host_b)
  );
$$;

comment on function public.are_pair_partners(uuid, uuid) is
  '0126で使う。ゲストが2人まとめて予約できるのは、ここが true の組だけ。';

revoke all on function public.are_pair_partners(uuid, uuid) from public, anon;
grant execute on function public.are_pair_partners(uuid, uuid) to authenticated;
