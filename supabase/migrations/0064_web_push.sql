-- ============================================================
-- 0064_web_push.sql
-- ブラウザへのプッシュ通知(Web Push)
-- ------------------------------------------------------------
-- これまで notifications は**アプリを開いたときにしか見えなかった**。
-- 0054の「推しが枠を開けました」も、開いてくれなければ意味がない。
-- ピタフレはApp Storeに出していないので、届く経路はWeb Pushだけになる。
--
-- ■ 設計で外せない点
--
-- 1. **通知の記録とプッシュの送信を切り離す。**
--    トリガーの中からHTTPを叩くと、プッシュ配信元(FCM/Apple)が落ちている
--    ときに notifications の insert ごと失敗する。予約や通報の通知が
--    「プッシュが送れなかったから」消えるのは本末転倒。
--    そこで push_outbox に積むだけにして、送信は別プロセス(Edge Function)が
--    引き取る。失敗しても再試行できて、溜まっている様子も見える。
--
-- 2. **プッシュは既存の通知設定とは別の口。**
--    notification_prefs の3つのトグルは「何を」の設定で、
--    プッシュは「どうやって」の設定。混ぜると
--    「アプリ内では見たいがロック画面には出したくない」が表現できない。
--    push_enabled を足して独立に切れるようにする。
--
-- 3. **ロック画面に本文を出さない種類がある。**
--    message_received はメッセージ本文の先頭60文字を、
--    gift_received は金額と添えた言葉を body に入れている(0012/0019)。
--    ロック画面は他人の目に入る場所なので、この2つは**題名だけ**にする。
--    「誰から来たか」は伝わるので用は足りる。
--
-- 4. **静かにする時間は既定で入れない。**
--    ゲームは夜に遊ぶもので、深夜の誘いはむしろ本題。運営が勝手に
--    止めると使えない通知になる。設定した人にだけ効かせ、しかも
--    急がない種類(枠が空いた・ギフト・募集)だけを止める。
--    判定は**送信時**に行う(0062と同じ理由。設定を変えたら即座に効く)。
--
-- 5. **iOSはホーム画面に追加しないと通知が使えない。** これは仕様。
--    追加への案内(src/lib/install.ts)と地続きの導線になっている。
--
-- ⚠️ 送信には VAPID 鍵が必要です。手順は docs/web-push-setup.md。
--    **秘密鍵はリポジトリに置かないこと。** Supabase の Secrets に入れる。
-- ============================================================

-- ------------------------------------------------------------
-- push_subscriptions: 端末ごとの購読先
-- ------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 配信元が発行するURL。端末+ブラウザを一意に指す
  endpoint text not null unique,
  -- 本文を暗号化するための公開鍵と認証シークレット(ブラウザが発行する)
  p256dh text not null,
  auth text not null,
  -- どの端末か(利用者が設定画面で見分けるため。判定には使わない)
  ua text,
  created_at timestamptz not null default now(),
  -- 起動ごとに更新する。古いものを片付ける目印
  last_seen_at timestamptz not null default now(),
  -- 配信元が404/410を返した(購読が消えた)。再送しない
  disabled_at timestamptz,
  fail_count smallint not null default 0
);

comment on table public.push_subscriptions is
  'Web Pushの購読先。endpointが端末+ブラウザを一意に指すので、同じ端末で別の人がログインしたら user_id が付け替わる(その端末には前の人へのプッシュは行かなくなる。これが正しい)。';

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id) where disabled_at is null;

alter table public.push_subscriptions enable row level security;

-- 自分の行だけ。設定画面で端末一覧を出し、消せるようにする。
drop policy if exists "push_subscriptions_select_own" on public.push_subscriptions;
drop policy if exists "push_subscriptions_delete_own" on public.push_subscriptions;

create policy "push_subscriptions_select_own"
  on public.push_subscriptions for select
  to authenticated
  using (user_id = auth.uid());

