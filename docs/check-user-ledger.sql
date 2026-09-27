-- ============================================================
-- 1人の利用者のコインの履歴を、まとめて見る
-- ------------------------------------------------------------
-- Supabase の SQL Editor に貼って実行してください。**読み取りだけ**で、
-- データは一切変更しません。
--
-- 使いどころ:
--   運営コンソールの「健全性」で残高のズレ(wallet_vs_lots_paid /
--   wallet_vs_ledger 等)が出たとき、そのユーザーに何が起きたかを見る。
--
-- 使いかた:
--   下の `target(user_id)` の値を、健全性の画面に出た user_id に書き換える。
--
-- 見かた:
--   「区分」の順に、利用者 → 残高 → ロット → 取引履歴 → 購入 → 台帳の手修正
--   が時刻順に並ぶ。
--   ・**「台帳の手修正」に行があれば**、アプリの機能を通さずに台帳が
--     書き換えられている(0044 の保護を外して直接 update/delete した記録)。
--   ・⚠️ ただし**残高(coin_wallets)とロットの残り(coin_lots.remaining)は
--     保護の対象外**なので、直接書き換えても「台帳の手修正」には残らない。
--     その場合は、ロットの作成日時に対応する取引履歴(purchase/refund 等)が
--     あるかを見る。**ロットだけあって取引履歴に対応する行が無ければ、
--     コインが SQL で直接入れられている。**
--   ・最後の「合計」の行が、健全性の画面に出た数字と一致するはず。
-- ============================================================

with target(user_id) as (values
  ('c78a5777-479e-4361-8243-287161c136d4'::uuid)
),
result as (
  select 0 as sec, p.created_at as at, '利用者'::text as "区分",
         coalesce(p.nickname, '(名前なし)') as "内容",
         null::int as "数量",
         jsonb_build_object(
           'is_admin', exists (select 1 from public.admins a where a.user_id = p.id),
           'registered_at', to_jsonb(u) -> 'created_at',
           'last_sign_in_at', to_jsonb(u) -> 'last_sign_in_at') as "詳細"
  from target t
  join public.profiles p on p.id = t.user_id
  left join auth.users u on u.id = t.user_id

  union all
  select 1, w.updated_at, '残高', '有償 / 無償 / 報酬',
         w.balance, to_jsonb(w) - 'user_id'
  from target t join public.coin_wallets w on w.user_id = t.user_id

  union all
  select 2, l.created_at, 'ロット', l.kind || ' / 期限 ' || to_char(l.expires_at, 'YYYY-MM-DD'),
         l.remaining, to_jsonb(l) - 'user_id'
  from target t join public.coin_lots l on l.user_id = t.user_id

  union all
  select 3, x.created_at, '取引履歴', x.type,
         x.amount, to_jsonb(x) - 'user_id'
  from target t join public.coin_transactions x on x.user_id = t.user_id

  union all
  select 4, c.created_at, '購入', c.pack_id,
         c.coins_credited, to_jsonb(c) - 'user_id'
  from target t join public.coin_purchases c on c.user_id = t.user_id

  union all
  -- 0044 の保護を外して行われた update/delete の記録(旧値つき)
  select 5, a.at, '台帳の手修正', a.table_name || ' ' || a.op,
         null, jsonb_build_object('actor', a.actor, 'old', a.old_row, 'new', a.new_row)
  from target t join public.ledger_audit a
    on (a.old_row ->> 'user_id')::uuid = t.user_id
    or (a.new_row ->> 'user_id')::uuid = t.user_id

  union all
  -- 突き合わせの答え(健全性の画面と同じ計算)
  select 6, null, '合計',
         '残高の合計 / ロット(有償)の残り / 取引履歴の累計',
         null,
         jsonb_build_object(
           'wallet_total', (select w.balance + w.bonus_balance + w.earned_balance
                              from public.coin_wallets w, target t where w.user_id = t.user_id),
           'paid_lots', (select coalesce(sum(l.remaining), 0) from public.coin_lots l, target t
                          where l.user_id = t.user_id and l.kind = 'paid'),
           'ledger_total', (select coalesce(sum(x.amount), 0) from public.coin_transactions x, target t
                             where x.user_id = t.user_id))
)
select "区分", to_char(at at time zone 'Asia/Tokyo', 'MM-DD HH24:MI') as "日時",
       "内容", "数量", "詳細"
from result
order by sec, at nulls last;
