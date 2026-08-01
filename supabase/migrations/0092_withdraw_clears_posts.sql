-- ============================================================
-- 0092: 退会で投稿等の表示を止める(規約 第10条の2第4項)
--
-- 2026-08-01、同種サービス(GameRoom)の規約と突合して、当社に
-- **投稿物に関する条文が1つも無い**ことが分かり、第10条の2を新設した。
--
--   4項「前項の許諾は、ユーザーが投稿等を削除し、または退会した後は、
--        **将来に向かって終了します**」
--
-- ■ 条文を書いたら、その場で実装まで持っていく
--   07-31の条文改訂では、条文だけ先に整えて実装が6件遅れた(G6〜G11)。
--   **同じことを繰り返さない。** 第10条の2第4項は、退会後も
--   自己紹介・音声プロフィール・アバターへの参照が残っていると
--   守れないので、退会の処理でそこを落とす。
--
-- ■ 落とさないもの
--   第10条の2第4項1号・2号の例外にあたるもの。
--   ・**レビューとマナースコアの算定根拠**(取引の正確性を保つために要る)
--   ・法令に基づく記録
--   ニックネームも残す。**取引履歴の相手が「(削除済み)」になると、
--   相手側が自分の履歴を確認できなくなる。**
--
-- ■ ここで消せないもの
--   ストレージ上の実体(音声・アバターのファイル)。**参照を切るだけ。**
--   実体の削除は avatar-delete / voice-delete を運営が回す。
-- ============================================================

create or replace function public.withdraw_account(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking int;
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;

  if exists (select 1 from public.profiles p
              where p.id = v_uid and p.withdrawn_at is not null) then
    raise exception 'ALREADY_WITHDRAWN';
  end if;

  -- 第6条の2第2項。**成立済みの予約を残したまま辞めさせない。**
  -- 相手のあることなので、片方が黙って消えると相手が救済されない
  select count(*) into v_blocking
  from public.bookings b
  where (b.guest_id = v_uid or b.host_id = v_uid)
    and b.status in ('requested', 'confirmed');
  if coalesce(v_blocking, 0) > 0 then
    raise exception 'HAS_ACTIVE_BOOKINGS';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = v_uid for update;

  -- ----------------------------------------------------------
  -- コインを消滅させる(第7条3項・第6条の2第3項)
  --
  -- **報酬コイン(earned_balance)には手を付けない。** 換金の対象であり、
  -- ここで消すと弁護士の指摘した「人質」そのものになる
  -- ----------------------------------------------------------
  if coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0 then
    update public.coin_lots
      set remaining = 0
      where user_id = v_uid and remaining > 0;
    update public.coin_wallets
      set balance = 0, bonus_balance = 0
      where user_id = v_uid;
    if coalesce(v_paid, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_paid, 'expire', 'withdraw_paid');
    end if;
    if coalesce(v_bonus, 0) > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (v_uid, -v_bonus, 'expire', 'withdraw_bonus');
    end if;
  end if;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**ので、
  -- ここを落とすことで退会者が誰の目にも触れなくなる
  update public.host_settings set is_host = false where user_id = v_uid;

  -- 0092: 規約 第10条の2第4項。**投稿等の利用許諾は退会で将来に向かって終わる。**
  -- 条文でそう約束した以上、表示に使う投稿物への参照はここで落とす。
  -- 落とさないものは第10条の2第4項1号・2号の例外(レビューと、
  -- マナースコアの算定根拠、法令に基づく記録)だけ。
  --
  -- ⚠️ ストレージ上の実体(音声・アバターのファイル)はここでは消せない。
  --    参照を切ったうえで、運営が avatar-delete / voice-delete を回す。
  --    **参照だけ切って安心しないこと。**
  update public.profiles
    set withdrawn_at = now(),
        presence_status = 'busy',
        bio = '',
        voice_path = null,
        voice_seconds = null,
        avatar_path = null,
        favorite_games = '{}'
    where id = v_uid;

  insert into public.account_withdrawals
    (user_id, expired_paid_coins, expired_bonus_coins, earned_balance, payout_deadline, reason)
  values (v_uid, coalesce(v_paid, 0), coalesce(v_bonus, 0), coalesce(v_earned, 0),
          v_deadline, p_reason);

  -- 期限を本人に残す。画面を閉じても分かるように通知にも書く
  insert into public.notifications (user_id, type, title, body)
  values (v_uid, 'system', '退会の手続が完了しました',
    case when coalesce(v_earned, 0) > 0
      then '報酬コイン' || v_earned || '枚の換金は、'
             || to_char(v_deadline, 'YYYY年MM月DD日') || 'まで申請できます。'
             || '期限を過ぎると消滅します。'
      else 'ご利用ありがとうございました。' end);

  return jsonb_build_object(
    'withdrawn_at', now(),
    'expired_paid', coalesce(v_paid, 0),
    'expired_bonus', coalesce(v_bonus, 0),
    'earned_balance', coalesce(v_earned, 0),
    'payout_deadline', v_deadline
  );
end;
$$;

revoke all on function public.withdraw_account(text) from public, anon;
grant execute on function public.withdraw_account(text) to authenticated;
