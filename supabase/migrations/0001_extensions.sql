-- 拡張機能の有効化。gen_random_uuid() 等のため。
create extension if not exists pgcrypto with schema public;

-- updated_at カラムを自動更新する共通トリガー関数。
-- (moddatetime 拡張への依存を避け、環境を問わず動作するよう自前定義)
create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
