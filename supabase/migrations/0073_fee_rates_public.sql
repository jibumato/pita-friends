-- ============================================================
-- 0073: 手数料の率を画面に出せるようにする
-- ------------------------------------------------------------
-- ■ なぜ必要か(条文と実装の食い違いを埋める)
--   弁護士の回答(Q22-a)に従い、可変性の高い料率の表を利用規約の本文から
--   外出しし、代わりに 第8条の2第3項に
--     「**具体的な率は本サービス上に表示します**」
--   と書いた。ところが**画面に料率を表示する仕組みが無かった。**
--   つまり条文が実装より進んでいる = 守れない約束を作ってしまっていた
--   (規約↔実装の突合表 G2。docs/legal/terms-implementation-matrix.md)。
--
--   弁護士:「条文が実装より進んでいる状態(＝守れない約束)は、施行後は
--            端的に債務不履行になります」
--
-- ■ 何を返すか
--   率は3か所に散らばっている:
--     ・段階制の率      … host_fee_tiers テーブル(0033)
--     ・リピート割引と下限 … _host_fee_for() の中の定数(0033)
--     ・ギフトの率      … _apply_gift_fee() の中の定数(0063で35%)
--   画面から3か所を別々に読むのは間違いのもとなので、**表示用の1つの口**に
--   まとめる。数値の権威は従来どおり各実装側に置き、ここは読み取り専用。
--
--   ⚠️ **定数を変えたらこの関数も直すこと。** 関数の中で同じ値を持って
--   いるため、ずれると画面の表示と実際の控除額が食い違う。
--   (テーブルに出すのが本来だが、率の変更は稀で、変更時は
--    「30日前の通知」「変更前に成立した予約には旧料率」の対応が必要になる
--    ため、いずれにせよ移行を書くことになる。そのときに揃える。)
--
-- ■ 誰が読めるか
--   **未ログインでも読める。** 手数料は「ピタメイトになるかどうか」を
--   判断する材料で、登録前に見えないと意味がない。
--   個人情報は含まないので anon に開放してよい。
-- ============================================================

create or replace function public.fee_rates()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    -- 予約の段階制。上限が null の段は「それ以上」
    'bookingTiers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'upperBound', t.upper_bound,
               'percent', round(t.rate * 100, 1)
             ) order by t.step), '[]'::jsonb)
      from public.host_fee_tiers t
    ),
    -- 同一ゲストからの2回目以降の引き下げ(pt)と、引き下げ後の下限
    'repeatDiscountPoints', 3,
    'floorPercent', 10,
    -- ありがとうギフトは一律(0063で30%から35%へ)
    'giftPercent', 35
  );
$$;

comment on function public.fee_rates() is
  '手数料の率(表示用)。規約 第8条の2第3項「具体的な率は本サービス上に表示します」を満たすための読み取り口。数値の権威は host_fee_tiers と各計算関数の定数にあり、変更時はここも揃えること。';

revoke all on function public.fee_rates() from public;
grant execute on function public.fee_rates() to anon, authenticated;
