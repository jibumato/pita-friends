-- ============================================================
-- 0046_account_anonymize.sql
-- 退会を「物理削除」から「匿名化」に変える
-- ------------------------------------------------------------
-- 【いま何が起きるか】
-- coin_wallets / coin_transactions / coin_lots / coin_purchases / payouts /
-- bookings は、すべて auth.users に on delete cascade でぶら下がっています。
-- つまり Supabase の管理画面からユーザーを1人消すと、その人の入金記録も
-- 換金記録も一緒に消えます。警告は出ません。「監査用」と書いた
-- coin_transactions ごと消えます。
--
-- そして account_requests(アカウント削除請求)は運営が手動で対応する設計なので、
-- 退会対応をした瞬間にこれを踏みます。事故ではなく通常運用で起きます。
--
-- 【なぜ消してはいけないか】
-- 消えるのは帳簿として保存義務のある記録です(所得税法上7年、資金決済法上の
-- 記録保持)。削除請求に応じる義務があるのは**個人情報**であって、取引金額の
-- 記録ではありません。プライバシーポリシー草案も
-- 「法令上の保存義務がある場合を除き削除」と書いており、実装と食い違っています。
--
-- 【この移行でやること】
--   ・氏名・連絡先・口座・画像など、その人を識別する情報は消す
--   ・金額と日時の記録は残す(誰のものかは user_id でのみ辿れる状態にする)
--   ・未処理の取引が残っているうちは実行できないようにする
--   ・残っている前払いコインは失効させ、履歴に1行残す(残高だけ0にすると
--     0043の照合が鳴るため)
--
-- なお 0044 の保護により、この関数を使わずユーザーを物理削除しようとすると
-- LEDGER_IMMUTABLE で止まります。黙って消えることはもうありません。
-- ============================================================

-- 退会時のコイン失効を履歴で区別できるようにする
alter table public.coin_transactions drop constraint if exists coin_transactions_type_check;
alter table public.coin_transactions
  add constraint coin_transactions_type_check
  check (type in (
    'purchase', 'booking_spend', 'refund', 'bonus',
    'booking_earned', 'payout', 'expire',
    'gift_sent', 'gift_received',
    'platform_fee', 'withdrawal'
  ));

-- 匿名化済みかどうかを画面側で判別できるようにする
alter table public.profiles
  add column if not exists anonymized_at timestamptz;

comment on column public.profiles.anonymized_at is
  '退会により匿名化した時刻。非nullの行は「退会したユーザー」として表示する。';

-- ------------------------------------------------------------
-- account_anonymizations: 匿名化の実施記録
--   誰の請求で・いつ・誰が実行したかを残す(個人情報保護法上の対応記録)
-- ------------------------------------------------------------
create table if not exists public.account_anonymizations (
  user_id uuid primary key references auth.users (id) on delete cascade,
  anonymized_at timestamptz not null default now(),
  actor uuid,
  reason text not null default 'user_request',
  forfeited_paid int not null default 0,
  forfeited_bonus int not null default 0
);

comment on table public.account_anonymizations is
  '退会(匿名化)の実施記録。個人情報の削除請求に対応したことの証跡。';

alter table public.account_anonymizations enable row level security;

drop policy if exists "account_anonymizations_select_admin" on public.account_anonymizations;
create policy "account_anonymizations_select_admin"
  on public.account_anonymizations for select
  to authenticated
  using (exists (select 1 from public.admins where user_id = auth.uid()));

-- ------------------------------------------------------------
-- anonymize_user: 退会処理の本体(管理者のみ)
-- ------------------------------------------------------------
create or replace function public.anonymize_user(
  p_user_id uuid,
  p_reason text default 'user_request'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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

  delete from storage.objects
    where name like p_user_id::text || '/%'
       or owner = p_user_id;

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
$$;

comment on function public.anonymize_user(uuid, text) is
  '退会処理。個人を識別する情報を消し、金額と日時の記録は残す。'
  '未処理の予約・換金・報酬残高があるときは実行できない。管理者のみ。';

revoke all on function public.anonymize_user(uuid, text) from public;
grant execute on function public.anonymize_user(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- pending_account_deletions: 退会請求の一覧(運営用)
--   実行できない理由(未処理の取引)も一緒に出す
-- ------------------------------------------------------------
create or replace view public.pending_account_deletions
with (security_invoker = true) as
select
  r.user_id,
  r.created_at as requested_at,
  p.nickname,
  (select count(*) from public.bookings b
    where (b.guest_id = r.user_id or b.host_id = r.user_id)
      and b.status in ('requested', 'confirmed')) as open_bookings,
  (select count(*) from public.payouts po
    where po.user_id = r.user_id and po.status = 'pending') as pending_payouts,
  coalesce(w.earned_balance, 0) as earned_balance,
  coalesce(w.balance, 0) + coalesce(w.bonus_balance, 0) as prepaid_balance
from public.account_requests r
join public.profiles p on p.id = r.user_id
left join public.coin_wallets w on w.user_id = r.user_id
where r.type = 'account_deletion' and r.status <> 'completed'
order by r.created_at;

comment on view public.pending_account_deletions is
  '未対応の退会請求。open_bookings/pending_payouts/earned_balance が全て0でないと anonymize_user() は実行できない。';
