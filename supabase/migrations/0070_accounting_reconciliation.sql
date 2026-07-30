-- ============================================================
-- 0070: 月次の残高照合と、将来のインボイス対応の下地
-- ------------------------------------------------------------
-- 税理士の回答(2026-07-30)§6-1 より:
--   「設計の要は、補助元帳の残高とシステム上のコイン残高を毎月末に
--     照合すること。『前受金(コイン)の帳簿残高 ＝ DB上の未使用コイン総数
--     (円換算)』が一致することを月次で証跡化してください。これは会計目的
--     だけでなく、**資金決済法上の分別管理の説明資料**にもなり、弁護士側の
--     推奨事項にも同時に応えます。」
--
-- 0043 の整合チェックは**利用者ごとの不一致**を探すもので、
-- 記帳に必要な**会社全体の残高**は出せない。ここで足す。
--
-- ■ 勘定科目との対応(税理士の提示した勘定設計に合わせている)
--   前受金(コイン)        … 未使用の**有償**コイン。1コイン=1円
--   前受金(予約エスクロー) … 予約成立済み・完了未確定のコイン
--   預り金(ホスト報酬)     … 確定済み・未換金の報酬コイン
--   未払金(換金申請中)     … 換金申請済み・未振込
--
-- ■ **無償コイン(ボーナス)は前受金に入れない。**
--   現金を受け取っていないので負債ではない。ただし利用者は使えるので、
--   「将来の値引き原資」として**別建てで参考表示**する。ここを混ぜると
--   前受金残高が現金と合わなくなり、分別管理の説明が崩れる。
--
-- ■ 読み取りのみ。テーブルもお金も一切変更しない。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 会計用の残高サマリー(運営のみ)
-- ------------------------------------------------------------
create or replace function public.accounting_balances()
returns table (
  区分 text,
  勘定科目 text,
  金額円 bigint,
  備考 text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  -- 未使用の有償コイン = 前受金。現金を受け取っている分だけを負債に立てる
  select '負債'::text, '前受金(コイン)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '未使用の有償コイン。1コイン=1円。分別口座の残高と対応させる'::text
  from public.coin_lots l
  where l.kind = 'paid' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 予約成立済み・完了未確定 = まだ誰の収益にもなっていない
  select '負債'::text, '前受金(予約エスクロー)'::text,
         coalesce(sum(b.coins), 0)::bigint,
         '予約成立済み・プレイ完了未確定。確定時に利用料と報酬に分かれる'::text
  from public.bookings b
  where b.status in ('requested', 'confirmed')

  union all
  -- 確定済み・未換金のホスト報酬 = 預り金
  select '負債'::text, '預り金(ホスト報酬)'::text,
         coalesce(sum(w.earned_balance), 0)::bigint,
         '確定済み・未換金の報酬コイン。**失効しない**(0018)'::text
  from public.coin_wallets w

  union all
  -- 換金申請済み・未振込 = 未払金(振込額と手数料を分けて持つ)
  select '負債'::text, '未払金(換金申請中)'::text,
         coalesce(sum(p.amount_yen), 0)::bigint,
         '換金申請済み・未振込の振込予定額(手数料控除後)'::text
  from public.payouts p
  where p.status = 'pending'

  union all
  -- ここから下は負債ではない参考値
  select '参考'::text, '無償コイン残(ボーナス)'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '**前受金に含めない**(現金を受け取っていない)。将来の値引き原資'::text
  from public.coin_lots l
  where l.kind = 'bonus' and l.remaining > 0 and l.expires_at > now()

  union all
  -- 期限切れで未処理のロット。ここが0でないと失効処理が追いついていない
  select '要確認'::text, '期限切れ・失効処理待ち'::text,
         coalesce(sum(l.remaining), 0)::bigint,
         '0でなければ expire_coins() が動いていない。雑収入の計上漏れになる'::text
  from public.coin_lots l
  where l.remaining > 0 and l.expires_at <= now();
end;
$$;

comment on function public.accounting_balances() is
  '月次の記帳・照合用の残高サマリー(運営のみ)。税理士の勘定設計に対応。読み取りのみ。';

revoke all on function public.accounting_balances() from public;
grant execute on function public.accounting_balances() to authenticated;

-- ------------------------------------------------------------
-- 2. 期間の損益サマリー(運営のみ)
-- ------------------------------------------------------------
-- 税理士の指摘 §1-2: 手数料の計上時期は「コイン消費時」ではなく
-- **「プレイ完了確定時」**(権利確定主義・所得税法36条1項)。
-- platform_fees は完了確定時に記録されるので、その期間合計を出せば
-- そのまま売上になる。あわせて、一覧から漏れていた
-- **換金手数料(§2-3 ④)**と**コイン失効益**も出す。
create or replace function public.accounting_revenue(p_from date, p_to date)
returns table (
  区分 text,
  科目 text,
  金額円 bigint,
  消費税 text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  -- プラットフォーム利用料(予約) … 完了確定時に platform_fees へ記録される
  select '売上'::text, 'PF利用料(予約)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'booking'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  select '売上'::text, 'PF利用料(ギフト)'::text,
         coalesce(sum(f.fee_coins), 0)::bigint, '課税10%'::text
  from public.platform_fees f
  where f.kind = 'gift'
    and f.created_at >= p_from and f.created_at < (p_to + 1)

  union all
  -- あんしんサポート料。購入時に売上計上する(税理士 §1-4)。0071で「あんしん保証料」から改称
  select '売上'::text, 'あんしんサポート料(購入時)'::text,
         coalesce(sum(cp.safety_fee_yen), 0)::bigint, '課税10%'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1)

  union all
  -- 換金手数料。**当初の資料で漏れていた課税売上**(税理士 §2-3 ④)
  select '売上'::text, '換金手数料'::text,
         coalesce(sum(p.fee_yen), 0)::bigint, '課税10%'::text
  from public.payouts p
  where p.status = 'paid'
    and p.paid_at >= p_from and p.paid_at < (p_to + 1)

  union all
  -- コイン失効益。不課税(対価性がない)
  select '雑収入'::text, 'コイン失効益'::text,
         coalesce(-sum(t.amount), 0)::bigint, '不課税'::text
  from public.coin_transactions t
  where t.type = 'expire'
    and t.created_at >= p_from and t.created_at < (p_to + 1)

  union all
  -- 参考: 期間中のコイン販売額。**売上ではない**(前受金)
  select '参考(売上でない)'::text, 'コイン販売額(前受金の増加)'::text,
         coalesce(sum(cp.price_yen), 0)::bigint, '不課税'::text
  from public.coin_purchases cp
  where cp.created_at >= p_from and cp.created_at < (p_to + 1);
end;
$$;

comment on function public.accounting_revenue(date, date) is
  '期間の売上サマリー(運営のみ)。手数料は完了確定時ベース。換金手数料と失効益を含む。コイン販売額は前受金なので参考表示。';

revoke all on function public.accounting_revenue(date, date) from public;
grant execute on function public.accounting_revenue(date, date) to authenticated;

-- ------------------------------------------------------------
-- 3. ホストごとの年間支払額(税理士 §4・§5-1)
-- ------------------------------------------------------------
-- 支払調書の提出義務は無い見込み(6号非該当)。ただし税理士の指摘どおり
-- 「**提出義務がないことと、記録を残さなくてよいことは別**」であり、
-- 国税通則法74条の7の2の情報照会に応じられる状態を保つ必要がある。
-- 「ホストごとの年間支払額を随時出力できる状態を常に保ってください」。
create or replace function public.accounting_host_payments(p_year int)
returns table (
  user_id uuid,
  nickname text,
  件数 int,
  支払額円 bigint,
  手数料円 bigint,
  最終支払日 timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  return query
  select p.user_id,
         coalesce(nullif(pr.nickname, ''), '(不明)'),
         count(*)::int,
         coalesce(sum(p.amount_yen), 0)::bigint,
         coalesce(sum(p.fee_yen), 0)::bigint,
         max(p.paid_at)
  from public.payouts p
  left join public.profiles pr on pr.id = p.user_id
  where p.status = 'paid'
    and p.paid_at >= make_date(p_year, 1, 1)
    and p.paid_at < make_date(p_year + 1, 1, 1)
  group by p.user_id, pr.nickname
  order by sum(p.amount_yen) desc;
end;
$$;

comment on function public.accounting_host_payments(int) is
  'ホストごとの年間支払額(運営のみ)。支払調書の義務は無い見込みだが、税務照会に応じられる状態を保つために持つ。';

revoke all on function public.accounting_host_payments(int) from public;
grant execute on function public.accounting_host_payments(int) to authenticated;

-- ------------------------------------------------------------
-- 4. 将来のインボイス対応の下地(列だけ用意する)
-- ------------------------------------------------------------
-- 税理士の指摘 §2-4:
--   「将来、当社が登録し、かつ課税事業者のホストが一定数を超えた段階で、
--     ホストから登録番号を収集し、当社が一括して適格請求書を発行する
--     仕組み(媒介者交付特例)として検討価値があります。システム改修が
--     必要になる論点なので、**DB設計の段階で「ホストの登録番号を持てる
--     列」だけは用意しておくと後が楽**です。」
--
-- いま使う予定はない。**画面も作らない。**列だけ置いておく。
-- 形式は「T + 13桁」。null を既定にし、入力を強制しない。
alter table public.host_settings
  add column if not exists invoice_registration_number text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'host_settings_invoice_number_format'
  ) then
    alter table public.host_settings
      add constraint host_settings_invoice_number_format
      check (invoice_registration_number is null
             or invoice_registration_number ~ '^T[0-9]{13}$');
  end if;
end $$;

comment on column public.host_settings.invoice_registration_number is
  '適格請求書発行事業者の登録番号(T+13桁)。将来の媒介者交付特例に備えた予約列で、現時点では未使用・画面も無い。';
