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
