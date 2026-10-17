-- ============================================================
-- 本番への適用 パート 3/4(0117〜0122)
-- tools/bundle-migrations.py で生成。手で直さないこと。
--
-- 1. このファイルの中身を全部 SQL Editor に貼って Run する
-- 2. docs/check-migrations.sql を流し、「次に適用するファイル」が
--    0122 の次(最後のパートなら「すべて適用済み」)になったことを確かめる
-- 3. エラーが出たら、そこで止めて内容を知らせる
--    (このパートの変更はまるごと取り消されている)
--
-- 先頭の関所は、順番の飛ばしと二重適用を止めるためのもの。
-- ============================================================

do $guard$
begin
  if not (exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'hidden_hosts')) then
    raise exception '順番が違います: 0116_hidden_hosts がまだ当たっていません。前のパートから流してください';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'platform_pricing' and column_name = 'activity_stats_min_plays') then
    raise exception 'このパートは適用済みです(0117_public_activity_stats が当たっています)。docs/check-migrations.sql で次に流すファイルを確かめてください';
  end if;
end $guard$;

-- >>>>>>>> 0117_public_activity_stats.sql
-- ============================================================
-- 0117: 未ログインの画面に「賑わい」を、個人を出さずに見せる
--
-- ■ なぜ
--   `public_host_cards`(0052)は在席・ボイス・空き枠を返さない。
--   **これは正しい設計**——未ログインの相手に「いま誰が居るか」を教えるのは
--   付きまといの材料になる。
--
--   ただし副作用として、初めて来た人には**誰も動いていないサイト**に見える。
--   ゲストが買いに来ているのは「確実性」なので、動いている形跡が
--   まったく見えないと、料金を見る前に引き返す。
--
-- ■ 出すもの / 出さないもの
--   出すのは**個人を特定できない集計だけ。**
--     ・対応タイトル数         … 掲載中のピタメイトが挙げているゲームの種類
--     ・掲載中のピタメイト数
--     ・今週成立した同行の件数
--     ・いま募集中の枠の数
--
--   出さないもの(0052 の判断をここで崩さない):
--     ・誰が居るか・誰が空いているか
--     ・特定の個人に紐づく数(この人は何件、など)
--     ・時間帯の分布(「深夜に何件」は在席の推定に使える)
--
-- ■ 数字が小さいうちは出さない
--   「今週2件」と出すのは、出さないより悪い。**信頼を作るつもりが
--   逆に働く。** そこで下限を置き、下回る項目は null を返す。
--   画面は null の項目を描かない。
--
--   下限は**運営コンソールから動かせる**(platform_pricing)。公開直後は
--   高めに置いて何も出さず、伸びてきたら下げる、という運用ができる。
--   ハードコードすると、その判断のたびに migration が要る。
--
-- ■ 対応タイトル数だけは下限をかけない
--   これは賑わいではなく**サービスの守備範囲**で、/about にも書いてある事実。
--   少なくても嘘にならない。
-- ============================================================

alter table public.platform_pricing
  add column if not exists activity_stats_min_plays int not null default 20,
  add column if not exists activity_stats_min_hosts int not null default 10;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'platform_pricing_activity_stats_check') then
    alter table public.platform_pricing
      add constraint platform_pricing_activity_stats_check check (
        activity_stats_min_plays between 0 and 1000
        and activity_stats_min_hosts between 0 and 1000
      );
  end if;
end $$;

comment on column public.platform_pricing.activity_stats_min_plays is
  '今週の同行件数を公開する下限(0117)。下回るあいだは出さない。0で常に出す。';
comment on column public.platform_pricing.activity_stats_min_hosts is
  'ピタメイト数・募集中の枠を公開する下限(0117)。下回るあいだは出さない。0で常に出す。';

-- ------------------------------------------------------------
-- 集計本体
--
-- **未ログインから呼べる。** 返すのは数だけで、行は一切返さない。
-- ------------------------------------------------------------
create or replace function public.public_activity_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_min_plays int;
  v_min_hosts int;
  v_games int;
  v_hosts int;
  v_plays int;
  v_slots int;
begin
  select coalesce(activity_stats_min_plays, 20), coalesce(activity_stats_min_hosts, 10)
    into v_min_plays, v_min_hosts
  from public.platform_pricing where id = 1;
  v_min_plays := coalesce(v_min_plays, 20);
  v_min_hosts := coalesce(v_min_hosts, 10);

  -- 掲載中で本人確認済みのピタメイトだけを母数にする。
  -- 掲載していない人を数に含めると、探しても出てこない人を数えることになる
  select count(*)::int into v_hosts
  from public.host_settings hs
  join public.profile_trust_stats ts
    on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
  where hs.is_host;

  select count(distinct g)::int into v_games
  from public.host_settings hs
  join public.profile_trust_stats ts
    on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
  cross join lateral unnest(hs.games) as g
  where hs.is_host;

  -- 「成立した同行」= 完了した予約。申請中・キャンセルは数えない
  -- (**申し込みの数を実績として出すと、実態より多く見える**)
  --
  -- 日付は `booking_slots`(0049)と同じ「実際に遊んだ時刻」で取る。
  -- ⚠️ `host_dashboard`(0034)は素の scheduled_at で期間を切っており、
  --    時間指定の予約を**申し込んだ日**で数えている。別物なので揃えていない
  --    (docs/open-issues.md に記録)。
  select count(*)::int into v_plays
  from public.bookings
  where status = 'completed'
    and coalesce(requested_start_at, scheduled_at) >= now() - interval '7 days'
    and coalesce(requested_start_at, scheduled_at) < now();

  select count(*)::int into v_slots
  from public.board_posts
  where status = 'open';

  return jsonb_build_object(
    'gameCount', v_games,
    'hostCount', case when v_hosts >= v_min_hosts then v_hosts end,
    'playsThisWeek', case when v_plays >= v_min_plays then v_plays end,
    'openSlots', case when v_hosts >= v_min_hosts then v_slots end
  );
end;
$$;

comment on function public.public_activity_stats() is
  '未ログインにも出せる集計(0117)。個人を特定できる情報は返さない(在席・空き枠は 0052 の判断どおり出さない)。'
  '下限を下回る項目は null。下限は platform_pricing で運営が動かす。';

revoke all on function public.public_activity_stats() from public;
grant execute on function public.public_activity_stats() to anon, authenticated;

-- ------------------------------------------------------------
-- 運営コンソールから下限を動かせるようにする
-- (0101 の「制限値」タブに2項目足すだけ)
-- ------------------------------------------------------------
create or replace function public.admin_platform_limits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p public.platform_pricing;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  select * into v_p from public.platform_pricing where id = 1;

  return jsonb_build_object(
    'newUser', jsonb_build_object(
      'days', v_p.new_user_days,
      'purchaseMaxYen', v_p.new_user_purchase_max_yen,
      'periodPurchaseMaxYen', v_p.new_user_period_purchase_max_yen,
      'payoutHoldDays', v_p.new_user_payout_hold_days
    ),
    'gift', jsonb_build_object(
      'maxPerTx', v_p.gift_max_per_tx,
      'maxPerDay', v_p.gift_max_per_day,
      'maxPerMonth', v_p.gift_max_per_month,
      'maxRecvMonth', v_p.gift_max_recv_month,
      'maxPairMonth', v_p.gift_max_pair_month,
      'windowDays', v_p.gift_window_days
    ),
    -- 0117: 未ログインに出す集計の下限
    'activityStats', jsonb_build_object(
      'minPlays', v_p.activity_stats_min_plays,
      'minHosts', v_p.activity_stats_min_hosts
    ),
    -- 天井(CHECK 制約と同じ値。片方だけ直すと画面が嘘をつく)
    'caps', jsonb_build_object(
      'newUserPayoutHoldDays', 30,
      'giftMaxPerTx', 100000,
      'giftMaxPerDay', 100000,
      'giftMaxPerMonth', 500000,
      'giftMaxRecvMonth', 2000000,
      'giftMaxPairMonth', 200000,
      'giftWindowDays', 90,
      'activityStatsMinPlays', 1000,
      'activityStatsMinHosts', 1000
    ),
    'updatedAt', v_p.updated_at
  );
end;
$$;

comment on function public.admin_platform_limits() is
  '運営コンソールの「制限値」タブ。現在値と、CHECK 制約が定める天井を返す。0117で公開集計の下限を追加。';

revoke all on function public.admin_platform_limits() from public, anon;
grant execute on function public.admin_platform_limits() to authenticated;

create or replace function public.admin_update_platform_limits(
  p_reason text,
  p_values jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_diff text := '';
  v_key text;
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object'
     or p_values = '{}'::jsonb then
    raise exception 'NO_CHANGES';
  end if;

  -- 知らないキーは黙って捨てない。**綴り間違いで「変えたつもり」に
  -- なるのが一番まずい**ので、その場で落とす
  for v_key in select jsonb_object_keys(p_values)
  loop
    if v_key not in (
      'newUserDays', 'newUserPurchaseMaxYen', 'newUserPeriodPurchaseMaxYen',
      'newUserPayoutHoldDays', 'giftMaxPerTx', 'giftMaxPerDay',
      'giftMaxPerMonth', 'giftMaxRecvMonth', 'giftMaxPairMonth',
      'giftWindowDays',
      'activityStatsMinPlays', 'activityStatsMinHosts'
    ) then
      raise exception 'UNKNOWN_KEY:%', v_key;
    end if;
  end loop;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days,
    'activityStatsMinPlays', activity_stats_min_plays,
    'activityStatsMinHosts', activity_stats_min_hosts
  ) into v_before
  from public.platform_pricing where id = 1;

  update public.platform_pricing set
    new_user_days = coalesce((p_values ->> 'newUserDays')::int, new_user_days),
    new_user_purchase_max_yen =
      coalesce((p_values ->> 'newUserPurchaseMaxYen')::int, new_user_purchase_max_yen),
    new_user_period_purchase_max_yen =
      coalesce((p_values ->> 'newUserPeriodPurchaseMaxYen')::int, new_user_period_purchase_max_yen),
    new_user_payout_hold_days =
      coalesce((p_values ->> 'newUserPayoutHoldDays')::int, new_user_payout_hold_days),
    gift_max_per_tx = coalesce((p_values ->> 'giftMaxPerTx')::int, gift_max_per_tx),
    gift_max_per_day = coalesce((p_values ->> 'giftMaxPerDay')::int, gift_max_per_day),
    gift_max_per_month = coalesce((p_values ->> 'giftMaxPerMonth')::int, gift_max_per_month),
    gift_max_recv_month = coalesce((p_values ->> 'giftMaxRecvMonth')::int, gift_max_recv_month),
    gift_max_pair_month = coalesce((p_values ->> 'giftMaxPairMonth')::int, gift_max_pair_month),
    gift_window_days = coalesce((p_values ->> 'giftWindowDays')::int, gift_window_days),
    activity_stats_min_plays =
      coalesce((p_values ->> 'activityStatsMinPlays')::int, activity_stats_min_plays),
    activity_stats_min_hosts =
      coalesce((p_values ->> 'activityStatsMinHosts')::int, activity_stats_min_hosts),
    updated_at = now()
  where id = 1;

  select jsonb_build_object(
    'newUserDays', new_user_days,
    'newUserPurchaseMaxYen', new_user_purchase_max_yen,
    'newUserPeriodPurchaseMaxYen', new_user_period_purchase_max_yen,
    'newUserPayoutHoldDays', new_user_payout_hold_days,
    'giftMaxPerTx', gift_max_per_tx,
    'giftMaxPerDay', gift_max_per_day,
    'giftMaxPerMonth', gift_max_per_month,
    'giftMaxRecvMonth', gift_max_recv_month,
    'giftMaxPairMonth', gift_max_pair_month,
    'giftWindowDays', gift_window_days,
    'activityStatsMinPlays', activity_stats_min_plays,
    'activityStatsMinHosts', activity_stats_min_hosts
  ) into v_after
  from public.platform_pricing where id = 1;

  for v_key in select jsonb_object_keys(v_after)
  loop
    if (v_before ->> v_key) is distinct from (v_after ->> v_key) then
      v_diff := v_diff || case when v_diff = '' then '' else ' / ' end
        || v_key || ': ' || (v_before ->> v_key) || '→' || (v_after ->> v_key);
    end if;
  end loop;

  if v_diff = '' then
    raise exception 'NO_CHANGES';
  end if;

  perform public._log_admin_action('update_platform_limits', null,
    v_diff || ' 理由: ' || p_reason);

  return jsonb_build_object('changed', v_diff, 'values', v_after);
