-- ============================================================
-- 0119: 居住地の確認をゲストにも効かせ、購入時の居住国を記録する
--
-- ■ 見つかった穴
--   規約 第3条3項は「本サービスは、**日本国内に居住する個人**に限り」と、
--   サービス全体を限っている。ところが `0081` の強制は
--   `identity_verifications` の INSERT トリガー**1か所だけ**だった。
--
--     ピタメイト(本人確認を出す人) … 申告を求め、「いいえ」なら止める
--     ゲスト(本人確認を出さない人) … **申告の機会が無く、素通り**
--
--   `declare_residency` を呼ぶ画面は本人確認の1か所だけで、予約も
--   `create_booking` が見るのは `HOST_NOT_VERIFIED`(ホスト側)だけ。
--   突合表では G4 を「✅実装」としていたが、**効いていたのは
--   ピタメイト側だけ**だった。
--
-- ■ どこで止めるか — 購入の1か所にする
--   予約にも足すことはできるが、**コインは購入からしか生まれない**
--   (0083 で購入ボーナスを廃止済み)。購入を止めれば、申告していない人は
--   役務を受けられない。
--
--   そして購入は、止める理由がいちばん強い場所でもある。
--     ・お金が動く手前で止まる
--     ・消費税の内外判定・消費者契約の準拠法が効いてくるのは、まさにここ
--     ・Edge Function が既に `allowed/code` を画面へ返す仕組みを持っている
--
--   **例外を投げず、既存の `allowed:false + code` の形に合わせる。**
--   別の形にすると、画面側にもう1本エラー処理が要る。
--
-- ■ 購入時の居住国を残す理由(★あとから遡れない)
--   消費税法4条3項3号の内外判定は「役務の提供を受ける者の住所等」で決まる。
--   海外の利用者への販売は**国外取引＝不課税**になるので、売上の区分が要る。
--   免税事業者のあいだは影響が小さいが、**課税事業者になってから
--   過去の購入を遡って区分することはできない。**
--
--   いまは日本限定なので、記録される値は当面すべて 'JP' になる。
--   それでよい。**器と経路を先に作っておくのが目的**で、開く判断をした
--   その日から正しく区分できる状態にしておく。
--
--   あわせて **決済された国**(Stripe の発行国)も残す。申告と食い違う購入は、
--   税務の区分だけでなく不正の手がかりにもなる。
--
-- ⚠️ この migration は**日本限定をやめるものではない。**
--    規約 第3条3項はそのまま。開くかどうかは弁護士・税理士の回答待ち
--    (`docs/legal/open-legal-matters.md` C-2)。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 申告に国を持たせる
--
-- いまは boolean(日本かどうか)だけ。開く判断をしたときに
-- 「どの国か」が要るので、器だけ先に作る。
-- ------------------------------------------------------------
alter table public.residency_declarations
  add column if not exists country_code text;

alter table public.residency_declarations
  drop constraint if exists residency_declarations_country_check;
alter table public.residency_declarations
  add constraint residency_declarations_country_check check (
    country_code is null or country_code ~ '^[A-Z]{2}$'
  );

comment on column public.residency_declarations.country_code is
  '申告された居住国(ISO 3166-1 alpha-2)。0119で追加。日本限定のあいだは JP か null。';

create or replace function public.declare_residency(
  p_declared_japan boolean,
  p_version text default 'v1',
  p_country_code text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_country text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_declared_japan is null then
    raise exception 'DECLARATION_REQUIRED';
  end if;

  -- 「日本に居住している」と答えたなら国は JP。取り違えを持ち込まない
  v_country := case
    when p_declared_japan then 'JP'
    else nullif(upper(btrim(coalesce(p_country_code, ''))), '')
  end;

  insert into public.residency_declarations
    (user_id, declared_japan, version, country_code)
  values (v_uid, p_declared_japan,
          coalesce(nullif(btrim(p_version), ''), 'v1'),
          v_country);
end;
$$;

comment on function public.declare_residency(boolean, text, text) is
  '居住地の自己申告を記録する(規約第3条3項)。上書きせず履歴として積む。0119で国コードを追加。';

revoke all on function public.declare_residency(boolean, text, text) from public;
grant execute on function public.declare_residency(boolean, text, text) to authenticated;

-- 引数が増えたので、古い2引数版は落とす。
-- **残すと画面が古いほうを呼び続け、国が記録されない**
drop function if exists public.declare_residency(boolean, text);

-- ------------------------------------------------------------
-- 2. いまの申告を1か所で読む
-- ------------------------------------------------------------
create or replace function public.residency_ok(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select d.declared_japan
       from public.residency_declarations d
      where d.user_id = p_user_id
      order by d.declared_at desc
      limit 1),
    false);
