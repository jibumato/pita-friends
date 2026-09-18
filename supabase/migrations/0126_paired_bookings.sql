-- ============================================================
-- 0126: ペア予約（ゲスト1人がペア相手の2人をまとめて予約する）
--
-- ■ 決めたこと（0125の続き）
--   ・ゲスト1人 × ホスト2人。2人とも active なペア相手であること(0125)
--   ・2人目も承認が必要。**片方だけの承諾では成立しない**
--   ・最初のリリースは新規予約のみ。ペア予約でも、成立後の1件1件は
--     **ふつうの予約と完全に同じ**。承諾・チェックイン・完了・キャンセル・
--     手数料・GMV・リピート判定は、0001〜0124 のロジックを一切変えずに
--     ホストごとに独立して流れる
--
-- ■ 何を新しく作るか
--   ・`booking_pairs`: 2件の bookings を束ねる薄い表(状態は持たない。
--     status は下の bookings 2件から導出する——2箇所に同じ状態を
--     持つと必ずずれる)
--   ・`bookings.from_pair_id`: どのペアに属す予約か(0120の
--     from_guest_request_id と同じ形)
--   ・`create_booking` の5引数版: p_pair_id を追加。**中身は4引数版と
--     ほぼ同一**で、変えたのはゲスト側の重複予約チェックが
--     「ペアの相方」を衝突と見なさない1点だけ。既存の4引数版は
--     この5引数版へ委譲するだけにする(2〜3引数版がすでに4引数版へ
--     委譲している、既存の書き方と揃える)。**既存の呼び出し元の挙動は
--     1文字も変わらない**(p_pair_id=null で今までと同じ経路を通る)。
--
-- ■ 「片方が断ったら、もう片方はどうなるか」
--   ゲストは「2人揃って遊ぶ」つもりで申し込んでいる。片方だけ確定した
--   ソロ予約に化けさせない。**もう片方が申請中(requested)のうちに
--   一方が断った/取り消したら、残りも同じ理由で全額返還して閉じる。**
--   （すでに両方 confirmed になったあとの片方キャンセルは、
--     このリリースでは自動連鎖させない——ゲストがもう片方だけで
--     続けたい場合もあるため。個別に判断してもらう。）
--
-- ■ 自作自演・0122との関係
--   ペアの2人は別々のホストなので、月間GMV・リピート判定・手数料は
--   **今までどおりホストごとに独立**して計算される(0122のロジックは
--   一切触っていない)。ペアという理由で優遇・軽減はしない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. bookings にペアの紐付け列を足す
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_pair_id uuid;

comment on column public.bookings.from_pair_id is
  '0126: ペア予約(booking_pairs)の一部なら、その行のid。'
  '単独の予約なら null。create_booking の5引数版だけがここを書く。';

create index if not exists bookings_from_pair_id_idx
  on public.bookings (from_pair_id) where from_pair_id is not null;

