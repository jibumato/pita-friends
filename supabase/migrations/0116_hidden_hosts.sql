-- ============================================================
-- 0116: 「この人は検索に出さない」(ブロックより軽い出口)
--
-- ■ なぜ要るか
--   いまある出口は通報とブロックの2つで、どちらも**相手に非がある**ことを
--   前提にした重い操作。「悪くはないが、自分には合わない」に当たる出口が無い。
--
--   出口が重すぎると2つのことが起きる。
--     ① 使われない。合わない相手が一覧に出続け、探すのが面倒になって離れる
--     ② 誤用される。相性の問題を通報やブロックで処理する人が出て、
--        通報の中身が薄まり、本当に危ない通報が埋もれる
--
--   **通報の精度を保つためにも、軽い出口が要る。**
--
-- ■ ブロックとの違い(混ぜないこと)
--                     ブロック(0008)        非表示(ここ)
--     相手への影響     予約もトークも不可     何も変わらない
--     自分の見え方     相手が見えない         検索に出ないだけ
--     相手に伝わるか   実質伝わる             伝わらない
--     運営の扱い       トラブルの記録         **何もしない**
--
--   非表示は**運営の判断材料にしない。** 好みの問題を安全の指標に混ぜると、
--   「この人は非表示にされやすい」といった評価が生まれてしまう。
--   だから件数の集計も、運営コンソールへの表示も作らない。
--
-- ■ 相手からは見えない
--   誰に非表示にされているかが分かると、それ自体が攻撃の材料になる。
--   RLS は自分の行だけ。集計する関数も置かない。
-- ============================================================

create table if not exists public.hidden_hosts (
  user_id uuid not null references auth.users (id) on delete cascade,
  hidden_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, hidden_id),
  constraint hidden_hosts_not_self check (user_id <> hidden_id)
);

comment on table public.hidden_hosts is
  '自分の検索結果に出したくない相手(0116)。ブロックと違い相手には何の影響も無く、'
  '相手からも見えない。運営の判断材料にしない(好みの問題を安全の指標に混ぜないため)。';

alter table public.hidden_hosts enable row level security;

-- 自分の行だけ。**相手からは一切見えない**
create policy "hidden_hosts_own"
  on public.hidden_hosts for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists hidden_hosts_user_idx on public.hidden_hosts (user_id);

-- ------------------------------------------------------------
-- 付け外し
-- ------------------------------------------------------------
create or replace function public.set_host_hidden(p_host_id uuid, p_on boolean)
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
  if v_uid = p_host_id then
    raise exception 'CANNOT_HIDE_SELF';
  end if;

  if p_on then
    insert into public.hidden_hosts (user_id, hidden_id)
    values (v_uid, p_host_id)
    on conflict do nothing;
  else
    delete from public.hidden_hosts
    where user_id = v_uid and hidden_id = p_host_id;
  end if;
end;
$$;

comment on function public.set_host_hidden(uuid, boolean) is
  '検索結果に出さない相手の付け外し(0116)。相手には何も起きず、通知も行かない。';

revoke all on function public.set_host_hidden(uuid, boolean) from public, anon;
grant execute on function public.set_host_hidden(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 自分が非表示にしている相手の一覧(解除できるように名前も返す)
--
-- 解除する画面が無いと「間違えて押した」を取り戻せない。
-- 軽い操作ほど誤タップされるので、取り消せることのほうが大事。
-- ------------------------------------------------------------
create or replace function public.my_hidden_hosts()
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    h.hidden_id,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    p.avatar_path,
    h.created_at
  from public.hidden_hosts h
  left join public.profiles p on p.id = h.hidden_id
  where h.user_id = auth.uid()
  order by h.created_at desc;
$$;

comment on function public.my_hidden_hosts() is
  '自分が検索に出さないようにしている相手(0116)。解除の画面で使う。';

revoke all on function public.my_hidden_hosts() from public, anon;
grant execute on function public.my_hidden_hosts() to authenticated;
