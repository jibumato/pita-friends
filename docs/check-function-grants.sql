-- ============================================================
-- 0093 / 0094 が効いているかの確認と、効いていないときの原因の切り分け
-- ------------------------------------------------------------
-- Supabase の SQL Editor は **NOTICE も WARNING も表示しません。**
-- とくに、関数の所有者でない役割が revoke すると PostgreSQL は
-- 「WARNING: no privileges could be revoked」を出すだけで**成功扱い**にします。
-- そのため「成功と出たのに穴が開いたまま」が起こりえます。
--
-- ⚠️ **見るのは PUBLIC ではなく anon です。** Supabase は public スキーマの
-- 関数を anon へ**直接** GRANT する既定権限を持っており、
-- PUBLIC を閉じても anon は開いたままになります(2026-08-03 に実際に起きた)。
--
-- **開いているものが上に来ます。0行目に ❌ が無ければ完了です。**
-- ❌ が残るときは「所有者」の列を見てください。実行中のロールと違えば、
-- そのロールでは revoke できません（Supabase サポートに所有者の変更を相談）。
-- ============================================================
with target as (
  select p.oid, p.proname
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
  case when has_function_privilege('anon', oid, 'execute')
       then '❌ まだ未ログインに開いている' else '✅ 閉じている' end as 状態,
  oid::regprocedure::text            as 関数,
  pg_get_userbyid(
    (select proowner from pg_proc where oid = target.oid)) as 所有者,
  current_user                        as "実行中のロール",
  coalesce(
    (select proacl::text from pg_proc where oid = target.oid),
    '(設定なし=PUBLICに開放)')       as "権限の設定"
from target
order by has_function_privilege('anon', oid, 'execute') desc, 2;
