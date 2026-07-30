-- Web Push(0064)の検証。
--
-- 重点は3つ。
--   ・**通知の記録がプッシュの都合で壊れないこと。** 積むだけで、送信は別。
--   ・**ロック画面に本文を出さない種類があること。** メッセージとギフトは題名だけ。
--   ・**静かにする時間で attempts が減らないこと。** 止めているあいだ試行回数を
--     食うと、朝になる前に「3回で諦め」に達して永久に届かなくなる。
--
-- 「いま何時か」に依存させないため、静かにする時間はJSTの現在時から作る。

\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f1000000-0000-0000-0000-000000000001'::uuid),  -- 端末を登録した人
  ('f1000000-0000-0000-0000-000000000002'::uuid),  -- 登録していない人
  ('f1000000-0000-0000-0000-000000000003'::uuid)   -- 端末を横取りする人
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('f1000000-0000-0000-0000-000000000001'::uuid, '購読者'),
  ('f1000000-0000-0000-0000-000000000002'::uuid, '未購読'),
  ('f1000000-0000-0000-0000-000000000003'::uuid, '別の人')
on conflict (id) do update set nickname = excluded.nickname;

\echo '=== 1. 端末を登録していない人の通知は積まれない ==='
do $$
begin
  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000002'::uuid, 'invite_received', '誘いが届きました', 'Apex');
  if (select count(*) from public.push_outbox
      where user_id = 'f1000000-0000-0000-0000-000000000002'::uuid) <> 0 then
    raise exception 'FAIL: 送り先が無いのに積まれた';
  end if;
  -- 通知そのものは残っている(プッシュの都合で消えない)
  if (select count(*) from public.notifications
      where user_id = 'f1000000-0000-0000-0000-000000000002'::uuid) <> 1 then
    raise exception 'FAIL: 通知が記録されていない';
  end if;
end $$;

\echo '=== 2. 端末は本人しか登録できない / 登録すると積まれる ==='
set test.uid = 'f1000000-0000-0000-0000-000000000001';
do $$
begin
  perform public.save_push_subscription('https://push.example/aaa', 'key-a', 'auth-a', 'iPhone Safari');
  if (select count(*) from public.push_subscriptions
      where user_id = 'f1000000-0000-0000-0000-000000000001'::uuid) <> 1 then
    raise exception 'FAIL: 登録できていない';
  end if;
  -- 2回呼んでも増えない(起動ごとに呼ぶ想定)
  perform public.save_push_subscription('https://push.example/aaa', 'key-a', 'auth-a', 'iPhone Safari');
  if (select count(*) from public.push_subscriptions
      where endpoint = 'https://push.example/aaa') <> 1 then
    raise exception 'FAIL: endpointが重複した';
  end if;

  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'booking_approved', '予約が承認されました', '明日21:00');
  if (select count(*) from public.push_outbox
      where user_id = 'f1000000-0000-0000-0000-000000000001'::uuid) <> 1 then
    raise exception 'FAIL: 積まれていない';
  end if;
end $$;

\echo '=== 3. ロック画面に本文を出さない種類(メッセージ・ギフト) ==='
do $$
declare v_body text;
begin
  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'message_received',
          'あきさんからメッセージ', '今夜21時からいける？集合場所は');
  select body into v_body from public.push_outbox
    where type = 'message_received' and user_id = 'f1000000-0000-0000-0000-000000000001'::uuid;
  if v_body <> '' then
    raise exception 'FAIL: メッセージ本文がロック画面に出る: %', v_body;
  end if;
  -- 題名は残る(誰から来たかは伝わってよい)
  if (select title from public.push_outbox where type = 'message_received'
      and user_id = 'f1000000-0000-0000-0000-000000000001'::uuid) not like '%あき%' then
    raise exception 'FAIL: 題名まで消えている';
  end if;

  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'gift_received',
          'あきさんからギフトが届きました', '5000コインを受け取りました「ナイスプレイ」');
  select body into v_body from public.push_outbox
    where type = 'gift_received' and user_id = 'f1000000-0000-0000-0000-000000000001'::uuid;
  if v_body <> '' then
    raise exception 'FAIL: ギフトの金額がロック画面に出る: %', v_body;
  end if;

  -- 予約の通知は本文を出してよい
  if (select body from public.push_outbox where type = 'booking_approved'
      and user_id = 'f1000000-0000-0000-0000-000000000001'::uuid) <> '明日21:00' then
    raise exception 'FAIL: 予約の本文まで消えている';
  end if;
