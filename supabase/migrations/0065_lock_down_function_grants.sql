-- ============================================================
-- 0065_lock_down_function_grants.sql
-- 意図せず未ログインに開いていた関数を閉じる（セキュリティ修正）
-- ------------------------------------------------------------
-- ■ 何が起きていたか
--   PostgreSQL は **関数を作ると既定で PUBLIC に EXECUTE を与える。**
--   `revoke all ... from public` を書かなかった関数は、そのぶん
--   anon（未ログイン）からも呼べる状態になっていた。
--   RLS も権限も正しく張れていて、anon はどのテーブルも直接は読めない
--   （`grant` が1つも無い）のに、**SECURITY DEFINER 関数はそれを飛び越える**
--   ため、内部用の補助関数が抜け穴になっていた。
--
-- ■ 実際に未ログインで再現した2件
--
--   (1) `_booking_slot_conflict(user, 開始, 分)` — **他人の予定を丸ごと引ける**
--       指定した相手がその時間に予約を持っていれば予約IDを返す。
--       時刻をずらして繰り返せば、任意の相手の予約表が復元できる。
--       しかも相手のUUIDは `public_host_cards()`（未ログインで見える一覧）が
--       返しているので、**掲載中のピタメイト全員の稼働予定が外から読めた。**
--       このサービスで「誰がいつ誰と遊ぶか」は最も漏らしてはいけない情報で、
--       出会い系非該当の実態維持にも関わる。
--
--   (2) `_ledger_record_bypass(表, 操作, 旧, 新)` — **台帳に嘘を書ける**
--       0044 の追記専用台帳（`ledger_audit`）へ、引数そのままの行を差し込む。
--       未ログインで「payouts を 9,999,999 円に更新した」という記録を
--       作れてしまった。金銭トラブルの立証や税務で使う記録なので、
--       汚染されると価値が消える。無制限に積めるので保管費用にも響く。
--
--   どちらも「読めてしまう / 書けてしまう」だけで、正規の残高やコインを
--   動かせるものではない。だが (1) は個人情報の漏えい、(2) は証跡の汚染で、
--   どちらも公開前に閉じる必要がある。
--
-- ■ 方針
--   内部用の補助関数と、トリガー用の関数は **PUBLIC から取り上げる。**
--   これらは SECURITY DEFINER 関数の中から呼ばれるだけで、そのときは
--   定義者の権限で動くため、PUBLIC の EXECUTE は要らない。
--
--   未ログインに見せてよいもの（`public_host_cards` / `host_ranking` /
--   `host_repeat_guests` / `host_repeat_stats` など、掲載一覧に出す材料）は
--   そのまま残す。閉じると未ログインのトップが空になる。
--
-- ■ 同じ穴を二度作らないために
--   `supabase/tests/74_anon_surface.sql` で、**未ログインが実行できる
--   SECURITY DEFINER 関数の一覧を固定**した。関数を足して revoke を
--   忘れると、そのテストが落ちる。
-- ============================================================

-- ------------------------------------------------------------
-- (1) 他人の予定を引ける穴を閉じる
-- ------------------------------------------------------------
-- create_booking / approve_booking / extend_booking の中から呼ばれるだけ。
-- 呼び出し元が SECURITY DEFINER なので、そこでは定義者の権限で実行される。
revoke all on function
  public._booking_slot_conflict(uuid, timestamptz, int, uuid, text[]) from public;

-- 予約枠の排他ロック。外から取れると予約作成を妨害できる（DoS）
revoke all on function public._lock_booking_slots(uuid, uuid) from public;

-- ------------------------------------------------------------
-- (2) 台帳に嘘を書ける穴を閉じる
-- ------------------------------------------------------------
-- 0044 の各トリガーの中からだけ呼ばれる。誰にも grant しない。
revoke all on function public._ledger_record_bypass(text, text, jsonb, jsonb) from public;

-- ------------------------------------------------------------
-- 旧シグネチャの create_booking（3引数）
-- ------------------------------------------------------------
-- 中で4引数版に委ねており、そちらが auth.uid() を検査するので実害は無いが、
-- 未ログインに見せる理由も無い。クライアントは4引数版しか使っていない。
revoke all on function public.create_booking(uuid, int, text) from public;
grant execute on function public.create_booking(uuid, int, text) to authenticated;

