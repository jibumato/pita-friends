-- ============================================================
-- 定期ジョブ・拡張・サーバー専用関数の点検
-- ------------------------------------------------------------
-- Supabase の SQL Editor に**そのまま貼って実行**してください。
-- 読み取りだけです。データもスキーマも一切変更しません。
--
-- ⚠️ **`relation "cron.job" does not exist` というエラーが出たら、
--    それが答えです。** pg_cron が有効になっていません。
--    Database → Extensions で pg_cron を有効にしてから、
--    末尾の「直しかた」でジョブを登録し直してください。
--
-- なぜ要るのか:
--   マイグレーションは cron ジョブを自分で登録しますが、
--   **失敗しても例外を握りつぶします**
--   (`exception when others then raise notice`)。
--   これは「pg_cron が使えない環境でもマイグレーションは通す」ための
--   作りですが、裏を返すと**登録に失敗しても静かに進む**ということです。
--
--   ジョブが1つ落ちていても画面はふつうに動きます。気づくのは
--   「72時間経っても予約が確定しない」「失効したはずのコインが残っている」
--   という形で、しかも**数日から数か月あと**です。
--
-- 見かた: 「状態」の列がすべて ✅ ならば問題ありません。
-- ============================================================

with
-- ------------------------------------------------------------
-- 期待している拡張
-- ------------------------------------------------------------
ext(seq, name, purpose) as (values
  (1, 'pg_cron', '定期ジョブ。予約の自動確定・コイン失効・整合性チェック・プッシュ送信'),
  (2, 'pg_net',  'DBからHTTPを叩く。プッシュ送信で Edge Function を呼ぶのに使う')
),

-- ------------------------------------------------------------
-- 期待している定期ジョブ
--   「無いとどうなるか」は、**気づきにくい順**に効いてくるものを書いた
-- ------------------------------------------------------------
jobs(seq, jobname, schedule, purpose, blocker) as (values
  (1, 'auto-complete-bookings',        '23 * * * *',
      'プレイ完了の自動確定(0015)',
      '★確定しないので報酬が発生せず、換金もできない'),
  (2, 'expire-stale-booking-requests', '47 * * * *',
      '承諾されない予約リクエストの期限切れ(0017)',
      'ゲストのコインが返らないまま滞留する'),
  (3, 'expire-coins',                  '11 3 * * *',
      'コインの失効(0018)',
      '★雑収入の計上漏れ。会計タブの「期限切れ・失効処理待ち」が0にならない'),
  (4, 'run-integrity-checks',          '7 4 * * *',
      '取引データの日次整合性チェック(0043)',
      '台帳のズレに気づけない'),
  (5, 'prune-integrity-checks',        '37 4 * * 0',
      '古いチェック結果の掃除(0043)',
      '行が増え続ける(実害は小さい)'),
  (6, 'check-ledger-export',           '17 4 * * *',
      '外部バックアップの鮮度チェック(0047)',
      '★バックアップが止まったことに気づけない'),
  (7, 'prune-ledger-exports',          '47 4 * * 0',
      '古い実行記録の掃除(0047)',
      '行が増え続ける(実害は小さい)'),
  (8, 'auto-hold-no-show',             '*/5 * * * *',
      '無断欠席の疑いがある予約の保留(0050)',
      '来なかった相手に満額が渡る'),
  (9, 'auto-resolve-no-show',          '13 * * * *',
      '無断欠席の確定処理(0050)',
      '保留のまま放置される'),
  -- ★0107 で 'expire-withdrawn-earned' は**廃止**しました(報酬コインを
  --   消さない方針に変わったため)。unschedule 済みなので、本番に残っていたら
  --   0107 が当たっていないか、当たる前の状態です。
  (10, 'close-withdrawn-payout-window', '31 3 * * *',
      '退会から90日でセルフの換金申請の受付を終了(0107。報酬コインは消さない)',
      '規約第6条の2第4項の期限が効かない'),
  (11, 'notify-expiring-coins',        '9 9 * * *',
      '有効期限が近いコインの事前通知(0089)',
      '★規約第7条5の3の「事前に通知します」を守れない'),
  (12, 'close-expired-board-posts',    '*/15 * * * *',
      '受付の締め切りを過ぎた募集を閉じる(0114)',
      '板が終わった募集で埋まる。公開直後にいちばん効く')
),

-- ------------------------------------------------------------
-- サーバー(service_role)だけが呼べるべき関数
--   **両方向に効く点検。** service_role が閉じていると Webhook が失敗し、
--   authenticated に開いていると利用者側から呼べてしまう。
-- ------------------------------------------------------------
funcs(seq, sig, note) as (values
  (1, 'public.credit_coins_for_purchase(uuid,text,integer,integer,integer,text,text)',
      'コインの付与(0009)'),
  (2, 'public.record_payment_dispute(text,text,text,integer,text,text)',
      'チャージバックの記録(0075)'),
  (3, 'public.record_payment_card(uuid,text,text,text)',
      '決済カードの記録(0080)')
),

