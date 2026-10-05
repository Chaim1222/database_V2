#!/usr/bin/env bash
# מריץ את המיגרציות והבדיקות על Postgres מקומי (מסד זמני). שימוש: v2/db/run_tests.sh
# דורש psql וגישה כ-superuser (ברירת מחדל: su postgres). משתני סביבה: PGHOST/PGUSER לשינוי.
set -euo pipefail
cd "$(dirname "$0")"
DB="v2_test_$$"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -P pager=off -t -A)
if [ "$(id -u)" = "0" ] && [ -z "${PGUSER:-}" ]; then RUN=(su postgres -c); else RUN=(bash -c); fi
run() { "${RUN[@]}" "$1"; }
cleanup() { run "psql -X -q -c 'drop database if exists $DB'" >/dev/null 2>&1 || true; }
trap cleanup EXIT
run "psql -X -q -c 'create database $DB'" >/dev/null
apply() { run "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f '$PWD/$1'" ; }
apply tests/00_supabase_stub.sql
for f in migrations/*.sql; do echo "migration: $f"; apply "$f"; done
fail=0
for f in tests/t*.sql; do
  if out=$(run "psql -X -q -t -A -v ON_ERROR_STOP=1 -d $DB -f '$PWD/$f' 2>&1"); then echo "$out" | grep -E "^ok" || true; else echo "FAIL $f"; echo "$out" | tail -8; fail=1; fi
done
[ "$fail" = 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
