-- ============================================================
-- 0099: 相殺の時的限界と、不正関与者の扱い（C-2）
-- ------------------------------------------------------------
-- 2026-08-04 の弁護士回答（第1の1(4)）。第8条の6は四重の限定を置いていて
-- 「抑制の効いた設計」と評価されたが、微修正が2点あった。
--
-- ■ 控除の時的限界（実装するのはこちら）
--   「**控除の時的限界が無限定**です。国際ブランドのチャージバック申立期間
--     （概ね120日）を踏まえ、報酬確定から一定期間（例えば180日）を経過した
--     取引は控除の対象としない旨の限定を置くと、**ピタメイト側の予見可能性が
--     高まり、条項の許容性がさらに強固になります**。」
--
--   期限を切らないと、ピタメイトは**いつまで取り返されうるのか分からない**。
--   規約 第8条の6第4項2の2号に条文を置き、ここで候補の抽出から外す。
--
-- ■ 不正関与者への請求（条文のみ・実装なし）
--   「第4項2号（支払済み金銭の返還を請求しない）は、**ピタメイト自身が不正に
--     関与していた場合**……にまで請求権を放棄する趣旨ではないはずですから、
--     ただし書を付すべきです。」
--
--   こちらは**支払済みの金銭を請求する**話で、システムの操作ではない
--   （訴訟・交渉の世界）。規約 第8条の6第4項2号のただし書だけを置いた。
--   実装で自動化するものではない。
-- ============================================================

create or replace function public.chargeback_offset_preview(p_purchase_id uuid)
returns table (
  host_id uuid,
  nickname text,
  booking_id uuid,
  gift_id uuid,
  funded_coins int,
  host_earned_coins int,
  deductible_coins int,
  already_offset boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  with funded as (
    select c.booking_id, c.gift_id, sum(c.coins)::int as funded
    from public.coin_lot_consumptions c
    join public.coin_lots l on l.id = c.lot_id
    where l.purchase_id = p_purchase_id
      -- **返還済み(restored_at)は充当が巻き戻っているので対象外**
      and c.restored_at is null
    group by c.booking_id, c.gift_id
  ),
  rows as (
    -- 予約: 報酬として確定した分だけが控除の対象(3項)
    select b.host_id,
           f.booking_id,
           null::uuid as gift_id,
           f.funded,
           -- **利用料を引いた後の、実際に渡った枚数。**
           -- 報酬確定は総額で入り(J8)、利用料は別行で控除される(J10)。
           -- 総額で引くと、当社の取り分まで相手から取り返すことになる
           coalesce((
             select sum(t.amount)::int from public.coin_transactions t
             where t.related_booking_id = b.id and t.type = 'booking_earned'
           ), 0)
           - coalesce((
             select sum(pf.fee_coins)::int from public.platform_fees pf
             where pf.booking_id = b.id and pf.kind = 'booking'
           ), 0) as earned,
           -- 報酬が確定した時刻。bookings に完了時刻の列が無いので、
           -- 報酬付与の記録の時刻を使う(0097 の send_gift と同じ考え方)
           (select max(t.created_at) from public.coin_transactions t
             where t.related_booking_id = b.id and t.type = 'booking_earned') as earned_at
    from funded f
    join public.bookings b on b.id = f.booking_id
    where f.booking_id is not null

    union all

    -- ギフト: 受領した枚数がそのまま報酬コインになる
    select g.receiver_id as host_id,
           null::uuid as booking_id,
           f.gift_id,
           f.funded,
           g.coins
           - coalesce((
             select sum(pf.fee_coins)::int from public.platform_fees pf
             where pf.gift_id = g.id and pf.kind = 'gift'
           ), 0) as earned,
           g.created_at as earned_at
    from funded f
    join public.gifts g on g.id = f.gift_id
    where f.gift_id is not null
  )
  select r.host_id,
         p.nickname,
         r.booking_id,
         r.gift_id,
         r.funded,
         r.earned,
         -- **充当された分と、実際に報酬になった分の小さいほう。**
         -- 利用料を引いた後の報酬しか渡っていないので、
         -- 充当額をそのまま引くと当社の取り分まで相手から取ることになる
         least(r.funded, r.earned) as deductible,
         exists (
           select 1 from public.chargeback_offsets o
           where o.purchase_id = p_purchase_id
             and o.booking_id is not distinct from r.booking_id
             and o.gift_id is not distinct from r.gift_id
             and o.status <> 'cancelled'
         ) as already
  from rows r
  left join public.profiles p on p.id = r.host_id
  where least(r.funded, r.earned) > 0
    -- 0099(規約 第8条の6第4項2の2号): **報酬確定から180日を過ぎた取引は対象外。**
    -- 国際ブランドの申立期間(概ね120日)を踏まえた時的限界。
    -- 期限を切らないと、ピタメイトは**いつまで取り返されうるのか分からない**。
    -- 弁護士:「ピタメイト側の予見可能性が高まり、条項の許容性がさらに強固になります」
    and r.earned_at is not null
    and r.earned_at > now() - interval '180 days'
  order by r.host_id;
end;
$$;

comment on function public.chargeback_offset_preview(uuid) is
  '相殺の対象候補。0099で「報酬確定から180日超は対象外」の時的限界を入れた(規約 第8条の6第4項2の2号)。';

revoke all on function public.chargeback_offset_preview(uuid) from public, anon;
grant execute on function public.chargeback_offset_preview(uuid) to authenticated;