end;
$$;

comment on function public.admin_update_platform_limits(text, jsonb) is
  '制限値の変更。天井は platform_pricing の CHECK 制約が持つ。理由は必須で、前後の値とともに admin_actions に残る(0101、0117で公開集計の下限を追加)。';

revoke all on function public.admin_update_platform_limits(text, jsonb) from public, anon;
grant execute on function public.admin_update_platform_limits(text, jsonb) to authenticated;


-- >>>>>>>> 0118_admin_message_moderation.sql
-- ============================================================
-- 0118: トークのメッセージを運営が削除できるようにする
--
-- ■ なぜ
--   通報は受け取れる（`admin_reports` が `message_snapshot` を返す）のに、
--   **その中身を消す手段が無かった。** `docs/admin-console.md` の
--   「まだ画面が無いもの」に、唯一「手段がありません」と書いてある項目。
--
--   募集は 0112 で取り下げられるようになったが、トークは残っていた。
--   外部への誘導・金銭の要求・嫌がらせの文言が通報されても、運営にできるのは
--   利用停止だけで、**相手の画面に残った文言はそのまま**になる。
--
-- ■ 行は消さない（0112 と同じ）
--   通報の裏取り・異議申立て・チャージバックの立証に要る。
--   `deleted_at` を立てて「消えた事実」を残す。
--
-- ■ ★本文はDBから消し、証跡は運営しか読めない場所へ移す
--   `deleted_at` を立てるだけだと、**本文は messages に残ったまま**で、
--   相手のクライアントにも普通に届く（画面が読み込む select は
--   `body` をそのまま取っている）。画面側で隠す実装にすると、
--   「隠しているだけで送信はしている」状態になる。
--
--   そこで本文は `message_deletions`（運営のみ）へ移し、
--   `messages.body` は空にする。**CHECK 制約で、削除済みなら本文が
--   空であることを強制する**ので、実装の抜けで本文が残ることがない。
--
-- ■ 消えたことは相手にも見せる（黙って消さない）
--   黙って消すと、受け取った側は会話の流れが飛んで混乱し、
--   送った側は何が悪かったのか分からないまま同じことを繰り返す。
--   画面には「運営が削除しました」を出し、**送信者には理由つきで通知**する
--   （規約 第10条の2 6項。0112 の板の取り下げと同じ扱い）。
--
-- ■ 読むこと自体を記録する
--   スレッドを開く関数は、**中身を見た事実を admin_actions に残す**。
--   0068 が `admin_reports` に入れた仕組みと同じ。
--   運営がトークを自由に読める仕組みを作る以上、記録が無い状態にはしない。
-- ============================================================

alter table public.messages
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_reason text,
  add column if not exists deleted_by uuid references auth.users (id) on delete set null;

comment on column public.messages.deleted_at is
  '運営が削除した日時(0118)。入っていると本文は空で、原文は message_deletions にある。';

-- ★削除済みなら本文が残っていないことを、制約で保証する。
--   画面側の実装に依存させない
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages
  add constraint messages_body_check check (
    (deleted_at is null and char_length(body) between 1 and 2000)
    or (deleted_at is not null and char_length(body) = 0)
  );

create index if not exists messages_deleted_idx
  on public.messages (promise_id) where deleted_at is not null;

-- ------------------------------------------------------------
-- 原文の保管（運営のみ）
-- ------------------------------------------------------------
create table if not exists public.message_deletions (
  message_id uuid primary key references public.messages (id) on delete cascade,
  promise_id uuid not null,
  sender_id uuid,
  body text not null,
  reason text not null,
  deleted_by uuid references auth.users (id) on delete set null,
  deleted_at timestamptz not null default now()
);

comment on table public.message_deletions is
  '運営が削除したメッセージの原文(0118)。通報の裏取り・異議申立ての立証に使う。'
  '当事者には見せない(消したものを別の場所から読めては、消した意味が無い)。';

alter table public.message_deletions enable row level security;
-- ポリシーを1つも作らない = 運営の security definer 関数からしか読めない