end $$;

\echo '=== 4. 取り出せる / 完了にすると二度と取り出されない ==='
do $$
declare v_n int; v_id uuid;
begin
  select count(*) into v_n from public.claim_push_batch(100);
  if v_n <> 3 then raise exception 'FAIL: 3件のはずが %件', v_n; end if;
  -- 試行回数が増えている
  if (select min(attempts) from public.push_outbox
      where user_id = 'f1000000-0000-0000-0000-000000000001'::uuid) <> 1 then
    raise exception 'FAIL: attemptsが増えていない';
  end if;

  -- 1件でも届いたら完了
  select id into v_id from public.push_outbox where type = 'booking_approved';
  perform public.mark_push_result(v_id, 1, null);
  if (select sent_at from public.push_outbox where id = v_id) is null then
    raise exception 'FAIL: 完了になっていない';
  end if;
  if exists (select 1 from public.claim_push_batch(100) c where c.outbox_id = v_id) then
    raise exception 'FAIL: 完了した分が再度出てきた';
  end if;
end $$;

\echo '=== 5. 3回で諦める ==='
do $$
declare v_id uuid;
begin
  select id into v_id from public.push_outbox where type = 'message_received';
  -- 上で1回、ここまでで2回。1回足して3回にする
  perform public.mark_push_result(v_id, 0, 'boom');
  perform public.claim_push_batch(100);
  if (select attempts from public.push_outbox where id = v_id) < 3 then
    raise exception 'FAIL: attemptsが3に届いていない: %',
      (select attempts from public.push_outbox where id = v_id);
  end if;
  if exists (select 1 from public.claim_push_batch(100) c where c.outbox_id = v_id) then
    raise exception 'FAIL: 3回を超えても取り出される';
  end if;
  if (select last_error from public.push_outbox where id = v_id) <> 'boom' then
    raise exception 'FAIL: エラーが残っていない';
  end if;
end $$;

\echo '=== 6. push_enabled を切ると取り出されない(積まれてはいる) ==='
do $$
begin
  perform public.set_push_settings(false, null, null);
  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'booking_cancelled', 'キャンセルされました', '');
  if not exists (select 1 from public.push_outbox where type = 'booking_cancelled') then
    raise exception 'FAIL: 積まれていない(送信時に判定する設計のはず)';
  end if;
  if exists (select 1 from public.claim_push_batch(100) c
             join public.push_outbox o on o.id = c.outbox_id
             where o.type = 'booking_cancelled') then
    raise exception 'FAIL: 切ってあるのに取り出された';
  end if;
  -- 戻せばそのまま届く。attemptsを食っていないこと
  if (select attempts from public.push_outbox where type = 'booking_cancelled') <> 0 then
    raise exception 'FAIL: 止めているあいだに試行回数を食っている';
  end if;
  perform public.set_push_settings(true, null, null);
  if not exists (select 1 from public.claim_push_batch(100) c
                 join public.push_outbox o on o.id = c.outbox_id
                 where o.type = 'booking_cancelled') then
    raise exception 'FAIL: 戻したのに取り出されない';
  end if;
end $$;

\echo '=== 7. 静かにする時間: 急がない種類だけ止まる ==='
-- 「いま」を含む1時間の範囲を作る。日付をまたぐ指定も同じ式で通る
do $$
declare
  h int := extract(hour from now() at time zone 'Asia/Tokyo')::int;
  v_casual uuid;
  v_urgent uuid;
