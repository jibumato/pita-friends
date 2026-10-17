-- ============================================================
-- 0129: 本人確認の画像を、サーバー側で確実に消して記録する
--
-- 規約 第3条5項は「本人確認のために取得した書類・顔写真の画像は、照合の
-- 完了後すみやかに削除」と約束している。ところが:
--   ・0007 の SQL による削除は権限エラーで承認ごと失敗したため 0008 で外され、
--     判定後に運営のブラウザから消す方式になっていた。失敗しても握りつぶし、
--     消したかどうかの記録も無い
--   ・申請行の作成に失敗すると、画像だけが残る
--   ・退会時の anonymize_user(0046)は、0008 で失敗したのと同じ SQL での
--     削除をしていて、本番では匿名化そのものが失敗するおそれがある
--
-- ファイルの削除は Edge Function `identity-images-purge`(service role で
-- Storage API を使う。avatar-delete と同じ方式)に移し、ここでは
-- 「消したか」を記録する列を足す。
--
-- ⚠️ anonymize_user の本体は適用済みのDBから取り出したもの。
--    差分は storage.objects の削除をやめた1か所だけ。
-- ============================================================

alter table public.identity_verifications
  add column if not exists images_deleted_at timestamptz;

comment on column public.identity_verifications.images_deleted_at is
  '提出画像(document_path / selfie_path)をストレージから消した日時(0129)。'
  'identity-images-purge が判定直後と毎日の掃除で入れる。null のまま判定済みなら消し残し。';

alter table public.account_anonymizations
  add column if not exists storage_purged_at timestamptz;

comment on column public.account_anonymizations.storage_purged_at is
  '匿名化した利用者のファイル(本人確認・アバター・声)をストレージから消した日時(0129)。'
  'anonymize_user は SQL で消せない(0008)ので、identity-images-purge の毎日の掃除が消して入れる。';

