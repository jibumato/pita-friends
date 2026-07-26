-- ============================================================
-- 0045_evidence_refund_percent.sql
-- 立証材料ビューの返還率が常に0%になる不具合を直す
-- ------------------------------------------------------------
-- 0040 で guest_cancellation_evidence を作り直したとき、返還率の算出に
-- b.status(=キャンセル**後**の状態)をそのまま渡していました。
-- booking_refund_percent() は「'confirmed' 以外は0」と判定するため、
-- キャンセル済みの行では必ず 0 が返っていました。
--
-- このビューは消費者契約法9条の「平均的な損害」を検討するための材料です。
-- 実際には全額戻していたケースまで「返還0%」と記録されるので、そのまま
-- 弁護士や当局に出すと事実と逆の説明をしてしまいます。
--
-- キャンセル直前の状態を confirmed_at の有無から復元して渡します。
-- あわせて、ゲスト都合以外(ピタメイト都合・辞退・無断欠席)は「率」の
-- 概念が違うので null にし、混ざらないようにします。
-- ============================================================

drop view if exists public.guest_cancellation_evidence;

create view public.guest_cancellation_evidence
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.guest_id,
  b.host_id,
  b.status,
  b.policy_version,
  b.policy_agreed_at,
  b.created_at as requested_at,
  b.confirmed_at as approved_at,
  b.requested_start_at,
  b.scheduled_at as starts_at,
  b.cancelled_at,
  b.coins,
  b.list_coins,
  b.discount_percent,
  extract(epoch from (b.cancelled_at - b.confirmed_at))::int as seconds_after_approval,
  extract(epoch from (b.scheduled_at - b.cancelled_at))::int as seconds_before_start,
  -- キャンセル直前の状態を復元して率を出す。
  -- ゲスト都合のキャンセルだけが「段階制の返還率」の対象。
  case
    when b.status = 'cancelled_by_guest' then
      public.booking_refund_percent(
        case when b.confirmed_at is not null then 'confirmed' else 'requested' end,
        b.confirmed_at, b.scheduled_at, b.cancelled_at)
    else null
  end as refund_percent_at_cancel
from public.bookings b
where b.cancelled_at is not null;

comment on view public.guest_cancellation_evidence is
  'キャンセルの実態(承諾からの経過・開始までの残り・適用された返還率)。'
  '消費者契約法9条の「平均的な損害」を検討するための材料。0040で承諾時刻ベースに修正し、'
  '0045でキャンセル直前の状態から返還率を復元するよう修正(それ以前は常に0%と表示されていた)。';
