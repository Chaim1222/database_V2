#!/usr/bin/env bash
# מייצר את db/schema.sql מהמיגרציות (לא נכתב ביד): מסד מקומי זמני, כל המיגרציות, pg_dump של המבנה בלי כותרות תלויות גרסה.
# שימוש: db/gen_schema.sh   (ה-CI מריץ אותו ובודק שאין הפרש)
set -euo pipefail
cd "$(dirname "$0")"
DB="v2_schema_$$"
if [ "$(id -u)" = "0" ] && [ -z "${PGUSER:-}" ]; then RUN=(su postgres -c); else RUN=(bash -c); fi
run() { "${RUN[@]}" "$1"; }
trap 'run "psql -X -q -d postgres -c \"drop database if exists $DB\"" >/dev/null 2>&1 || true' EXIT
run "psql -X -q -d postgres -c 'create database $DB'" >/dev/null
run "psql -X -q -1 -v ON_ERROR_STOP=1 -d $DB -f '$PWD/tests/00_supabase_stub.sql'"
for f in migrations/*.sql; do run "psql -X -q -1 -v ON_ERROR_STOP=1 -d $DB -f '$PWD/$f'" >/dev/null; done
{
  echo "-- נוצר אוטומטית מ-db/migrations (db/gen_schema.sh). אין לערוך ידנית."
  run "pg_dump -d $DB --schema-only --no-owner --no-comments --schema=ref --schema=mirror --schema=derived --schema=enrich --schema=work --schema=ops --schema=api" \
    | grep -v -E '^(-- Dumped|[\\]restrict|[\\]unrestrict|SET |SELECT pg_catalog.set_config)' | sed -E 's/^(ALTER DEFAULT PRIVILEGES) FOR ROLE [A-Za-z0-9_]+ /\1 /' | cat -s   # בלי שם המשתמש שיצר את המסד (שונה בין מחשבים)
} > schema.sql
echo "db/schema.sql: $(wc -l < schema.sql) שורות"
