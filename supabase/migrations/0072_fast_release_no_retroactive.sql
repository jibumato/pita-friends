-- ============================================================
-- 0072: 検収期間の短縮設定を、既存の予約に遡って効かせない
-- ------------------------------------------------------------
-- ■ 弁護士の指摘(2026-07-30 回答 Q28)
--   「短縮設定の変更は既存の進行中予約には及ばず、**変更後に成立した予約に
--     適用される**旨を条文に明記してください。**遡って検収期間が縮むのは
--     利用者の不利益変更で、10条の議論を自ら招きます。**」
--
-- ■ 何が問題だったか
--   0062 は「判定を自動確定の実行時に読む」設計にしていた。外したときに
--   すぐ72時間へ戻る(利用者に有利)ことを狙ったものだが、**裏返しとして
--   設定をONにした瞬間、すでに進行中の予約の検収期間も縮んでいた。**
--   ゲストが自分で選んだ設定であっても、「予約したときの条件」が後から
--   短くなるのは不利益変更で、消費者契約法10条の議論を招く。
--
-- ■ 直し方
--   `fast_release_prefs.created_at` は設定・変更のたびに now() で更新される
--   (0062 の on conflict で created_at も更新している)ため、**「予約が
--   成立した時点で、その設定がすでに有効だったか」**をこれで判定できる。
--
--     設定の時刻 <= 予約の成立時刻  → 短縮を適用する
--     設定の時刻 >  予約の成立時刻  → 適用しない(既定の72時間)
--
--   これで:
--     ・ONにしても、**すでにある予約は72時間のまま**(不利益の遡及が消える)
--     ・24h→48h のように**延ばす変更**も、その時点で created_at が更新される
--       ので既存予約には及ばない(=72時間のまま。利用者に不利にならない)
--     ・**外した(行を消した)ときは即座に72時間へ戻る**(行が無いので
--       coalesce で既定値になる)。有利な方向は従来どおり即時
--
-- ■ 変えていないもの
--   下限24時間・3回以上遊んだ相手のみ・ゲストしか設定できない・保留(held_at)
--   優先、はすべて0062のまま。**関数の引数・戻り値も変えていない。**
-- ============================================================

create or replace function public.auto_complete_bookings()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c_default_hours constant int := 72;
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select b.id, b.host_id, b.coins
    from public.bookings b
    where b.status = 'confirmed'
      -- 保留(通報・申し出)は従来どおり優先。短くしても確定しない
      and b.held_at is null
      -- 相関副問い合わせで引くこと。left join にすると
      -- 「FOR UPDATE cannot be applied to the nullable side of an outer join」で落ちる。
      and b.scheduled_at
          + make_interval(mins => b.duration_minutes)
          + make_interval(hours => coalesce(
              (select f.hours from public.fast_release_prefs f
               where f.guest_id = b.guest_id and f.host_id = b.host_id
                 -- 0072: **予約が成立した時点で有効だった設定にだけ従う。**
                 -- あとから短くしても、すでにある予約の検収期間は縮まない
                 -- (消費者契約法10条。弁護士Q28)。
                 and f.created_at <= b.created_at),
              c_default_hours)) < now()
    for update skip locked
  loop
    update public.bookings set status = 'completed' where id = v_booking.id;

    update public.coin_wallets
      set earned_balance = earned_balance + v_booking.coins
      where user_id = v_booking.host_id;

    insert into public.coin_transactions (user_id, amount, type, related_booking_id, note)
      values (v_booking.host_id, v_booking.coins, 'booking_earned', v_booking.id, 'auto_complete_bookings');

    update public.promises set status = 'completed' where booking_id = v_booking.id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

comment on function public.auto_complete_bookings() is
  '終了から一定時間が過ぎた予約を自動確定する。既定72時間。ゲストが相手ごとに短縮できる(0062)が、0072で「予約成立時点で有効だった設定にだけ従う」ようにした(不利益の遡及を避ける)。';

revoke all on function public.auto_complete_bookings() from public;

comment on column public.fast_release_prefs.created_at is
  'この設定を最後に変更した時刻。0072で、予約成立時点でこの設定が有効だったかの判定に使う(設定・変更のたびに更新される)。';
