-- ============================================================
-- 0108: 利用停止のときに、購入コインを一律で消さないようにする
--
-- 2026-08-05の弁護士回答（論点A-2）による。
--
--   「利用停止等の**原因・程度を問わず**購入コインを一律に消滅させる定めは、
--    違約金・損害賠償額の予定の性質を帯び、消費者契約法9条1号（平均的な損害を
--    超える部分の無効）・10条の攻撃対象になります。軽微な違反（例: マナー違反の
--    累積）でも数万円分の残高が没収される帰結は、**平均的損害との均衡を欠く**と
--    評価されやすい。」
--
-- 報酬コインは 0098 の時点で既に「原則残す・没収は個別判断」になっていた
-- （p_forfeit_earned）。**購入コインだけが無条件に消えていた。**
--
-- ■ 新しい建付け（規約 第6条の3第5項）
--
--   不正な取得・利用が認められる場合に限り消滅させる。
--   それ以外は**消さない**。停止が解除されれば使えるし、解除されなければ
--   第7条5項の有効期限（6か月）で通常どおり失効する。
--
--   **有効期限に委ねるのが要点。** 失効の根拠が「制裁」ではなく
--   「もともとの期限」になるので、平均的損害の議論から外れる。
--
-- ■ 既定値を「消さない」にする
--   p_forfeit_paid の既定は false。**うっかり消えるより、うっかり残るほうが安全。**
--   消すときは運営が明示的に選ぶ（理由は admin_actions に残る）。
-- ============================================================

create or replace function public.admin_suspend_account(
  p_user_id uuid,
  p_reason text,
  p_forfeit_earned boolean default false,
  p_forfeit_paid boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid int;
  v_bonus int;
  v_earned int;
  v_deadline timestamptz := now() + interval '90 days';
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;
  -- **理由は必須。** 第6条の3第6項の再審査に応じられない措置は取らない
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED';
  end if;

  select coalesce(balance, 0), coalesce(bonus_balance, 0), coalesce(earned_balance, 0)
    into v_paid, v_bonus, v_earned
  from public.coin_wallets where user_id = p_user_id for update;

  -- 第6条の3第5項（0108で改訂）:
  -- **不正な取得・利用が認められる場合に限り**購入コインを消滅させる。
  -- それ以外は触らない。停止が解除されれば使えるし、解除されなければ
  -- 第7条5項の有効期限で通常どおり失効する。
  if p_forfeit_paid and (coalesce(v_paid, 0) > 0 or coalesce(v_bonus, 0) > 0) then
    update public.coin_lots set remaining = 0 where user_id = p_user_id and remaining > 0;
    update public.coin_wallets set balance = 0, bonus_balance = 0 where user_id = p_user_id;
    if v_paid > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_paid, 'expire', 'suspend_paid');
    end if;
    if v_bonus > 0 then
      insert into public.coin_transactions (user_id, amount, type, note)
        values (p_user_id, -v_bonus, 'expire', 'suspend_bonus');
    end if;
  end if;

  -- 第6条の3第2項/第3項: **報酬コインは原則として残す。**
  -- 没収するのは、違反行為により取得されたものに限る（運営が個別に判断）。
  if p_forfeit_earned and coalesce(v_earned, 0) > 0 then
    update public.coin_wallets set earned_balance = 0 where user_id = p_user_id;
    insert into public.coin_transactions (user_id, amount, type, note)
      values (p_user_id, -v_earned, 'expire', 'suspend_earned_forfeit');
    v_deadline := null;
  end if;

  update public.profiles
    set suspended_at = now(),
        payout_claim_deadline = v_deadline
    where id = p_user_id;

  -- 掲載を止める。**検索・ランキング・「いま遊べる」は is_host を見ている**
  update public.host_settings set is_host = false where user_id = p_user_id;

  perform public._log_admin_action(
    'suspend_account', p_user_id,
    case when p_forfeit_paid then '購入コイン没収 / ' else '購入コインは残す / ' end
    || case when p_forfeit_earned then '報酬コインも没収: ' else '報酬コインは残す: ' end
    || p_reason);

  return jsonb_build_object(
    'user_id', p_user_id,
    'paid_expired', case when p_forfeit_paid then v_paid else 0 end,
    'bonus_expired', case when p_forfeit_paid then v_bonus else 0 end,
    'paid_kept', case when p_forfeit_paid then 0 else v_paid end,
    'earned_forfeited', case when p_forfeit_earned then v_earned else 0 end,
    'payout_claim_deadline', v_deadline
  );
end;
$$;

comment on function public.admin_suspend_account(uuid, text, boolean, boolean) is
  '利用停止(規約 第6条の3)。**購入コインも報酬コインも、既定では消さない。**消すのは違反行為による不正な取得・利用が認められる場合だけで、運営が明示的に選ぶ(0108・2026-08-05の弁護士回答 論点A-2)。消さなかった購入コインは第7条5項の有効期限で通常どおり失効する。';

revoke all on function public.admin_suspend_account(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.admin_suspend_account(uuid, text, boolean, boolean) to authenticated;

-- 3引数の旧シグネチャは残さない。**既定値が変わったのに古い版が残っていると、
-- どちらが呼ばれたかで結果が変わる。**
drop function if exists public.admin_suspend_account(uuid, text, boolean);
