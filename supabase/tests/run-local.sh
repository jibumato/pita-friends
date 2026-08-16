#!/usr/bin/env bash
# ============================================================
# ローカルPostgresでマイグレーションとテストを通しで流す。
#
# README.md の手順をそのまま script にしたもの。本番DBには一切触れない。
#
#   ./supabase/tests/run-local.sh          … 全部流す
#   ./supabase/tests/run-local.sh 32 88    … 番号で始まるものだけ流す
#
# ■ テストごとにDBを作り直している理由
#   `40_host_fees.sql` と `60_extension.sql` は同じフィクスチャ
#   (`_fixture_host.sql`)を使うので、同一DBに続けて流すと2本目が重複キーで
#   落ちる。1本ごとに作り直せば、この手の依存を気にしなくてよくなる。
#   (作り直しは数秒。まとめて流すより遅いが、原因の切り分けがずっと楽)
# ============================================================
set -uo pipefail

PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
PGPORT=${PGPORT:-55432}
PGHOST=${PGHOST:-/tmp}
PGDATA=${PGDATA:-/home/pgtest/pgdata}
PGUSER=${PGUSER:-postgres}
DB=${DB:-pita}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

psql_() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$@"; }

# ------------------------------------------------------------
# 1. 起動していなければ起動する(initdb も無ければ作る)
# ------------------------------------------------------------
ensure_server() {
  if psql_ -d postgres -c 'select 1' >/dev/null 2>&1; then return 0; fi

  if [ ! -d "$PGDATA" ]; then
    echo "== initdb =="
    id pgtest >/dev/null 2>&1 || useradd -m -s /bin/bash pgtest
    mkdir -p "$PGDATA" && chown -R pgtest:pgtest "$(dirname "$PGDATA")"
    su pgtest -c "$PGBIN/initdb -D $PGDATA -U $PGUSER --auth=trust" >/tmp/initdb.log 2>&1 \
      || { echo "initdb に失敗: /tmp/initdb.log"; exit 1; }
  fi

  echo "== postgres を起動 =="
  su pgtest -c "$PGBIN/pg_ctl -D $PGDATA -o '-p $PGPORT -k $PGHOST' -l /tmp/pg.log start" >/dev/null 2>&1
  for _ in $(seq 1 20); do
    psql_ -d postgres -c 'select 1' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "起動できなかった: /tmp/pg.log"; exit 1
}

# ------------------------------------------------------------
# 2. まっさらなDB + シム + マイグレーション全適用
# ------------------------------------------------------------
#
# ⚠️ ここでのループ変数は必ず local にすること。
#   bash の関数は呼び出し元と同じ変数空間を使うので、`for f in ...` のような
#   ありふれた名前を使うと**呼び出し元の $f を書き換える**。
#   実際にそれで、テストの代わりに最後のマイグレーションを流し直して
#   全部 ok と報告する状態を作ってしまった(出力も差分も無いので気づけない)。
reset_db() {
  local mig
  psql_ -d postgres -q -c "drop database if exists $DB" >/dev/null
  psql_ -d postgres -q -c "create database $DB" >/dev/null
  psql_ -d "$DB" -q -c "create extension if not exists pgcrypto" >/dev/null
  psql_ -d "$DB" -q -c "create publication supabase_realtime" >/dev/null
  # ロールはDBをまたいで共有されるので、2回目以降は既にある(無視してよい)
  psql_ -d "$DB" -q -c "create role anon nologin" >/dev/null 2>&1
  psql_ -d "$DB" -q -c "create role authenticated nologin" >/dev/null 2>&1
  psql_ -d "$DB" -q -c "create role service_role nologin" >/dev/null 2>&1
  psql_ -d "$DB" -q -v ON_ERROR_STOP=1 -f "$ROOT/supabase/tests/00_supabase_shim.sql" >/dev/null || return 1
  psql_ -d "$DB" -q -v ON_ERROR_STOP=1 -f "$ROOT/supabase/tests/01_storage_shim.sql" >/dev/null || return 1
  for mig in "$ROOT"/supabase/migrations/*.sql; do
    if ! psql_ -d "$DB" -q -v ON_ERROR_STOP=1 -f "$mig" >/tmp/mig.log 2>&1; then
      echo "マイグレーション失敗: $(basename "$mig")"; tail -20 /tmp/mig.log; return 1
    fi
  done
}

ensure_server

# ------------------------------------------------------------
# 3. 流す対象を決める(引数があれば番号で絞る)
# ------------------------------------------------------------
files=()
for f in "$ROOT"/supabase/tests/*.sql; do
  base=$(basename "$f")
  case "$base" in 00_*|01_*|_fixture_*) continue ;; esac
  if [ $# -gt 0 ]; then
    match=0
    for want in "$@"; do case "$base" in "$want"*) match=1 ;; esac; done
    [ $match -eq 1 ] || continue
  fi
  files+=("$f")
done

echo "== マイグレーションを適用して ${#files[@]} 本を流す =="
pass=0; fail=0; failed=()
for f in "${files[@]}"; do
  base=$(basename "$f")
  if ! reset_db; then echo "FAIL(準備) $base"; fail=$((fail+1)); failed+=("$base"); continue; fi
  if psql_ -d "$DB" -q -v ON_ERROR_STOP=1 -f "$f" >/tmp/test.log 2>&1; then
    # 何も出力しないテストは「流れていない」ことのほうが多い。
    # (どのテストも raise notice / \echo で経過を出す作りになっている)
    if [ ! -s /tmp/test.log ]; then
      fail=$((fail+1)); failed+=("$base")
      printf '  FAIL %s  ← 何も出力していない。流れていない可能性がある\n' "$base"
      continue
    fi
    pass=$((pass+1)); printf '  ok   %s\n' "$base"
  else
    fail=$((fail+1)); failed+=("$base")
    printf '  FAIL %s\n' "$base"
    grep -E 'ERROR|FAIL' /tmp/test.log | head -5 | sed 's/^/       /'
  fi
done

echo "==== PASS=$pass FAIL=$fail ===="
if [ $fail -gt 0 ]; then printf '落ちたもの: %s\n' "${failed[*]}"; exit 1; fi
