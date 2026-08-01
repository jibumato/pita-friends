-- ============================================================
-- 25: 購入の取消しとサポート料の返還(0090・G5)
-- ------------------------------------------------------------
-- 規約 第7条の3第5項 / 税理士 第2回回答 Q14(c)。
--
-- 「サポート料だけ返さない」は法的に維持しにくい——という指摘への対応。
-- **返せることより、返しすぎないこと**のほうが事故になりやすいので、
-- 二重返金の経路を重点的に落とす。
--
--   ・未使用コインが消え、代金とサポート料が返金債務になること
--   ・**チャージバックがある購入は取り消せないこと**(二重返金)
--   ・二度取り消せないこと
--   ・理由なしに取り消せないこと
--   ・会計で科目が分かれること(前受金 / 売上のマイナス)
-- ============================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('c3000000-0000-0000-0000-000000000001'),
  ('c3000000-0000-0000-0000-000000000002'),
  ('c3000000-0000-0000-0000-000000000009');
insert into public.profiles (id, nickname) values
  ('c3000000-0000-0000-0000-000000000001','未成年だった人'),
  ('c3000000-0000-0000-0000-000000000002','別の人'),
  ('c3000000-0000-0000-0000-000000000009','運営')
  on conflict (id) do update set nickname = excluded.nickname;
insert into public.admins (user_id) values ('c3000000-0000-0000-0000-000000000009');

-- 3,000円の購入(サポート料150円)。1,000コインだけ使った状態にする
select public.credit_coins_for_purchase(
  'c3000000-0000-0000-0000-000000000001', null, 3000, 0, 3000, 'sess_void', 'pi_void');

begin;
set local app.ledger_override = 'on';
update public.coin_purchases set safety_fee_yen = 150
  where stripe_session_id = 'sess_void';
commit;

update public.coin_lots set remaining = 2000
  where user_id = 'c3000000-0000-0000-0000-000000000001';
update public.coin_wallets set balance = 2000
  where user_id = 'c3000000-0000-0000-0000-000000000001';

create temporary table _p as
select id from public.coin_purchases where stripe_session_id = 'sess_void';

set test.uid = 'c3000000-0000-0000-0000-000000000009';

-- ------------------------------------------------------------
\echo '=== 1. 押す前に、何が起きるか出せること ==='
do $$
declare v jsonb;
begin
  v := public.void_purchase_preview((select id from _p));
  if (v->>'unused_coins')::int <> 2000 then
    raise exception 'FAIL: 未使用コインが合わない(%)', v;
  end if;
  if (v->>'consumed_coins')::int <> 1000 then
    raise exception 'FAIL: 消費済みが合わない(%)', v;
  end if;
  if (v->>'refund_total_yen')::int <> 3150 then
    raise exception 'FAIL: 返金額にサポート料が入っていない(%)', v;
  end if;
  if (v->>'can_void')::boolean is not true then
    raise exception 'FAIL: 取り消せる状態のはずが can_void=false(%)', v;
  end if;
  raise notice 'OK: 未使用2000 / 消費済み1000 / 返金3150円(うちサポート料150)';
end $$;

-- ------------------------------------------------------------
\echo '=== 2. 理由なしには取り消せないこと ==='
-- 返金を伴う操作なので、後から説明できる必要がある
do $$
begin
  perform public.admin_void_purchase((select id from _p), '  ');
  raise exception 'FAIL: 理由なしで取り消せてしまった';
exception when others then
  if sqlerrm <> 'REASON_REQUIRED' then raise; end if;
  raise notice 'OK: REASON_REQUIRED で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 3. 取消しで、未使用が消え、代金とサポート料が債務になること ==='
do $$
declare v jsonb; v_bal int; v_lots int; v_coins int; v_fee int;
begin
  v := public.admin_void_purchase((select id from _p), '未成年者取消しの申出');

  select balance into v_bal from public.coin_wallets
   where user_id = 'c3000000-0000-0000-0000-000000000001';
  select coalesce(sum(remaining), 0) into v_lots from public.coin_lots
   where purchase_id = (select id from _p);

  if v_bal <> 0 or v_lots <> 0 then
    raise exception 'FAIL: 未使用コインが残っている(残高% / ロット%)', v_bal, v_lots;
  end if;

  -- **代金とサポート料は別の行。**会計科目が違う
  select amount_yen into v_coins from public.cash_refunds
   where user_id = 'c3000000-0000-0000-0000-000000000001' and cause = 'purchase_void_coins';
  select amount_yen into v_fee from public.cash_refunds
   where user_id = 'c3000000-0000-0000-0000-000000000001' and cause = 'purchase_void_fee';

  if coalesce(v_coins, 0) <> 3000 then
    raise exception 'FAIL: コイン代金の返金債務が合わない(%)', v_coins;
  end if;
  if coalesce(v_fee, 0) <> 150 then
    raise exception
      'FAIL: **サポート料が返金債務になっていない(%)。** 第7条の3第5項の未履行', v_fee;
  end if;
  if (v->>'refund_yen')::int <> 3150 then
    raise exception 'FAIL: 戻り値の返金額が合わない(%)', v;
  end if;
  raise notice 'OK: 未使用は消滅 / 代金3000円 + サポート料150円 の債務';
end $$;

\echo '--- 本人に通知していること(黙って残高を減らさない) ---'
do $$
begin
  if not exists (
    select 1 from public.notifications
     where user_id = 'c3000000-0000-0000-0000-000000000001'
       and title like '%ご購入を取り消し%'
       and body like '%あんしんサポート料を含みます%') then
    raise exception 'FAIL: 取消しの通知が無い、またはサポート料に触れていない';
  end if;
  raise notice 'OK: 返金にサポート料が含まれることを本人に伝えている';