-- ------------------------------------------------------------
-- 2. booking_pairs（2件の bookings を束ねるだけの表）
--
-- **状態を持たない。** 「承認待ち／両方確定／片方だけ確定」などは
-- 2件の bookings.status から毎回導くもので、ここに複製すると
-- どちらかの更新を忘れたときに食い違う。
-- ------------------------------------------------------------
create table if not exists public.booking_pairs (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null references auth.users (id) on delete cascade,
  booking_a uuid references public.bookings (id) on delete cascade,
  booking_b uuid references public.bookings (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint booking_pairs_distinct check (booking_a is null or booking_a <> booking_b)
);

comment on table public.booking_pairs is
  '0126: 2件のbookingsを束ねるだけの表。状態は持たない'
  '(bookings.status から導出する。get_paired_booking / my_paired_bookings を参照)。';

alter table public.booking_pairs enable row level security;

create policy "booking_pairs_select_participant"
  on public.booking_pairs for select
  to authenticated
  using (
    guest_id = auth.uid()
    or exists (
      select 1 from public.bookings b
      where b.id in (booking_a, booking_b) and b.host_id = auth.uid()
    )
  );

-- insert / update のポリシーは置かない。**RPCが唯一の入口**

alter table public.bookings
  add constraint bookings_from_pair_id_fkey
  foreign key (from_pair_id) references public.booking_pairs (id) on delete set null;

-- ------------------------------------------------------------
-- 3. create_booking の5引数版（p_pair_id を追加）
--
-- ⚠️ 本体は適用済みのDBから取り出したもの。差分は2箇所だけ:
--    ・ゲスト側の重複予約チェックが「ペアの相方」を除外する
--    ・insert 文に from_pair_id を足す
-- ------------------------------------------------------------
create or replace function public.create_booking(p_host_id uuid, p_duration_minutes integer, p_policy_version text, p_scheduled_at timestamp with time zone, p_pair_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_hourly_rate int;
  v_is_host boolean;
  v_verified boolean;
  v_coins int;
  v_list_coins int;
  v_discount int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_booking_id uuid;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
  v_min_lead int;
  v_max_lead int;
  v_start timestamptz;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;

  if v_guest_id = p_host_id then
    raise exception 'CANNOT_BOOK_SELF';
  end if;

  -- 0121: ブロック関係があれば予約させない。
  -- **0116 が「ブロック＝予約もトークも不可」と書いているのに、
  --   ここには検査が無かった。** create_booking_from_board(0113)だけが
  --   独自に見ていたので、板を経由しない経路は全部素通りだった。
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_guest_id and b.blocked_id = p_host_id)
       or (b.blocker_id = p_host_id and b.blocked_id = v_guest_id)
  ) then
    raise exception 'BLOCKED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;

  if p_scheduled_at is not null then
    if p_scheduled_at < now() + make_interval(mins => v_min_lead) then
      raise exception 'START_TOO_SOON';
    end if;
    if p_scheduled_at > now() + make_interval(days => v_max_lead) then
      raise exception 'START_TOO_FAR';
    end if;
  end if;

  select hs.hourly_rate, hs.is_host into v_hourly_rate, v_is_host
  from public.host_settings hs where hs.user_id = p_host_id for share;
  if not coalesce(v_is_host, false) or v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  select pts.is_verified into v_verified
  from public.profile_trust_stats pts where pts.user_id = p_host_id;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  v_start := coalesce(p_scheduled_at, now());

  if not public.booking_fits_availability(p_host_id, v_start, p_duration_minutes) then
    raise exception 'HOST_NOT_OPEN';
  end if;

  -- 常連への先行予約(0057)。開始まで遠い枠は、一緒に遊んだことのある人だけ。
  if not public.slot_open_to(p_host_id, v_guest_id, v_start) then
    raise exception 'REGULARS_FIRST';
  end if;

  perform public._lock_booking_slots(v_guest_id, p_host_id);

  if public._booking_slot_conflict(p_host_id, v_start, p_duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペア予約(同じゲスト・同じ時間で2人のホストに同時に申し込む)は、
  -- ここが無いと**自分自身の、もう片方への申し込み**を「重複」として
  -- 弾いてしまう。p_pair_id が同じ予約(=ペアの相方)だけ、この検査から除く
  -- (他のゲストの予約や、別のペアとは今までどおり衝突させる)。
  -- **_booking_slot_conflict は1件しか返さない**ので、ここは書き直さず
  -- 素の exists で「相方以外との重なり」だけを見る。
  if exists (
    select 1 from public.bookings b
    where b.status = any (array['requested', 'confirmed'])
      and (b.guest_id = v_guest_id or b.host_id = v_guest_id)
      and (p_pair_id is null or b.from_pair_id is distinct from p_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes),
            '[)')
          && tstzrange(v_start, v_start + make_interval(mins => p_duration_minutes), '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  v_discount := public.host_trial_discount_for(p_host_id, v_guest_id);
  v_list_coins := round(v_hourly_rate * p_duration_minutes / 60.0);
  v_coins := greatest(1, round(v_list_coins * (100 - v_discount) / 100.0));

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_guest_id for update;
  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 有償を先に使い切るのではなく、**有効期限の早いロットから**充当する。
  -- 同一期限内では有償が先。詳細は 0082 の冒頭を参照。
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_guest_id, v_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_guest_id;

  insert into public.bookings (
    guest_id, host_id, duration_minutes, coins, status,
    paid_coins, bonus_coins, policy_version, policy_agreed_at,
    list_coins, discount_percent, requested_start_at, from_pair_id
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at, p_pair_id
  )
  returning id into v_booking_id;

  v_paid_lots := public._consume_coin_lots_tracked(v_guest_id, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_guest_id, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_guest_id, v_booking_id, 'bonus', v_bonus_lots);

  insert into public.coin_transactions (user_id, amount, type, related_booking_id)
  values (v_guest_id, -v_coins, 'booking_spend', v_booking_id);

  return v_booking_id;
end;
$$;

comment on function public.create_booking(uuid, integer, text, timestamptz, uuid) is
  '予約の確定+コイン消費(0003)。0126でp_pair_idを追加——'
  'ペアの相方への同時申し込みを、ゲスト側の重複予約チェックから除外する。'
  '**単独では呼ばない。** create_paired_booking からだけ使う内部経路。';

revoke all on function public.create_booking(uuid, integer, text, timestamptz, uuid) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz, uuid) to authenticated;

-- 4引数版は、この5引数版へ委譲するだけにする(2〜3引数版が4引数版へ
-- 委譲しているのと同じ書き方)。**p_pair_id=null なので、経路も挙動も
-- 今までと1バイトも変わらない**——上で足した分岐は p_pair_id is null の
-- ときはすべて素通りする。
create or replace function public.create_booking(
  p_host_id uuid, p_duration_minutes integer, p_policy_version text,
  p_scheduled_at timestamp with time zone
)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.create_booking(p_host_id, p_duration_minutes, p_policy_version, p_scheduled_at, null::uuid);
$$;

revoke all on function public.create_booking(uuid, integer, text, timestamptz) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 4. 「片方が申請中のうちにもう片方が終わったら、連鎖して閉じる」
--
-- ゲストは「2人揃って遊ぶ」つもりで申し込んでいる。片方が断られた/
-- 取り消されたのに、もう片方だけ残って**ソロ予約に化ける**のを防ぐ。
--
-- ⚠️ **承認(confirmed)後の片方キャンセルは連鎖させない。** 両方確定した
--    あとにどちらかが個別の理由でキャンセルするのは、通常のキャンセルと
--    同じ扱いでよく、ゲストがもう片方だけで続けたい場合もあるため。
--    連鎖は「まだ両方とも返事待ちの段階」に限る。
-- ------------------------------------------------------------
alter table public.bookings drop constraint bookings_status_check;
alter table public.bookings add constraint bookings_status_check
  check (status = any (array[
    'requested', 'confirmed', 'completed',
    'cancelled_by_guest', 'cancelled_by_host', 'declined_by_host',
    'no_show_host', 'no_show_guest',
    -- 0126: ペアの相方が申請段階で終わったことによる、システム側の自動取消し。
    -- 本人が押したのではないので、既存の理由と混ぜない
    'cancelled_by_platform'
  ]));

create or replace function public._cascade_pair_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sibling public.bookings;
  v_host_name text;
begin
  -- ペアに属さない予約、または「申請中」以外からの遷移は無関係
  if new.from_pair_id is null or old.status <> 'requested' then
    return new;
  end if;
  -- 連鎖の対象は「本人の意思で終わった」遷移だけ。
  -- **cancelled_by_platform はここに含めない**——含めると、いま自分が
  -- 起こしている連鎖が、相手側の行を経由して往復してしまう
  if new.status not in ('declined_by_host', 'cancelled_by_guest', 'cancelled_by_host') then
    return new;
  end if;

  select * into v_sibling from public.bookings
    where from_pair_id = new.from_pair_id and id <> new.id
    for update;
  -- 相方が無い、またはすでに動いている(承認済み・すでに連鎖済みなど)なら何もしない
  if v_sibling.id is null or v_sibling.status <> 'requested' then
    return new;
  end if;

  update public.bookings
    set status = 'cancelled_by_platform', cancelled_at = now(),
        cancel_reason = 'pair_partner_declined'
    where id = v_sibling.id;

  update public.coin_wallets
    set balance = balance + v_sibling.paid_coins, bonus_balance = bonus_balance + v_sibling.bonus_coins
    where user_id = v_sibling.guest_id;
  perform public._refund_coin_lots_for_booking(v_sibling.id, null, null, 'host_fault');
  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
    values (v_sibling.guest_id, v_sibling.coins, 'refund', v_sibling.id, 'pair_partner_declined');

  select nickname into v_host_name from public.profiles where id = v_sibling.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_sibling.guest_id, 'booking_cancelled',
    'ペアの片方が成立しなかったため、もう一方も取り消しました',
    coalesce(nullif(v_host_name, ''), '相手') || 'さんへの申し込みはコイン全額を返却しました',
    v_sibling.id);

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_sibling.host_id, 'booking_cancelled',
    'ペア予約の申し込みが取り消されました',
    'もう一方が成立しなかったため、この申し込みも自動的に取り消されました',
    v_sibling.id);

  return new;
