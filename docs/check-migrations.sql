-- ============================================================
-- どこまでマイグレーションを適用したかを調べる
-- ------------------------------------------------------------
-- Supabase の SQL Editor に貼って実行してください。**読み取りだけ**で、
-- データもスキーマも一切変更しません。
--
-- マイグレーションは SQL Editor から手で流す運用なので、適用履歴を持つ表が
-- ありません。そこで「そのマイグレーションでしか作られないもの」が実在するかを
-- 1本ずつ確かめます。目印には、列やテーブルのように**追加されたら消えない**ものを
-- 優先して選んでいます(関数の中身は後のマイグレーションで差し替わるため)。
-- ============================================================

with expected(seq, migration, kind, obj, needle) as (
  values
    -- host_ranking() が avatar_path を返すようになった
    (37, '0037_ranking_avatar',          'funcsrc', 'host_ranking',                'avatar_path'),
    (38, '0038_host_trial_discount',     'column',  'host_settings',               'trial_discount_percent'),
    -- extend_booking が「延長は定価」に差し替わった(以降の版もこの注記を持つ)
    (39, '0039_extension_full_price',    'funcsrc', 'extend_booking',              '0039'),
    (40, '0040_scheduled_booking',       'column',  'bookings',                    'requested_start_at'),
    (41, '0041_longer_bookings',         'column',  'platform_pricing',            'max_duration_minutes'),
    (42, '0042_booking_hold',            'column',  'bookings',                    'held_at'),
    (43, '0043_integrity_checks',        'table',   'integrity_checks',            null),
    (44, '0044_ledger_immutable',        'table',   'ledger_audit',                null),
    -- 立証材料ビューが「キャンセル直前の状態」を復元するようになった
    (45, '0045_evidence_refund_percent', 'view',    'guest_cancellation_evidence', 'WHEN (confirmed_at IS NOT NULL)'),
    (46, '0046_account_anonymize',       'table',   'account_anonymizations',      null),
    (47, '0047_ledger_export_heartbeat', 'table',   'ledger_exports',              null),
    (48, '0048_longer_play_12h',         'column',  'platform_pricing',            'cancel_forfeit_cap_minutes'),
    (49, '0049_booking_slot_conflict',   'view',    'booking_slots',               'FROM bookings'),
    (50, '0050_no_show_auto',            'column',  'bookings',                    'guest_checked_in_at'),
    (51, '0051_host_availability',       'table',   'host_availability',           null),
    (52, '0052_public_host_listing',    'funcsrc', 'public_host_cards',           'discoverable'),
    (53, '0053_favorites',              'table',   'favorites',                   null),
    (54, '0054_favorite_slot_notify',   'column',  'host_settings',               'slots_notified_at'),
    (55, '0055_play_history_with',      'funcsrc', 'my_play_history_with',        'last_played_at'),
    (56, '0056_host_status',            'column',  'host_settings',               'status_text'),
    (57, '0057_regulars_first',         'column',  'host_settings',               'regulars_first_hours'),
    (58, '0058_repeat_proof',           'funcsrc', 'public_host_cards',           'repeat_guests'),
    (59, '0059_last_play_shape',        'funcsrc', 'my_play_history_with',        'last_duration_minutes'),
    (60, '0060_discovery_repeat_rank',  'funcsrc', 'public_host_cards',           'repeat_score'),
    (61, '0061_booking_series',         'funcsrc', 'create_booking_series',       'INVALID_SERIES_COUNT'),
    (62, '0062_fast_release',           'table',   'fast_release_prefs',          null),
    (63, '0063_align_payout_terms',     'funcsrc', 'request_bank_payout',         '5000'),
    (64, '0064_web_push',               'table',   'push_subscriptions',          null),
    -- 未ログインへの過剰なEXECUTEを閉じた。塞げたかは has_function_privilege で見る
    (65, '0065_lock_down_function_grants', 'noexec', '_ledger_record_bypass(text, text, jsonb, jsonb)', null),
    (66, '0066_admin_console',          'table',   'admin_actions',               null),
    -- コメントだけを直した移行。表の説明文が新しい言い方になっているかで見る
    (67, '0067_favorites_wording',      'tcomment', 'favorites',                  'お気に入り登録。誰が誰を'),
    -- 管理操作の記録漏れをふさいだ。通報の閲覧を記録するようになったかで見る
    (68, '0068_admin_read_audit',       'funcsrc', 'admin_reports',              'view_reports'),
    -- 0063で消えたギフトの7日換金保留を復活させた
    (69, '0069_restore_gift_payout_hold', 'funcsrc', 'request_bank_payout',      'GIFT_ON_HOLD'),
    -- 会計用の残高集計。将来のインボイス用の列でも見られる
    (70, '0070_accounting_reconciliation', 'column', 'host_settings',            'invoice_registration_number'),
    -- あんしん保証料→あんしんサポート料。コメントの文言で見る
    (71, '0071_safety_fee_rename',       'tcomment', 'platform_pricing',          'あんしんサポート料の率'),
    -- 短縮設定が既存予約に遡らないようにした。判定条件が入ったかで見る
    (72, '0072_fast_release_no_retroactive', 'funcsrc', 'auto_complete_bookings',  'f.created_at <= b.created_at'),
    -- 料率を画面に出すための読み取り口(規約 第8条の2第3項)
    (73, '0073_fee_rates_public',        'funcsrc', 'fee_rates',                  'bookingTiers'),
    -- みまもり撤回に実際の効果を持たせた。メッセージ側のトリガで見る
    (74, '0074_monitoring_revoke_effect', 'trigger', 'messages',                  'messages_require_consent'),
    -- チャージバック中はコインを使えなくした(税理士 第2回Q14・リリース前必須)
    (75, '0075_payment_dispute_freeze',  'table',   'payment_disputes',           null),
    -- 会計集計を税理士の第2回回答に合わせた。仮受金の行が出るかで見る
    (76, '0076_accounting_round2',       'funcsrc', 'accounting_balances',        '仮受金(換金手数料)'),
    -- 係争中のチャージバックに紐づく報酬を換金保留にした(税理士 第3回)
    (77, '0077_dispute_payout_hold',     'funcsrc', 'request_bank_payout',        'DISPUTE_ON_HOLD'),
    -- 純額処理を選べるよう「PF利用料のうち無償コイン起因」を内数で出す(税理士 第4回)
    (78, '0078_bonus_origin_fee',        'funcsrc', 'accounting_revenue',         '無償コイン起因'),
    -- 会計ソフト取込用の仕訳を自動生成する(月次の締めをSQL Editorから外す)
    (79, '0079_accounting_journal',      'funcsrc', 'accounting_journal',         '販売促進費'),
    -- カード共有の検知(E-9)。端末0021・IP0022と揃えて3つ目
    (80, '0080_card_fingerprint_monitoring', 'table', 'user_payment_cards',      null),
    -- 居住地の自己申告(規約第3条3項・突合表G4)
    (81, '0081_residency_declaration',   'trigger', 'identity_verifications',    'identity_verifications_require_residency'),
    -- コインの消費順序を期限優先に(弁護士 第3回回答 論点4)
    (82, '0082_consume_by_expiry',       'funcsrc', 'create_booking',            '_split_coins_by_expiry'),
    -- 購入ボーナスの廃止(事業判断。法務・税務・資金の3論点が同時に消える)
    (83, '0083_no_purchase_bonus',    'constraint', 'coin_packs',                'coin_packs_no_bonus_check'),
    -- 通知設定の行が無いユーザーの救済(設定画面のトグルが無反応だった)
    (84, '0084_notification_prefs_selfheal', 'funcsrc', 'get_notification_prefs',  'on conflict (user_id) do nothing'),
    -- 無帰責の返還で消滅した分の金銭返金(規約第9条5の3・G8)
    (85, '0085_cash_refund_lapsed',        'table', 'cash_refunds',              null),
    -- 退会(規約第6条の2・G6)。退会後90日は報酬コインの換金だけができる
    (86, '0086_account_withdrawal',        'column', 'profiles',                  'withdrawn_at'),
    -- 新規ユーザーの購入上限とコインの出所(規約第8条の6第5項1号・G11前半)
    (87, '0087_new_user_purchase_limit',   'column', 'coin_lots',                 'purchase_id'),
    -- チャージバック清算の相殺と、新規原資の換金保留(規約第8条の6・G11後半)
    (88, '0088_chargeback_offset',          'table', 'chargeback_offsets',        null),
    -- 失効の事前通知・期限の表示(G7)と申出の期間制限(G9)
    (89, '0089_expiry_notice_and_claim_window', 'column', 'coin_lots',            'expiry_notified_at'),
    -- 購入の取消しとサポート料の返還(規約第7条の3第5項・税理士Q14(c)・G5)
    (90, '0090_void_purchase_refund',        'table', 'purchase_voids',           null),
    -- 料率の遡及適用の防止(規約第8条の2第4項・5項・G3)
    (91, '0091_fee_rate_grandfathering',    'column', 'host_fee_tiers',           'effective_from'),
    -- 退会で投稿等の表示を止める(規約第10条の2第4項)
    (92, '0092_withdraw_clears_posts',    'funcsrc', 'withdraw_account',          'voice_path = null'),
    -- 0065の当て漏れの回収。0091が作り直して開き直した穴も同時に閉じる
    (93, '0093_relock_function_grants',  'noexec',  'host_progressive_fee(int, timestamptz)', null),
    -- 未ログインに開いていた163本を5本に絞る(Supabaseの既定権限への対処)
    (94, '0094_close_anon_function_grants', 'noexec', '_booking_slot_conflict(uuid, timestamptz, int, uuid, text[])', null),
    -- Edge Function だけが呼ぶ関数を利用者から閉じる(コインの付与が開いていた)
    (95, '0095_close_server_only_functions', 'noexec',
         'credit_coins_for_purchase(uuid, text, int, int, int, text, text)', null),

    -- ── 2026-08-26 追記(0096〜0117)。目印は、全適用済みのローカルDBで
    --    1本ずつ「実際に残っているか」を確認して選んでいます。
    --    ★関数を目印にするときは、**後のマイグレーションで差し替わっても
    --      残る文字列**を選ぶこと。番号のコメントは書き換えで消えます
    --      (0102 の '0102' は 0109 の差し替えで消えていました)。
    --      消えるものしか無い場合は、関数名そのものを needle にして
    --      「その関数が存在するか」を見ています。
    (96,  '0096_payment_method_on_purchase', 'column',  'coin_purchases',      'payment_method'),
    (97,  '0097_gift_as_two_obligations',    'funcsrc', 'send_gift',           '0097'),
    (98,  '0098_withdrawal_payout_and_suspension_coins',
                                             'column',  'profiles',            'payout_claim_deadline'),
    (99,  '0099_offset_time_limit',          'funcsrc', 'chargeback_offset_preview', '0099'),
    (100, '0100_final_payout_must_be_whole', 'funcsrc', 'request_bank_payout', '0100'),
    (101, '0101_operator_adjustable_limits', 'column',  'platform_pricing',    'gift_max_per_tx'),
    (102, '0102_played_then_cancelled',      'funcsrc', 'cancel_booking',      '0102'),
    (103, '0103_fee_on_actual_earnings',     'funcsrc', '_apply_booking_fee',  '0103'),
    -- 0104 は「番号」が本体に残らないので、緩めた対象の列名を目印にする
    (104, '0104_webhook_purchase_records',   'funcsrc', '_purchase_immutable', 'payment_method'),
    -- 0105 が作る2関数のうち、後で差し替わらないほう
    (105, '0105_business_kpis',              'funcsrc', 'admin_payment_method_mix', 'admin_payment_method_mix'),
    (106, '0106_dispute_evidence',           'table',   'purchase_evidence',   null),
    (107, '0107_earned_survives_window',     'column',  'account_withdrawals', 'payout_window_closed_at'),
    (108, '0108_suspension_paid_coins_limited', 'funcsrc', 'admin_suspend_account', '0108'),
    (109, '0109_refund_expiry_preview',      'funcsrc', 'my_booking_refund_quote', '0109'),
    (110, '0110_gift_share_metric',          'funcsrc', 'admin_business_kpis', '0110'),
    -- ★0111 は 0110 の作った集計窓のTZずれを直したもの。日付変数の導入が目印
    --   (0110 の版は ::timestamptz で、この変数を持たない)
    (111, '0111_kpi_window_timezone_fix',    'funcsrc', 'admin_business_kpis', 'v_from_d'),
    (112, '0112_admin_board_moderation',     'funcsrc', 'admin_remove_board_post', 'admin_remove_board_post'),
    (113, '0113_board_is_for_hosts',         'column',  'bookings',            'from_board_post_id'),
    (114, '0114_board_time_window',          'column',  'board_posts',         'window_start'),
    (115, '0115_hosts_open_at',              'funcsrc', 'hosts_open_at',       'hosts_open_at'),
    (116, '0116_hidden_hosts',               'table',   'hidden_hosts',        null),
    (117, '0117_public_activity_stats',      'column',  'platform_pricing',    'activity_stats_min_plays')
),
checked as (
  select
    e.seq,
    e.migration,
    case e.kind
      when 'table' then exists (
        select 1 from information_schema.tables
        where table_schema = 'public' and table_name = e.obj)
      when 'column' then exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = e.obj and column_name = e.needle)
      when 'view' then exists (
        select 1 from pg_views
        where schemaname = 'public' and viewname = e.obj
          and definition like '%' || e.needle || '%')
      when 'funcsrc' then exists (
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = e.obj
          and pg_get_functiondef(p.oid) like '%' || e.needle || '%')
      -- 「未ログインから呼べなくなっていること」を確認する種別
      when 'noexec' then not has_function_privilege('anon', 'public.' || e.obj, 'execute')
      -- 表に検査制約が付いているか(obj=表名, needle=制約名)
      when 'constraint' then exists (
        select 1 from pg_constraint c
        where c.conrelid = ('public.' || e.obj)::regclass and c.conname = e.needle)
      -- 表のコメント(説明文)が期待どおりに書き換わっているか
      when 'tcomment' then coalesce(
        obj_description(('public.' || e.obj)::regclass) like '%' || e.needle || '%', false)
      -- 表にトリガが付いているか(obj=表名, needle=トリガ名)
      when 'trigger' then exists (
        select 1 from pg_trigger t
        where t.tgrelid = ('public.' || e.obj)::regclass
          and not t.tgisinternal and t.tgname = e.needle)
    end as applied
  from expected e
)
select
  c.seq as "番号",
  c.migration || '.sql' as "ファイル",
  case when c.applied then '✅ 適用済み' else '⬜ 未適用' end as "状態",
  case
    -- 未適用なのに、その後ろが適用されている = 順番を飛ばしている
    when not c.applied and exists (
      select 1 from checked l where l.seq > c.seq and l.applied)
      then '⚠️ 飛ばされています。後続を当て直す必要があります'
    when not c.applied and c.seq = (select min(seq) from checked where not applied)
      then '← 次はこれ'
    else ''
  end as "備考"
