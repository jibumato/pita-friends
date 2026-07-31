-- ============================================================
-- 0080: カード(決済手段)フィンガープリントの監視  ★E-9
--
-- 弁護士 Q11(c) の推奨「同一IP/端末/カードを監視」のうち、
-- **カードだけが未実装のまま残っていた**(0021が端末、0022がIP)。
-- 換金を解禁する前に埋めておく必要がある項目。
--
-- なぜカードが要るのか:
--   端末IDは localStorage を消せば変わる。IPは回線を変えれば変わる。
--   **カードのフィンガープリントは、同じ実カードである限り変わらない。**
--   Stripe が発行する値で、番号そのものではないので当社は番号を持たない。
--   自作自演(自分のカードで買ったコインを、別アカウントの自分に
--   ギフトで渡して換金する)を見つける手段としては、3つの中で最も強い。
--
-- 3つの信号の扱いを揃えていない理由:
--   ・端末が同じ  → **遮断**(0021)。ほぼ同一人物
--   ・IPが同じ    → **フラグ**(0022)。同居・同じWi-Fi・キャリアNATで正当に一致する
--   ・カードが同じ → **フラグ**(本migration)。家族カード・同一世帯で正当に一致しうる
--
--   カードを遮断にしないのは、**夫婦や親子が同じカードを使っている**という
--   ごく普通の状況を、送金の完全遮断で潰してしまうため。
--   代わりに**換金の直前に必ず目に入る**ようにする(下記 admin_pending_payouts)。
--   資金が外へ出る瞬間に判断できれば足りる。
-- ============================================================

-- ------------------------------------------------------------
-- user_payment_cards: 利用者が使った決済手段の記録
--
-- **カード番号は保存しない。** Stripe のフィンガープリント(同一カードなら
-- 同じ値になる不可逆な識別子)と、ブランド・下4桁だけを持つ。
-- 下4桁は運営が目視で照合するときの手がかりで、これ単体では特定できない。
-- ------------------------------------------------------------
create table if not exists public.user_payment_cards (
  user_id uuid not null references auth.users (id) on delete cascade,
  fingerprint text not null check (char_length(fingerprint) between 4 and 128),
  brand text,
  last4 text check (last4 is null or char_length(last4) <= 4),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  uses int not null default 1,
  primary key (user_id, fingerprint)
);

comment on table public.user_payment_cards is
  '利用者が使った決済カードの記録(Stripeのフィンガープリント。カード番号は保存しない)。自作自演の検知に用いる。家族カードで正当に一致しうるため遮断ではなくフラグに使う。';

alter table public.user_payment_cards enable row level security;

-- 本人は自分の分だけ見える。他人のカード共有は見せない
create policy "user_payment_cards_select_own"
  on public.user_payment_cards for select
  to authenticated
  using (user_id = auth.uid());

-- 書き込みは record_payment_card(service_role)経由のみ。ポリシーは作らない。

create index if not exists user_payment_cards_fp_idx
  on public.user_payment_cards (fingerprint);