end $$;

\echo '--- 管理操作が記録されていること ---'
do $$
begin
  if not exists (select 1 from public.admin_actions
                  where kind = 'void_purchase' and target_id = (select id from _p)) then
    raise exception 'FAIL: 管理操作が記録されていない';
  end if;
  raise notice 'OK: 記録あり';
end $$;

-- ------------------------------------------------------------
\echo '=== 4. 二度取り消せないこと ==='
do $$
begin
  perform public.admin_void_purchase((select id from _p), 'もう一度');
  raise exception 'FAIL: 二度取り消せてしまった(返金債務が二重に立つ)';
exception when others then
  if sqlerrm <> 'ALREADY_VOIDED' then raise; end if;
  raise notice 'OK: ALREADY_VOIDED で止まる';
end $$;

-- ------------------------------------------------------------
\echo '=== 5. チャージバックがある購入は取り消せないこと(二重返金) ==='
-- **カード会社が決済ごと戻しているので、サポート料も一緒に戻っている。**
-- ここで債務を立てると、同じ金額を二度返すことになる
select public.credit_coins_for_purchase(
  'c3000000-0000-0000-0000-000000000002', null, 1000, 0, 1000, 'sess_cb2', 'pi_cb2');
insert into public.payment_disputes
  (user_id, stripe_dispute_id, stripe_charge_id, stripe_payment_intent,
   amount_yen, reason, status)
values ('c3000000-0000-0000-0000-000000000002','dp_v','ch_v','pi_cb2',
        1000,'fraudulent','lost');

do $$
declare v_id uuid; v jsonb;
begin
  select id into v_id from public.coin_purchases where stripe_session_id = 'sess_cb2';

  v := public.void_purchase_preview(v_id);
  if (v->>'can_void')::boolean is not false then
    raise exception 'FAIL: 異議がある購入なのに取り消せることになっている(%)', v;
  end if;

  begin
    perform public.admin_void_purchase(v_id, '取り消したい');
    raise exception 'FAIL: **二重返金の経路が開いている**';
  exception when others then
    if sqlerrm <> 'HAS_DISPUTE' then raise; end if;
  end;
  raise notice 'OK: HAS_DISPUTE で止まり、押す前にも分かる';
end $$;

-- ------------------------------------------------------------
\echo '=== 6. 会計で科目が分かれること ==='
-- コイン代金は**前受金の取崩し**、サポート料は**売上のマイナス**
-- (税理士 第2回回答 Q14(b))
do $$
declare v_coins bigint; v_fee bigint; v_kari bigint; v_zatsu int;
begin
  select 金額円 into v_coins from public.accounting_journal('2000-01-01','2100-01-01')
   where 摘要 like '購入の取消しによる返金(コイン代金)%';
  select 金額円 into v_fee from public.accounting_journal('2000-01-01','2100-01-01')
   where 摘要 like '購入の取消しによる返金(サポート料)%';

  if coalesce(v_coins, 0) <> 3000 then
    raise exception 'FAIL: コイン代金の仕訳が出ない(%)', v_coins;
  end if;
  if coalesce(v_fee, 0) <> 150 then
    raise exception 'FAIL: サポート料の仕訳が出ない(%)', v_fee;
  end if;

  -- 科目が正しいか
  if not exists (
    select 1 from public.accounting_journal('2000-01-01','2100-01-01')
     where 摘要 like '購入の取消しによる返金(コイン代金)%' and 借方科目 = '前受金') then
    raise exception 'FAIL: コイン代金の借方が前受金でない';
  end if;
  if not exists (
    select 1 from public.accounting_journal('2000-01-01','2100-01-01')
     where 摘要 like '購入の取消しによる返金(サポート料)%' and 借方科目 = '売上高') then
    raise exception 'FAIL: サポート料の借方が売上高でない(売上のマイナスにならない)';
  end if;

  -- 未使用コインの取消しも仕訳に出ること
  select 金額円 into v_kari from public.accounting_journal('2000-01-01','2100-01-01')
   where 摘要 = '購入取消による未使用コインの取消';
  if coalesce(v_kari, 0) <> 2000 then
    raise exception 'FAIL: 未使用コインの取消が仕訳に出ない(%)', v_kari;
  end if;

  -- **無帰責返還(J19)には混ざらないこと。**混ざると失効益が二重に動く
  select count(*) into v_zatsu from public.accounting_journal('2000-01-01','2100-01-01')
   where 区分 = '返金債務';
  if v_zatsu > 0 then
    raise exception 'FAIL: 購入取消しが J19(返金債務)にも出ている(%件)', v_zatsu;
  end if;
  raise notice 'OK: 前受金3000 / 売上高150 / 仮受金2000。J19には混ざらない';
end $$;

-- ------------------------------------------------------------
\echo '=== 7. 一般ユーザーは取り消せないこと ==='
set test.uid = 'c3000000-0000-0000-0000-000000000001';
do $$
begin
  perform public.admin_void_purchase((select id from _p), 'なりすまし');
  raise exception 'FAIL: 一般ユーザーが購入を取り消せた';
exception when others then
  if sqlerrm <> 'NOT_ADMIN' then raise; end if;
  raise notice 'OK: NOT_ADMIN で止まる';
end $$;

\echo '=== 25: 購入の取消しとサポート料の返還 すべて通過 ==='