$$;

comment on function public.residency_ok(uuid) is
  '最新の申告が「日本国内に居住」か。未申告は false(0119)。';

revoke all on function public.residency_ok(uuid) from public, anon;
grant execute on function public.residency_ok(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. 購入を、申告が済むまで通さない
--
-- **例外ではなく allowed:false で返す。** Edge Function が既に
-- code を画面へ渡す形になっているので、そこに乗せる。
-- 未申告と「いいえ」を分けるのは 0081 と同じ理由(画面の文言が違う)。
-- ------------------------------------------------------------
create or replace function public.check_purchase_allowed(p_user_id uuid, p_price_yen int)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_per int;
  v_remaining bigint;
  v_declared boolean;
begin
  -- 0119: 居住地の確認を最初に見る。上限の話より前に、そもそも
  -- 利用できる人かどうかが決まる
  select d.declared_japan into v_declared
  from public.residency_declarations d
  where d.user_id = p_user_id
  order by d.declared_at desc
  limit 1;

  if v_declared is null then
    return jsonb_build_object('allowed', false, 'code', 'RESIDENCY_NOT_DECLARED');
  end if;
  if not v_declared then
    return jsonb_build_object('allowed', false, 'code', 'RESIDENCY_OUTSIDE_JAPAN');
  end if;

  v := public.purchase_limit_status(p_user_id);
  if not (v->>'is_new_user')::boolean then
    return jsonb_build_object('allowed', true);
  end if;

  v_per := (v->>'per_purchase_max_yen')::int;
  v_remaining := (v->>'remaining_yen')::bigint;

  if p_price_yen > v_per then
    return jsonb_build_object(
      'allowed', false,
      'code', 'PURCHASE_LIMIT_PER',
      'limit_yen', v_per,
      'remaining_yen', v_remaining,
      'period_days', (v->>'period_days')::int);
  end if;

  if p_price_yen > v_remaining then
    return jsonb_build_object(
      'allowed', false,
      'code', 'PURCHASE_LIMIT_PERIOD',
      'limit_yen', (v->>'period_max_yen')::int,
      'remaining_yen', v_remaining,
      'period_days', (v->>'period_days')::int);
  end if;

  return jsonb_build_object('allowed', true);
end;
$$;

comment on function public.check_purchase_allowed(uuid, int) is
  '買ってよいかの判定。0119で居住地の確認を追加(規約第3条3項)。決済の前に呼ぶこと——代金を受け取ってから弾くのは、防ごうとしている損失より重い事故になる。';

revoke all on function public.check_purchase_allowed(uuid, int) from public, anon, authenticated;
grant execute on function public.check_purchase_allowed(uuid, int) to service_role;

-- ------------------------------------------------------------
-- 4. 購入に「どこの人が買ったか」を残す
-- ------------------------------------------------------------
alter table public.coin_purchases
  add column if not exists buyer_country text,
  add column if not exists payment_country text;

comment on column public.coin_purchases.buyer_country is
  '購入時点の申告に基づく居住国(0119)。消費税法4条3項3号の内外判定の材料。'
  '**あとから遡って区分できないので、日本限定のあいだも記録する。**';
comment on column public.coin_purchases.payment_country is
  'Stripe が返した決済の国(カードの発行国など。0119)。申告と食い違う購入は不正の手がかりにもなる。';

-- 付与のときに、そのときの申告から書く。
-- **引数は増やさない。** 引数を変えると、migration の適用と Edge Function の
-- デプロイの順序が前後したときに付与そのものが落ちる(0104 と同じ判断)。
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
  v_purchase_id uuid;
  v_country text;
begin
  if p_coins <= 0 then
    raise exception 'INVALID_AMOUNT';
  end if;

  -- 冪等性: 同じ session を二度処理しない
  if exists (select 1 from public.coin_purchases where stripe_session_id = p_session_id) then
    return;
  end if;

  -- 0083: 購入ボーナスは廃止した。**引数は無視する。**
  if coalesce(p_bonus_coins, 0) <> 0 then
    raise notice '0083: 購入ボーナスは廃止済みのため無視しました(session=%, bonus=%)',
      p_session_id, p_bonus_coins;
  end if;

  -- 0119: 購入時点の申告国。**ここで確定させる。**
  -- あとで申告が変わっても、この購入がどこ向けだったかは動かない
  select case when d.declared_japan then coalesce(d.country_code, 'JP') else d.country_code end
    into v_country
  from public.residency_declarations d
  where d.user_id = p_user_id
  order by d.declared_at desc
  limit 1;

  insert into public.coin_purchases
    (user_id, pack_id, coins_credited, price_yen, stripe_session_id, stripe_payment_intent,
     buyer_country)
    values (p_user_id, p_pack_id, p_coins, p_price_yen, p_session_id, p_payment_intent,
     v_country)
    returning id into v_purchase_id;

  update public.coin_wallets
    set balance = balance + p_coins
    where user_id = p_user_id;

  insert into public.coin_lots (user_id, kind, remaining, expires_at, purchase_id)
    values (p_user_id, 'paid', p_coins, v_expires, v_purchase_id);

  insert into public.coin_transactions (user_id, amount, type, note)
    values (p_user_id, p_coins, 'purchase', 'stripe:' || p_session_id);
end;
$fn$;

comment on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) is
  'Webhook から呼ぶ冪等なコイン付与(service_role専用)。0083で購入ボーナスを廃止(引数は互換のため残す)。0087でロットに購入を紐づけ、0119で購入時点の居住国を記録する。';