-- ------------------------------------------------------------
-- トリガー用の関数
-- ------------------------------------------------------------
-- plpgsql のトリガー関数は直接呼ぶとエラーになるので実害は無い。
-- ただし「未ログインに開いている SECURITY DEFINER 関数」の一覧に紛れると、
-- 本当に危ないものを見落とす。監査できる状態を保つために閉じる。
revoke all on function public._apply_booking_fee() from public;
revoke all on function public._apply_gift_fee() from public;
revoke all on function public._checkin_on_message() from public;
revoke all on function public._consumption_restore_only() from public;
revoke all on function public._enqueue_push() from public;
revoke all on function public._hold_bookings_on_report() from public;
revoke all on function public._ledger_immutable() from public;
revoke all on function public._ledger_no_delete() from public;
revoke all on function public._payout_amount_immutable() from public;
revoke all on function public.check_host_requires_verification() from public;
revoke all on function public.clear_last_seen_on_hide() from public;
revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user_notification_prefs() from public;
revoke all on function public.handle_new_user_wallet() from public;
revoke all on function public.notify_board_joined() from public;
revoke all on function public.notify_invite_approved() from public;
revoke all on function public.notify_invite_received() from public;
revoke all on function public.notify_message_received() from public;
revoke all on function public.reviews_after_insert_recompute() from public;
revoke all on function public.set_report_severity() from public;
revoke all on function public.set_updated_at() from public;

-- ------------------------------------------------------------
-- 内部計算用の関数
-- ------------------------------------------------------------
-- SECURITY DEFINER ではないので RLS は飛び越えないが、
-- 手数料や失効日の計算を外から叩けるようにしておく理由も無い。
revoke all on function public._push_is_casual(text) from public;
revoke all on function public._push_lockscreen_body(text, text) from public;
revoke all on function public._push_in_quiet_hours(smallint, smallint) from public;
revoke all on function public._ledger_override_on() from public;
revoke all on function public.host_progressive_fee(int) from public;
revoke all on function public.host_monthly_ticket_gmv(uuid, timestamptz, uuid) from public;
revoke all on function public.safety_fee_for(int) from public;
revoke all on function public.coin_expiry_from(timestamptz) from public;
revoke all on function public.is_valid_booking_duration(int) from public;
revoke all on function public.booking_refund_percent(text, timestamptz, timestamptz, timestamptz) from public;
revoke all on function public.booking_refund_coins(int, int, int, timestamptz, timestamptz) from public;
revoke all on function public.fresh_host_status(text, timestamptz) from public;
revoke all on function public.booking_fits_availability(uuid, timestamptz, int) from public;
-- 枠の判定はどちらも public_host_cards / create_booking の中から呼ばれるだけで、
-- クライアントは直接叩いていない。掲載一覧に必要な情報は
-- public_host_cards が返しているので、こちらは閉じる。
revoke all on function public.host_has_availability(uuid) from public;
revoke all on function public.host_is_open_at(uuid, timestamptz) from public;

-- ------------------------------------------------------------
-- 未ログインに残すもの（意図的）
-- ------------------------------------------------------------
-- 掲載中のピタメイト一覧・ランキングは未ログインでも見える設計（0052）。
-- 閉じるとトップページが空になる。返している内容は
-- 86_public_host_listing.sql で「未ログインに見せてよいか」を都度確認している。
--   public_host_cards(int)         … 一覧そのもの
--   host_ranking(text, int)        … ランキング（金額は含めない：弁護士Q11(d)）
--   host_repeat_guests(uuid)       … リピーター数（人数のみ。一覧にも出ている）
--   host_repeat_stats(uuid[])      … 同上を一括で
-- この4本はクライアントが実際に未ログインで呼んでいる。ほかは閉じてよい。
grant execute on function public.public_host_cards(int) to anon, authenticated;
grant execute on function public.host_ranking(text, int) to anon, authenticated;
grant execute on function public.host_repeat_guests(uuid) to anon, authenticated;
grant execute on function public.host_repeat_stats(uuid[]) to anon, authenticated;
