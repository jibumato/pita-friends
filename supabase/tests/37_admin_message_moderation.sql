-- ============================================================
-- 37: トークのメッセージを運営が削除できる(0118)
--
-- ■ このテストの主眼
--   **削除したのに本文が残っていないこと。**
--   画面が読み込む select は body をそのまま取っているので、
--   `deleted_at` を立てるだけでは相手に本文が届き続ける。
--   7番目で、当事者の経路から本文が取れないことを確かめる。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('37000000-0000-0000-0000-000000000001'),  -- 送信者
  ('37000000-0000-0000-0000-000000000002'),  -- 相手
  ('37000000-0000-0000-0000-0000000000ad')   -- 運営
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('37000000-0000-0000-0000-000000000001','送信者'),
  ('37000000-0000-0000-0000-000000000002','相手'),
  ('37000000-0000-0000-0000-0000000000ad','運営')
on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('37000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;

-- promises は invite_id / booking_id のどちらか一方が要る(制約)
insert into public.bookings (id, guest_id, host_id, duration_minutes, coins, status, scheduled_at)
values ('37000000-0000-0000-0000-000000000c01',
        '37000000-0000-0000-0000-000000000002',
        '37000000-0000-0000-0000-000000000001',
        60, 1000, 'confirmed', now());

insert into public.promises (id, booking_id, user_a, user_b, scheduled_at, status)
values ('37000000-0000-0000-0000-000000000b01',
        '37000000-0000-0000-0000-000000000c01',
        '37000000-0000-0000-0000-000000000001',
        '37000000-0000-0000-0000-000000000002', now(), 'scheduled');

insert into public.messages (id, promise_id, sender_id, body) values
  ('37000000-0000-0000-0000-000000000a01','37000000-0000-0000-0000-000000000b01',
   '37000000-0000-0000-0000-000000000001','LINEのIDはこれです abc123'),
  ('37000000-0000-0000-0000-000000000a02','37000000-0000-0000-0000-000000000b01',
   '37000000-0000-0000-0000-000000000002','よろしくお願いします');

delete from public.notifications;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 運営以外は読むことも消すこともできない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '37000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.admin_thread_messages('37000000-0000-0000-0000-000000000b01');
    raise exception 'FAIL 運営以外がトークを読めた';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
  begin
    perform public.admin_remove_message('37000000-0000-0000-0000-000000000a01','消したい');
    raise exception 'FAIL 運営以外が削除できた';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
  raise notice 'OK NOT_ADMIN / FORBIDDEN で止まる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. 理由は必須 ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '37000000-0000-0000-0000-0000000000ad';
do $$
begin
  begin
    perform public.admin_remove_message('37000000-0000-0000-0000-000000000a01','   ');
    raise exception 'FAIL 空白だけの理由で消せた';
  exception when others then
    if sqlerrm not like '%REASON_REQUIRED%' then raise; end if;
  end;
  if (select deleted_at from public.messages
      where id = '37000000-0000-0000-0000-000000000a01') is not null then
    raise exception 'FAIL 弾かれたのに削除されている';
  end if;
  raise notice 'OK REASON_REQUIRED で止まり、状態も変わらない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 読むと記録が残る(0068と同じ) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  perform public.admin_thread_messages('37000000-0000-0000-0000-000000000b01');
  select count(*) into v_n from public.admin_actions
    where kind = 'view_thread' and target_id = '37000000-0000-0000-0000-000000000b01';
  if v_n < 1 then raise exception 'FAIL 閲覧の記録が無い'; end if;
  raise notice 'OK 中身を見た事実が admin_actions に残る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 削除すると行は残り、理由が入る ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v public.messages;
begin
  perform public.admin_remove_message(
    '37000000-0000-0000-0000-000000000a01', '外部サービスへの誘導');

  select * into v from public.messages where id = '37000000-0000-0000-0000-000000000a01';
  if v.id is null then raise exception 'FAIL 行ごと消えている'; end if;
  if v.deleted_at is null then raise exception 'FAIL 削除日時が入らない'; end if;
  if v.deleted_reason <> '外部サービスへの誘導' then
    raise exception 'FAIL 理由が残っていない: %', v.deleted_reason;
  end if;
  raise notice 'OK 行は残り、理由が残る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. ★本文がDBから消えている ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_body text;
begin
  select body into v_body from public.messages
    where id = '37000000-0000-0000-0000-000000000a01';
  if v_body <> '' then
    raise exception 'FAIL 本文が残っている: %', v_body;
  end if;

  -- 制約が「削除済みなら本文は空」を強制していること。
  -- 実装の抜けで本文を戻せてしまわないか
  begin
    update public.messages set body = 'もどす'
      where id = '37000000-0000-0000-0000-000000000a01';
    raise exception 'FAIL 削除済みなのに本文を書き戻せた';
  exception when check_violation then
    null;
  end;
  raise notice 'OK 本文は空・書き戻しも制約が止める';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. 原文は運営の側に残っている(立証に使う) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_body text;
begin
  select body into v_body from public.message_deletions
    where message_id = '37000000-0000-0000-0000-000000000a01';
  if v_body is null then raise exception 'FAIL 原文が保管されていない'; end if;
  if v_body not like '%abc123%' then
    raise exception 'FAIL 原文が違う: %', v_body;
  end if;
  raise notice 'OK 原文は message_deletions に残る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 7. ★当事者の経路から本文が取れない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '37000000-0000-0000-0000-000000000002';
do $$
declare v_body text; v_n int;
begin
  -- 画面が読む select と同じ形(RLSはテストでは効かないので、
  -- 「返る値そのもの」が空であることを見る)
  select body into v_body from public.messages
    where id = '37000000-0000-0000-0000-000000000a01';
  if v_body <> '' then
    raise exception 'FAIL 相手の画面に本文が届く: %', v_body;
  end if;

  -- 保管先には当事者向けのポリシーが1つも無いこと
  select count(*) into v_n from pg_policies
    where schemaname = 'public' and tablename = 'message_deletions';
  if v_n <> 0 then
    raise exception 'FAIL message_deletions にポリシーがある(当事者に読まれうる): %', v_n;
  end if;
  raise notice 'OK 消したものは当事者からは読めない';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 8. 送信者に理由つきで通知が届く ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_body text; v_n int;
begin
  select count(*) into v_n from public.notifications
    where user_id = '37000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'FAIL 通知が1件でない: %', v_n; end if;

  select body into v_body from public.notifications
    where user_id = '37000000-0000-0000-0000-000000000001';
  if v_body not like '%外部サービスへの誘導%' then
    raise exception 'FAIL 理由が入っていない: %', v_body;
  end if;

  -- ★相手(受け取った側)には通知しない。運営の判断の内容を第三者に配らない
  if exists (select 1 from public.notifications
             where user_id = '37000000-0000-0000-0000-000000000002') then
    raise exception 'FAIL 受け取った側にも通知が飛んでいる';
  end if;
  raise notice 'OK 送信者にだけ、理由つきで届く';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 9. 二重削除は無害・操作記録が残る ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '37000000-0000-0000-0000-0000000000ad';
do $$
declare v_n int;
begin
  perform public.admin_remove_message('37000000-0000-0000-0000-000000000a01','二度目');
  select count(*) into v_n from public.notifications
    where user_id = '37000000-0000-0000-0000-000000000001';
  if v_n <> 1 then raise exception 'FAIL 二重削除で通知が増えた: %', v_n; end if;

  select count(*) into v_n from public.admin_actions
    where kind = 'message_removed' and target_id = '37000000-0000-0000-0000-000000000a01';
  if v_n <> 1 then raise exception 'FAIL 操作記録が1件でない: %', v_n; end if;
  raise notice 'OK 連打しても増えない・記録は1件';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 10. 消していないメッセージは無傷 ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_body text;
begin
  select body into v_body from public.messages
    where id = '37000000-0000-0000-0000-000000000a02';
  if v_body <> 'よろしくお願いします' then
    raise exception 'FAIL 別のメッセージまで変わっている: %', v_body;
  end if;
  raise notice 'OK 対象だけが消える';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 11. 通報された相手のトークを辿れる ==='; end $$;
-- ------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.admin_user_threads('37000000-0000-0000-0000-000000000001')
    limit 1;
  if r.promise_id is null then raise exception 'FAIL スレッドが引けない'; end if;
  if r.other_nickname <> '相手' then
    raise exception 'FAIL 相手の名前が出ない: %', r.other_nickname;
  end if;
  if r.message_count <> 2 then
    raise exception 'FAIL 件数が合わない: %', r.message_count;
  end if;
  raise notice 'OK 相手のIDからスレッドへ辿れる(件数=%)', r.message_count;
end $$;

\echo '==== 37: すべて通過 ===='
