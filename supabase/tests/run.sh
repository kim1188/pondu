#!/usr/bin/env bash
# 일반 Postgres에 임시 DB를 만들어 마이그레이션 전체를 적용하고 테스트를 돌린다.
#   supabase/tests/run.sh            전체
#   supabase/tests/run.sh sessions   supabase/tests/sessions/*.sql 만
# 테스트 파일은 실패 시 예외를 던지는 SQL이다(assert 또는 raise exception). 예외가 없으면 통과.
set -euo pipefail
cd "$(dirname "$0")/.."

PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
DATA="${PONDU_PGDATA:-/tmp/pondu-pg}"
PORT="${PONDU_PGPORT:-54329}"
RUNAS=""
if [ "$(id -u)" = "0" ]; then RUNAS="runuser -u postgres --"; fi

if ! $RUNAS "$PGBIN/pg_isready" -q -h 127.0.0.1 -p "$PORT"; then
  if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA"; [ -n "$RUNAS" ] && chown postgres "$DATA"
    $RUNAS "$PGBIN/initdb" -D "$DATA" -A trust -U postgres >/dev/null
  fi
  $RUNAS "$PGBIN/pg_ctl" -D "$DATA" -o "-p $PORT -c listen_addresses=127.0.0.1" -l "$DATA/log" -w start >/dev/null
fi

PSQL="psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p $PORT -U postgres"
DB="pondu_test_$$"
$PSQL -d postgres -c "create database $DB encoding 'UTF8' locale 'C.UTF-8' template template0"
trap '$PSQL -d postgres -c "drop database if exists $DB" >/dev/null' EXIT

$PSQL -d "$DB" -c "create extension if not exists pgcrypto" -f tests/shim.sql
for f in $(ls migrations/*.sql | sort); do
  $PSQL -d "$DB" -f "$f" >/dev/null || { echo "마이그레이션 실패: $f"; exit 1; }
done
echo "마이그레이션 $(ls migrations/*.sql | wc -l)개 적용"

pass=0; fail=0
for f in $(ls tests/${1:-*}/*.sql 2>/dev/null | sort); do
  if out=$($PSQL -d "$DB" -f "$f" 2>&1); then pass=$((pass+1)); echo "  ✓ $f"
  else fail=$((fail+1)); echo "  ✗ $f"; echo "$out" | sed 's/^/      /' | tail -8; fi
done
echo "통과 $pass, 실패 $fail"
[ "$fail" = "0" ]
