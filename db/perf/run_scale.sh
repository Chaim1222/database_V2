#!/usr/bin/env bash
# מריץ את בדיקת הקנה מידה על מסד מקומי זמני, אחרי המיגרציות. שימוש: v2/db/perf/run_scale.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB="v2_scale_$$"
if [ "$(id -u)" = "0" ] && [ -z "${PGUSER:-}" ]; then RUN=(su postgres -c); else RUN=(bash -c); fi
run() { "${RUN[@]}" "$1"; }
trap 'run "psql -X -q -d postgres -c \"drop database if exists $DB\"" >/dev/null 2>&1 || true' EXIT
run "psql -X -q -d postgres -c 'create database $DB'" >/dev/null
run "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f '$PWD/tests/00_supabase_stub.sql'"
for f in migrations/*.sql; do run "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f '$PWD/$f'"; done
run "psql -X -v ON_ERROR_STOP=1 -d $DB -f '$PWD/perf/${SCALE_SCRIPT:-scale_test.sql}'"
