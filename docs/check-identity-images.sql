-- ============================================================
-- 本人確認の画像が、ストレージに何枚残っているかを数える
-- ------------------------------------------------------------
-- Supabase の SQL Editor に貼って実行してください。**読み取りだけ**で、
-- 画像を開いたり消したりはしません(件数と日時だけを見ます)。
--
-- なぜ要るのか:
--   規約 第3条5項は「照合の完了後すみやかに削除」と約束している。ところが
--   削除は運営のブラウザから行っていて、失敗しても気づけない作りになっている
--   (docs/legal/terms-implementation-matrix.md 第3条5項)。
--
-- 見かた:
--   「審査待ち」以外が 0 なら約束どおり。
--   ・審査済みなのに残っている … 承認/却下のあとの削除が失敗している
--   ・申請に紐づかない          … 申請の作成に失敗して画像だけ残った、または
--                                  退会の匿名化で参照だけ外れた
-- ============================================================

with obj as (
  select o.name, (to_jsonb(o) ->> 'created_at')::timestamptz as created_at,
         v.status
  from storage.objects o
  left join public.identity_verifications v
    on o.name = v.document_path or o.name = v.selfie_path
  where o.bucket_id = 'identity-documents'
)
select
  case
    when status = 'pending' then '審査待ち(残っていてよい)'
    when status is null then '申請に紐づかない'
    else '審査済みなのに残っている(' || status || ')'
  end as "区分",
  count(*) as "枚数",
  to_char(min(created_at) at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') as "最も古いもの"
from obj
group by 1
order by 1;
