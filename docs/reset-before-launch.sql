-- ============================================================
-- 公開前のテストデータ全消去
-- ------------------------------------------------------------
-- ⚠️⚠️ **本番のデータを消します。実行は1回きりです。** ⚠️⚠️
--
-- 目的:
--   開発中に作ったテスト用のコイン残高・取引・予約・トークを、
--   **公開前に完全に消して 0 から始める**ためのスクリプト。
--
-- ■ 安全装置(3段)
--
--   ①**アカウントを明示的に列挙しないと動きません。** 下の
--     `target_users` に消すユーザーのIDを書きます。空なら何もしません。
--   ②**列挙したアカウント以外にデータが1件でもあれば中断します。**
--     ＝ 本物の利用者が1人でも使い始めたら、このスクリプトは動きません。
--   ③**振込済み(status='paid')の換金が1件でもあれば中断します。**
--     実際にお金が動いた記録を消させないためです。
--
--   さらに全体が1つのトランザクションです。途中で中断すれば**何も消えません。**
--
-- ■ 消すもの / 残すもの
--
--   消す: コイン残高・ロット・取引・購入・換金・利用料・予約・約束・
--         トーク・ギフト・レビュー・通報・通知・信頼スコア 等
--   残す: **アカウント(auth.users)・プロフィール・運営権限(admins)**
--         **ledger_audit(この消去自体の記録)・admin_actions(操作記録)**
--
--   監査の記録を残すのは意図的です。**「消した」ことの記録まで消すと、
--   後から誰も検証できません。** 未公開の期間に消したという事実は、
--   むしろ残しておくほうが説明が楽になります。
--
-- ■ 手順
--
--   1. まず「0. 下見」だけを実行して、消える件数を確認する
--   2. `target_users` に自分のテストアカウントのIDを書く
--   3. 全体を実行する
--   4. 「9. 確認」の出力がすべて 0 になっていることを見る
--   5. **Supabase の Database → Backups で、実行前のバックアップがあることを
--      確認してから始める**(Proプランの日次バックアップ)
-- ============================================================


-- ============================================================
-- 0. 下見(読み取りのみ)。**まずこれだけを実行してください。**
-- ============================================================
select 'ユーザー' as 対象, u.id::text as id,
       coalesce(p.nickname, '(名前なし)') as 名前,
       coalesce(w.balance, 0) as 有償コイン,
       coalesce(w.bonus_balance, 0) as 無償コイン,
       coalesce(w.earned_balance, 0) as 報酬コイン,
       (select count(*) from public.bookings b
         where b.guest_id = u.id or b.host_id = u.id) as 予約件数,
       (select count(*) from public.coin_transactions t where t.user_id = u.id) as 取引件数,
       case when a.user_id is not null then '運営' else '' end as 権限
from auth.users u
left join public.profiles p on p.id = u.id
left join public.coin_wallets w on w.user_id = u.id
left join public.admins a on a.user_id = u.id
order by 権限 desc, 名前;


-- ============================================================
-- 1〜9. 本体。**ここから下をまとめて実行します。**
-- ============================================================
begin;

-- 追記専用の台帳(0044)を一時的に解除する。
-- **set local なのでこのトランザクションの中だけ**有効で、
-- 解除して行った操作は ledger_audit に自動で記録されます。
set local app.ledger_override = 'on';

-- ------------------------------------------------------------
-- 1. 消す対象のアカウントをここに書く
--
-- ⚠️ **ここを埋めないと何も起きません。**(空の配列 = 対象0件)
--    「0. 下見」で出た id をコピーしてください。
-- ------------------------------------------------------------
create temporary table target_users (user_id uuid primary key) on commit drop;

insert into target_users (user_id) values
  -- ('00000000-0000-0000-0000-000000000000'),   -- ← テストアカウント
  -- ('00000000-0000-0000-0000-000000000000')    -- ← 管理者アカウント
  ('00000000-0000-0000-0000-000000000000')       -- ← ダミー。**必ず書き換える**
;