create policy "push_subscriptions_delete_own"
  on public.push_subscriptions for delete
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATEポリシーは作らない。下の RPC 経由だけにして、
-- user_id を他人のものにできないようにする。

-- ------------------------------------------------------------
-- プッシュの受け取り設定
-- ------------------------------------------------------------
alter table public.notification_prefs
  add column if not exists push_enabled boolean not null default true;
-- 静かにする時間(JSTの時。null で無効)。23→7 のように日付をまたいでよい
alter table public.notification_prefs
  add column if not exists push_quiet_from smallint;
alter table public.notification_prefs
  add column if not exists push_quiet_to smallint;

alter table public.notification_prefs
  drop constraint if exists notification_prefs_quiet_range_check;
alter table public.notification_prefs
  add constraint notification_prefs_quiet_range_check check (
    (push_quiet_from is null and push_quiet_to is null)
    or (push_quiet_from between 0 and 23 and push_quiet_to between 0 and 23)
  );

comment on column public.notification_prefs.push_enabled is
  'ロック画面へのプッシュを受け取るか。アプリ内の通知一覧とは独立(見たいがロック画面には出したくない、を表現できるようにするため)。';
comment on column public.notification_prefs.push_quiet_from is
  'プッシュを止める開始時刻(JSTの時)。既定はnull=止めない。ゲームは夜に遊ぶので運営が勝手に止めない。';

-- ------------------------------------------------------------
-- 種類ごとの扱い
-- ------------------------------------------------------------
/**
 * 急がない種類か。静かにする時間で止めてよいのはこれだけ。
 * 予約・通報・本人確認・メッセージ・誘いは、深夜でも本題なので止めない
 * (2時に届いたメッセージは2時に読みたい)。
 */
create or replace function public._push_is_casual(p_type text)
returns boolean
language sql
immutable
as $$
  select p_type in (
    'host_slots_opened',  -- 0054。もともと24時間に1回に絞ってある
    'gift_received',
    'board_joined',
    'board_cancelled',
    'booking_completed'
  );
$$;

/**
 * ロック画面に出す本文。**他人の目に入る前提で削る。**
 * message_received はメッセージ本文、gift_received は金額と添えた言葉が
 * body に入っている(0012/0019)。この2つは題名だけにする。
 */
create or replace function public._push_lockscreen_body(p_type text, p_body text)
returns text
language sql
immutable
as $$
  select case when p_type in ('message_received', 'gift_received') then '' else coalesce(p_body, '') end;
$$;

/** いま静かにする時間の中か。日付をまたぐ指定(23→7)も扱う。 */
create or replace function public._push_in_quiet_hours(p_from smallint, p_to smallint)
returns boolean
language sql
stable
as $$
  select case
    when p_from is null or p_to is null or p_from = p_to then false
    when p_from < p_to then t.h >= p_from and t.h < p_to
    else t.h >= p_from or t.h < p_to
  end
  from (select extract(hour from now() at time zone 'Asia/Tokyo')::int as h) t;
$$;

-- ------------------------------------------------------------
-- push_outbox: 送信待ち
-- ------------------------------------------------------------
create table if not exists public.push_outbox (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  type text not null,
  title text not null,
  body text not null default '',
  related_id uuid,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts smallint not null default 0,
  last_error text
);

comment on table public.push_outbox is
  '送信待ちのプッシュ。トリガーからHTTPを叩くと配信元の障害でnotificationsのinsertごと失敗するので、いったんここへ積んで別プロセスが引き取る。';

create index if not exists push_outbox_pending_idx
  on public.push_outbox (created_at) where sent_at is null;

alter table public.push_outbox enable row level security;
-- 利用者に見せるものではない(自分の通知は notifications で見える)。
-- ポリシーを1本も作らないので、authenticated からは一切読めない。