begin
  -- 判定そのものの確認。h をまたぐ4通りで、両方の分岐(from<to / from>to)を通る
  if not public._push_in_quiet_hours(h::smallint, ((h + 1) % 24)::smallint) then
    raise exception 'FAIL: いまを含む範囲が false';
  end if;
  if public._push_in_quiet_hours(((h + 1) % 24)::smallint, ((h + 2) % 24)::smallint) then
    raise exception 'FAIL: いまを含まない範囲が true';
  end if;
  if not public._push_in_quiet_hours(h::smallint, ((h + 23) % 24)::smallint) then
    raise exception 'FAIL: 23時間の範囲(いまを含む)が false';
  end if;
  if public._push_in_quiet_hours(((h + 1) % 24)::smallint, h::smallint) then
    raise exception 'FAIL: 23時間の範囲(いまだけ除く)が true';
  end if;
  -- null は「止めない」
  if public._push_in_quiet_hours(null, null) then
    raise exception 'FAIL: 未設定で止まった';
  end if;

  perform public.set_push_settings(true, h, (h + 1) % 24);

  -- 急がない種類(枠が空いた)は止まる
  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'host_slots_opened', 'お気に入りのピタメイトが枠を開けました', '今週末')
  returning id into v_casual;
  -- 急ぐ種類(通報の警告)は通る
  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'integrity_alert', '確認のお願い', '')
  returning id into v_urgent;

  if exists (select 1 from public.claim_push_batch(100) c
             join public.push_outbox o on o.id = c.outbox_id
             where o.notification_id = v_casual) then
    raise exception 'FAIL: 静かな時間に急がない通知が出た';
  end if;
  if not exists (select 1 from public.claim_push_batch(100) c
                 join public.push_outbox o on o.id = c.outbox_id
                 where o.notification_id = v_urgent) then
    raise exception 'FAIL: 静かな時間でも急ぐ通知は通すべき';
  end if;
  -- **ここが肝**: 止めているあいだ試行回数を食っていない
  if (select attempts from public.push_outbox where notification_id = v_casual) <> 0 then
    raise exception 'FAIL: 止めているあいだに試行回数を食っている(朝までに諦めてしまう)';
  end if;

  -- 時間が明ければそのまま届く
  perform public.set_push_settings(true, (h + 2) % 24, (h + 3) % 24);
  if not exists (select 1 from public.claim_push_batch(100) c
                 join public.push_outbox o on o.id = c.outbox_id
                 where o.notification_id = v_casual) then
    raise exception 'FAIL: 時間が明けたのに届かない';
  end if;
  perform public.set_push_settings(true, null, null);
end $$;

\echo '=== 8. 404で止めた購読には送らない ==='
do $$
begin
  perform public.disable_push_subscription('https://push.example/aaa', 'gone');
  insert into public.notifications (user_id, type, title, body)
  values ('f1000000-0000-0000-0000-000000000001'::uuid, 'booking_no_show', '来ませんでした', '');
  -- 送り先が無いので積まれない
  if exists (select 1 from public.push_outbox where type = 'booking_no_show') then
    raise exception 'FAIL: 止めた購読しか無いのに積まれた';
  end if;
  -- 行は残す(調べる手がかりのため)
  if not exists (select 1 from public.push_subscriptions where endpoint = 'https://push.example/aaa') then
    raise exception 'FAIL: 行を消してしまっている';
  end if;
  -- 登録し直すと生き返る
  perform public.save_push_subscription('https://push.example/aaa', 'key-a2', 'auth-a2', 'iPhone Safari');
  if (select disabled_at from public.push_subscriptions where endpoint = 'https://push.example/aaa') is not null then
    raise exception 'FAIL: 登録し直しても止まったまま';
  end if;
end $$;

