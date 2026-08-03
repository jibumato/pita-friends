-- ============================================================
-- 0093_relock_function_grants.sql
-- 0065 の当て漏れを回収する（セキュリティ修正の再適用）
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   本番で **0065 だけが当たっていなかった。** 0064 まで当て、0066 以降を
--   当てたため、`docs/check-migrations.sql` が「順番が飛んでいます」を
--   出していた（2026-08-03 に発覚）。
--
--   0065 は「関数を作ると PostgreSQL が既定で PUBLIC に EXECUTE を与える」
--   という性質への対処で、**未ログインから内部用の補助関数を呼べる穴**を
--   閉じるものだった。当たっていないので、その穴が本番に残っていた。
--   とくに次の2つ（0065 の記述より）:
--
--     (1) `_booking_slot_conflict` … 掲載中のピタメイト全員の稼働予定が
--         未ログインで復元できる
--     (2) `_ledger_record_bypass`  … 追記専用の台帳に嘘の記録を積める
--
-- ■ なぜ 0065 をそのまま流せないか
--   `0091` が `host_progressive_fee` の引数を `(int)` から
--   `(int, timestamptz)` に変えている。0065 は古い署名で revoke するので、
--   いま流すと **`function public.host_progressive_fee(integer) does not exist`**
--   で止まる。手元で 0065 以外を当てた DB に 0065 を流して確認した。
--
-- ■ 方針
--   **署名ではなく関数名で引く。** 引数が変わっても、名前が同じなら
--   すべての多重定義から PUBLIC を取り上げる。これで今後の署名変更で
--   同じことが起きない。何度流しても結果は同じ（冪等）。
--
--   `revoke ... from public` は `authenticated` / `anon` への明示的な
--   grant には触れない。未ログインに見せてよいもの（public_host_cards /
--   host_ranking / fee_rates など）は 0065 と同じくそのまま残る。
--
--   固定した一覧は `supabase/tests/74_anon_surface.sql` が検証している。
-- ============================================================

do $$
declare
  v_names text[] := array[
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
  ];
  r record;
  n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname = any (v_names)
  loop
    execute format('revoke all on function %s from public', r.sig);
    n := n + 1;
  end loop;

  raise notice '0093: % 個の関数から PUBLIC の EXECUTE を取り上げました', n;

  -- **1つも取り上げられなかったら、名前の書き間違いを疑う。**
  -- 静かに何もしないのが一番まずい（穴が開いたままになる）
  if n = 0 then
    raise exception '0093: 対象の関数が1つも見つかりません。関数名の一覧を確認してください';
  end if;
end $$;