result as (
  -- 1. 拡張 --------------------------------------------------
  select 1 as sec, e.seq,
         '拡張'::text as "区分",
         e.name::text as "対象",
         case when x.extname is not null then '✅ 有効' else '❌ 未有効' end as "状態",
         e.purpose::text as "内容",
         case when x.extname is null
              then 'Database → Extensions で有効にし、下記のジョブ登録も行うこと'
              else '' end::text as "備考"
  from ext e
  left join pg_extension x on x.extname = e.name

  union all

  -- 2. 定期ジョブ --------------------------------------------
  select 2, j.seq,
         '定期ジョブ'::text,
         j.jobname::text,
         case
           when c.jobname is null           then '❌ 未登録'
           when not c.active                then '⚠️ 停止中'
           when c.schedule <> j.schedule    then '⚠️ 時刻ちがい(' || c.schedule || ')'
           else '✅'
         end::text,
         j.purpose::text,
         case when c.jobname is null then j.blocker else '' end::text
  from jobs j
  left join cron.job c on c.jobname = j.jobname

  union all

  -- 3. 権限 --------------------------------------------------
  select 3, f.seq,
         '権限'::text,
         f.sig::text,
         case
           when not has_function_privilege('service_role', f.sig, 'execute')
             then '❌ service_role が呼べない(Webhookが失敗します)'
           when has_function_privilege('authenticated', f.sig, 'execute')
             then '❌ authenticated に開いている(利用者から呼べます)'
           else '✅'
         end::text,
         f.note::text,
         ''::text
  from funcs f

  union all

  -- 4. まとめ ------------------------------------------------
  select 4, 1,
         '── 判定 ──'::text,
         ''::text,
         case when
           (select count(*) from ext e
             where not exists (select 1 from pg_extension x where x.extname = e.name))
           + (select count(*) from jobs j
               left join cron.job c on c.jobname = j.jobname
              where c.jobname is null or not c.active or c.schedule <> j.schedule)
           + (select count(*) from funcs f
              where not has_function_privilege('service_role', f.sig, 'execute')
                 or has_function_privilege('authenticated', f.sig, 'execute'))
           = 0
         then '✅ すべて問題ありません'
         else '❌ 上に ❌ または ⚠️ があります。末尾の「直しかた」へ' end::text,
         ''::text, ''::text
)
select "区分", "対象", "状態", "内容", "備考"
from result
order by sec, seq;


-- ============================================================
-- 直しかた
-- ============================================================
--
-- 【拡張が未有効】
--   Database → Extensions で pg_cron / pg_net を有効にしてから、
--   下の「ジョブが未登録」を実行してください。
--   **拡張を後から有効にしても、過去のマイグレーションは遡って
--   ジョブを登録し直しません。**
--
-- 【ジョブが未登録 / 停止中 / 時刻ちがい】
--   次をそのまま実行します。**すでにあるものは上書きされるだけで安全**です。
--
--   select cron.schedule('auto-complete-bookings',        '23 * * * *',  'select public.auto_complete_bookings()');
--   select cron.schedule('expire-stale-booking-requests', '47 * * * *',  'select public.expire_stale_booking_requests()');
--   select cron.schedule('expire-coins',                  '11 3 * * *',  'select public.expire_coins()');
--   select cron.schedule('run-integrity-checks',          '7 4 * * *',   'select public.run_integrity_checks()');
--   select cron.schedule('prune-integrity-checks',        '37 4 * * 0',  'select public.prune_integrity_checks()');
--   select cron.schedule('check-ledger-export',           '17 4 * * *',  'select public.check_ledger_export()');
--   select cron.schedule('prune-ledger-exports',          '47 4 * * 0',  'select public.prune_ledger_exports()');
--   select cron.schedule('auto-hold-no-show',             '*/5 * * * *', 'select public.auto_hold_no_show_bookings()');
--   select cron.schedule('auto-resolve-no-show',          '13 * * * *',  'select public.auto_resolve_no_show_bookings()');
--   select cron.schedule('close-withdrawn-payout-window', '31 3 * * *',  'select public.close_withdrawn_payout_window()');
--   select cron.schedule('notify-expiring-coins',         '9 9 * * *',   'select public.notify_expiring_coins()');
--   select cron.schedule('close-expired-board-posts',     '*/15 * * * *','select public.close_expired_board_posts()');
--
--   ※ 時刻はUTCではなくDBのタイムゾーン(Supabaseの既定はUTC)で解釈されます。
--     夜間に寄せているのは、失敗しても翌朝に気づける時間帯にするためです。
--
-- 【service_role が ❌】
--   grant execute on function <上の関数> to service_role;
--
--   ⚠️ **authenticated には絶対に grant しないこと。**
--     コインの付与と決済カードの記録を、利用者側から自由に呼べてしまいます。
--
-- 【プッシュ通知(push-send / prune-push)】
--   **VAPID鍵を設定してから**登録します(`docs/web-push-setup.md` の手順5)。
--   鍵が無いうちは登録しないでください。送信が毎分失敗し続けます。
--   本スクリプトの点検対象にこの2つを入れていないのは、
--   **鍵の設定前は「未登録が正しい状態」だから**です。
--
-- ============================================================
-- 失敗しているジョブを見る(必要なときだけ・別途実行)
-- ============================================================
--
--   select j.jobname, d.status, d.start_time,
--          left(coalesce(d.return_message, ''), 200) as message
--   from cron.job_run_details d
--   join cron.job j on j.jobid = d.jobid
--   where d.start_time > now() - interval '3 days'
--     and d.status <> 'succeeded'
--   order by d.start_time desc
--   limit 20;
--
--   0件なら直近3日は全部成功しています。