-- ------------------------------------------------------------
-- 通報された相手のトークを探す
-- ------------------------------------------------------------
-- reports は promise_id を持たないので、通報から直接スレッドへ辿れない。
-- 相手のIDから、その人が参加しているスレッドを引けるようにする。
create or replace function public.admin_user_threads(
  p_user_id uuid,
  p_limit int default 30
)
returns table (
  promise_id uuid,
  other_id uuid,
  other_nickname text,
  message_count int,
  last_message_at timestamptz,
  status text
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
  select pr.id,
         case when pr.user_a = p_user_id then pr.user_b else pr.user_a end,
         coalesce(nullif(p.nickname, ''), '(不明)'),
         (select count(*)::int from public.messages m where m.promise_id = pr.id),
         (select max(m.created_at) from public.messages m where m.promise_id = pr.id),
         pr.status
  from public.promises pr
  left join public.profiles p
    on p.id = case when pr.user_a = p_user_id then pr.user_b else pr.user_a end
  where pr.user_a = p_user_id or pr.user_b = p_user_id
  order by (select max(m.created_at) from public.messages m where m.promise_id = pr.id) desc nulls last
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$$;

comment on function public.admin_user_threads(uuid, int) is
  'その人が参加しているトークの一覧(0118)。中身は返さない(件数と最終発言だけ)ので、ここでは閲覧記録を残さない。';

revoke all on function public.admin_user_threads(uuid, int) from public, anon;
grant execute on function public.admin_user_threads(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- スレッドの中身を読む ★閲覧を記録する
-- ------------------------------------------------------------
create or replace function public.admin_thread_messages(
  p_promise_id uuid,
  p_limit int default 200
)
returns table (
  id uuid,
  sender_id uuid,
  sender_nickname text,
  body text,
  created_at timestamptz,
  deleted_at timestamptz,
  deleted_reason text
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

  select count(*)::int into v_n from public.messages m where m.promise_id = p_promise_id;

  -- 0068 と同じ。**中身を見た事実を残す。**
  perform public._log_admin_action(
    'view_thread', p_promise_id,
    '該当' || v_n || '件のメッセージを表示');

  return query
  select m.id,
         m.sender_id,
         coalesce(nullif(p.nickname, ''), '(不明)'),
         -- 削除済みは原文を返さない。運営でも、消したものは一覧では読まない
         -- (立証で要るときは message_deletions を直接見る)
         case when m.deleted_at is null then m.body else '' end,
         m.created_at,
         m.deleted_at,
         m.deleted_reason
  from public.messages m
  left join public.profiles p on p.id = m.sender_id
  where m.promise_id = p_promise_id
  order by m.created_at
  limit greatest(1, least(coalesce(p_limit, 200), 500));
end;
$$;

comment on function public.admin_thread_messages(uuid, int) is
  'トークの中身(運営)。**閲覧すると admin_actions に記録が残る**(0068と同じ)。削除済みの原文は返さない。';

revoke all on function public.admin_thread_messages(uuid, int) from public, anon;
grant execute on function public.admin_thread_messages(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 削除する
-- ------------------------------------------------------------
create or replace function public.admin_remove_message(
  p_message_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m public.messages;
begin
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;
  -- 理由は必須。あとから「なぜ消したか」を説明できない削除を作らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_m from public.messages where id = p_message_id for update;
  if v_m.id is null then
    raise exception 'MESSAGE_NOT_FOUND';
  end if;

  -- 連打しても2度目は何もしない(通知が増えない)
  if v_m.deleted_at is not null then
    return;
  end if;

  insert into public.message_deletions
    (message_id, promise_id, sender_id, body, reason, deleted_by)
  values
    (v_m.id, v_m.promise_id, v_m.sender_id, v_m.body, btrim(p_reason), auth.uid());

  update public.messages
    set body = '',
        deleted_at = now(),
        deleted_reason = btrim(p_reason),
        deleted_by = auth.uid()
    where id = p_message_id;

  -- ★送信者には理由を渡す。渡さないと同じことをもう一度書く
  insert into public.notifications (user_id, type, title, body)
  values (v_m.sender_id, 'system', 'メッセージを削除しました',
          '送信したメッセージを運営が削除しました。理由：' || btrim(p_reason)
          || E'\n利用規約に反する内容が続く場合、アカウントの利用を停止することがあります。');

  perform public._log_admin_action('message_removed', p_message_id,
    btrim(p_reason));
end;
$$;

comment on function public.admin_remove_message(uuid, text) is
  'トークのメッセージを運営が削除する(0118)。行は残し、本文は message_deletions へ移す。理由必須。送信者に理由つきで通知(規約 第10条の2 6項)。';

revoke all on function public.admin_remove_message(uuid, text) from public, anon;
grant execute on function public.admin_remove_message(uuid, text) to authenticated;


-- >>>>>>>> 0119_residency_for_guests.sql
-- ============================================================
-- 0119: 居住地の確認をゲストにも効かせ、購入時の居住国を記録する
--
-- ■ 見つかった穴
--   規約 第3条3項は「本サービスは、**日本国内に居住する個人**に限り」と、
--   サービス全体を限っている。ところが `0081` の強制は
--   `identity_verifications` の INSERT トリガー**1か所だけ**だった。
--
--     ピタメイト(本人確認を出す人) … 申告を求め、「いいえ」なら止める
--     ゲスト(本人確認を出さない人) … **申告の機会が無く、素通り**
--
--   `declare_residency` を呼ぶ画面は本人確認の1か所だけで、予約も
--   `create_booking` が見るのは `HOST_NOT_VERIFIED`(ホスト側)だけ。
--   突合表では G4 を「✅実装」としていたが、**効いていたのは
--   ピタメイト側だけ**だった。
--
-- ■ どこで止めるか — 購入の1か所にする
--   予約にも足すことはできるが、**コインは購入からしか生まれない**
--   (0083 で購入ボーナスを廃止済み)。購入を止めれば、申告していない人は
--   役務を受けられない。
--
--   そして購入は、止める理由がいちばん強い場所でもある。
--     ・お金が動く手前で止まる
--     ・消費税の内外判定・消費者契約の準拠法が効いてくるのは、まさにここ
--     ・Edge Function が既に `allowed/code` を画面へ返す仕組みを持っている
--
--   **例外を投げず、既存の `allowed:false + code` の形に合わせる。**
--   別の形にすると、画面側にもう1本エラー処理が要る。
--
-- ■ 購入時の居住国を残す理由(★あとから遡れない)
--   消費税法4条3項3号の内外判定は「役務の提供を受ける者の住所等」で決まる。
--   海外の利用者への販売は**国外取引＝不課税**になるので、売上の区分が要る。
--   免税事業者のあいだは影響が小さいが、**課税事業者になってから
--   過去の購入を遡って区分することはできない。**
--
--   いまは日本限定なので、記録される値は当面すべて 'JP' になる。
--   それでよい。**器と経路を先に作っておくのが目的**で、開く判断をした
--   その日から正しく区分できる状態にしておく。
--
--   あわせて **決済された国**(Stripe の発行国)も残す。申告と食い違う購入は、
--   税務の区分だけでなく不正の手がかりにもなる。
--
-- ⚠️ この migration は**日本限定をやめるものではない。**
--    規約 第3条3項はそのまま。開くかどうかは弁護士・税理士の回答待ち
--    (`docs/legal/open-legal-matters.md` C-2)。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 申告に国を持たせる
--
-- いまは boolean(日本かどうか)だけ。開く判断をしたときに
-- 「どの国か」が要るので、器だけ先に作る。
-- ------------------------------------------------------------
alter table public.residency_declarations
  add column if not exists country_code text;

alter table public.residency_declarations
  drop constraint if exists residency_declarations_country_check;
alter table public.residency_declarations
  add constraint residency_declarations_country_check check (
    country_code is null or country_code ~ '^[A-Z]{2}$'
  );

comment on column public.residency_declarations.country_code is
  '申告された居住国(ISO 3166-1 alpha-2)。0119で追加。日本限定のあいだは JP か null。';

create or replace function public.declare_residency(
  p_declared_japan boolean,
  p_version text default 'v1',
  p_country_code text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_country text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_declared_japan is null then
    raise exception 'DECLARATION_REQUIRED';
  end if;

  -- 「日本に居住している」と答えたなら国は JP。取り違えを持ち込まない
  v_country := case
    when p_declared_japan then 'JP'
    else nullif(upper(btrim(coalesce(p_country_code, ''))), '')
  end;

  insert into public.residency_declarations
    (user_id, declared_japan, version, country_code)
  values (v_uid, p_declared_japan,
          coalesce(nullif(btrim(p_version), ''), 'v1'),
          v_country);
end;
$$;

comment on function public.declare_residency(boolean, text, text) is
  '居住地の自己申告を記録する(規約第3条3項)。上書きせず履歴として積む。0119で国コードを追加。';

revoke all on function public.declare_residency(boolean, text, text) from public;
grant execute on function public.declare_residency(boolean, text, text) to authenticated;

-- 引数が増えたので、古い2引数版は落とす。
-- **残すと画面が古いほうを呼び続け、国が記録されない**
drop function if exists public.declare_residency(boolean, text);

-- ------------------------------------------------------------
-- 2. いまの申告を1か所で読む
-- ------------------------------------------------------------
create or replace function public.residency_ok(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select d.declared_japan
       from public.residency_declarations d
      where d.user_id = p_user_id
      order by d.declared_at desc
      limit 1),
    false);
$$;

comment on function public.residency_ok(uuid) is
  '最新の申告が「日本国内に居住」か。未申告は false(0119)。';

revoke all on function public.residency_ok(uuid) from public, anon;
grant execute on function public.residency_ok(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. 購入を、申告が済むまで通さない
--
-- **例外ではなく allowed:false で返す。** Edge Function が既に
-- code を画面へ渡す形になっているので、そこに乗せる。
-- 未申告と「いいえ」を分けるのは 0081 と同じ理由(画面の文言が違う)。
-- ------------------------------------------------------------
create or replace function public.check_purchase_allowed(p_user_id uuid, p_price_yen int)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_per int;
  v_remaining bigint;
  v_declared boolean;
begin
  -- 0119: 居住地の確認を最初に見る。上限の話より前に、そもそも
  -- 利用できる人かどうかが決まる
  select d.declared_japan into v_declared
  from public.residency_declarations d
  where d.user_id = p_user_id
  order by d.declared_at desc
  limit 1;

  if v_declared is null then
    return jsonb_build_object('allowed', false, 'code', 'RESIDENCY_NOT_DECLARED');
  end if;
  if not v_declared then
    return jsonb_build_object('allowed', false, 'code', 'RESIDENCY_OUTSIDE_JAPAN');
  end if;

  v := public.purchase_limit_status(p_user_id);
  if not (v->>'is_new_user')::boolean then
    return jsonb_build_object('allowed', true);
  end if;

  v_per := (v->>'per_purchase_max_yen')::int;
  v_remaining := (v->>'remaining_yen')::bigint;

  if p_price_yen > v_per then
    return jsonb_build_object(
      'allowed', false,
      'code', 'PURCHASE_LIMIT_PER',
      'limit_yen', v_per,
      'remaining_yen', v_remaining,
      'period_days', (v->>'period_days')::int);
  end if;

  if p_price_yen > v_remaining then
    return jsonb_build_object(
      'allowed', false,
      'code', 'PURCHASE_LIMIT_PERIOD',
      'limit_yen', (v->>'period_max_yen')::int,
      'remaining_yen', v_remaining,
      'period_days', (v->>'period_days')::int);
  end if;

  return jsonb_build_object('allowed', true);
end;
$$;

comment on function public.check_purchase_allowed(uuid, int) is
  '買ってよいかの判定。0119で居住地の確認を追加(規約第3条3項)。決済の前に呼ぶこと——代金を受け取ってから弾くのは、防ごうとしている損失より重い事故になる。';

revoke all on function public.check_purchase_allowed(uuid, int) from public, anon, authenticated;
grant execute on function public.check_purchase_allowed(uuid, int) to service_role;

-- ------------------------------------------------------------
-- 4. 購入に「どこの人が買ったか」を残す
-- ------------------------------------------------------------
alter table public.coin_purchases
  add column if not exists buyer_country text,
  add column if not exists payment_country text;

comment on column public.coin_purchases.buyer_country is
  '購入時点の申告に基づく居住国(0119)。消費税法4条3項3号の内外判定の材料。'
  '**あとから遡って区分できないので、日本限定のあいだも記録する。**';
comment on column public.coin_purchases.payment_country is
  'Stripe が返した決済の国(カードの発行国など。0119)。申告と食い違う購入は不正の手がかりにもなる。';

-- 付与のときに、そのときの申告から書く。
-- **引数は増やさない。** 引数を変えると、migration の適用と Edge Function の
-- デプロイの順序が前後したときに付与そのものが落ちる(0104 と同じ判断)。
create or replace function public.credit_coins_for_purchase(
  p_user_id uuid,
  p_pack_id text,
  p_coins int,
  p_bonus_coins int,
  p_price_yen int,
  p_session_id text,
  p_payment_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
  v_purchase_id uuid;
  v_country text;
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 冪等性: 同じ session を二度処理しない
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  -- 0083: 購入ボーナスは廃止した。**引数は無視する。**
  if coalesce(p_bonus_coins, 0) <> 0 then
    raise notice '0083: 購入ボーナスは廃止済みのため無視しました(session=%, bonus=%)',
      p_session_id, p_bonus_coins;
  end if;

  -- 0119: 購入時点の申告国。**ここで確定させる。**
  -- あとで申告が変わっても、この購入がどこ向けだったかは動かない
  select case when d.declared_japan then coalesce(d.country_code, 'JP') else d.country_code end
    into v_country
  from public.residency_declarations d
  where d.user_id = p_user_id
  order by d.declared_at desc
  limit 1;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent,
     buyer_country)
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent,
     v_country)
    returning id into v_purchase_id;

  update public.coin_wallets
    set balance = balance + p_coins
    where user_id = p_user_id;

  insert into public.coin_lots (user_id, kind, remaining, expires_at, purchase_id)
    values (p_user_id, 'paid', p_coins, v_expires, v_purchase_id);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$fn$;

comment on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) is
  'Webhook から呼ぶ冪等なコイン付与(service_role専用)。0083で購入ボーナスを廃止(引数は互換のため残す)。0087でロットに購入を紐づけ、0119で購入時点の居住国を記録する。';

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- 5. 追記専用トリガーに payment_country を通す
--
-- 0104 と同じ理由。webhook が決済成立後に一度だけ書く列を足すので、
-- **その列だけ**初回の書き込みを許す。金額・ユーザー・セッションIDは
-- 従来どおり変更できない。
--
-- ⚠️ **本体は 0104 のものをそのまま持ってきて、payment_country の分だけ
--    足している。** 記憶で書き直したところ safety_fee_yen の上書き禁止と
--    DELETE の分岐を落としており、テスト28 が拾った。
--    トリガーを差し替えるときは、必ず前の版から差分で作ること。
-- ------------------------------------------------------------
create or replace function public._purchase_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rest_old jsonb;
  v_rest_new jsonb;
begin
  -- 明示的な解除は従来どおり通す(記録つき)
  if public._ledger_override_on() then
    perform public._ledger_record_bypass(
      TG_TABLE_NAME, TG_OP,
      to_jsonb(OLD),
      case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);
    if TG_OP = 'DELETE' then return OLD; end if;
    return NEW;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases の行は削除できません。訂正が必要な場合は打ち消しの行を追加してください。';
  end if;

  -- webhook が決済成立後に書く3列だけを、書き込み1回に限って通す(0119で1列追加)。
  -- 「同値の再書き込み」を許すのは、Stripe が同じイベントを再送するため
  -- (冪等な再実行を例外にしない)。
  v_rest_old := to_jsonb(OLD) - 'safety_fee_yen' - 'payment_method' - 'payment_country';
  v_rest_new := to_jsonb(NEW) - 'safety_fee_yen' - 'payment_method' - 'payment_country';
  if v_rest_old <> v_rest_new then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases は追記専用です(変更できるのは safety_fee_yen / payment_method / payment_country の初回書き込みだけ)。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。';
  end if;
  if NEW.safety_fee_yen is distinct from OLD.safety_fee_yen
     and OLD.safety_fee_yen <> 0 then
    raise exception 'LEDGER_IMMUTABLE: safety_fee_yen は一度しか書き込めません(現在値 %)', OLD.safety_fee_yen;
  end if;
  if NEW.payment_method is distinct from OLD.payment_method
     and OLD.payment_method is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_method は一度しか書き込めません(現在値 %)', OLD.payment_method;
  end if;
  -- 0119: 決済国も一度だけ
  if NEW.payment_country is distinct from OLD.payment_country
     and OLD.payment_country is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_country は一度しか書き込めません(現在値 %)', OLD.payment_country;
  end if;

  return NEW;
end;
$$;

comment on function public._purchase_immutable() is
  'coin_purchases の不変トリガー。0044 の全面禁止から、webhook が決済成立後に書く safety_fee_yen / payment_method / payment_country の初回書き込みだけを通す形に緩めた(0104、0119)。金額・ユーザー・セッションIDは従来どおり変更できない。';


-- >>>>>>>> 0120_guest_requests.sql
-- ============================================================
-- 0120: ゲストのリクエスト（板に出さずに、条件の合う相手にだけ届ける）
--
-- ■ なぜ要るか
--   `0113` で募集板を**ピタメイト専用**に作り直した。判断そのものは正しい
--   （無料で遊べる経路を board に作ると、いちばん使われる導線がその抜け道に
--   なる）が、副作用として**ゲストが「遊びたい」と言える場所が消えた。**
--
--   いまゲストにできるのは「開いている枠を探す」だけ。開いていなければ、
--   何も起きずに離脱する。ピタメイト側からは**その離脱がまったく見えない。**
--   需要と供給が、互いに見えないまますれ違っている。
--
-- ■ 設計の芯：**板には載せない**
--   リクエストは公開の掲示板ではない。条件に合うピタメイトへ**通知として**
--   届き、応じた人の分だけがリクエストした本人に見える。
--
--     ゲスト  「金曜21時ごろ・Apex・60分」でリクエストを出す
--       ↓ 通知（ゲームが一致するピタメイトへ）
--     ピタメイト  「21:00からなら空けられます」と応じる
--       ↓ 通知（リクエストした本人へ）
--     ゲスト  出てきた候補から**通常どおり予約する**（＝有償の入口を必ず通る）
--
--   板に載せてしまうと、そこが「無料で相手を募る場所」になり、0113 が閉じた
--   抜け道が形を変えて戻ってくる。**リクエストは予約の入口であって、
--   遊びの場ではない。**
--
-- ■ ★「応じる」で枠が開く仕組み（ここが実装のいちばんの勘所）
--   素直に作るなら「応じたら host_availability に足す」だが、
--   `host_availability` は**毎週くり返す**設定なので、1回のリクエストに
--   応じただけで「毎週金曜21時が空き枠」になってしまう。本人が頼んでいない
--   永続的な変更で、あとから消す導線も無い。
--
--   そこで**応じた行そのものを「開いている」根拠にする。**
--     `host_is_open_at` に「open のリクエストへの応答が、この時刻を覆っているか」
--     を足す。リクエストが成立/取消/期限切れになれば status が open でなくなり、
--     **開けた枠は自動的に閉じる。** 掃除の cron も、後始末の帳簿も要らない。
--
--   同じ理由で `slot_open_to`（0057 の常連先行）にも足す。ピタメイトが
--   その人に向けて明示的に応じたのに「常連ではない」で弾かれるのは、
--   本人の意思と矛盾する。**判定は 2 つとも既存の1か所に足す**——
--   写して増やすと必ずズレる（0115 で確認した方針）。
--
--   ⚠️ `host_is_open_at` は相手を取らないので、**応じて開いた時間は
--      ほかの人からも予約できる。** これは仕様。「応じる＝その時間を開ける」
--      であって「その人のために取り置く」ではない。画面でもそう書く。
--
-- ■ 開始時刻を「毎正時」に限る理由
--   `booking_fits_availability`(0051) は、予約が触る**時間の枡**を1つずつ見る。
--   21:30 開始・60分の予約は 21時台と22時台の両方を要求する。応じた行の範囲を
--   21:30〜22:30 のまま使うと、21時台が「開いていない」ことになって
--   **応じたのに予約できない**が起きる。毎正時に揃えれば枡と範囲が一致する。
--   （30分刻みの選択は、もともと枠に収まる範囲でしか意味を持たない）
--
-- ■ 通知を送る相手を、空き時間で絞らないこと
--   「範囲に空きがある人だけに送る」は一見親切だが、**それはゲストが探す画面
--   (0115)ですでに見つけられる人**である。リクエストは、その画面に出てこな
--   かったから出されている。絞ると意味が消える。
--   代わりに **登録ゲームの一致**で絞り、1件あたりの宛先に上限を置く。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 通知の種別を足す（既存を欠かさないこと）
-- ------------------------------------------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in (
    'invite_received', 'invite_approved', 'message_received',
    'verification_approved', 'verification_rejected', 'board_joined',
    'booking_cancelled', 'booking_completed', 'booking_requested',
    'booking_approved', 'gift_received', 'booking_extended',
    'board_cancelled', 'integrity_alert', 'booking_no_show',
    'host_slots_opened', 'system',
    -- 0120
    'guest_request_received',   -- ピタメイトへ：条件の合うリクエストが出た
    'guest_request_answered'));  -- ゲストへ：応じた人が出た

-- ------------------------------------------------------------
-- 2. リクエスト本体
-- ------------------------------------------------------------
create table if not exists public.guest_requests (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null references auth.users (id) on delete cascade,
  game text not null,
  -- **範囲は必須。** 板(0114)は「相談で」を許すが、こちらは
  -- 「いつ空ければいいのか」が伝わらないとピタメイトが動けない
  window_start timestamptz not null,
  window_end timestamptz not null,
  duration_minutes int not null default 60,
  note text not null default '',
  status text not null default 'open'
    check (status in ('open', 'matched', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  close_reason text,
  constraint guest_requests_window_ok check (window_end > window_start),
  constraint guest_requests_duration_ok check (public.is_valid_booking_duration(duration_minutes)),
  constraint guest_requests_game_len check (char_length(game) between 1 and 60),
  constraint guest_requests_note_len check (char_length(note) <= 300)
);

comment on table public.guest_requests is
  'ゲストが「この日時・このゲーム・この長さで遊びたい」と出すリクエスト(0120)。'
  '**板には載せない。**条件の合うピタメイトへ通知として届き、応じた人だけが本人に見える。'
  '成立は通常の予約(create_booking)を通る——無料で遊べる経路を作らないため(0113)。';

comment on column public.guest_requests.window_end is
  '受付の終わり。過ぎると expire_guest_requests が expired にし、'
  '応じて開いていた枠もその時点で閉じる(host_is_open_at が open しか見ないため)。';

alter table public.guest_requests enable row level security;

-- **自分の出したものしか見えない。** 一覧は関数(guest_requests_for_host)で配る。
-- 直接 select させると、条件に合わない人にも他人の予定が読めてしまう
create policy "guest_requests_select_own"
  on public.guest_requests for select
  to authenticated
  using (guest_id = auth.uid());

-- insert / update のポリシーは置かない。**RPC が唯一の入口**にする
-- （リードタイム・件数上限・同意の検査を画面の実装に依存させない）

create index if not exists guest_requests_open_idx
  on public.guest_requests (status, window_start) where status = 'open';
create index if not exists guest_requests_guest_idx
  on public.guest_requests (guest_id, created_at desc);

-- みまもりの同意を撤回した人はリクエストを出せない（0074 と揃える）
create or replace function public._guest_requests_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.guest_id, null);
  return new;
end;
$$;

revoke all on function public._guest_requests_require_consent() from public, anon;

drop trigger if exists guest_requests_require_consent on public.guest_requests;
create trigger guest_requests_require_consent
  before insert on public.guest_requests
  for each row execute function public._guest_requests_require_consent();

-- ------------------------------------------------------------
-- 3. 応じた記録
--
--    この行が「その時間が開いている」根拠そのものになる（冒頭参照）。
-- ------------------------------------------------------------
create table if not exists public.guest_request_responses (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.guest_requests (id) on delete cascade,
  host_id uuid not null references auth.users (id) on delete cascade,
  starts_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (request_id, host_id),
  -- 毎正時に揃える（冒頭「開始時刻を毎正時に限る理由」）。
  -- **date_trunc(timestamptz) は stable なので CHECK に書けない。**
  -- 一度 timestamp に落とせば immutable になる。日本時間の時差は
  -- ちょうど9時間なので、UTC で正時なら日本時間でも正時
  constraint guest_request_responses_on_the_hour
    check (starts_at = date_trunc('hour', starts_at at time zone 'UTC') at time zone 'UTC')
);

comment on table public.guest_request_responses is
  'リクエストに応じたピタメイトと、その開始時刻(0120)。'
  '**この行自体が「その時間を開けている」根拠**で、host_is_open_at と slot_open_to が見る。'
  'リクエストが open でなくなれば、開けた枠も同時に閉じる。';

alter table public.guest_request_responses enable row level security;

-- 応じた本人と、リクエストを出した本人だけが見える
create policy "guest_request_responses_select_involved"
  on public.guest_request_responses for select
  to authenticated
  using (
    host_id = auth.uid()
    or exists (
      select 1 from public.guest_requests q
      where q.id = guest_request_responses.request_id and q.guest_id = auth.uid()
    )
  );

create index if not exists guest_request_responses_host_idx
  on public.guest_request_responses (host_id, starts_at);

-- ------------------------------------------------------------
-- 4. 予約との紐づけ（0113 の from_board_post_id と同じ考え方）
-- ------------------------------------------------------------
alter table public.bookings
  add column if not exists from_guest_request_id uuid
    references public.guest_requests (id) on delete set null;

comment on column public.bookings.from_guest_request_id is
  'リクエストから成立した予約は、そのリクエストを指す(0120)。';

create index if not exists bookings_from_guest_request_idx
  on public.bookings (from_guest_request_id) where from_guest_request_id is not null;

-- ------------------------------------------------------------
-- 5. ★判定を既存の1か所に足す
-- ------------------------------------------------------------
/**
 * 応じた行が、その時刻を覆っているか。
 * host_is_open_at と slot_open_to の両方から呼ぶので、条件を1か所に書く。
 * **どちらか片方だけ直すとズレる。**
 */
create or replace function public._request_response_covers(
  p_host_id uuid,
  p_at timestamptz,
  p_guest_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.guest_request_responses r
    join public.guest_requests q on q.id = r.request_id
    where r.host_id = p_host_id
      -- **open だけ。** 成立/取消/期限切れになった時点で枠は閉じる
      and q.status = 'open'
      and (p_guest_id is null or q.guest_id = p_guest_id)
      and p_at >= r.starts_at
      and p_at < r.starts_at + make_interval(mins => q.duration_minutes)
  );
$$;

comment on function public._request_response_covers(uuid, timestamptz, uuid) is
  'リクエストに応じて開けた時間が、その時刻を覆っているか(0120)。'
  'p_guest_id を渡すと、その人が出したリクエストへの応答だけを見る。';

revoke all on function public._request_response_covers(uuid, timestamptz, uuid) from public, anon;

-- 0051 の本体に、応答ぶんを足すだけ。**シグネチャは変えない**
-- （booking_fits_availability・hosts_open_at・host_schedule がそのまま乗る）
create or replace function public.host_is_open_at(p_host_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not public.host_has_availability(p_host_id) then true
    else exists (
      select 1 from public.host_availability a
      where a.user_id = p_host_id
        and a.weekday = extract(dow from (p_at at time zone 'Asia/Tokyo'))::smallint
        and a.hour = extract(hour from (p_at at time zone 'Asia/Tokyo'))::smallint
    )
    -- 0120: リクエストに応じて開けた時間。**相手は問わない**
    -- （「応じる＝その時間を開ける」であって、取り置きではない）
    or public._request_response_covers(p_host_id, p_at)
  end;
$$;

comment on function public.host_is_open_at(uuid, timestamptz) is
  'その時刻が募集枠の中か。枠を設定していないピタメイトは常に受け付ける(true)。'
  '0120で「ゲストのリクエストに応じて開けた時間」も開いている扱いにした。';

revoke all on function public.host_is_open_at(uuid, timestamptz) from public, anon;
grant execute on function public.host_is_open_at(uuid, timestamptz) to authenticated;

-- 0057 の本体に、応答ぶんを足すだけ。こちらは**その人に向けた応答だけ**を見る
create or replace function public.slot_open_to(p_host_id uuid, p_guest_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_guest_id is null then false
    -- 0120: 本人のリクエストに応じているなら、先行予約の期間中でも通す。
    -- **ピタメイトが名指しで応じたのに常連判定で弾くのは、本人の意思と矛盾する**
    when public._request_response_covers(p_host_id, p_at, p_guest_id) then true
    -- 先行予約を使っていなければ従来どおり
    when coalesce((select h.regulars_first_hours from public.host_settings h
                   where h.user_id = p_host_id), 0) = 0 then true
    -- 開始が近づいたら誰でも取れる
    when p_at <= now() + make_interval(
           hours => (select h.regulars_first_hours from public.host_settings h
                     where h.user_id = p_host_id)) then true
    else public._played_together_count(p_host_id, p_guest_id) > 0
  end;
$$;

comment on function public.slot_open_to(uuid, uuid, timestamptz) is
  'その時刻の枠を、この人がいま予約できるか。先行予約の期間中は一緒に遊んだことのある人だけ true。'
  '0120で「本人のリクエストに応じた枠」を例外にした。';

revoke all on function public.slot_open_to(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.slot_open_to(uuid, uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 6. リクエストを出す
-- ------------------------------------------------------------
create or replace function public.create_guest_request(
  p_game text,
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_duration_minutes int default 60,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 同時に開けるリクエストの数。**上限が無いと、1人で全ピタメイトの通知を
  -- 埋められる。** 3件あれば「今夜」「週末」「来週」を並べるには足りる
  c_max_open constant int := 3;
  -- 1件あたりの宛先の上限。掲載人数が増えたときに、1回のリクエストが
  -- 全員へ届くのを避ける
  c_max_notify constant int := 50;
  -- 範囲の広さの上限。広すぎる範囲は「いつでもいい」と同じで、
  -- 応じた枠が長時間開きっぱなしになる
  c_max_span constant interval := interval '7 days';
  v_uid uuid := auth.uid();
  v_id uuid;
  v_game text;
  v_note text;
  v_min_lead int;
  v_max_lead int;
  v_open int;
  v_name text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  v_game := nullif(btrim(coalesce(p_game, '')), '');
  if v_game is null then
    raise exception 'GAME_REQUIRED';
  end if;
  if not public.is_valid_booking_duration(p_duration_minutes) then
    raise exception 'INVALID_DURATION';
  end if;
  if p_window_start is null or p_window_end is null then
    raise exception 'WINDOW_REQUIRED';
  end if;

  select min_lead_minutes, max_lead_days into v_min_lead, v_max_lead
  from public.platform_pricing where id = 1;
  v_min_lead := coalesce(v_min_lead, 30);
  v_max_lead := coalesce(v_max_lead, 35);

  -- 予約が受け付けられない範囲でリクエストを出させない。
  -- **出せてしまうと、応じた側が予約されない枠を開けることになる**
  if p_window_start < now() + make_interval(mins => v_min_lead) then
    raise exception 'WINDOW_TOO_SOON';
  end if;
  if p_window_end > now() + make_interval(days => v_max_lead) then
    raise exception 'WINDOW_TOO_FAR';
  end if;
  if p_window_end - p_window_start < make_interval(mins => p_duration_minutes) then
    raise exception 'WINDOW_TOO_SHORT';
  end if;
  if p_window_end - p_window_start > c_max_span then
    raise exception 'WINDOW_TOO_WIDE';
  end if;

  select count(*) into v_open
  from public.guest_requests q
  where q.guest_id = v_uid and q.status = 'open';
  if v_open >= c_max_open then
    raise exception 'TOO_MANY_OPEN_REQUESTS';
  end if;

  v_note := left(btrim(coalesce(p_note, '')), 300);

  insert into public.guest_requests
    (guest_id, game, window_start, window_end, duration_minutes, note)
  values
    (v_uid, v_game, p_window_start, p_window_end, p_duration_minutes, v_note)
  returning id into v_id;

  select nickname into v_name from public.profiles where id = v_uid;

  -- ------------------------------------------------------------
  -- 宛先。**空き時間では絞らない**（冒頭参照）
  -- ------------------------------------------------------------
  insert into public.notifications (user_id, type, title, body, related_id)
  select
    h.user_id,
    'guest_request_received',
    coalesce(nullif(v_name, ''), 'ゲスト') || 'さんが' || v_game || 'を募集しています',
    to_char(p_window_start at time zone 'Asia/Tokyo', 'MM/DD HH24:MI')
      || '〜' || to_char(p_window_end at time zone 'Asia/Tokyo', 'MM/DD HH24:MI')
      || '・' || p_duration_minutes || '分',
    v_id
  from (
    select hs.user_id
    from public.host_settings hs
    join public.profile_trust_stats ts
      on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
    join public.profiles pr on pr.id = hs.user_id
    where hs.is_host
      and hs.hourly_rate is not null
      and hs.user_id <> v_uid
      and pr.withdrawn_at is null
      -- **登録しているゲームが一致すること。** ここを緩めると、
      -- 遊ばないゲームの通知が届き続けて通知そのものが読まれなくなる
      and v_game = any (hs.games)
      and not exists (
        select 1 from public.blocks b
        where (b.blocker_id = v_uid and b.blocked_id = hs.user_id)
           or (b.blocker_id = hs.user_id and b.blocked_id = v_uid)
      )
      -- 自分が非表示にした相手には送らない(0116)。
      -- **相手には何も伝わらない**——非表示であることが漏れない形
      and not exists (
        select 1 from public.hidden_hosts hh
        where hh.user_id = v_uid and hh.hidden_id = hs.user_id
      )
      -- みまもりの同意を撤回している人へは送らない(0074)。
      -- 送っても、応じた先の予約が止まる
      and not public._monitoring_consent_revoked(hs.user_id)
    order by hs.user_id
    limit c_max_notify
  ) h;

  return v_id;
end;
$$;

comment on function public.create_guest_request(text, timestamptz, timestamptz, int, text) is
  'ゲストのリクエストを出す(0120)。**板には載せず**、登録ゲームの一致するピタメイトへ通知だけを送る。'
  '同時に開けるのは3件まで、宛先は1件あたり50人まで。範囲は予約できる期間(min_lead/max_lead)の中に限る。';

revoke all on function public.create_guest_request(text, timestamptz, timestamptz, int, text) from public, anon;
grant execute on function public.create_guest_request(text, timestamptz, timestamptz, int, text) to authenticated;

-- ------------------------------------------------------------
-- 7. 応じる
-- ------------------------------------------------------------
create or replace function public.respond_to_guest_request(
  p_request_id uuid,
  p_starts_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 1件のリクエストに応じられる人数。**上限が無いと、成立するのは1人なのに
  -- 大勢が同じ時間を開けたまま待つことになる**
  c_max_responses constant int := 5;
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_is_host boolean;
  v_rate int;
  v_verified boolean;
  v_min_lead int;
  v_end timestamptz;
  v_count int;
  v_name text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.status <> 'open' then
    raise exception 'REQUEST_NOT_OPEN';
  end if;
  if v_req.guest_id = v_uid then
    raise exception 'CANNOT_ANSWER_OWN_REQUEST';
  end if;

  -- 応じられるのは、実際に予約を受けられる状態の人だけ。
  -- **create_booking が見ているのと同じ条件**（応じたのに予約できない、を作らない）
  select hs.is_host, hs.hourly_rate into v_is_host, v_rate
  from public.host_settings hs where hs.user_id = v_uid;
  if not coalesce(v_is_host, false) or v_rate is null then
    raise exception 'HOST_ONLY';
  end if;
  select ts.is_verified into v_verified
  from public.profile_trust_stats ts where ts.user_id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'HOST_NOT_VERIFIED';
  end if;

  -- みまもりの同意（双方）。撤回されていれば、そもそも予約が成立しない
  perform public._require_monitoring_consent(v_uid, v_req.guest_id);

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = v_uid and b.blocked_id = v_req.guest_id)
       or (b.blocker_id = v_req.guest_id and b.blocked_id = v_uid)
  ) then
    raise exception 'BLOCKED';
  end if;

  -- 毎正時に揃える（冒頭「開始時刻を毎正時に限る理由」）
  if p_starts_at is null then
    raise exception 'START_TIME_REQUIRED';
  end if;
  if p_starts_at <> date_trunc('hour', p_starts_at) then
    raise exception 'START_MUST_BE_ON_THE_HOUR';
  end if;

  v_end := p_starts_at + make_interval(mins => v_req.duration_minutes);
  if p_starts_at < v_req.window_start or v_end > v_req.window_end then
    raise exception 'OUTSIDE_REQUEST_WINDOW';
  end if;

  select min_lead_minutes into v_min_lead from public.platform_pricing where id = 1;
  if p_starts_at < now() + make_interval(mins => coalesce(v_min_lead, 30)) then
    raise exception 'START_TOO_SOON';
  end if;

  -- 先約と重なっていないこと。ピタメイト側・ゲスト側の両方を見る
  -- （出したのに申し込めない、を作らない）
  if public._booking_slot_conflict(v_uid, p_starts_at, v_req.duration_minutes) is not null then
    raise exception 'HOST_SLOT_TAKEN';
  end if;
  if public._booking_slot_conflict(v_req.guest_id, p_starts_at, v_req.duration_minutes) is not null then
    raise exception 'GUEST_SLOT_TAKEN';
  end if;

  select count(*) into v_count
  from public.guest_request_responses r
  where r.request_id = p_request_id and r.host_id <> v_uid;
  if v_count >= c_max_responses then
    raise exception 'ENOUGH_RESPONSES';
  end if;

  -- 時刻の言い直しは許す（同じ人が2度目に応じたら上書き）
  insert into public.guest_request_responses (request_id, host_id, starts_at)
  values (p_request_id, v_uid, p_starts_at)
  on conflict (request_id, host_id) do update set starts_at = excluded.starts_at
  returning id into v_id;

  select nickname into v_name from public.profiles where id = v_uid;

  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_req.guest_id,
    'guest_request_answered',
    coalesce(nullif(v_name, ''), 'ピタメイト') || 'さんが応じました',
    v_req.game || '・'
      || to_char(p_starts_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI')
      || '〜・' || v_req.duration_minutes || '分',
    p_request_id
  );

  return v_id;
end;
$$;

comment on function public.respond_to_guest_request(uuid, timestamptz) is
  'ゲストのリクエストに応じる(0120)。開始時刻は毎正時で、リクエストの範囲に収まること。'
  '**この行自体がその時間の空き枠になる**(host_is_open_at/slot_open_to が見る)ので、'
  'create_booking と同じ条件(掲載・本人確認・先約・同意)をここでも見る。1件につき5人まで。';

revoke all on function public.respond_to_guest_request(uuid, timestamptz) from public, anon;
grant execute on function public.respond_to_guest_request(uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 8. 応じた人から予約する
--
--    `create_booking` をそのまま呼ぶ。**検証をここで作り直さない**（0113 と同じ）。
-- ------------------------------------------------------------
create or replace function public.create_booking_from_request(
  p_request_id uuid,
  p_host_id uuid,
  p_policy_version text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_res public.guest_request_responses;
  v_booking_id uuid;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.guest_id <> v_uid then
    raise exception 'NOT_MY_REQUEST';
  end if;
  if v_req.status <> 'open' then
    raise exception 'REQUEST_NOT_OPEN';
  end if;

  select * into v_res from public.guest_request_responses
  where request_id = p_request_id and host_id = p_host_id;
  if v_res.id is null then
    raise exception 'RESPONSE_NOT_FOUND';
  end if;

  -- ★**create_booking を先に通す。** ここで status を先に変えると、
  --   host_is_open_at が open のリクエストしか見ないので、
  --   自分で開けた枠を自分で閉じてから予約することになる
  v_booking_id := public.create_booking(
    p_host_id,
    v_req.duration_minutes,
    p_policy_version,
    v_res.starts_at
  );

  update public.bookings
    set from_guest_request_id = p_request_id
    where id = v_booking_id;

  update public.guest_requests
    set status = 'matched', closed_at = now()
    where id = p_request_id;

  -- 応じてくれた他の人に、決まったことを知らせる。
  -- **開けていた枠は同時に閉じている**ので、そのことも書く
  for v_other in
    select r.host_id from public.guest_request_responses r
    where r.request_id = p_request_id and r.host_id <> p_host_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストは他の方で決まりました',
      v_req.game || '・応じていただいた時間の枠は閉じました。ありがとうございました',
      p_request_id
    );
  end loop;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_request(uuid, uuid, text) is
  'リクエストに応じた相手を予約する(0120)。create_booking をそのまま呼ぶ(検証は向こうに集約)。'
  '**予約が通ってからリクエストを matched にする**——先に閉じると、応じて開いた枠が消えて予約できない。';

revoke all on function public.create_booking_from_request(uuid, uuid, text) from public, anon;
grant execute on function public.create_booking_from_request(uuid, uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 9. 取り下げる
-- ------------------------------------------------------------
create or replace function public.cancel_guest_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.guest_id <> v_uid then
    raise exception 'NOT_MY_REQUEST';
  end if;
  if v_req.status <> 'open' then
    return; -- 二重取り下げは何もしない(連打対策)
  end if;

  update public.guest_requests
    set status = 'cancelled', closed_at = now()
    where id = p_request_id;

  -- 応じてくれた人には必ず知らせる。**枠を開けて待っている人がいる**
  for v_other in
    select r.host_id from public.guest_request_responses r where r.request_id = p_request_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストが取り下げられました',
      v_req.game || '・応じていただいた時間の枠は閉じました',
      p_request_id
    );
  end loop;
end;
$$;

comment on function public.cancel_guest_request(uuid) is
  '自分のリクエストを取り下げる(0120)。応じてくれた人に通知する(枠を開けて待っているため)。';

revoke all on function public.cancel_guest_request(uuid) from public, anon;
grant execute on function public.cancel_guest_request(uuid) to authenticated;

-- ------------------------------------------------------------
-- 10. 期限切れ
--
--     **開けた枠が閉じるのはここではなく status の側。**
--     行を消さないので、あとから「何件出て何件応じられたか」を読める
-- ------------------------------------------------------------
create or replace function public.expire_guest_requests()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ⚠️ ループの中で `get diagnostics ... row_count` を使わないこと。
  --    最後に走った文（通知の insert）の件数を拾ってしまい、
  --    「0件処理して2を返す」ような値になる
  v_n int := 0;
  v_row record;
begin
  for v_row in
    select q.id, q.guest_id, q.game,
           (select count(*) from public.guest_request_responses r where r.request_id = q.id) as answers
    from public.guest_requests q
    where q.status = 'open' and q.window_end <= now()
    for update
  loop
    update public.guest_requests
      set status = 'expired', closed_at = now()
      where id = v_row.id;

    -- **誰も応じなかったときだけ知らせる。** 応じた人がいたのに予約しなかった
    -- のは本人の選択なので、そこへ追い打ちの通知は出さない
    if v_row.answers = 0 then
      insert into public.notifications (user_id, type, title, body, related_id)
      values (
        v_row.guest_id,
        'system',
        'リクエストの受付が終わりました',
        v_row.game || '・応じた方はいませんでした。日時やゲームを変えて、もう一度出せます',
        v_row.id
      );
    end if;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

comment on function public.expire_guest_requests() is
  '受付の終わったリクエストを expired にする(0120)。'
  '応じて開いていた枠も同時に閉じる(host_is_open_at が open しか見ないため)。'
  '誰も応じなかった場合だけ、出した本人に知らせる。';

revoke all on function public.expire_guest_requests() from public, anon, authenticated;

select cron.unschedule('expire-guest-requests')
  where exists (select 1 from cron.job where jobname = 'expire-guest-requests');

-- 15分おき。0114 の close-expired-board-posts と揃える
select cron.schedule('expire-guest-requests', '*/15 * * * *',
  $cron$select public.expire_guest_requests();$cron$);

-- ------------------------------------------------------------
-- 11. 読み出し
-- ------------------------------------------------------------
/** 自分が出したリクエスト（応じた人数つき）。 */
create or replace function public.my_guest_requests(p_limit int default 20)
returns table (
  id uuid,
  game text,
  window_start timestamptz,
  window_end timestamptz,
  duration_minutes int,
  note text,
  status text,
  responses int,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    q.id, q.game, q.window_start, q.window_end, q.duration_minutes,
    q.note, q.status,
    (select count(*)::int from public.guest_request_responses r where r.request_id = q.id),
    q.created_at
  from public.guest_requests q
  where q.guest_id = auth.uid()
  order by (q.status = 'open') desc, q.created_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

comment on function public.my_guest_requests(int) is '自分が出したリクエストの一覧(0120)。open を先に並べる。';

revoke all on function public.my_guest_requests(int) from public, anon;
grant execute on function public.my_guest_requests(int) to authenticated;

/**
 * 自分のリクエストに応じた人。
 * **料金は host_settings から都度読む**(0113 と同じ理由——写すと古い額を出す)。
 */
create or replace function public.guest_request_answers(p_request_id uuid)
returns table (
  host_id uuid,
  nickname text,
  avatar_initial text,
  avatar_color text,
  avatar_path text,
  hourly_rate int,
  starts_at timestamptz,
  answered_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.host_id,
         p.nickname,
         coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
         coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
         p.avatar_path,
         hs.hourly_rate, r.starts_at, r.created_at
  from public.guest_request_responses r
  join public.guest_requests q on q.id = r.request_id
  left join public.profiles p on p.id = r.host_id
  left join public.host_settings hs on hs.user_id = r.host_id
  where r.request_id = p_request_id
    and q.guest_id = auth.uid()
  order by r.starts_at;
$$;

comment on function public.guest_request_answers(uuid) is
  '自分のリクエストに応じたピタメイトの一覧(0120)。料金は host_settings から都度読む。';

revoke all on function public.guest_request_answers(uuid) from public, anon;
grant execute on function public.guest_request_answers(uuid) to authenticated;

/**
 * 自分（ピタメイト）に届いているリクエスト。
 * **通知と同じ条件で絞る。** 通知は届いたのに一覧に出ない、を作らない。
 */
create or replace function public.guest_requests_for_host(p_limit int default 30)
returns table (
  id uuid,
  guest_id uuid,
  guest_nickname text,
  guest_avatar_initial text,
  guest_avatar_color text,
  game text,
  window_start timestamptz,
  window_end timestamptz,
  duration_minutes int,
  note text,
  answered boolean,
  my_starts_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    q.id, q.guest_id, p.nickname,
    coalesce(nullif(p.avatar_initial, ''), left(coalesce(nullif(p.nickname, ''), '?'), 1)),
    coalesce(nullif(p.avatar_color, ''), '#B3E5F2'),
    q.game,
    q.window_start, q.window_end, q.duration_minutes, q.note,
    (r.id is not null), r.starts_at, q.created_at
  from public.guest_requests q
  join public.profiles p on p.id = q.guest_id
  left join public.guest_request_responses r
    on r.request_id = q.id and r.host_id = auth.uid()
  where q.status = 'open'
    and q.window_end > now()
    and q.guest_id <> auth.uid()
    and exists (
      select 1 from public.host_settings hs
      join public.profile_trust_stats ts
        on ts.user_id = hs.user_id and coalesce(ts.is_verified, false)
      where hs.user_id = auth.uid()
        and hs.is_host
        and hs.hourly_rate is not null
        and q.game = any (hs.games)
    )
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = q.guest_id)
         or (b.blocker_id = q.guest_id and b.blocked_id = auth.uid())
    )
    and not exists (
      select 1 from public.hidden_hosts hh
      where hh.user_id = q.guest_id and hh.hidden_id = auth.uid()
    )
  order by q.window_start
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

comment on function public.guest_requests_for_host(int) is
  '自分(ピタメイト)に届いているリクエストの一覧(0120)。通知と同じ条件で絞る。'
  '登録ゲームが一致しないと1件も返らない——ピタメイト設定でゲームを登録してもらう前提。';

revoke all on function public.guest_requests_for_host(int) from public, anon;
grant execute on function public.guest_requests_for_host(int) to authenticated;

-- ------------------------------------------------------------
-- 12. 運営コンソールから見る・下ろす
--     （運営作業は SQL Editor ではなくコンソールから行う方針）
-- ------------------------------------------------------------
create or replace function public.admin_guest_requests(
  p_status text default 'open',
  p_limit int default 50
)
returns table (
  id uuid,
  guest_id uuid,
  guest_nickname text,
  game text,
  window_start timestamptz,
  window_end timestamptz,
  duration_minutes int,
  note text,
  status text,
  responses int,
  bookings int,
  created_at timestamptz,
  closed_at timestamptz,
  close_reason text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    q.id, q.guest_id, p.nickname, q.game,
    q.window_start, q.window_end, q.duration_minutes, q.note, q.status,
    (select count(*)::int from public.guest_request_responses r where r.request_id = q.id),
    (select count(*)::int from public.bookings b where b.from_guest_request_id = q.id),
    q.created_at, q.closed_at, q.close_reason
  from public.guest_requests q
  left join public.profiles p on p.id = q.guest_id
  where public._is_admin()
    and (p_status = 'all' or q.status = p_status)
  order by q.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

comment on function public.admin_guest_requests(text, int) is
  'ゲストのリクエスト一覧(運営・0120)。p_status に ''all'' で全件。';

revoke all on function public.admin_guest_requests(text, int) from public, anon;
grant execute on function public.admin_guest_requests(text, int) to authenticated;

create or replace function public.admin_remove_guest_request(
  p_request_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_reason text;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public._is_admin() then
    raise exception 'FORBIDDEN';
  end if;

  -- **理由は必須**（0112 と同じ。記録の要らない削除は、あとから説明できない）
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'REASON_REQUIRED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.status <> 'open' then
    return; -- 二重取り下げは何もしない
  end if;

  update public.guest_requests
    set status = 'cancelled',
        closed_at = now(),
        close_reason = left('運営による取り下げ：' || v_reason, 200)
    where id = p_request_id;

  -- 出した本人には**理由つき**（規約 第10条の2 6項）
  insert into public.notifications (user_id, type, title, body, related_id)
  values (
    v_req.guest_id,
    'system',
    'リクエストを取り下げました',
    v_req.game || '（理由：' || v_reason || '）',
    p_request_id
  );

  -- 応じた人には**理由なし**（運営の判断の内容を第三者に配らない）
  for v_other in
    select r.host_id from public.guest_request_responses r where r.request_id = p_request_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストが取り下げられました',
      v_req.game || '・応じていただいた時間の枠は閉じました',
      p_request_id
    );
  end loop;

  perform public._log_admin_action('guest_request_removed', p_request_id, v_reason);
end;
$$;

comment on function public.admin_remove_guest_request(uuid, text) is
  'ゲストのリクエストを運営が取り下げる(0120)。行は消さず cancelled にし、理由を close_reason に残す。'
  '理由は必須。本人には理由つき、応じた人には理由なしで通知し、admin_actions に記録する。';

revoke all on function public.admin_remove_guest_request(uuid, text) from public, anon;
grant execute on function public.admin_remove_guest_request(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 13. プッシュの扱い
--
--     `guest_request_received` は**多数へ一斉に飛ぶ**唯一の種別。
--     静かにする時間を設定している人は、そこで止めてよい種類に入れる。
--     `guest_request_answered` は自分が出したものへの返事なので止めない。
-- ------------------------------------------------------------
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
    'booking_completed',
    'guest_request_received'  -- 0120。一斉に飛ぶので静かな時間では止める
  );
$$;

revoke all on function public._push_is_casual(text) from public, anon;


-- >>>>>>>> 0121_blocked_and_stale_time.sql
-- ============================================================
-- 0121: 想定外の順序で操作したときに、黙って間違う3つを塞ぐ
--
-- `supabase/tests/41_unexpected_order.sql` を書いて見つけたもの。
-- **どれも例外が出ずに、頼んでいない結果が確定していた。**
--
-- ------------------------------------------------------------
-- ① ブロックしても予約できた（既存の穴・いちばん広い）
--
--   `0116` は「ブロック(0008) → 相手への影響: 予約もトークも不可」と
--   表で明記している。**ところが実装に検査が無かった。**
--     ・`create_booking` … ブロックを一切見ていない
--     ・`messages` の RLS … 約束の当事者かどうかだけ。ブロックを見ていない
--   ブロックを見ていたのは `create_booking_from_board`(0113) だけで、
--   板を経由しない経路（さがす・お気に入り・再予約・リクエスト）は素通り。
--
--   RLS で見えないので**ふつうには起きない**が、
--     ・一緒に遊んだ相手をブロックしても、既存のトークからは送れる
--     ・リクエストに応じてもらったあとにブロックされても、予約が通る
--   の2つは実際に到達する。**41 のテスト7で、通ることを確認した。**
--
--   ここでは判定を**予約とメッセージの入口そのもの**に置く。
--   画面側で隠すのは補助で、守っているのはここ。
--
-- ------------------------------------------------------------
-- ② 応じる時刻を変えられると、ゲストは画面と違う時刻で成立した
--
--   ホストが 20:00 で応じる → ゲストの画面に 20:00 が出る
--   → ホストが 22:00 に変える → ゲストが「予約する」を押す
--   → **22:00 で成立する。**
--
--   `create_booking_from_request` が時刻を引数で受け取らず、
--   応答の行をその場で読み直していたため。エラーは出ないので、
--   ゲストは 20:00 のつもりで 22:00 の約束を買うことになる。
--   **金銭を伴う約束が、見ていた内容と違う条件で確定する。**
--
--   見ていた時刻を引数で受け取り、食い違ったら止める。
--   （楽観ロック。**時刻の権威はサーバのまま**で、
--     「画面が古い」ことだけを検出する）
--
-- ------------------------------------------------------------
-- ③ ブロックの解除は、予約を復活させない
--   ブロックを外せば、また予約できる。ここでは状態を持たない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. create_booking にブロック検査を足す
--
--    ⚠️ **本体は適用済みDBから取り出したものをそのまま使い、
--       ブロック検査の分だけを足している。** 記憶で書き直すと、
--       有効期限順の充当(0082)や安全手数料の扱いを落とす
--       （0119 で実際にやって、テスト28 が拾った）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_booking(p_host_id uuid, p_duration_minutes integer, p_policy_version text, p_scheduled_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if public._booking_slot_conflict(v_guest_id, v_start, p_duration_minutes) is not null then
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
    list_coins, discount_percent, requested_start_at
  )
  values (
    v_guest_id, p_host_id, p_duration_minutes, v_coins, 'requested',
    v_from_paid, v_from_bonus, p_policy_version,
    case when p_policy_version is null then null else now() end,
    v_list_coins, v_discount, p_scheduled_at
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
$function$;
comment on function public.create_booking(uuid, integer, text, timestamptz) is
  'ピタメイトの予約を申し込み、コインを確保する。0121でブロック検査を追加'
  '（0116 が「ブロック＝予約もトークも不可」と書いているのに、検査が無かった）。';

revoke all on function public.create_booking(uuid, integer, text, timestamptz) from public, anon;
grant execute on function public.create_booking(uuid, integer, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 2. メッセージにもブロック検査を足す
--
--    RLS の with check ではなくトリガーにする。理由は 0113・0081 と同じで、
--    **エラー名で理由を返せる**ため。みまもり同意の検査(0074)と同じ場所に置く。
-- ------------------------------------------------------------
create or replace function public._messages_require_not_blocked()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
begin
  select case when pr.user_a = new.sender_id then pr.user_b else pr.user_a end
    into v_other
  from public.promises pr where pr.id = new.promise_id;

  if v_other is null then
    return new; -- 相手が特定できない行は、ここでは判断しない
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = new.sender_id and b.blocked_id = v_other)
       or (b.blocker_id = v_other and b.blocked_id = new.sender_id)
  ) then
    raise exception 'BLOCKED';
  end if;
  return new;
end;
$$;

comment on function public._messages_require_not_blocked() is
  'ブロック関係があればメッセージを送れない(0121)。'
  '**既存のトークでも止める**——一緒に遊んだあとにブロックした相手から'
  '送り続けられると、ブロックの意味が無くなる。';

revoke all on function public._messages_require_not_blocked() from public, anon;

drop trigger if exists messages_require_not_blocked on public.messages;
create trigger messages_require_not_blocked
  before insert on public.messages
  for each row execute function public._messages_require_not_blocked();

-- ------------------------------------------------------------
-- 3. リクエストからの予約に「見ていた時刻」を渡させる
--
--    引数を足すので、**古い3引数版は落とす。** 残すと画面側が
--    古いほうを呼び続けられてしまい、直したことにならない
--    （0119 で declare_residency の2引数版を落としたのと同じ理由）。
-- ------------------------------------------------------------
drop function if exists public.create_booking_from_request(uuid, uuid, text);

create or replace function public.create_booking_from_request(
  p_request_id uuid,
  p_host_id uuid,
  p_policy_version text,
  p_expected_starts_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.guest_requests;
  v_res public.guest_request_responses;
  v_booking_id uuid;
  v_other record;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select * into v_req from public.guest_requests where id = p_request_id for update;
  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.guest_id <> v_uid then
    raise exception 'NOT_MY_REQUEST';
  end if;
  if v_req.status <> 'open' then
    raise exception 'REQUEST_NOT_OPEN';
  end if;

  select * into v_res from public.guest_request_responses
  where request_id = p_request_id and host_id = p_host_id;
  if v_res.id is null then
    raise exception 'RESPONSE_NOT_FOUND';
  end if;

  -- ★0121: 画面に出ていた時刻と、いまの応答の時刻が食い違っていたら止める。
  --   ホストは応じたあとに時刻を言い直せる(on conflict do update)。
  --   ここを見ないと、**ゲストは 20:00 のつもりで 22:00 の約束を買う。**
  --   null のときは検査しない（古い画面からの呼び出しを壊さないため。
  --   画面側は必ず渡す）
  if p_expected_starts_at is not null and v_res.starts_at <> p_expected_starts_at then
    raise exception 'RESPONSE_TIME_CHANGED';
  end if;

  -- ★create_booking を先に通す。ここで status を先に変えると、
  --   host_is_open_at が open のリクエストしか見ないので、
  --   自分で開けた枠を自分で閉じてから予約することになる
  v_booking_id := public.create_booking(
    p_host_id,
    v_req.duration_minutes,
    p_policy_version,
    v_res.starts_at
  );

  update public.bookings
    set from_guest_request_id = p_request_id
    where id = v_booking_id;

  update public.guest_requests
    set status = 'matched', closed_at = now()
    where id = p_request_id;

  -- 応じてくれた他の人に、決まったことを知らせる。
  -- **開けていた枠は同時に閉じている**ので、そのことも書く
  for v_other in
    select r.host_id from public.guest_request_responses r
    where r.request_id = p_request_id and r.host_id <> p_host_id
  loop
    insert into public.notifications (user_id, type, title, body, related_id)
    values (
      v_other.host_id,
      'system',
      'リクエストは他の方で決まりました',
      v_req.game || '・応じていただいた時間の枠は閉じました。ありがとうございました',
      p_request_id
    );
  end loop;

  return v_booking_id;
end;
$$;

comment on function public.create_booking_from_request(uuid, uuid, text, timestamptz) is
  'リクエストに応じた相手を予約する(0120、0121で p_expected_starts_at を追加)。'
  '画面に出ていた時刻と食い違っていたら RESPONSE_TIME_CHANGED で止める'
  '——ホストは応じたあとに時刻を言い直せるので、見ていた時刻と違う約束が成立しうる。';

revoke all on function public.create_booking_from_request(uuid, uuid, text, timestamptz) from public, anon;
grant execute on function public.create_booking_from_request(uuid, uuid, text, timestamptz) to authenticated;


-- >>>>>>>> 0122_fee_on_actual_gmv.sql
-- ============================================================
-- 0122: 手数料の「月間売上」と「リピート」を、利用料の対象額で数える
--
-- 料率の制度そのものに穴がないかを調べて見つけたもの
-- （テストは `supabase/tests/42_fee_loopholes.sql`）。
-- **どちらも例外は出ず、黙ってホストに有利／不利に働いていた。**
--
-- ------------------------------------------------------------
-- ① 返金された予約が、月間売上に満額カウントされていた
--
--   実測（0122 適用前）:
--     予約額 10,000 ／ ホストの受取 0 ／ 手数料 0 ／ status = completed
--     → **月間GMV に 10,000 が満額計上される**
--
--   `release_hold_and_refund` は返金しても status を completed にする。
--   `host_monthly_ticket_gmv` は `b.coins`(額面)を合計していたので、
--   **1円も受け取っていない予約が段を押し上げ、以降が安くなっていた。**
--   紛争でゲストに全額返金された予約が手数料を下げる——向きが逆。
--
--   ⚠️ **逆向きの取りこぼしもあった。** 遊んだあとのキャンセル(0102)は
--   status が cancelled_* のまま**利用料まで引かれている**のに、
--   GMV には数えられていなかった。
--
-- ② 全額返金された予約でも「リピート」が成立していた
--
--   リピート判定も `status = 'completed'` しか見ていなかったため、
--   受取 0 の予約のあと、同じゲストとの次が 3pt 引きになっていた。
--
-- ------------------------------------------------------------
-- ■ 何を基準にするか：**利用料の対象になった額**（`platform_fees`）
--
--   `0103` は手数料について「受け取っていないものからは引かない」
--   （規約 第8条の2第2項）と決めた。ところが**段を決める GMV と
--   リピート判定だけが額面のまま**で、そこがずれていた。
--
--   両方を `platform_fees`（kind='booking'）に揃える。この行は
--   **運営が「役務の対価として扱った」ときだけ**作られる:
--
--     完了                   → 作られる
--     遊んだあとのキャンセル → 作られる（0102。役務の対価）
--     全額返金で終わった予約 → 作られない（受取 0）
--     無断欠席の没収         → 作られない（**遊んでいない**）
--
--   ⚠️ **`booking_earned` の合計ではだめ。** 無断欠席の没収でも
--      報酬は発生するが、あれは遊んでいないので利用料も引かれていない。
--      それを「前回一緒に遊んだ」と数えると、**会っていない相手が
--      リピート扱いになる。** 最初そう書いて、テスト26 が拾った。
--
--   status での絞り込みはやめる。status は実体の近似でしかない
--   （completed でも 0 のことがあり、cancelled でも対価が発生する）。
--
-- ■ 月の区切りは変えない
--   予約の `scheduled_at`（遊ぶ日）の属する月・日本時間の暦月。
--   完了日で数えると、月末の予約が翌月に落ちて段がずれる。
--
-- ■ 循環しないこと
--   `_booking_fee_coins` は自分の `platform_fees` 行が**作られる前**に
--   呼ばれ、かつ `p_exclude_booking` で自分を外している。
--
-- ■ 影響
--   `host_dashboard` も同じ関数を使うので、画面の「今月の売上」も
--   利用料の対象額に揃う（従来は額面だった）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 月間売上を「利用料の対象になった額」で数える
-- ------------------------------------------------------------
create or replace function public.host_monthly_ticket_gmv(
  p_host_id uuid,
  -- ⚠️ 既定値は既存と**完全に一致させること**。省くと
  --    「cannot remove parameter defaults from existing function」で落ちる
  p_at timestamptz default now(),
  p_exclude_booking uuid default null
)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(pf.gross_coins), 0)::int
  from public.platform_fees pf
  join public.bookings b on b.id = pf.booking_id
  where pf.kind = 'booking'
    and pf.host_id = p_host_id
    -- 遊ぶ日の属する月で数える(完了日ではない)
    and date_trunc('month', (b.scheduled_at at time zone 'Asia/Tokyo'))
        = date_trunc('month', (p_at at time zone 'Asia/Tokyo'))
    and (p_exclude_booking is null or b.id <> p_exclude_booking);
$$;

comment on function public.host_monthly_ticket_gmv(uuid, timestamptz, uuid) is
  'その月に利用料の対象になった予約の合計(0122)。'
  '**額面ではなく platform_fees.gross_coins の合計。** 全額返金された予約と'
  '無断欠席の没収は入らず、遊んだあとのキャンセル(0102)は入る。'
  '手数料の基準(0103)と同じ額で段を決めるため。';

revoke all on function public.host_monthly_ticket_gmv(uuid, timestamptz, uuid) from public, anon;

-- ------------------------------------------------------------
-- 2. リピートの判定も同じ基準で見る
--
--    ⚠️ **本体は適用済みDBから取り出したものをそのまま使い、
--       判定の分だけを差し替えている。** 記憶で書き直すと累進の計算や
--       下限の扱いを落とす（0119 で実際にやって、テスト28 が拾った）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._booking_fee_coins(p_host_id uuid, p_guest_id uuid, p_booking_id uuid, p_gross_coins integer, p_scheduled_at timestamp with time zone, p_agreed_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c_repeat_discount constant numeric := 0.03;
  c_rate_floor constant numeric := 0.10;
  v_gmv_before int;
  v_gmv_after int;
  v_base_fee numeric;
  v_rate numeric;
  v_discount numeric := 0;
  v_is_repeat boolean := false;
  v_fee int;
begin
  if p_gross_coins is null or p_gross_coins <= 0 then
    return jsonb_build_object('fee', 0, 'repeat', false);
  end if;

  -- この予約を除いた当月GMV(=確定前)と、含めた額(=確定後)
  v_gmv_before := public.host_monthly_ticket_gmv(p_host_id, p_scheduled_at, p_booking_id);
  v_gmv_after := v_gmv_before + p_gross_coins;

  v_base_fee := public.host_progressive_fee(v_gmv_after, p_agreed_at)
              - public.host_progressive_fee(v_gmv_before, p_agreed_at);
  v_rate := v_base_fee / p_gross_coins;

  -- 指名リピート: 同じゲストと過去に完了した予約があるか
  -- 0122: **「利用料が計算された予約」だけを前回と数える。**
  --   platform_fees に行があるかで見る。この行は、運営が
  --   「役務の対価として扱った」ときだけ作られるため:
  --     ・完了                   → 作られる（前回に数える）
  --     ・遊んだあとのキャンセル → 作られる（0102。役務の対価なので数える）
  --     ・全額返金で終わった予約 → 作られない（受取 0。数えない）
  --     ・無断欠席の没収         → 作られない（**遊んでいない**。数えない）
  --   以前は status = 'completed' だけを見ていたので、全額返金でも
  --   リピートが成立し、遊んだあとのキャンセルは数えられていなかった。
  select exists (
    select 1
    from public.platform_fees pf
    join public.bookings b on b.id = pf.booking_id
    where pf.kind = 'booking'
      and pf.host_id = p_host_id
      and b.guest_id = p_guest_id
      and b.id <> p_booking_id
      and b.scheduled_at < p_scheduled_at
  ) into v_is_repeat;

  if v_is_repeat then
    v_discount := least(c_repeat_discount, greatest(0, v_rate - c_rate_floor)) * p_gross_coins;
  end if;

  v_fee := least(greatest(0, round(v_base_fee - v_discount))::int, p_gross_coins);

  return jsonb_build_object('fee', v_fee, 'repeat', v_is_repeat);
end;
$function$;

comment on function public._booking_fee_coins(uuid, uuid, uuid, integer, timestamptz, timestamptz) is
  '1件ぶんの利用料と、リピート割引が効いたかを返す(0102、0122でリピート判定を変更)。'
  '**利用料が計算された予約だけを「前回」と数える**——全額返金で終わった予約で'
  'リピートが成立し、無断欠席の没収(遊んでいない)まで数える余地があった。';

revoke all on function public._booking_fee_coins(uuid, uuid, uuid, integer, timestamptz, timestamptz) from public, anon;
