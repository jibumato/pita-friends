-- ============================================================
-- 0083: 購入ボーナス(上乗せコイン)を廃止する
--
-- 事業判断による廃止。**法務・税務・会計の3方向で、無償コインだけを
-- 原因とする論点が同時に消える。**
--
--   法務: 弁護士 第3回回答 論点4(景品表示法5条2号・有利誤認)
--         「ボーナス+100」と表示して購入を誘引しながら、消費順序の
--         仕組み上ボーナスが失効しやすいのは説明しづらい、という指摘。
--         **表示自体をやめれば論点が成立しない。**
--   税務: 無償コイン起因のPF利用料の純額処理(税理士 第4回回答)。
--         現金を受け取っていない取引で課税売上高が膨らむ問題が消える。
--   資金: 分別管理規程 第7条2号の「無償コイン起因のピタメイト報酬」=
--         **回収されない真の持ち出し**。上乗せ率1.5%の分岐点も消える。
--
-- ■ 何を消して、何を残すか
--
-- 消す:   coin_packs.bonus_coins を全て0にし、**0以外を入れられなくする**
-- 残す:   coin_lots.kind='bonus' / bookings.bonus_coins /
--         coin_transactions.type='bonus' の**列と値の定義**
--
--   残す理由は2つ。
--   ①これらは追記専用の台帳(0044)であり、**過去の行を消せない**。
--     未公開で実データは無いが、列を落とすと復元の経路まで壊れる。
--   ②将来ボーナスを再開する判断があったとき、**器を作り直すより
--     この migration を1本戻すほうが安全**。0082の消費順序
--     (期限の早い順・同一期限内は有償が先)もそのまま効く。
--
-- ■ 表示の建付けは変えない
--   購入は「コイン代金 + あんしんサポート料」の2行のまま。
--   ボーナスが0になるだけで、決済額の計算は変わらない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 全パックのボーナスを0にする
-- ------------------------------------------------------------
update public.coin_packs set bonus_coins = 0 where bonus_coins <> 0;

-- ------------------------------------------------------------
-- 2. **0以外を入れられなくする**
--
-- データを0にするだけだと、管理画面やSQLから戻せてしまう。
-- 廃止は事業判断なので、**戻すときは migration を書く**という形にする。
-- 「なぜ0なのか」がスキーマに残るのが要点。
-- ------------------------------------------------------------
alter table public.coin_packs drop constraint if exists coin_packs_no_bonus_check;
alter table public.coin_packs
  add constraint coin_packs_no_bonus_check check (bonus_coins = 0);

comment on column public.coin_packs.bonus_coins is
  '購入時の上乗せコイン。**0083で廃止し、0以外を入れられない。**再開する場合は制約を外す migration を書くこと(法務: 景表法の有利誤認 / 税務: 無償コイン起因の純額処理 / 資金: 分別口座への補填が同時に復活する)。';

-- ------------------------------------------------------------
-- 3. 付与側でも止める(多層で防ぐ)
--
-- Webhook はパックの bonus_coins をメタデータ経由で渡してくる。
-- 上の制約でパック側は0になるが、**メタデータは決済時点の値が
-- そのまま残る**ので、廃止をまたいだ決済が届く可能性がある。
--
-- ⚠️ **例外にはしない。** ここで失敗させると、代金を受け取ったのに
-- コインが付与されない事故になる。**有償分だけを付与して先へ進む。**
-- ------------------------------------------------------------
create or replace function public.credit_coins_for_purchase(
  p_user_id uuid,
  p_pack_id text,
  p_coins int,
  p_bonus_coins int,
  p_price_yen int,
  p_session_id text,
  p_payment_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_expires timestamptz := public.coin_expiry_from(now());
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 冪等性: 同じ session を二度処理しない
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  -- 0083: 購入ボーナスは廃止した。**引数は無視する。**
  -- 廃止をまたいだ決済(メタデータに古い値が残っているもの)が届いても、
  -- 有償分だけを付与して処理を続ける。
  if coalesce(p_bonus_coins, 0) <> 0 then
    raise notice '0083: 購入ボーナスは廃止済みのため無視しました(session=%, bonus=%)',
      p_session_id, p_bonus_coins;
  end if;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent)
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent);

  update public.coin_wallets
    set balance = balance + p_coins
    where user_id = p_user_id;

  insert into public.coin_lots (user_id, kind, remaining, expires_at)
    values (p_user_id, 'paid', p_coins, v_expires);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$fn$;

comment on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) is
  'Webhook から呼ぶ冪等なコイン付与(service_role専用)。0083で購入ボーナスを廃止したため、p_bonus_coins は無視する(引数は互換のために残している)。';

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;
