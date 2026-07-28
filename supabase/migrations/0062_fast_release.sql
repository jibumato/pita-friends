-- ============================================================
-- 0062_fast_release.sql
-- 常連との予約だけ、自動確定を早める(ゲストが選んだときだけ)
-- ------------------------------------------------------------
-- いまはプレイ終了から72時間で自動確定する。ゲストが毎回「完了」を押せば
-- すぐ確定するが、実際には押し忘れる。押し忘れた分、ピタメイトの入金は
-- 3日遅れる。手取りは1コインも変わらないのに、体感だけが悪い。
--
-- 何度も遊んでいる相手なら、ゲスト側も毎回確認する必要を感じていない。
-- そこで「この人との予約は24時間で確定してよい」を**一度選べば以降ずっと**
-- 効くようにする。押し忘れが構造的に消える。
--
-- ■ ここは慎重に設計する必要がある
--   72時間は、ゲストが申し出(0042の保留)を出すための窓でもある。
--   短くすることは消費者側の権利を削る方向で、運営が勝手に決めれば
--   消費者契約法10条(一方的に不利な条項)の問題になりうる。
--   だから:
--     ・**ゲストが自分で選んだときだけ**適用する。既定は72時間のまま
--     ・**いつでも外せる。** 外した瞬間から72時間に戻る(保存済みの
--       予約にも効く。判定は自動確定の実行時に読むため)
--     ・**下限24時間。** 0時間を許すと、前払いして即座に取り返せない
--       のと区別がつかなくなる
--     ・**3回以上遊んだ相手にだけ**選べる。初回から出すと、
--       仕組みを理解する前に押させることになる
--     ・保留(held_at)は従来どおり優先。通報・申し出があれば確定しない
--
-- ■ ピタメイト側からは設定できない
--   相手に「早く確定して」と言わせる余地を作らない。設定はゲストの側にしか
--   置かず、ピタメイトからは誰が設定しているかも見えない。
-- ============================================================

create table if not exists public.fast_release_prefs (
  guest_id uuid not null references auth.users (id) on delete cascade,
  host_id uuid not null references auth.users (id) on delete cascade,
  -- 終了から何時間で自動確定してよいか。24時間未満は認めない
  hours smallint not null check (hours between 24 and 72),
  created_at timestamptz not null default now(),
  primary key (guest_id, host_id),
  check (guest_id <> host_id)
);

comment on table public.fast_release_prefs is
  'ゲストが「この相手とは早く確定してよい」と選んだ設定。既定(72時間)より短くするのはゲスト本人だけで、いつでも外せる。ピタメイト側からは設定も参照もできない。';

alter table public.fast_release_prefs enable row level security;

-- 自分の行だけ。ピタメイト側に見せる口はどこにも作らない。
-- 当て直しても壊れないよう、いったん落としてから作る。
drop policy if exists "fast_release_select_own" on public.fast_release_prefs;
drop policy if exists "fast_release_insert_own" on public.fast_release_prefs;
drop policy if exists "fast_release_delete_own" on public.fast_release_prefs;

create policy "fast_release_select_own"
  on public.fast_release_prefs for select
  to authenticated
  using (guest_id = auth.uid());

create policy "fast_release_insert_own"
  on public.fast_release_prefs for insert
  to authenticated
  with check (guest_id = auth.uid());

create policy "fast_release_delete_own"
  on public.fast_release_prefs for delete
  to authenticated
  using (guest_id = auth.uid());

-- ------------------------------------------------------------
-- set_fast_release(): 設定する / 外す
-- ------------------------------------------------------------
create or replace function public.set_fast_release(p_host_id uuid, p_hours int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_min_plays constant int := 3;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if v_uid = p_host_id then
    raise exception 'CANNOT_SET_SELF';
  end if;

  -- null または 72 で「既定に戻す」= 行を消す
  if p_hours is null or p_hours >= 72 then
    delete from public.fast_release_prefs where guest_id = v_uid and host_id = p_host_id;
    return;
  end if;

  if p_hours < 24 then
    raise exception 'FAST_RELEASE_TOO_SHORT';
  end if;

  -- 仕組みを理解する前に押させないため、何度か遊んだ相手にだけ許す
  if public._played_together_count(v_uid, p_host_id) < c_min_plays then
    raise exception 'NOT_ENOUGH_PLAYS';
  end if;

  insert into public.fast_release_prefs (guest_id, host_id, hours)
  values (v_uid, p_host_id, p_hours)
  on conflict (guest_id, host_id) do update set hours = excluded.hours, created_at = now();
end;
$$;

comment on function public.set_fast_release(uuid, int) is
  'この相手との予約を終了から何時間で自動確定してよいか(24〜71)。nullまたは72で既定に戻す。3回以上遊んだ相手にだけ設定できる。';

revoke all on function public.set_fast_release(uuid, int) from public;
grant execute on function public.set_fast_release(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- my_fast_release(): いまの設定と、設定できる状態か
-- ------------------------------------------------------------
create or replace function public.my_fast_release(p_host_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'hours', (select f.hours from public.fast_release_prefs f
              where f.guest_id = auth.uid() and f.host_id = p_host_id),
    'eligible', coalesce(public._played_together_count(auth.uid(), p_host_id) >= 3, false)
  );
$$;

comment on function public.my_fast_release(uuid) is
  '自分がこの相手に設定している自動確定の時間と、設定できる状態かどうか。';

revoke all on function public.my_fast_release(uuid) from public;
grant execute on function public.my_fast_release(uuid) to authenticated;

-- ------------------------------------------------------------
-- 自動確定が、この設定を見るようにする
-- ------------------------------------------------------------
-- 設定を**実行時に読む**のが肝。予約を作った時点で焼き付けると、
-- あとから設定を外しても、既にある予約は短いままになってしまう。
create or replace function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_default_hours constant int := 72;
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select b.id, b.host_id, b.coins
    from public.bookings b
    where b.status = 'confirmed'
      -- 保留(通報・申し出)は従来どおり優先。短くしても確定しない
      and b.held_at is null
      -- 相関副問い合わせで引くこと。left join にすると
      -- 「FOR UPDATE cannot be applied to the nullable side of an outer join」で落ちる。
      and b.scheduled_at
          + make_interval(mins => b.duration_minutes)
          + make_interval(hours => coalesce(
              (select f.hours from public.fast_release_prefs f
               where f.guest_id = b.guest_id and f.host_id = b.host_id),
              c_default_hours)) < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  'ゲストが完了操作をしないまま終了から一定時間が過ぎた予約を自動確定する。'
  '既定72時間。0062でゲストが相手ごとに24時間まで短くできるようにした(設定は実行時に読むので、外せば即座に既定へ戻る)。'
  '保留中(held_at)のものは対象外(E-12)。';

revoke all on function public.auto_complete_bookings() from public;