end;
$$;

comment on function public._cascade_pair_cancel() is
  '0126: ペアの片方が「申請中」のまま終わったら、もう片方も同時に閉じて全額返還する。'
  '両方confirmed後の片方キャンセルは連鎖させない(設計どおり)。';

revoke all on function public._cascade_pair_cancel() from public, anon, authenticated;

drop trigger if exists bookings_cascade_pair_cancel on public.bookings;
create trigger bookings_cascade_pair_cancel
  after update on public.bookings
  for each row execute function public._cascade_pair_cancel();

-- ------------------------------------------------------------
-- 5. ゲストが2人まとめて申し込む
-- ------------------------------------------------------------
create or replace function public.create_paired_booking(
  p_host_a_id uuid,
  p_host_b_id uuid,
  p_duration_minutes integer,
  p_policy_version text,
  p_scheduled_at timestamptz
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id uuid := auth.uid();
  v_pair_id uuid;
  v_booking_a uuid;
  v_booking_b uuid;
begin
  if v_guest_id is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_host_a_id is null or p_host_b_id is null or p_host_a_id = p_host_b_id then
    raise exception 'INVALID_PAIR';
  end if;

  -- ゲストが誰とでも組ませられるわけではない。**両方が合意した組だけ**(0125)
  if not public.are_pair_partners(p_host_a_id, p_host_b_id) then
    raise exception 'NOT_PAIR_PARTNERS';
  end if;
  -- 成立後にブロックが起きている可能性がある。are_pair_partners は
  -- 申請の状態しか見ないので、ここで別途確認する
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = p_host_a_id and b.blocked_id = p_host_b_id)
       or (b.blocker_id = p_host_b_id and b.blocked_id = p_host_a_id)
  ) then
    raise exception 'PARTNER_BLOCKED';
  end if;

  insert into public.booking_pairs (guest_id) values (v_guest_id)
  returning id into v_pair_id;

  -- **create_booking をそのまま呼ぶ。** 検査(掲載・本人確認・先約・同意・
  -- ブロック・残高)を作り直さない(0113/0120と同じ方針)。片方が失敗すれば
  -- 例外が伝播し、この関数全体がロールバックする(booking_pairs の行も含めて
  -- 何も残らない)——**中途半端な「片方だけ成立」を作らない**。
  v_booking_a := public.create_booking(
    p_host_a_id, p_duration_minutes, p_policy_version, p_scheduled_at, v_pair_id);
  v_booking_b := public.create_booking(
    p_host_b_id, p_duration_minutes, p_policy_version, p_scheduled_at, v_pair_id);

  update public.booking_pairs
    set booking_a = v_booking_a, booking_b = v_booking_b
    where id = v_pair_id;

  return v_pair_id;