-- ダミーのままなら止める(書き換え忘れの事故を防ぐ)
do $$
begin
  if exists (select 1 from target_users where user_id = '00000000-0000-0000-0000-000000000000') then
    raise exception
      '⛔ target_users がダミーのままです。「0. 下見」で出たIDに書き換えてください';
  end if;
  if not exists (select 1 from target_users) then
    raise exception '⛔ target_users が空です。消す対象を1件以上書いてください';
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. ★安全装置: 対象外のアカウントにデータがあれば中断する
--
-- **本物の利用者が1人でも使い始めていたら、ここで止まります。**
-- 「テストデータを消すつもりが、本番のデータを消していた」は
-- 取り返しがつかないので、確認ではなく**中断**にしてあります。
-- ------------------------------------------------------------
do $$
declare v_n int; v_who text;
begin
  select count(*), string_agg(distinct x.user_id::text, ', ')
    into v_n, v_who
  from (
    select user_id from public.coin_transactions
    union select user_id from public.coin_purchases
    union select user_id from public.coin_lots
    union select user_id from public.payouts
    union select guest_id from public.bookings
    union select host_id from public.bookings
  ) x
  where x.user_id not in (select user_id from target_users);

  if v_n > 0 then
    raise exception
      '⛔ 対象外のアカウントに取引データがあります(%件)。本物の利用者が使い始めている可能性があるため中断しました。該当: %',
      v_n, left(v_who, 300);
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. ★安全装置: 振込済みの換金があれば中断する
--
-- 実際に銀行送金が行われた記録は、テストであっても消しません。
-- (テスト中に「振込済みにする」を押していた場合は、まずその意味を
--  確認してください。押した記録自体が運用の証跡です)
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from public.payouts where status = 'paid';
  if v_n > 0 then
    raise exception
      '⛔ 振込済みの換金が%件あります。実際に送金した記録は消せません。中断しました', v_n;
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. 予約に紐づくもの(子から順に消す)
-- ------------------------------------------------------------
create temporary table target_bookings on commit drop as
  select b.id from public.bookings b
  where b.guest_id in (select user_id from target_users)
     or b.host_id in (select user_id from target_users);

create temporary table target_promises on commit drop as
  select id from public.promises where booking_id in (select id from target_bookings);

delete from public.gifts         where promise_id in (select id from target_promises);
delete from public.message_reads where promise_id in (select id from target_promises);
delete from public.messages      where promise_id in (select id from target_promises);
delete from public.reviews       where promise_id in (select id from target_promises);
delete from public.promises      where id in (select id from target_promises);
delete from public.platform_fees where booking_id in (select id from target_bookings);
delete from public.coin_lot_consumptions where booking_id in (select id from target_bookings);
delete from public.bookings where id in (select id from target_bookings);

-- ------------------------------------------------------------
-- 5. コインの台帳
-- ------------------------------------------------------------
delete from public.coin_lot_consumptions where user_id in (select user_id from target_users);
delete from public.coin_lots            where user_id in (select user_id from target_users);
delete from public.coin_transactions    where user_id in (select user_id from target_users);
delete from public.coin_purchases       where user_id in (select user_id from target_users);
delete from public.payouts              where user_id in (select user_id from target_users);
delete from public.platform_fees        where host_id in (select user_id from target_users);
delete from public.payment_disputes     where user_id in (select user_id from target_users);
delete from public.user_payment_cards   where user_id in (select user_id from target_users);

-- 残高を0に戻す(行は残す。無いと次の購入で落ちるため)
update public.coin_wallets
   set balance = 0, bonus_balance = 0, earned_balance = 0
 where user_id in (select user_id from target_users);

-- ------------------------------------------------------------
-- 6. 交流の記録(予約に紐づかないもの)
-- ------------------------------------------------------------
delete from public.message_reads where user_id in (select user_id from target_users);
delete from public.messages     where sender_id in (select user_id from target_users);
-- 残った約束(誘い由来。予約に紐づかないもの)も消す
delete from public.gifts        where sender_id in (select user_id from target_users)
                                   or receiver_id in (select user_id from target_users);
delete from public.reviews      where reviewer_id in (select user_id from target_users)
                                   or reviewee_id in (select user_id from target_users);
delete from public.message_reads where promise_id in (
  select id from public.promises where user_a in (select user_id from target_users)
                                     or user_b in (select user_id from target_users));
delete from public.messages     where promise_id in (
  select id from public.promises where user_a in (select user_id from target_users)
                                     or user_b in (select user_id from target_users));
delete from public.promises     where user_a in (select user_id from target_users)
                                   or user_b in (select user_id from target_users);
delete from public.invites      where from_user in (select user_id from target_users)
                                   or to_user in (select user_id from target_users);
delete from public.board_participants where user_id in (select user_id from target_users);
delete from public.board_posts  where creator_id in (select user_id from target_users);
delete from public.favorites    where user_id in (select user_id from target_users)
                                   or host_id in (select user_id from target_users);
delete from public.blocks       where blocker_id in (select user_id from target_users)
                                   or blocked_id in (select user_id from target_users);
delete from public.manner_penalties where report_id in (
  select id from public.reports where reporter_id in (select user_id from target_users)
                                    or reported_id in (select user_id from target_users));
delete from public.reports      where reporter_id in (select user_id from target_users)
                                   or reported_id in (select user_id from target_users);
delete from public.content_flags where user_id in (select user_id from target_users);
delete from public.manner_penalties where user_id in (select user_id from target_users);
delete from public.notifications where user_id in (select user_id from target_users);
delete from public.push_outbox   where user_id in (select user_id from target_users);
delete from public.account_requests where user_id in (select user_id from target_users);