-- ------------------------------------------------------------
-- record_payment_card: 購入が成立したカードを記録する
--
-- **stripe-webhook からのみ呼ぶ(service_role)。** クライアントに開けると、
-- 他人のフィンガープリントを詐称して共有関係を捏造できてしまう。
-- ------------------------------------------------------------
create or replace function public.record_payment_card(
  p_user_id uuid,
  p_fingerprint text,
  p_brand text default null,
  p_last4 text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fp text := btrim(coalesce(p_fingerprint, ''));
begin
  if p_user_id is null or char_length(v_fp) < 4 or char_length(v_fp) > 128 then
    return;
  end if;

  insert into public.user_payment_cards (user_id, fingerprint, brand, last4)
  values (p_user_id, v_fp, nullif(btrim(coalesce(p_brand, '')), ''),
          nullif(btrim(coalesce(p_last4, '')), ''))
  on conflict (user_id, fingerprint) do update
    set last_seen_at = now(),
        uses = public.user_payment_cards.uses + 1,
        -- 初回に取れなかった場合だけ埋める(上書きはしない)
        brand = coalesce(public.user_payment_cards.brand, excluded.brand),
        last4 = coalesce(public.user_payment_cards.last4, excluded.last4);
end;
$$;

comment on function public.record_payment_card(uuid, text, text, text) is
  '購入が成立した決済カードのフィンガープリントを記録する。stripe-webhook(service_role)専用。';

revoke all on function public.record_payment_card(uuid, text, text, text) from public;
-- authenticated には**あえて grant しない**(詐称を防ぐため)

-- ------------------------------------------------------------
-- _shares_payment_card: 2人が同じカードを使った履歴があるか
-- ------------------------------------------------------------
create or replace function public._shares_payment_card(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_a is not null and p_b is not null and p_a <> p_b
     and exists (
       select 1
       from public.user_payment_cards a
       join public.user_payment_cards b on b.fingerprint = a.fingerprint
       where a.user_id = p_a and b.user_id = p_b
     );
$$;

revoke all on function public._shares_payment_card(uuid, uuid) from public;

-- ------------------------------------------------------------
-- gifts.card_flagged: 送り主と受け手がカードを共有していた
--
-- **send_gift 本体は書き換えない。** 送金の本流を触らずにトリガで足す。
-- 0022 の ip_flagged と同じ扱い(遮断しない・換金前の目視対象)。
-- ------------------------------------------------------------
alter table public.gifts
  add column if not exists card_flagged boolean not null default false;

comment on column public.gifts.card_flagged is
  '送り主と受け手が同じ決済カードを使った履歴がある場合にtrue。遮断はしないが、換金前の目視確認対象。';

create or replace function public._flag_gift_shared_card()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.card_flagged := public._shares_payment_card(new.sender_id, new.receiver_id);
  return new;
end;
$$;

revoke all on function public._flag_gift_shared_card() from public;

drop trigger if exists gifts_flag_shared_card on public.gifts;
create trigger gifts_flag_shared_card
  before insert on public.gifts
  for each row execute function public._flag_gift_shared_card();

-- ------------------------------------------------------------
-- admin_shared_cards: カードを共有しているアカウントの組(調査の入口)
-- ------------------------------------------------------------
create or replace function public.admin_shared_cards()
returns table (
  fingerprint text,
  brand text,
  last4 text,
  user_a uuid,
  name_a text,
  user_b uuid,
  name_b text,
  last_seen_at timestamptz
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
  select a.fingerprint,
         coalesce(a.brand, b.brand),
         coalesce(a.last4, b.last4),
         a.user_id, coalesce(nullif(pa.nickname, ''), '(不明)'),
         b.user_id, coalesce(nullif(pb.nickname, ''), '(不明)'),
         greatest(a.last_seen_at, b.last_seen_at)
  from public.user_payment_cards a
  join public.user_payment_cards b
    on b.fingerprint = a.fingerprint and a.user_id < b.user_id
  left join public.profiles pa on pa.id = a.user_id
  left join public.profiles pb on pb.id = b.user_id
  order by greatest(a.last_seen_at, b.last_seen_at) desc;
end;
$$;

comment on function public.admin_shared_cards() is
  '同じ決済カードを使ったアカウントの組(運営のみ)。振込前の確認に使う。一致だけでは不正と断定しないこと(家族カード)。';

revoke all on function public.admin_shared_cards() from public;
grant execute on function public.admin_shared_cards() to authenticated;

-- ------------------------------------------------------------
-- admin_pending_payouts を作り直し、**共有の件数を並べて出す**
--
-- 別画面に置くと見に行かない。**資金が外へ出る瞬間に目に入る**ことが
-- この機能の値打ちなので、振込リストの各行に出す。
-- ------------------------------------------------------------
-- 返す列が増えるので、create or replace では差し替えられない
drop function if exists public.admin_pending_payouts(int);

create function public.admin_pending_payouts(p_limit int default 100)
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
  is_verified boolean,
  shared_card_count int,
  flagged_gift_count int
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
         coalesce(ts.is_verified, false),
         -- このピタメイトとカードを共有している**他の**アカウントの数
         (select count(distinct b.user_id)::int
            from public.user_payment_cards a
            join public.user_payment_cards b
              on b.fingerprint = a.fingerprint and b.user_id <> a.user_id
           where a.user_id = p.user_id),
         -- 受け取ったギフトのうち、IPまたはカードの共有で印が付いたもの
         (select count(*)::int from public.gifts g
           where g.receiver_id = p.user_id
             and (g.ip_flagged or g.card_flagged))
  from public.payouts p
  left join public.profiles pf on pf.id = p.user_id
  left join public.profile_trust_stats ts on ts.user_id = p.user_id
  where p.status = 'pending'
  order by p.created_at
  limit greatest(1, least(p_limit, 500));
end;
$$;

comment on function public.admin_pending_payouts(int) is
  '未振込の換金申請と振込先(運営のみ)。0080でカード共有件数と要確認ギフト件数を追加した(資金が出る瞬間に目に入るようにするため)。閲覧は操作記録に残る。';

revoke all on function public.admin_pending_payouts(int) from public;
grant execute on function public.admin_pending_payouts(int) to authenticated;
