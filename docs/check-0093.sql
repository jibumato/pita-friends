-- ============================================================
-- 0093 が効いているかの確認
-- ------------------------------------------------------------
-- Supabase の SQL Editor は **RAISE NOTICE を表示しません。**
-- 0093 を流しても「Success. No rows returned」としか出ないので、
-- 効いたかどうかはこれで見ます。
--
-- なお 0093 には「対象が1つも見つからなければ例外を出す」ガードが
-- 入っているので、**エラーにならずに成功した時点で何かは処理されています。**
-- ここでは取りこぼしが無いかまで見ます。
-- ============================================================
with target as (
  select p.oid, p.oid::regprocedure::text as 関数
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = any (array[
    '_booking_slot_conflict',
    '_lock_booking_slots',
    '_ledger_record_bypass',
    'create_booking',
    '_apply_booking_fee',
    '_apply_gift_fee',
    '_checkin_on_message',
    '_consumption_restore_only',
    '_enqueue_push',
    '_hold_bookings_on_report',
    '_ledger_immutable',
    '_ledger_no_delete',
    '_payout_amount_immutable',
    'check_host_requires_verification',
    'clear_last_seen_on_hide',
    'handle_new_user',
    'handle_new_user_notification_prefs',
    'handle_new_user_wallet',
    'notify_board_joined',
    'notify_invite_approved',
    'notify_invite_received',
    'notify_message_received',
    'reviews_after_insert_recompute',
    'set_report_severity',
    'set_updated_at',
    '_push_is_casual',
    '_push_lockscreen_body',
    '_push_in_quiet_hours',
    '_ledger_override_on',
    'host_progressive_fee',
    'host_monthly_ticket_gmv',
    'safety_fee_for',
    'coin_expiry_from',
    'is_valid_booking_duration',
    'booking_refund_percent',
    'booking_refund_coins',
    'fresh_host_status',
    'booking_fits_availability',
    'host_has_availability',
    'host_is_open_at'
     ])
)
select
  count(*)                                                              as "対象の関数",
  count(*) filter (where has_function_privilege('public', oid, 'execute')) as "まだ未ログインに開いている",
  case when count(*) filter (where has_function_privilege('public', oid, 'execute')) = 0
       then '✅ 0093 は適用済み'
       else '❌ まだ当たっていない。0093 を実行してください' end        as 判定
from target;