-- ------------------------------------------------------------
-- notifications への insert で積む
-- ------------------------------------------------------------
create or replace function public._enqueue_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 端末を1つも登録していない人の分は積まない(大半はこれで落ちる)。
  -- push_enabled と静かにする時間は**送信時**に見る。設定を変えたら
  -- 積んである分にもすぐ効くようにするため(0062と同じ考え)。
  if not exists (
    select 1 from public.push_subscriptions s
    where s.user_id = new.user_id and s.disabled_at is null
  ) then
    return new;
  end if;

  insert into public.push_outbox (notification_id, user_id, type, title, body, related_id)
  values (
    new.id, new.user_id, new.type, new.title,
    public._push_lockscreen_body(new.type, new.body),
    new.related_id
  );
  return new;
end;
$$;

drop trigger if exists notifications_enqueue_push on public.notifications;
create trigger notifications_enqueue_push
  after insert on public.notifications
  for each row execute function public._enqueue_push();

-- ------------------------------------------------------------
-- 端末の登録・解除(本人のみ)
-- ------------------------------------------------------------
create or replace function public.save_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text, p_ua text default null
)
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
  if p_endpoint is null or p_endpoint = '' or p_p256dh is null or p_auth is null then
    raise exception 'INVALID_SUBSCRIPTION';
  end if;

  -- 同じ端末で別の人がログインしたら付け替える。disabled_at も戻す
  -- (購読し直したということなので、また生きている)
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, ua)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(coalesce(p_ua, ''), 300))
  on conflict (endpoint) do update
    set user_id = v_uid,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        ua = excluded.ua,
        last_seen_at = now(),
        disabled_at = null,
        fail_count = 0;
end;
$$;

comment on function public.save_push_subscription(text, text, text, text) is
  'この端末をプッシュの宛先として登録する。起動ごとに呼んでよい(last_seen_atが更新される)。';

revoke all on function public.save_push_subscription(text, text, text, text) from public;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;

create or replace function public.delete_push_subscription(p_endpoint text)
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
  delete from public.push_subscriptions
    where endpoint = p_endpoint and user_id = v_uid;
end;
$$;

revoke all on function public.delete_push_subscription(text) from public;
grant execute on function public.delete_push_subscription(text) to authenticated;

-- ------------------------------------------------------------
-- 送信側(service_role のみ)
-- ------------------------------------------------------------
/**
 * 送るぶんを取り出して、試行回数を1つ増やす。
 *
 * 1つの通知に対して端末ぶんの行を返す。静かにする時間・push_enabled は
 * ここで見るので、止まっている間は attempts が増えない(時間が明けたら
 * そのまま届く。「朝になったらまとめて来る」が正しい振る舞い)。
 */
