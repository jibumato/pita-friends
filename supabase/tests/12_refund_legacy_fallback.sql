\set ON_ERROR_STOP on
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into public.profiles (id, nickname) values
  ('11111111-1111-1111-1111-111111111111','ゲスト'),
  ('22222222-2222-2222-2222-222222222222','ホスト')
  on conflict (id) do update set nickname = excluded.nickname;

-- 0030 より前に作られた予約を模す(消費記録なし・3か月前作成)
insert into public.bookings (guest_id, host_id, duration_minutes, coins, paid_coins, bonus_coins, status, created_at)
values ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
        60, 1000, 700, 300, 'requested', now() - interval '3 months')
returning id as bid \gset

select public._refund_coin_lots_for_booking(:'bid');

\echo '--- フォールバック: 予約作成時刻(3か月前)基準で戻っているか ---'
select kind, remaining, to_char(expires_at,'YYYY-MM-DD') as expires
from public.coin_lots where user_id='11111111-1111-1111-1111-111111111111' order by kind;
\echo '(3か月前 + 6か月 - 1日 = 約3か月後。今から6か月後になっていなければ正しい)'

select case when max(expires_at) < now() + interval '4 months'
            then 'PASS: 予約作成時刻を基準に引き直している'
            else 'FAIL: 今から6か月になっている' end as verdict
from public.coin_lots where user_id='11111111-1111-1111-1111-111111111111';
