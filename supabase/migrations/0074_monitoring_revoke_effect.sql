-- ============================================================
-- 0074: みまもり同意の撤回に実際の効果を持たせる(E-5)
-- ------------------------------------------------------------
-- ■ 経緯
--   0031 で同意の記録と撤回のRPCを用意したが、そこには
--     「撤回時のサービス提供の可否は運用・規約側の論点(Q19)。
--       ここでは記録のみを行い、機能の制限はしない。」
--   と書いてあるとおり、**撤回しても何も起きない**器だけの状態だった。
--   撤回条項をどう書くかが未確定で、どちらに倒すかで実装が変わるためである。
--
--   2026-07-30 の弁護士回答(Q16)で文言が確定した:
--
--     > ユーザーは、前項の同意を設定画面からいつでも撤回することができます。
--     > ただし、本項の確認は本サービスにおける安全確保の基盤であるため、
--     > 撤回された場合、当社はメッセージ機能その他の利用者間のやりとりに
--     > 関する機能の提供を停止します。この場合も、既に成立した予約の履行
--     > および換金の手続については、本規約の定めに従います。
--
--   理由(Q16):「撤回できるが撤回すれば退会」では任意性が空文化するが、
--   「撤回すれば当該機能が使えなくなる」は同意の対象と帰結が論理的に
--   対応している(= **監視できない通信は提供しない**)。
--
-- ■ なぜ相手側も止まるのか(Q19)
--   メッセージは**送信者と受信者の双方の通信**であるため、有効な同意は
--   両当事者から得られている必要がある。撤回者が現れた瞬間、その相手との
--   通信は「片方が未同意」になる。したがって撤回は本人の送信を止めるだけでは
--   足りず、**撤回者を相手とするやりとりを双方向で止める**必要がある。
--   これはQ19が「Q16の撤回条項を機能単位にすべき論理的な根拠そのもの」と
--   述べている点の実装である。
--
-- ■ 何を止め、何を止めないか
--   止める(= 新しく「やりとり」を発生させる操作):
--     ・メッセージの送信          … messages への insert(双方向)
--     ・誘いの送信・受領          … invites への insert(双方向)
--     ・募集の投稿・参加          … board_posts / board_participants への insert
--     ・**新規の**予約の成立      … bookings への insert(双方向)
--       予約は必ずトークルームを伴うため、止まっている機能を売ることになる。
--
--   止めない(規約の「既に成立した予約の履行および換金の手続」):
--     ・チェックイン・完了・延長・キャンセル・レビュー … いずれも既存行の update
--     ・コインの購入、換金の申請、口座の登録          … 通信ではない
--     ・ありがとうギフト … 完了済みプレイに対する謝礼で、通信ではない
--
-- ■ 「記録が無い」場合は撤回とみなさない
--   0031 より前に登録した利用者や、同意の記録に失敗した利用者
--   (recordMonitoringConsent は失敗を握りつぶす)には行が無い。
--   行が無いことを「未同意」として機能を止めると、**同意画面で同意した人を
--   記録の失敗という当社側の事情で締め出す**ことになる。
--   よって判定は「撤回した行があり、かつ有効な行が無い」= 明示的に撤回した
--   状態に限る。再同意すれば有効な行が入り、その瞬間に戻る。
-- ============================================================