revoke all on function public.credit_coins_for_purchase(uuid, text, int, int, int, text, text) from public;

-- ------------------------------------------------------------
-- 5. 追記専用トリガーに payment_country を通す
--
-- 0104 と同じ理由。webhook が決済成立後に一度だけ書く列を足すので、
-- **その列だけ**初回の書き込みを許す。金額・ユーザー・セッションIDは
-- 従来どおり変更できない。
--
-- ⚠️ **本体は 0104 のものをそのまま持ってきて、payment_country の分だけ
--    足している。** 記憶で書き直したところ safety_fee_yen の上書き禁止と
--    DELETE の分岐を落としており、テスト28 が拾った。
--    トリガーを差し替えるときは、必ず前の版から差分で作ること。
-- ------------------------------------------------------------
create or replace function public._purchase_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rest_old jsonb;
  v_rest_new jsonb;
begin
  -- 明示的な解除は従来どおり通す(記録つき)
  if public._ledger_override_on() then
    perform public._ledger_record_bypass(
      TG_TABLE_NAME, TG_OP,
      to_jsonb(OLD),
      case when TG_OP = 'UPDATE' then to_jsonb(NEW) else null end);
    if TG_OP = 'DELETE' then return OLD; end if;
    return NEW;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases の行は削除できません。訂正が必要な場合は打ち消しの行を追加してください。';
  end if;

  -- webhook が決済成立後に書く3列だけを、書き込み1回に限って通す(0119で1列追加)。
  -- 「同値の再書き込み」を許すのは、Stripe が同じイベントを再送するため
  -- (冪等な再実行を例外にしない)。
  v_rest_old := to_jsonb(OLD) - 'safety_fee_yen' - 'payment_method' - 'payment_country';
  v_rest_new := to_jsonb(NEW) - 'safety_fee_yen' - 'payment_method' - 'payment_country';
  if v_rest_old <> v_rest_new then
    raise exception 'LEDGER_IMMUTABLE: coin_purchases は追記専用です(変更できるのは safety_fee_yen / payment_method / payment_country の初回書き込みだけ)。やむを得ず直接操作する場合は同一トランザクションで set local app.ledger_override = ''on'' を宣言してください(操作は ledger_audit に記録されます)。';
  end if;
  if NEW.safety_fee_yen is distinct from OLD.safety_fee_yen
     and OLD.safety_fee_yen <> 0 then
    raise exception 'LEDGER_IMMUTABLE: safety_fee_yen は一度しか書き込めません(現在値 %)', OLD.safety_fee_yen;
  end if;
  if NEW.payment_method is distinct from OLD.payment_method
     and OLD.payment_method is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_method は一度しか書き込めません(現在値 %)', OLD.payment_method;
  end if;
  -- 0119: 決済国も一度だけ
  if NEW.payment_country is distinct from OLD.payment_country
     and OLD.payment_country is not null then
    raise exception 'LEDGER_IMMUTABLE: payment_country は一度しか書き込めません(現在値 %)', OLD.payment_country;
  end if;

  return NEW;
end;
$$;

comment on function public._purchase_immutable() is
  'coin_purchases の不変トリガー。0044 の全面禁止から、webhook が決済成立後に書く safety_fee_yen / payment_method / payment_country の初回書き込みだけを通す形に緩めた(0104、0119)。金額・ユーザー・セッションIDは従来どおり変更できない。';
