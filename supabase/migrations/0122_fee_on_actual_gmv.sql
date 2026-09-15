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
