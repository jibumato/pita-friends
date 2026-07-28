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
    (59, '0059_last_play_shape',        'funcsrc', 'my_play_history_with',        'last_duration_minutes')
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
    (59, '0059_last_play_shape',        'funcsrc', 'my_play_history_with',        'last_duration_minutes')
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
