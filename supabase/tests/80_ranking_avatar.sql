-- host_ranking() が avatar_path を返すこと(0037)の確認。
-- 「トップページのランキングにプロフィール写真が表示されない」不具合の再現/修正確認。

begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'host1@test.com')
  on conflict do nothing;
update public.profiles
  set nickname = 'てすと', avatar_initial = 'て', avatar_color = '#FFC7D9',
      avatar_path = 'avatars/11111111-1111-1111-1111-111111111111/pic.webp'
  where id = '11111111-1111-1111-1111-111111111111';

insert into auth.users (id, email) values ('22222222-2222-2222-2222-222222222222', 'guest1@test.com')
  on conflict do nothing;
update public.profiles
  set nickname = 'げすと', avatar_initial = 'げ', avatar_color = '#B3E5F2'
  where id = '22222222-2222-2222-2222-222222222222';

insert into public.bookings (host_id, guest_id, status, scheduled_at, duration_minutes, coins, paid_coins, bonus_coins)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'completed', now(), 30, 100, 100, 0);

do $$
declare
  v_path text;
begin
  select avatar_path into v_path from public.host_ranking('weekly', 30)
    where host_id = '11111111-1111-1111-1111-111111111111';
  if v_path is distinct from 'avatars/11111111-1111-1111-1111-111111111111/pic.webp' then
    raise exception 'FAIL: avatar_path not returned by host_ranking (got %)', v_path;
  end if;
  raise notice 'OK: host_ranking returns avatar_path';
end $$;

rollback;