-- ------------------------------------------------------------
-- 7. 実績のカウンタを初期化する
--
-- **ここを忘れると、テストで作った「完了3回」「マナースコア」が
-- そのまま公開後の掲載順とプロフィールに出ます。**
-- ------------------------------------------------------------
update public.profile_trust_stats
   set manner_score = default,
       review_count = 0,
       confirmed_count = 0,
       dotakyan_count = 0,
       updated_at = now()
 where user_id in (select user_id from target_users);

-- ------------------------------------------------------------
-- 8. 開発中に触った端末・IPの記録
--    (不正検知の材料。テスト分が残ると誤検知のもとになる)
-- ------------------------------------------------------------
delete from public.user_devices where user_id in (select user_id from target_users);
delete from public.user_ips     where user_id in (select user_id from target_users);

-- ------------------------------------------------------------
-- 9. 確認: **すべて 0 になっていること**
--    1件でも残っていたら、ここで中断して rollback します
-- ------------------------------------------------------------
do $$
declare v_rec record; v_bad int := 0;
begin
  for v_rec in
    select 'コイン取引' as 項目, count(*) as 件数 from public.coin_transactions
    union all select 'コイン購入', count(*) from public.coin_purchases
    union all select 'コインロット', count(*) from public.coin_lots
    union all select '換金', count(*) from public.payouts
    union all select '予約', count(*) from public.bookings
    union all select '約束', count(*) from public.promises
    union all select 'メッセージ', count(*) from public.messages
    union all select 'ギフト', count(*) from public.gifts
    union all select 'PF利用料', count(*) from public.platform_fees
    union all select '残高の合計',
      coalesce(sum(balance + bonus_balance + earned_balance), 0)::bigint
      from public.coin_wallets
  loop
    raise notice '  % … %', v_rec.項目, v_rec.件数;
    if v_rec.件数 <> 0 then v_bad := v_bad + 1; end if;
  end loop;

  if v_bad > 0 then
    raise exception
      '⛔ %項目にデータが残っています。**rollback します。**対象アカウントの列挙漏れか、このスクリプトが拾えていない表があります',
      v_bad;
  end if;
  raise notice '✅ すべて0になりました。commit してよい状態です';
end $$;

-- ⚠️ 上の確認が通ったら commit、通らなければ自動で rollback されます
commit;


-- ============================================================
-- 実行後にやること
-- ============================================================
--
-- 1. **会計の突合をやり直す**(運営コンソール →「会計」タブ)
--    3科目とも 0 / 0 / OK になるはずです。
--    ⚠️ ただし**取引が0件なので、この OK は「合っている」証拠になりません。**
--    0と0を比べているだけです。最初の実購入が通ってから改めて見てください。
--
-- 2. **整合性チェックを1回流す**
--      select public.run_integrity_checks();
--      select * from public.integrity_latest;
--    すべて ok になっていることを確認します。
--
-- 3. **消した記録が残っていることを確認する**
--      select table_name, action, count(*)
--      from public.ledger_audit
--      where at > now() - interval '1 hour'
--      group by 1, 2 order by 1;
--    追記専用の台帳を解除して消したので、ここに件数が出ます。
--    **これは残しておいてください。**「未公開の期間にテストデータを
--    消した」という記録そのものです。
--
-- 4. Stripe 側のテストデータは**別管理**です。ダッシュボードを
--    「テスト環境」に切り替えて確認してください。本番環境(live)に
--    データが無ければ、そちらは何もしなくて構いません。
--
-- ============================================================
-- 消していないもの(意図的)
-- ============================================================
--
-- | 残すもの | 理由 |
-- |---|---|
-- | auth.users / profiles / admins | アカウントそのもの。**運営アカウントを消すと入れなくなる** |
-- | ledger_audit | **この消去自体の記録。** 消すと誰も検証できなくなる |
-- | admin_actions | 運営操作の記録(誰がいつ口座情報を見たか等) |
-- | identity_verifications | 本人確認の履歴。再提出の手間を避けるため |
-- | monitoring_consents / residency_declarations | 同意・申告の記録。**取り直すと日付が今日になる** |
-- | integrity_checks / ledger_exports | 監視の履歴。古い分は自動で間引かれる |
--
-- **本人確認や同意もやり直したい場合**は、上の commit の前に次を足します。
-- ただし**同意の記録を消すと、みまもりの同意を取り直すまで
-- メッセージが送れなくなります**(0074)。承知のうえで。
--
--   delete from public.identity_verifications where user_id in (select user_id from target_users);
--   delete from public.monitoring_consents    where user_id in (select user_id from target_users);
--   delete from public.residency_declarations where user_id in (select user_id from target_users);
--   update public.profile_trust_stats set is_verified = false
--    where user_id in (select user_id from target_users);
