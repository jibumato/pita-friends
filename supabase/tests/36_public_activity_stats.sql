-- ============================================================
-- 36: 未ログインに出す集計(0117)
--
-- ■ このテストの主眼
--   **数字が小さいうちは出さない**こと。「今週2件」と出すのは出さないより
--   悪い。下限の判定が効いていないと、公開直後にいちばん見られるページで
--   いちばん見せたくない数字が出る。
--
--   あわせて、0052 の判断(未ログインに在席を出さない)を崩していないこと——
--   返るのが数だけで、誰が居るかに繋がる情報を含まないこと。
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('36000000-0000-0000-0000-000000000001'),
  ('36000000-0000-0000-0000-000000000002'),
  ('36000000-0000-0000-0000-000000000003'),
  ('36000000-0000-0000-0000-000000000009'),
  ('36000000-0000-0000-0000-0000000000ad')
on conflict do nothing;
insert into public.profiles (id, nickname) values
  ('36000000-0000-0000-0000-000000000001','A'),
  ('36000000-0000-0000-0000-000000000002','B'),
  ('36000000-0000-0000-0000-000000000003','C'),
  ('36000000-0000-0000-0000-000000000009','ゲスト'),
  ('36000000-0000-0000-0000-0000000000ad','運営')
on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('36000000-0000-0000-0000-0000000000ad')
  on conflict do nothing;

update public.profile_trust_stats set is_verified = true
  where user_id in ('36000000-0000-0000-0000-000000000001',
                    '36000000-0000-0000-0000-000000000002',
                    '36000000-0000-0000-0000-000000000003',
                    '36000000-0000-0000-0000-000000000009');

insert into public.host_settings (user_id, is_host, hourly_rate, games) values
  ('36000000-0000-0000-0000-000000000001', true, 1000, array['Apex','VALORANT']),
  ('36000000-0000-0000-0000-000000000002', true, 1000, array['Apex','スプラ']),
  -- 掲載していない人。数に入れてはいけない(探しても出てこないため)
  ('36000000-0000-0000-0000-000000000003', false, 1000, array['CoD'])
on conflict (user_id) do update
  set is_host = excluded.is_host, hourly_rate = 1000, games = excluded.games;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 1. 対応タイトル数は下限をかけずに出す ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb;
begin
  -- 下限は既定(plays=20 / hosts=10)。どちらも満たしていない状態
  v := public.public_activity_stats();

  -- Apex / VALORANT / スプラ の3種。掲載していない C の CoD は入らない
  if (v ->> 'gameCount')::int <> 3 then
    raise exception 'FAIL 対応タイトル数が合わない: %', v ->> 'gameCount';
  end if;
  raise notice 'OK 対応タイトル数=3(掲載していない人のゲームは数えない)';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 2. ★下限を下回るものは出さない ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb;
begin
  v := public.public_activity_stats();
  if v -> 'hostCount' <> 'null'::jsonb then
    raise exception 'FAIL 少ないピタメイト数が出ている: %', v ->> 'hostCount';
  end if;
  if v -> 'playsThisWeek' <> 'null'::jsonb then
    raise exception 'FAIL 少ない同行件数が出ている: %', v ->> 'playsThisWeek';
  end if;
  if v -> 'openSlots' <> 'null'::jsonb then
    raise exception 'FAIL 少ないうちに枠数が出ている: %', v ->> 'openSlots';
  end if;
  raise notice 'OK 下限を下回る項目は null';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 3. 下限を下げると出るようになる(運営が動かせる) ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '36000000-0000-0000-0000-0000000000ad';
do $$
declare v jsonb;
begin
  perform public.admin_update_platform_limits(
    '公開直後のため下限を下げる',
    jsonb_build_object('activityStatsMinHosts', 1, 'activityStatsMinPlays', 1));

  v := public.public_activity_stats();
  if (v ->> 'hostCount')::int <> 2 then
    raise exception 'FAIL 掲載中のピタメイト数が合わない: %', v ->> 'hostCount';
  end if;
  raise notice 'OK 下限を下げると出る(ピタメイト=2)';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 4. 変更が admin_actions に前後の値ごと残る ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v_note text;