from checked c
order by c.seq;

-- ------------------------------------------------------------
-- ひとことでの要約
-- ------------------------------------------------------------
with expected(seq, migration, kind, obj, needle) as (
  values
    (37, '0037_ranking_avatar',          'funcsrc', 'host_ranking',                'avatar_path'),
    (38, '0038_host_trial_discount',     'column',  'host_settings',               'trial_discount_percent'),
    (39, '0039_extension_full_price',    'funcsrc', 'extend_booking',              '0039'),
    (40, '0040_scheduled_booking',       'column',  'bookings',                    'requested_start_at'),
    (41, '0041_longer_bookings',         'column',  'platform_pricing',            'max_duration_minutes'),
    (42, '0042_booking_hold',            'column',  'bookings',                    'held_at'),
    (43, '0043_integrity_checks',        'table',   'integrity_checks',            null),
    (44, '0044_ledger_immutable',        'table',   'ledger_audit',                null),
    (45, '0045_evidence_refund_percent', 'view',    'guest_cancellation_evidence', 'WHEN (confirmed_at IS NOT NULL)'),
    (46, '0046_account_anonymize',       'table',   'account_anonymizations',      null),
    (47, '0047_ledger_export_heartbeat', 'table',   'ledger_exports',              null),
    (48, '0048_longer_play_12h',         'column',  'platform_pricing',            'cancel_forfeit_cap_minutes'),
    (49, '0049_booking_slot_conflict',   'view',    'booking_slots',               'FROM bookings'),
    (50, '0050_no_show_auto',            'column',  'bookings',                    'guest_checked_in_at'),
    (51, '0051_host_availability',       'table',   'host_availability',           null),
    (52, '0052_public_host_listing',    'funcsrc', 'public_host_cards',           'discoverable'),
    (53, '0053_favorites',              'table',   'favorites',                   null),
    (54, '0054_favorite_slot_notify',   'column',  'host_settings',               'slots_notified_at'),
    (55, '0055_play_history_with',      'funcsrc', 'my_play_history_with',        'last_played_at'),
    (56, '0056_host_status',            'column',  'host_settings',               'status_text'),
    (57, '0057_regulars_first',         'column',  'host_settings',               'regulars_first_hours'),
    (58, '0058_repeat_proof',           'funcsrc', 'public_host_cards',           'repeat_guests'),
    (59, '0059_last_play_shape',        'funcsrc', 'my_play_history_with',        'last_duration_minutes'),
    (60, '0060_discovery_repeat_rank',  'funcsrc', 'public_host_cards',           'repeat_score'),
    (61, '0061_booking_series',         'funcsrc', 'create_booking_series',       'INVALID_SERIES_COUNT'),
    (62, '0062_fast_release',           'table',   'fast_release_prefs',          null),
    (63, '0063_align_payout_terms',     'funcsrc', 'request_bank_payout',         '5000'),
    (64, '0064_web_push',               'table',   'push_subscriptions',          null),
    -- 未ログインへの過剰なEXECUTEを閉じた。塞げたかは has_function_privilege で見る
    (65, '0065_lock_down_function_grants', 'noexec', '_ledger_record_bypass(text, text, jsonb, jsonb)', null),
    (66, '0066_admin_console',          'table',   'admin_actions',               null),
    -- コメントだけを直した移行。表の説明文が新しい言い方になっているかで見る
    (67, '0067_favorites_wording',      'tcomment', 'favorites',                  'お気に入り登録。誰が誰を'),
    -- 管理操作の記録漏れをふさいだ。通報の閲覧を記録するようになったかで見る
    (68, '0068_admin_read_audit',       'funcsrc', 'admin_reports',              'view_reports'),
    -- 0063で消えたギフトの7日換金保留を復活させた
    (69, '0069_restore_gift_payout_hold', 'funcsrc', 'request_bank_payout',      'GIFT_ON_HOLD'),
    -- 会計用の残高集計。将来のインボイス用の列でも見られる
    (70, '0070_accounting_reconciliation', 'column', 'host_settings',            'invoice_registration_number'),
    -- あんしん保証料→あんしんサポート料。コメントの文言で見る
    (71, '0071_safety_fee_rename',       'tcomment', 'platform_pricing',          'あんしんサポート料の率'),
    -- 短縮設定が既存予約に遡らないようにした。判定条件が入ったかで見る
    (72, '0072_fast_release_no_retroactive', 'funcsrc', 'auto_complete_bookings',  'f.created_at <= b.created_at'),
    -- 料率を画面に出すための読み取り口(規約 第8条の2第3項)
    (73, '0073_fee_rates_public',        'funcsrc', 'fee_rates',                  'bookingTiers'),
    -- みまもり撤回に実際の効果を持たせた。メッセージ側のトリガで見る
    (74, '0074_monitoring_revoke_effect', 'trigger', 'messages',                  'messages_require_consent'),
    -- チャージバック中はコインを使えなくした(税理士 第2回Q14・リリース前必須)
    (75, '0075_payment_dispute_freeze',  'table',   'payment_disputes',           null),
    -- 会計集計を税理士の第2回回答に合わせた。仮受金の行が出るかで見る
    (76, '0076_accounting_round2',       'funcsrc', 'accounting_balances',        '仮受金(換金手数料)'),
    -- 係争中のチャージバックに紐づく報酬を換金保留にした(税理士 第3回)
    (77, '0077_dispute_payout_hold',     'funcsrc', 'request_bank_payout',        'DISPUTE_ON_HOLD'),
    -- 純額処理を選べるよう「PF利用料のうち無償コイン起因」を内数で出す(税理士 第4回)
    (78, '0078_bonus_origin_fee',        'funcsrc', 'accounting_revenue',         '無償コイン起因'),
    -- 会計ソフト取込用の仕訳を自動生成する(月次の締めをSQL Editorから外す)
    (79, '0079_accounting_journal',      'funcsrc', 'accounting_journal',         '販売促進費'),
    -- カード共有の検知(E-9)。端末0021・IP0022と揃えて3つ目
    (80, '0080_card_fingerprint_monitoring', 'table', 'user_payment_cards',      null),
    -- 居住地の自己申告(規約第3条3項・突合表G4)
    (81, '0081_residency_declaration',   'trigger', 'identity_verifications',    'identity_verifications_require_residency'),
    -- コインの消費順序を期限優先に(弁護士 第3回回答 論点4)
    (82, '0082_consume_by_expiry',       'funcsrc', 'create_booking',            '_split_coins_by_expiry'),
    -- 購入ボーナスの廃止(事業判断。法務・税務・資金の3論点が同時に消える)
    (83, '0083_no_purchase_bonus',    'constraint', 'coin_packs',                'coin_packs_no_bonus_check'),
    -- 通知設定の行が無いユーザーの救済(設定画面のトグルが無反応だった)
    (84, '0084_notification_prefs_selfheal', 'funcsrc', 'get_notification_prefs',  'on conflict (user_id) do nothing'),
    -- 無帰責の返還で消滅した分の金銭返金(規約第9条5の3・G8)
    (85, '0085_cash_refund_lapsed',        'table', 'cash_refunds',              null),
    -- 退会(規約第6条の2・G6)。退会後90日は報酬コインの換金だけができる
    (86, '0086_account_withdrawal',        'column', 'profiles',                  'withdrawn_at'),
    -- 新規ユーザーの購入上限とコインの出所(規約第8条の6第5項1号・G11前半)
    (87, '0087_new_user_purchase_limit',   'column', 'coin_lots',                 'purchase_id'),
    -- チャージバック清算の相殺と、新規原資の換金保留(規約第8条の6・G11後半)
    (88, '0088_chargeback_offset',          'table', 'chargeback_offsets',        null),
    -- 失効の事前通知・期限の表示(G7)と申出の期間制限(G9)
    (89, '0089_expiry_notice_and_claim_window', 'column', 'coin_lots',            'expiry_notified_at'),
    -- 購入の取消しとサポート料の返還(規約第7条の3第5項・税理士Q14(c)・G5)
    (90, '0090_void_purchase_refund',        'table', 'purchase_voids',           null),
    -- 料率の遡及適用の防止(規約第8条の2第4項・5項・G3)
    (91, '0091_fee_rate_grandfathering',    'column', 'host_fee_tiers',           'effective_from'),
    -- 退会で投稿等の表示を止める(規約第10条の2第4項)
    (92, '0092_withdraw_clears_posts',    'funcsrc', 'withdraw_account',          'voice_path = null'),
    -- 0065の当て漏れの回収。0091が作り直して開き直した穴も同時に閉じる
    (93, '0093_relock_function_grants',  'noexec',  'host_progressive_fee(int, timestamptz)', null),
    -- 未ログインに開いていた163本を5本に絞る(Supabaseの既定権限への対処)
    (94, '0094_close_anon_function_grants', 'noexec', '_booking_slot_conflict(uuid, timestamptz, int, uuid, text[])', null),
    -- Edge Function だけが呼ぶ関数を利用者から閉じる(コインの付与が開いていた)
    (95, '0095_close_server_only_functions', 'noexec',
         'credit_coins_for_purchase(uuid, text, int, int, int, text, text)', null),

    -- ── 2026-08-26 追記(0096〜0117)。目印は、全適用済みのローカルDBで
    --    1本ずつ「実際に残っているか」を確認して選んでいます。
    --    ★関数を目印にするときは、**後のマイグレーションで差し替わっても
    --      残る文字列**を選ぶこと。番号のコメントは書き換えで消えます
    --      (0102 の '0102' は 0109 の差し替えで消えていました)。
    --      消えるものしか無い場合は、関数名そのものを needle にして
    --      「その関数が存在するか」を見ています。
    (96,  '0096_payment_method_on_purchase', 'column',  'coin_purchases',      'payment_method'),
    (97,  '0097_gift_as_two_obligations',    'funcsrc', 'send_gift',           '0097'),
    (98,  '0098_withdrawal_payout_and_suspension_coins',
                                             'column',  'profiles',            'payout_claim_deadline'),
    (99,  '0099_offset_time_limit',          'funcsrc', 'chargeback_offset_preview', '0099'),
    (100, '0100_final_payout_must_be_whole', 'funcsrc', 'request_bank_payout', '0100'),
    (101, '0101_operator_adjustable_limits', 'column',  'platform_pricing',    'gift_max_per_tx'),
    (102, '0102_played_then_cancelled',      'funcsrc', 'cancel_booking',      '0102'),
    (103, '0103_fee_on_actual_earnings',     'funcsrc', '_apply_booking_fee',  '0103'),
    -- 0104 は「番号」が本体に残らないので、緩めた対象の列名を目印にする
    (104, '0104_webhook_purchase_records',   'funcsrc', '_purchase_immutable', 'payment_method'),
    -- 0105 が作る2関数のうち、後で差し替わらないほう
    (105, '0105_business_kpis',              'funcsrc', 'admin_payment_method_mix', 'admin_payment_method_mix'),
    (106, '0106_dispute_evidence',           'table',   'purchase_evidence',   null),
    (107, '0107_earned_survives_window',     'column',  'account_withdrawals', 'payout_window_closed_at'),
    (108, '0108_suspension_paid_coins_limited', 'funcsrc', 'admin_suspend_account', '0108'),
    (109, '0109_refund_expiry_preview',      'funcsrc', 'my_booking_refund_quote', '0109'),
    (110, '0110_gift_share_metric',          'funcsrc', 'admin_business_kpis', '0110'),
    -- ★0111 は 0110 の作った集計窓のTZずれを直したもの。日付変数の導入が目印
    --   (0110 の版は ::timestamptz で、この変数を持たない)
    (111, '0111_kpi_window_timezone_fix',    'funcsrc', 'admin_business_kpis', 'v_from_d'),
    (112, '0112_admin_board_moderation',     'funcsrc', 'admin_remove_board_post', 'admin_remove_board_post'),
    (113, '0113_board_is_for_hosts',         'column',  'bookings',            'from_board_post_id'),
    (114, '0114_board_time_window',          'column',  'board_posts',         'window_start'),
    (115, '0115_hosts_open_at',              'funcsrc', 'hosts_open_at',       'hosts_open_at'),
    (116, '0116_hidden_hosts',               'table',   'hidden_hosts',        null),
    (117, '0117_public_activity_stats',      'column',  'platform_pricing',    'activity_stats_min_plays')
),
checked as (
  select e.seq, e.migration,
    case e.kind
      when 'table' then exists (select 1 from information_schema.tables
        where table_schema = 'public' and table_name = e.obj)
      when 'column' then exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = e.obj and column_name = e.needle)
      when 'view' then exists (select 1 from pg_views
        where schemaname = 'public' and viewname = e.obj
          and definition like '%' || e.needle || '%')
      when 'funcsrc' then exists (select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = e.obj
          and pg_get_functiondef(p.oid) like '%' || e.needle || '%')
      when 'noexec' then not has_function_privilege('anon', 'public.' || e.obj, 'execute')
      -- 表に検査制約が付いているか(obj=表名, needle=制約名)
      when 'constraint' then exists (
        select 1 from pg_constraint c
        where c.conrelid = ('public.' || e.obj)::regclass and c.conname = e.needle)
      -- 表のコメント(説明文)が期待どおりに書き換わっているか
      when 'tcomment' then coalesce(
        obj_description(('public.' || e.obj)::regclass) like '%' || e.needle || '%', false)
      -- 表にトリガが付いているか(obj=表名, needle=トリガ名)
      when 'trigger' then exists (
        select 1 from pg_trigger t
        where t.tgrelid = ('public.' || e.obj)::regclass
          and not t.tgisinternal and t.tgname = e.needle)
    end as applied
  from expected e
)
select
  count(*) filter (where applied) as "適用済み",
  count(*) filter (where not applied) as "未適用",
  coalesce((select migration || '.sql' from checked where not applied order by seq limit 1),
           'すべて適用済み') as "次に適用するファイル",
  case
    when exists (
      select 1 from checked a
      where not a.applied and exists (select 1 from checked b where b.seq > a.seq and b.applied))
      then '⚠️ 順番が飛んでいます。飛ばした番号から順に当て直してください'
    else 'OK 順番の飛びはありません'
  end as "順番の確認"
from checked;