end;
$$;

comment on function public.create_paired_booking(uuid, uuid, integer, text, timestamptz) is
  '0126: ペア相手の2人をまとめて予約する。承認・チェックイン・完了・キャンセル・'
  '手数料・GMV・リピート判定は、成立後は通常の1対1予約と完全に同じ経路を通る'
  '(ホストごとに独立)。片方が申請段階で終わったら、もう片方も自動的に閉じる。';

revoke all on function public.create_paired_booking(uuid, uuid, integer, text, timestamptz) from public, anon;
grant execute on function public.create_paired_booking(uuid, uuid, integer, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 6. ペアの情報を引く（両側から使う）
-- ------------------------------------------------------------
create or replace function public.fetch_booking_pair(p_booking_id uuid)
returns table (
  pair_id uuid,
  sibling_booking_id uuid,
  sibling_user_id uuid,
  sibling_nickname text,
  sibling_status text,
  sibling_starts_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    bp.id,
    sib.id,
    -- 呼び出し元がゲストなら相方の「ホスト」を、ホストなら相方の「ゲスト」…
    -- ではなく、常に「もう一方の予約のホスト」を返す。ゲストは同一人物なので
    -- 見せる意味が無い
    sib.host_id,
    p.nickname,
    sib.status,
    coalesce(sib.requested_start_at, sib.scheduled_at)
  from public.bookings me
  join public.booking_pairs bp on bp.id = me.from_pair_id
  join public.bookings sib on sib.from_pair_id = bp.id and sib.id <> me.id
  join public.profiles p on p.id = sib.host_id
  where me.id = p_booking_id
    and (me.guest_id = auth.uid() or me.host_id = auth.uid());
$$;

comment on function public.fetch_booking_pair(uuid) is
  '0126: この予約がペアの一部なら、相方の状態を返す(無ければ0行)。'
  '承認画面・トーク画面で「ペア予約です」と出すのに使う。';

revoke all on function public.fetch_booking_pair(uuid) from public, anon;
grant execute on function public.fetch_booking_pair(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. 自分のペア予約の一覧（ゲスト向け）
-- ------------------------------------------------------------
create or replace function public.my_paired_bookings(p_limit int default 20)
returns table (
  pair_id uuid,
  booking_a uuid,
  host_a_id uuid,
  host_a_nickname text,
  status_a text,
  booking_b uuid,
  host_b_id uuid,
  host_b_nickname text,
  status_b text,
  starts_at timestamptz,
  duration_minutes int,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    bp.id, a.id, a.host_id, pa.nickname, a.status,
    b.id, b.host_id, pb.nickname, b.status,
    coalesce(a.requested_start_at, a.scheduled_at), a.duration_minutes,
    bp.created_at
  from public.booking_pairs bp
  join public.bookings a on a.id = bp.booking_a
  join public.bookings b on b.id = bp.booking_b
  join public.profiles pa on pa.id = a.host_id
  join public.profiles pb on pb.id = b.host_id
  where bp.guest_id = auth.uid()
  order by bp.created_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;

comment on function public.my_paired_bookings(int) is
  '0126: 自分(ゲスト)が申し込んだペア予約の一覧。';

revoke all on function public.my_paired_bookings(int) from public, anon;
grant execute on function public.my_paired_bookings(int) to authenticated;

-- ------------------------------------------------------------
-- 8. approve_booking / extend_booking も同じ理由で1点だけ直す
--
-- ⚠️ **設計時点では気づけなかった追加の変更。** 「create_booking以外の
--    予約ライフサイクル(承認・チェックイン・完了・キャンセル)には
--    一切手を入れない」つもりだったが、実装してテストを流したところ
--    approve_booking と extend_booking にも**ゲスト側の「成立済みと
--    重複していないか」の再チェック**があり、これがペアの相方を
--    「衝突」として検出してしまうことが分かった:
--
--      ・ペアの片方を承諾した瞬間、もう片方の承諾がGUEST_SLOT_TAKENで
--        弾かれる(テスト46の★4で実際に踏んだ)
--      ・ペア予約は延長が一度もできない(相方が同じ時刻で確定して
--        いる以上、延長前から必ず重なって見えるため)
--
--    どちらも「本人の別予約と重複していないか」という**既存の検査の
--    意図を変えていない**。除外するのは「ペアの相方」1種類だけで、
--    通常の1対1予約の挙動(from_pair_idがnull)は一切変わらない。
--    本体は適用済みのDBから取り出したもので、変更点はコメントで示した
--    exists節1つずつだけ。
-- ------------------------------------------------------------
create or replace function public.approve_booking(p_booking_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_promise_id uuid;
  v_host_name text;
  v_start timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.host_id then
    raise exception 'ONLY_HOST_CAN_APPROVE';
  end if;
  if v_booking.status <> 'requested' then
    raise exception 'BOOKING_NOT_REQUESTED';
  end if;

  -- 指定があればその時刻、無ければ従来どおり承諾時点が開始時刻。
  -- 承諾時刻は別に持つ(キャンセル猶予の起点になるため。0040以前は
  -- scheduled_at が承諾時刻を兼ねていた)。
  v_start := coalesce(v_booking.requested_start_at, now());

  -- ここで見るのは**成立済み(confirmed)だけ**。
  -- 申請中の予約まで見ると、同じ枠に2件のリクエストが並んだときに
  -- ピタメイトが**どちらも承諾できなくなります**。申請は「希望」であって
  -- 確約ではないので、承諾の可否を縛るべきではありません。
  -- (先に1件を承諾すれば、もう1件はここで弾かれて全額返還されます。)
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_start, v_booking.duration_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペアの相方(同じfrom_pair_id)は「重複」として数えない。
  -- ペア予約は両方が同じ時刻で確定するのが前提なので、ここが無いと
  -- 1件目を承諾した瞬間、2件目の承諾がここで弾かれてしまう
  -- (_booking_slot_conflict は素の関数なので、除外条件はここに直接書く)。
  if exists (
    select 1 from public.bookings b
    where b.status = 'confirmed'
      and b.guest_id = v_booking.guest_id
      and b.id <> p_booking_id
      and (v_booking.from_pair_id is null
           or b.from_pair_id is distinct from v_booking.from_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes), '[)')
          && tstzrange(v_start, v_start + make_interval(mins => v_booking.duration_minutes), '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  update public.bookings
    set status = 'confirmed', scheduled_at = v_start, confirmed_at = now()
    where id = p_booking_id;

  insert into public.promises (booking_id, user_a, user_b)
  values (p_booking_id, v_booking.guest_id, v_booking.host_id)
  returning id into v_promise_id;

  select nickname into v_host_name from public.profiles where id = v_booking.host_id;
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_booking.guest_id,
    'booking_approved',
    coalesce(nullif(v_host_name, ''), 'ピタメイト') || 'さんが予約を承諾しました',
    case when v_booking.requested_start_at is null
         then 'トークが始まりました。プレイの準備をしましょう'
         else to_char(v_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '〜 で成立しました' end,
    v_promise_id
  );

  return v_promise_id;
end;
$$;

comment on function public.approve_booking(uuid) is
  '予約の承諾(0003)。0126で、ペアの相方(from_pair_id)は成立済みどうしの'
  '重複チェックから除く(両方が同じ時刻で確定するのがペア予約の前提のため)。';

revoke all on function public.approve_booking(uuid) from public, anon;
grant execute on function public.approve_booking(uuid) to authenticated;

create or replace function public.extend_booking(p_booking_id uuid, p_additional_minutes integer)
 returns integer
 language plpgsql
 security definer
 set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_hourly_rate int;
  v_add_coins int;
  v_max int;
  v_paid int;
  v_bonus int;
  v_from_paid int;
  v_from_bonus int;
  v_paid_lots jsonb;
  v_bonus_lots jsonb;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_additional_minutes not in (30, 60) then
    raise exception 'INVALID_DURATION';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;
  if v_uid <> v_booking.guest_id then
    raise exception 'ONLY_GUEST_CAN_EXTEND';
  end if;
  if v_booking.status <> 'confirmed' then
    raise exception 'BOOKING_NOT_EXTENDABLE';
  end if;

  -- 延長後の合計が上限を超えないこと。
  select max_duration_minutes into v_max from public.platform_pricing where id = 1;
  if v_booking.duration_minutes + p_additional_minutes > v_max then
    raise exception 'DURATION_LIMIT_EXCEEDED';
  end if;

  -- 延長は終了時刻を後ろにずらすので、次の予約に食い込まないか確かめる。
  -- ここも成立済みだけを見る。まだ承諾されていない後続のリクエストのために
  -- 進行中のプレイの延長を止めるのは、優先順位が逆。
  perform public._lock_booking_slots(v_booking.guest_id, v_booking.host_id);
  if public._booking_slot_conflict(
       v_booking.host_id, v_booking.scheduled_at,
       v_booking.duration_minutes + p_additional_minutes,
       p_booking_id, array['confirmed']) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  -- 0126: ペアの相方(同じfrom_pair_id)は「重複」として数えない。
  -- 相方は同じ開始時刻で確定しているので、延長前の時点で必ず重なって見える。
  -- ここが無いと、ペア予約の延長が一度もできない。
  if exists (
    select 1 from public.bookings b
    where b.status = 'confirmed'
      and b.guest_id = v_booking.guest_id
      and b.id <> p_booking_id
      and (v_booking.from_pair_id is null
           or b.from_pair_id is distinct from v_booking.from_pair_id)
      and tstzrange(
            coalesce(b.requested_start_at, b.scheduled_at),
            coalesce(b.requested_start_at, b.scheduled_at)
              + make_interval(mins => b.duration_minutes), '[)')
          && tstzrange(
               v_booking.scheduled_at,
               v_booking.scheduled_at + make_interval(mins => v_booking.duration_minutes + p_additional_minutes),
               '[)')
  ) then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select hourly_rate into v_hourly_rate
  from public.host_settings where user_id = v_booking.host_id for share;
  if v_hourly_rate is null then
    raise exception 'HOST_NOT_AVAILABLE';
  end if;

  -- 延長は通常価格。初回お試し割引は最初に予約した分にしか効かない(0039)。
  v_add_coins := round(v_hourly_rate * p_additional_minutes / 60.0);

  select balance, bonus_balance into v_paid, v_bonus
  from public.coin_wallets where user_id = v_uid for update;

  if v_paid is null or (v_paid + coalesce(v_bonus, 0)) < v_add_coins then
    raise exception 'INSUFFICIENT_COINS';
  end if;

  -- 0082: 期限の早いロットから充当する(同一期限内は有償が先)
  select s.paid, s.bonus into v_from_paid, v_from_bonus
  from public._split_coins_by_expiry(v_uid, v_add_coins) s;

  update public.coin_wallets
    set balance = balance - v_from_paid,
        bonus_balance = bonus_balance - v_from_bonus
    where user_id = v_uid;

  v_paid_lots := public._consume_coin_lots_tracked(v_uid, 'paid', v_from_paid);
  v_bonus_lots := public._consume_coin_lots_tracked(v_uid, 'bonus', v_from_bonus);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'paid', v_paid_lots);
  perform public._record_lot_consumptions(v_uid, p_booking_id, 'bonus', v_bonus_lots);

  update public.bookings
    set duration_minutes = duration_minutes + p_additional_minutes,
        coins = coins + v_add_coins,
        paid_coins = paid_coins + v_from_paid,
        bonus_coins = bonus_coins + v_from_bonus,
        list_coins = coalesce(list_coins, coins) + v_add_coins
    where id = p_booking_id;

  insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
  values (v_uid, -v_add_coins, 'booking_spend', p_booking_id, 'extend_booking');

  insert into public.notifications (user_id, type, title, body, related_id)
  values (v_booking.host_id, 'booking_extended',
    'プレイが' || p_additional_minutes || '分延長されました',
    v_add_coins || 'コインが追加されました', p_booking_id);

  return v_add_coins;
end;
$$;

comment on function public.extend_booking(uuid, integer) is
  'プレイ時間の延長(0055)。0126で、ペアの相方(from_pair_id)は'
  '重複チェックから除く(相方は同じ開始時刻の別予約として必ず重なるため。'
  '除かないとペア予約は一度も延長できない)。片方だけ延長すると2人の'
  '終了時刻がずれる——連動させるかは今回のリリース範囲外。';

revoke all on function public.extend_booking(uuid, integer) from public, anon;
grant execute on function public.extend_booking(uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- 9. このホストの、active なペア相手を誰でも見られるようにする
--
-- `host_pair_partners` はRLSで当事者にしか見えない。しかし
-- 「このピタメイトはペアで予約できます」はゲストへの案内なので、
-- **公開情報として見せる必要がある**(掲載中のゲーム・時給と同じ扱い)。
-- 見せるのは active な相手の最小限の表示情報だけで、申請中の行や
-- 誰が申請した側かは渡さない。
-- ------------------------------------------------------------
create or replace function public.host_pair_partners_of(p_host_id uuid)
returns table (
  partner_id uuid,
  partner_nickname text,
  partner_avatar_initial text,
  partner_avatar_color text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    case when r.host_lo = p_host_id then r.host_hi else r.host_lo end,
    coalesce(nullif(p.nickname, ''), '(名前未設定)'),
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2')
  from public.host_pair_partners r
  join public.profiles p
    on p.id = case when r.host_lo = p_host_id then r.host_hi else r.host_lo end
  where r.status = 'active' and p_host_id in (r.host_lo, r.host_hi);
$$;

comment on function public.host_pair_partners_of(uuid) is
  '0126: 指定したホストの、active なペア相手の一覧(誰でも見られる)。'
  'プロフィール画面の「ペアで予約できます」の案内に使う。';

revoke all on function public.host_pair_partners_of(uuid) from public, anon;
grant execute on function public.host_pair_partners_of(uuid) to authenticated;