begin
  select note into v_note from public.admin_actions
    where kind = 'update_platform_limits' order by at desc limit 1;
  if v_note not like '%activityStatsMinHosts: 10→1%' then
    raise exception 'FAIL 前後の値が残っていない: %', v_note;
  end if;
  if v_note not like '%公開直後のため下限を下げる%' then
    raise exception 'FAIL 理由が残っていない: %', v_note;
  end if;
  raise notice 'OK 「%」', v_note;
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 5. 数えるのは完了した予約だけ(申込みは実績ではない) ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb; v_before int;
begin
  v := public.public_activity_stats();
  v_before := coalesce((v ->> 'playsThisWeek')::int, 0);

  -- 申請中の予約を1件。これは数に入ってはいけない
  insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, requested_start_at)
  values ('36000000-0000-0000-0000-000000000009','36000000-0000-0000-0000-000000000001',
          60, 1000, 'requested', now(), now() - interval '2 hours');
  v := public.public_activity_stats();
  if coalesce((v ->> 'playsThisWeek')::int, 0) <> v_before then
    raise exception 'FAIL 申請中が実績に数えられた';
  end if;

  -- 完了した予約は数える
  insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, requested_start_at)
  values ('36000000-0000-0000-0000-000000000009','36000000-0000-0000-0000-000000000002',
          60, 1000, 'completed', now() - interval '2 days', now() - interval '1 day');
  v := public.public_activity_stats();
  if coalesce((v ->> 'playsThisWeek')::int, 0) <> v_before + 1 then
    raise exception 'FAIL 完了した予約が数えられていない: %', v ->> 'playsThisWeek';
  end if;

  -- 8日前に遊んだものは「今週」に入らない
  insert into public.bookings (guest_id, host_id, duration_minutes, coins, status, scheduled_at, requested_start_at)
  values ('36000000-0000-0000-0000-000000000009','36000000-0000-0000-0000-000000000002',
          60, 1000, 'completed', now() - interval '10 days', now() - interval '8 days');
  v := public.public_activity_stats();
  if coalesce((v ->> 'playsThisWeek')::int, 0) <> v_before + 1 then
    raise exception 'FAIL 8日前の分まで数えている: %', v ->> 'playsThisWeek';
  end if;
  raise notice 'OK 完了・直近7日のものだけ';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 6. ★誰が居るかに繋がる情報は返さない ==='; end $$;
-- ------------------------------------------------------------
do $$
declare v jsonb; k text;
begin
  v := public.public_activity_stats();
  -- 返るキーは4つだけ。増えたら気づけるようにしておく
  -- (0052 が隠している在席・空き枠が紛れ込むのを防ぐ)
  for k in select jsonb_object_keys(v)
  loop
    if k not in ('gameCount','hostCount','playsThisWeek','openSlots') then
      raise exception 'FAIL 想定外のキーが返っている: %', k;
    end if;
  end loop;
  -- 値はすべて数か null。IDや名前が混ざっていないこと
  for k in select jsonb_object_keys(v)
  loop
    if jsonb_typeof(v -> k) not in ('number','null') then
      raise exception 'FAIL 数以外が返っている: % = %', k, v -> k;
    end if;
  end loop;
  raise notice 'OK 返るのは数だけ';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 7. 未ログインでも呼べる(これは公開用) ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '';
do $$
declare v jsonb;
begin
  v := public.public_activity_stats();
  if v is null then raise exception 'FAIL 未ログインで呼べない'; end if;
  raise notice 'OK 未ログインでも数だけ返る';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 8. 下限は運営以外には触れない ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '36000000-0000-0000-0000-000000000009';
do $$
begin
  begin
    perform public.admin_update_platform_limits('下げたい',
      jsonb_build_object('activityStatsMinPlays', 0));
    raise exception 'FAIL 運営以外が下限を変えられた';
  exception when others then
    if sqlerrm not like '%NOT_ADMIN%' then raise; end if;
  end;
  raise notice 'OK NOT_ADMIN で止まる';
end $$;

-- ------------------------------------------------------------
do $$ begin raise notice '=== 9. 綴り間違いはその場で落ちる ==='; end $$;
-- ------------------------------------------------------------
set test.uid = '36000000-0000-0000-0000-0000000000ad';
do $$
begin
  begin
    perform public.admin_update_platform_limits('typo',
      jsonb_build_object('activityStatsMinPlay', 0));
    raise exception 'FAIL 知らないキーが黙って通った';
  exception when others then
    if sqlerrm not like '%UNKNOWN_KEY%' then raise; end if;
  end;
  raise notice 'OK UNKNOWN_KEY で止まる(「変えたつもり」を作らない)';
end $$;

\echo '==== 36: すべて通過 ===='