-- ------------------------------------------------------------
-- _monitoring_consent_revoked: その利用者が「撤回した状態」か
-- ------------------------------------------------------------
create or replace function public._monitoring_consent_revoked(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null
     and exists (
       select 1 from public.monitoring_consents c
       where c.user_id = p_user and c.revoked_at is not null
     )
     and not exists (
       select 1 from public.monitoring_consents c
       where c.user_id = p_user and c.revoked_at is null
     );
$$;

comment on function public._monitoring_consent_revoked(uuid) is
  'みまもり同意を明示的に撤回した状態かどうか。記録が無い場合は false(撤回とみなさない)。';

revoke all on function public._monitoring_consent_revoked(uuid) from public;
-- 呼び出しは下のトリガ関数と my_monitoring_consent() の内部からのみ。
-- SECURITY DEFINER 同士の呼び出しには execute 権限は不要なので誰にも付与しない。

-- ------------------------------------------------------------
-- トリガ本体。二人組の関係(自分と相手)を引数で受けて判定する
-- ------------------------------------------------------------
create or replace function public._require_monitoring_consent(p_self uuid, p_other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public._monitoring_consent_revoked(p_self) then
    raise exception 'MONITORING_CONSENT_REVOKED';
  end if;
  if public._monitoring_consent_revoked(p_other) then
    raise exception 'PARTNER_MONITORING_CONSENT_REVOKED';
  end if;
end;
$$;

comment on function public._require_monitoring_consent(uuid, uuid) is
  'みまもり同意が撤回されていたら例外。メッセージは双方の通信なので相手側も見る(Q19)。';

revoke all on function public._require_monitoring_consent(uuid, uuid) from public;

-- ------------------------------------------------------------
-- messages: 送信を双方向で止める
-- ------------------------------------------------------------
create or replace function public._messages_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
begin
  select case when pr.user_a = new.sender_id then pr.user_b else pr.user_a end
    into v_other
    from public.promises pr
   where pr.id = new.promise_id;
  perform public._require_monitoring_consent(new.sender_id, v_other);
  return new;
end;
$$;

revoke all on function public._messages_require_consent() from public;

drop trigger if exists messages_require_consent on public.messages;
create trigger messages_require_consent
  before insert on public.messages
  for each row execute function public._messages_require_consent();

-- ------------------------------------------------------------
-- invites: 誘いの送信・受領を双方向で止める
-- ------------------------------------------------------------
create or replace function public._invites_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.from_user, new.to_user);
  return new;
end;
$$;

revoke all on function public._invites_require_consent() from public;

drop trigger if exists invites_require_consent on public.invites;
create trigger invites_require_consent
  before insert on public.invites
  for each row execute function public._invites_require_consent();

-- ------------------------------------------------------------
-- bookings: 新規の成立を双方向で止める(既存行の update は止めない)
-- ------------------------------------------------------------
create or replace function public._bookings_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.guest_id, new.host_id);
  return new;
end;
$$;

revoke all on function public._bookings_require_consent() from public;

drop trigger if exists bookings_require_consent on public.bookings;
create trigger bookings_require_consent
  before insert on public.bookings
  for each row execute function public._bookings_require_consent();

-- ------------------------------------------------------------
-- board_posts: 募集の投稿を止める(相手はまだ居ないので本人のみ)
-- ------------------------------------------------------------
create or replace function public._board_posts_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_monitoring_consent(new.creator_id, null);
  return new;
end;
$$;

revoke all on function public._board_posts_require_consent() from public;

drop trigger if exists board_posts_require_consent on public.board_posts;
create trigger board_posts_require_consent
  before insert on public.board_posts
  for each row execute function public._board_posts_require_consent();

-- ------------------------------------------------------------
-- board_participants: 募集への参加を双方向で止める
-- ------------------------------------------------------------
create or replace function public._board_participants_require_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_creator uuid;
begin
  select p.creator_id into v_creator
    from public.board_posts p where p.id = new.post_id;
  perform public._require_monitoring_consent(new.user_id, v_creator);
  return new;
end;
$$;

revoke all on function public._board_participants_require_consent() from public;

drop trigger if exists board_participants_require_consent on public.board_participants;
create trigger board_participants_require_consent
  before insert on public.board_participants
  for each row execute function public._board_participants_require_consent();

-- ------------------------------------------------------------
-- my_monitoring_consent: 自分の同意の現状(設定画面の表示用)
-- ------------------------------------------------------------
-- 撤回すると何が止まるのかを画面で正確に出すために、
-- 「今どちらの状態か」「いつ・どの版に同意したか」を返す。
-- 履歴そのものは monitoring_consents の select ポリシーで本人が読める。
-- ------------------------------------------------------------
create or replace function public.my_monitoring_consent()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    -- 有効な同意があるか。記録が無い場合も true(締め出さない。0074冒頭の注記)
    'active', not public._monitoring_consent_revoked(auth.uid()),
    -- 記録が1件も無い(0031より前の登録・記録の失敗)
    'unrecorded', not exists (
      select 1 from public.monitoring_consents c where c.user_id = auth.uid()
    ),
    'version', (
      select c.version from public.monitoring_consents c
      where c.user_id = auth.uid() and c.revoked_at is null
      order by c.agreed_at desc limit 1
    ),
    'agreedAt', (
      select c.agreed_at from public.monitoring_consents c
      where c.user_id = auth.uid() and c.revoked_at is null
      order by c.agreed_at desc limit 1
    ),
    'revokedAt', (
      select c.revoked_at from public.monitoring_consents c
      where c.user_id = auth.uid() and c.revoked_at is not null
      order by c.revoked_at desc limit 1
    )
  )
  where auth.uid() is not null;
$$;

comment on function public.my_monitoring_consent() is
  'みまもり同意の現状(設定画面の表示用)。未ログインでは null を返す。';

revoke all on function public.my_monitoring_consent() from public;
grant execute on function public.my_monitoring_consent() to authenticated;