create or replace function public.claim_push_batch(p_limit int default 100)
returns table (
  outbox_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  payload jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_attempts constant int := 3;
begin
  return query
  with picked as (
    select o.id
    from public.push_outbox o
    join public.notification_prefs np on np.user_id = o.user_id
    where o.sent_at is null
      and o.attempts < c_max_attempts
      and np.push_enabled
      -- 急がない種類だけ、静かにする時間のあいだ待たせる
      and not (
        public._push_is_casual(o.type)
        and public._push_in_quiet_hours(np.push_quiet_from, np.push_quiet_to)
      )
      and exists (
        select 1 from public.push_subscriptions s
        where s.user_id = o.user_id and s.disabled_at is null
      )
    order by o.created_at
    limit p_limit
    for update of o skip locked
  ),
  bumped as (
    update public.push_outbox o
      set attempts = o.attempts + 1
      where o.id in (select id from picked)
      returning o.id, o.user_id, o.type, o.title, o.body, o.related_id
  )
  select b.id, s.endpoint, s.p256dh, s.auth,
         jsonb_build_object(
           'type', b.type,
           'title', b.title,
           'body', b.body,
           'relatedId', b.related_id,
           'notificationId', b.id
         )
  from bumped b
  join public.push_subscriptions s
    on s.user_id = b.user_id and s.disabled_at is null;
end;
$$;

comment on function public.claim_push_batch(int) is
  '送信待ちを端末ぶんに展開して取り出す。運営(Edge Function)専用。試行3回で諦める。';

revoke all on function public.claim_push_batch(int) from public;
grant execute on function public.claim_push_batch(int) to service_role;

/** 1件でも届いたら完了にする。0件なら次の回に再試行(3回で諦める)。 */
create or replace function public.mark_push_result(
  p_outbox_id uuid, p_delivered int, p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.push_outbox
    set sent_at = case when p_delivered > 0 then now() else sent_at end,
        last_error = left(p_error, 500)
    where id = p_outbox_id;
end;
$$;

revoke all on function public.mark_push_result(uuid, int, text) from public;
grant execute on function public.mark_push_result(uuid, int, text) to service_role;

/**
 * 配信元が404/410を返した購読を止める。**行は消さない。**
 * 消してしまうと、同じ端末から登録し直したときに履歴が切れて、
 * 「登録したのに来ない」を調べる手がかりが無くなる。
 */
create or replace function public.disable_push_subscription(p_endpoint text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.push_subscriptions
    set disabled_at = now(), fail_count = fail_count + 1
    where endpoint = p_endpoint;
end;
$$;

revoke all on function public.disable_push_subscription(text, text) from public;
grant execute on function public.disable_push_subscription(text, text) to service_role;

/**
 * 片付け。pg_cron から1日1回。
 *   ・送信済み/諦めた outbox を7日で消す
 *   ・積んだまま1日たった分を捨てる(登録が消えた等で送り先が無い)
 *   ・180日起動されていない購読を消す(端末を手放している)
 */
create or replace function public.prune_push()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int := 0;
  v_x int;
begin
  delete from public.push_outbox
    where sent_at is not null and sent_at < now() - interval '7 days';
  get diagnostics v_x = row_count;
  v_n := v_n + v_x;

  delete from public.push_outbox
    where sent_at is null and created_at < now() - interval '1 day';
  get diagnostics v_x = row_count;
  v_n := v_n + v_x;

  delete from public.push_subscriptions
    where last_seen_at < now() - interval '180 days';
  get diagnostics v_x = row_count;
  v_n := v_n + v_x;

  return v_n;
end;
$$;

revoke all on function public.prune_push() from public;

-- ------------------------------------------------------------
-- 自分の設定を読む/書く(設定画面用)
-- ------------------------------------------------------------
create or replace function public.my_push_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'enabled', coalesce((select np.push_enabled from public.notification_prefs np
                         where np.user_id = auth.uid()), true),
    'quietFrom', (select np.push_quiet_from from public.notification_prefs np
                  where np.user_id = auth.uid()),
    'quietTo', (select np.push_quiet_to from public.notification_prefs np
                where np.user_id = auth.uid()),
    'devices', coalesce((select count(*) from public.push_subscriptions s
                         where s.user_id = auth.uid() and s.disabled_at is null), 0)
  );
$$;

revoke all on function public.my_push_settings() from public;
grant execute on function public.my_push_settings() to authenticated;

create or replace function public.set_push_settings(
  p_enabled boolean, p_quiet_from int default null, p_quiet_to int default null
)
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
  -- 片方だけ指定されたら「指定なし」に倒す(半端な状態を残さない)
  if p_quiet_from is null or p_quiet_to is null then
    p_quiet_from := null;
    p_quiet_to := null;
  end if;

  insert into public.notification_prefs (user_id, push_enabled, push_quiet_from, push_quiet_to)
  values (v_uid, coalesce(p_enabled, true), p_quiet_from::smallint, p_quiet_to::smallint)
  on conflict (user_id) do update
    set push_enabled = coalesce(p_enabled, true),
        push_quiet_from = p_quiet_from::smallint,
        push_quiet_to = p_quiet_to::smallint;
end;
$$;

revoke all on function public.set_push_settings(boolean, int, int) from public;
grant execute on function public.set_push_settings(boolean, int, int) to authenticated;
