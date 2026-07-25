-- ============================================================
-- マナースコアの算出を設計どおりに置き換える
-- 設計: docs/trust-safety-spec.md §1.1 / §1.2
-- ------------------------------------------------------------
-- 0005 の実装は「直近30件の単純平均 − 減点」という簡略版で、次の問題があった。
--   ・レビュー1件で満点(★5.00)になってしまい、実績のあるユーザーと並ぶ
--   ・新しいレビューほど重く扱う指数減衰(半減期90日)が入っていない
--   ・base=4.50 の「中立スタート」がレビュー1件で消える
--
-- ここでは次の式に置き換える。
--
--   score = (BASE * PRIOR_W + Σ(w_i * stars_i)) / (PRIOR_W + Σ w_i) - penalty
--   w_i   = 0.5 ^ (経過日数 / 90)      … 半減期90日の指数減衰
--
-- 設計書の "base + review_component - penalty_component" は、そのまま足すと
-- 4.50 + 4.80 のようになり上限に張り付くため、**baseを事前分布(中立な仮想レビュー)
-- として扱い、レビューが増えるほどbaseの影響が薄れる**形で解釈した。
-- これにより「新規は中立、実績が積まれるほど実際の評価に寄る」という
-- 設計意図(コールドスタート対策)を満たす。
--
-- PRIOR_W = 3 は「レビュー3件で事前分布と実測が同じ重みになる」設定で、
-- §1.2 の「3件未満はスコアを表示しない」というしきい値と揃えてある。
-- ============================================================

create or replace function public.recompute_manner_score(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 新規ユーザーの中立スタート(§1.1)
  c_base constant numeric := 4.50;
  -- 事前分布の重み。レビュー3件で実測と同等になる
  c_prior_w constant numeric := 3.0;
  -- 指数減衰の半減期(日)
  c_half_life constant numeric := 90.0;

  v_weighted_sum numeric := 0;
  v_weight_sum numeric := 0;
  v_review_count int := 0;
  v_penalty numeric;
  v_score numeric;
begin
  -- 直近30件のみを対象に、新しいレビューほど重く重み付けする
  select
    coalesce(sum(power(0.5, extract(epoch from (now() - r.created_at)) / 86400.0 / c_half_life) * r.stars), 0),
    coalesce(sum(power(0.5, extract(epoch from (now() - r.created_at)) / 86400.0 / c_half_life)), 0),
    count(*)
  into v_weighted_sum, v_weight_sum, v_review_count
  from (
    select stars, created_at
    from public.reviews
    where reviewee_id = p_user_id
    order by created_at desc
    limit 30
  ) r;

  select coalesce(sum(points), 0) into v_penalty
  from public.manner_penalties
  where user_id = p_user_id;

  -- baseを仮想レビューとして混ぜる(レビューが増えるほど影響が薄れる)
  v_score := (c_base * c_prior_w + v_weighted_sum) / (c_prior_w + v_weight_sum) - v_penalty;
  v_score := greatest(1.00, least(5.00, v_score));

  update public.profile_trust_stats
    set manner_score = round(v_score, 2),
        review_count = v_review_count,
        updated_at = now()
    where user_id = p_user_id;
end;
$$;

comment on function public.recompute_manner_score(uuid) is
  'マナースコアの再計算(docs/trust-safety-spec.md §1.1)。baseを事前分布として扱い、半減期90日で減衰させた直近30件のレビューを加重平均し、確定した違反の減点を差し引く。';

-- ------------------------------------------------------------
-- 既存ユーザーのスコアを新しい式で一度ならす
-- (旧式で満点になっていたユーザーが残らないようにする)
-- ------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in select user_id from public.profile_trust_stats loop
    perform public.recompute_manner_score(r.user_id);
  end loop;
end;
$$;