\echo '=== 9. 同じ端末で別の人がログインしたら付け替わる ==='
set test.uid = 'f1000000-0000-0000-0000-000000000003';
do $$
begin
  perform public.save_push_subscription('https://push.example/aaa', 'key-b', 'auth-b', 'iPhone Safari');
  if (select user_id from public.push_subscriptions where endpoint = 'https://push.example/aaa')
     <> 'f1000000-0000-0000-0000-000000000003'::uuid then
    raise exception 'FAIL: 付け替わっていない';
  end if;
  -- 前の人にはもうその端末へ行かない
  if exists (select 1 from public.push_subscriptions
             where user_id = 'f1000000-0000-0000-0000-000000000001'::uuid and disabled_at is null) then
    raise exception 'FAIL: 前の人の宛先として残っている';
  end if;
end $$;

\echo '=== 10. 他人の購読は見えない ==='
do $$
declare v text;
begin
  -- ポリシーは自分の行の select/delete だけ。insert/update の口は作らない
  select string_agg(polname, ', ' order by polname) into v
  from pg_policy where polrelid = 'public.push_subscriptions'::regclass;
  if v is distinct from 'push_subscriptions_delete_own, push_subscriptions_select_own' then
    raise exception 'FAIL: 想定外のポリシー: %', coalesce(v, '(なし)');
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.push_subscriptions'::regclass) then
    raise exception 'FAIL: RLSが無効';
  end if;
  -- outbox は利用者に一切見せない(ポリシーを1本も作らない)
  if exists (select 1 from pg_policy where polrelid = 'public.push_outbox'::regclass) then
    raise exception 'FAIL: outboxにポリシーがある(利用者に見せる必要はない)';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.push_outbox'::regclass) then
    raise exception 'FAIL: outboxのRLSが無効';
  end if;
end $$;

\echo '=== 11. 権限: 送信側の関数を利用者が叩けない ==='
do $$
begin
  if has_function_privilege('authenticated', 'public.claim_push_batch(integer)', 'execute') then
    raise exception 'FAIL: 利用者が送信待ちを取り出せる';
  end if;
  if has_function_privilege('authenticated', 'public.mark_push_result(uuid, integer, text)', 'execute') then
    raise exception 'FAIL: 利用者が送信結果を書ける';
  end if;
  if has_function_privilege('authenticated', 'public.disable_push_subscription(text, text)', 'execute') then
    raise exception 'FAIL: 利用者が他人の購読を止められる';
  end if;
  if has_function_privilege('authenticated', 'public.prune_push()', 'execute') then
    raise exception 'FAIL: 利用者が片付けを叩ける';
  end if;
  if has_function_privilege('anon', 'public.save_push_subscription(text, text, text, text)', 'execute') then
    raise exception 'FAIL: 未ログインで端末を登録できる';
  end if;
  if has_function_privilege('anon', 'public.my_push_settings()', 'execute') then
    raise exception 'FAIL: 未ログインで設定を読める';
  end if;
  -- 本人向けの口は authenticated に開いていること
  if not has_function_privilege('authenticated', 'public.save_push_subscription(text, text, text, text)', 'execute') then
    raise exception 'FAIL: 本人が端末を登録できない';
  end if;
  if not has_function_privilege('service_role', 'public.claim_push_batch(integer)', 'execute') then
    raise exception 'FAIL: 送信側が取り出せない';
  end if;
end $$;

\echo '=== 12. 片付け ==='
do $$
declare v_n int;
begin
  update public.push_outbox set sent_at = now() - interval '8 days' where sent_at is not null;
  update public.push_outbox set created_at = now() - interval '2 days' where sent_at is null;
  v_n := public.prune_push();
  if (select count(*) from public.push_outbox) <> 0 then
    raise exception 'FAIL: 古い分が残っている(%件)', (select count(*) from public.push_outbox);
  end if;
  if v_n < 1 then raise exception 'FAIL: 件数を返していない'; end if;
end $$;

reset test.uid;
delete from public.push_outbox where user_id::text like 'f1000000-%';
delete from public.push_subscriptions where user_id::text like 'f1000000-%';
delete from public.notifications where user_id::text like 'f1000000-%';
delete from public.notification_prefs where user_id::text like 'f1000000-%';
delete from public.profiles where id::text like 'f1000000-%';
delete from auth.users where id::text like 'f1000000-%';

\echo '=== 75_web_push: 全項目OK ==='