CREATE OR REPLACE FUNCTION public.anonymize_user(p_user_id uuid, p_reason text DEFAULT 'user_request'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_paid int;
  v_bonus int;
  v_earned int;
  v_open_bookings int;
  v_pending_payouts int;
  v_has_deleted_at boolean;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if p_user_id is null then
    raise exception 'INVALID_USER';
  end if;
  if exists (select 1 from public.account_anonymizations where user_id = p_user_id) then
    raise exception 'ALREADY_ANONYMIZED';
  end if;

  -- ------------------------------------------------------------
  -- 未処理の取引が残っているうちは実行しない。
  -- 匿名化してから「振込先が分からない」「相手が誰か分からない」と
  -- なるのを防ぐ。先に決着をつけてから退会させる。
  -- ------------------------------------------------------------
  select count(*) into v_open_bookings from public.bookings
    where (guest_id = p_user_id or host_id = p_user_id)
      and status in ('requested', 'confirmed');
  if v_open_bookings > 0 then
    raise exception 'OPEN_BOOKINGS_REMAIN';
  end if;

  select count(*) into v_pending_payouts from public.payouts
    where user_id = p_user_id and status = 'pending';
  if v_pending_payouts > 0 then
    raise exception 'PENDING_PAYOUT_REMAINS';
  end if;

  select balance, bonus_balance, earned_balance
    into v_paid, v_bonus, v_earned
    from public.coin_wallets where user_id = p_user_id for update;

  -- 報酬は役務の対価(未払金)なので、勝手に消してはいけない。
  -- 換金するか、本人の意思で放棄してもらうまで退会させない。
  if coalesce(v_earned, 0) > 0 then
    raise exception 'EARNED_BALANCE_REMAINS';
  end if;

  -- ------------------------------------------------------------
  -- 残っている前払いコインを失効させる(規約:退会時の払戻しなし)。
  -- 残高だけ0にすると履歴と食い違い、0043の照合が鳴るので、
  -- ロット・残高・履歴の3点セットで落とす。
  -- ------------------------------------------------------------
  update public.coin_lots set remaining = 0
    where user_id = p_user_id and remaining > 0;

  if coalesce(v_paid, 0) + coalesce(v_bonus, 0) > 0 then
    update public.coin_wallets set balance = 0, bonus_balance = 0
      where user_id = p_user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, -(coalesce(v_paid, 0) + coalesce(v_bonus, 0)),
              'withdrawal', 'anonymize:' || p_reason);
  end if;

  -- ------------------------------------------------------------
  -- ここから個人を識別する情報を消す
  -- ------------------------------------------------------------
  update public.profiles set
    nickname = '退会したユーザー',
    gender = 'na',
    avatar_initial = '',
    avatar_color = '#CCCCCC',
    favorite_games = '{}',
    play_style = 'エンジョイ',
    bio = '',
    voice_path = null,
    voice_seconds = null,
    avatar_path = null,
    last_seen_at = null,
    -- presence_status に「退会」は無いので、少なくとも空き扱いにならない値にする
    -- (一覧からは anonymized_at と is_host=false で外れる)
    presence_status = 'busy',
    anonymized_at = now()
  where id = p_user_id;

  -- 掲載を止め、紹介文を消す
  update public.host_settings set
    is_host = false,
    games = '{}',
    bio = ''
  where user_id = p_user_id;

  -- 振込先口座は保存義務の対象ではない(金額はpayoutsに残る)
  delete from public.host_bank_accounts where user_id = p_user_id;

  -- 本人確認書類の参照を外す(実体はstorageから消す)
  update public.identity_verifications set
    document_path = null,
    selfie_path = null,
    provider_reference = null
  where user_id = p_user_id;

  -- 0129: ここで storage.objects を SQL で消していたのをやめる。
  -- 0008 で、同じやり方が本番では権限エラー(42501)になり承認ごと失敗した
  -- 記録がある。このままだと**匿名化そのものが失敗する**。ファイルの削除は
  -- identity-images-purge(service role の Storage API)に任せ、ここでは
  -- 下の account_anonymizations.storage_purged_at が null のまま残ることで
  -- 「まだ消していない」印にする。

  -- 端末・IPは不正検知用の識別子なので消す
  delete from public.user_devices where user_id = p_user_id;
  delete from public.user_ips where user_id = p_user_id;

  -- 通知・通知設定・安心設定は残す理由がない
  delete from public.notifications where user_id = p_user_id;
  delete from public.notification_prefs where user_id = p_user_id;
  delete from public.safety_prefs where user_id = p_user_id;

  -- 募集は取り下げ、自由記述を消す
  update public.board_posts set
    status = 'cancelled',
    note = null,
    cancelled_at = coalesce(cancelled_at, now()),
    cancel_reason = coalesce(cancel_reason, '投稿者の退会')
  where creator_id = p_user_id and status <> 'cancelled';

  -- 削除請求があれば完了にする
  update public.account_requests set status = 'completed'
    where user_id = p_user_id and type = 'account_deletion' and status <> 'completed';

  -- ------------------------------------------------------------
  -- 認証情報(メールアドレス)も消す。
  -- 本番の auth.users には deleted_at があるので論理削除にし、行そのものは
  -- 残す(消すと台帳が道連れになるため)。テスト用シムには無いので、
  -- 列の有無を見てから実行する。
  -- ------------------------------------------------------------
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users' and column_name = 'deleted_at'
  ) into v_has_deleted_at;

  if v_has_deleted_at then
    execute format(
      'update auth.users set email = %L, deleted_at = coalesce(deleted_at, now()) where id = %L',
      'anonymized+' || p_user_id::text || '@invalid.local', p_user_id);
  else
    execute format('update auth.users set email = %L where id = %L',
      'anonymized+' || p_user_id::text || '@invalid.local', p_user_id);
  end if;

  insert into public.account_anonymizations
    (user_id, actor, reason, forfeited_paid, forfeited_bonus)
    values (p_user_id, auth.uid(), p_reason, coalesce(v_paid, 0), coalesce(v_bonus, 0));
end;
$function$;
