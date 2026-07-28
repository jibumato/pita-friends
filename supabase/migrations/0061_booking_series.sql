-- ============================================================
-- 0061_booking_series.sql
-- まとめ予約(毎週くり返し)
-- ------------------------------------------------------------
-- 「毎週金曜22時」が決まっている二人でも、いまは毎週その都度予約する。
-- ピタメイト側から見ると、続けて来る人がいても枠は毎回ゼロから埋め直しで、
-- 先の予定が立たない。
--
-- 同じ相手・同じ時刻を4回分まとめて押さえられるようにする。
-- **新しいお金の仕組みは作らない。** 既存の create_booking を回数分呼ぶだけで、
-- 料金・割引・コインの消費・キャンセル規定はすべて1件ずつ従来どおり効く。
-- 回数券でも定期契約でもないので、前払式支払手段の整理も変わらない。
--
-- ■ 全部通るか、1件も作らないか
--   3週目だけ埋まっていたときに1・2・4週目を作ると、ゲストは頼んでいない
--   組み合わせに払わされる。同じトランザクションの中で回すので、どこかで
--   失敗すれば全部巻き戻る。エラーには何回目で落ちたかを載せる。
--
-- ■ 予約できる先を35日に延ばす
--   14日のままだと「4回分」が入らない(4回目が28日先になる)。
--   遠い予約ほどキャンセルの返還率は高い(0040の段階制)ので、ゲスト側の
--   不利は増えない。コインの有効期限は取得から6か月なので、そちらとも
--   ぶつからない。
-- ============================================================

update public.platform_pricing set max_lead_days = 35 where id = 1 and max_lead_days < 35;
alter table public.platform_pricing alter column max_lead_days set default 35;

comment on column public.platform_pricing.max_lead_days is
  '何日先まで予約できるか。0061でまとめ予約(4回分=28日先)が入るよう35日にした。';

-- ------------------------------------------------------------
-- create_booking_series(): 同じ時刻を毎週くり返して押さえる
-- ------------------------------------------------------------
create or replace function public.create_booking_series(
  p_host_id uuid,
  p_duration_minutes int,
  p_policy_version text,
  p_first_start timestamptz,
  p_count int
)
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max_count constant int := 4;
  v_ids uuid[] := '{}';
  v_at timestamptz;
  i int;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_first_start is null then
    raise exception 'SERIES_NEEDS_START';
  end if;
  -- 1回だけなら create_booking をそのまま使えばよい。ここは2回以上のための口。
  if p_count is null or p_count < 2 or p_count > c_max_count then
    raise exception 'INVALID_SERIES_COUNT';
  end if;

  for i in 0 .. p_count - 1 loop
    v_at := p_first_start + make_interval(days => 7 * i);
    begin
      -- 料金・割引・コイン消費・枠の重複・常連への先行予約(0057)は
      -- すべて create_booking の中の判定に委ねる。ここで写し取らない。
      v_ids := v_ids || public.create_booking(p_host_id, p_duration_minutes, p_policy_version, v_at);
    exception when others then
      -- 何回目で落ちたかを添えて投げ直す。元のメッセージは残すので、
      -- 画面側の INSUFFICIENT_COINS 等の判定はそのまま効く。
      raise exception '% [まとめ予約 %回目/%]', sqlerrm, i + 1, p_count;
    end;
  end loop;

  return v_ids;
end;
$$;

comment on function public.create_booking_series(uuid, int, text, timestamptz, int) is
  '同じ時刻を毎週くり返して2〜4回まとめて予約する。中身は create_booking を回数分呼ぶだけで、料金・割引・キャンセル規定は1件ずつ従来どおり。どこかで失敗すれば全部巻き戻る。';

revoke all on function public.create_booking_series(uuid, int, text, timestamptz, int) from public;
grant execute on function public.create_booking_series(uuid, int, text, timestamptz, int) to authenticated;
