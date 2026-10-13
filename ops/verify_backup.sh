#!/usr/bin/env bash
# בדיקת שחזור של גיבוי אמיתי (פלט backup.yml): מסד זמני מהמיגרציות, שחזור work_data.sql, השוואה ל-counts.txt
# ובדיקת api.is_admin למנהל מ-admins.csv. auth.users אינו בגיבוי: מוקם כאן רק המזהה, כמו בהקמה מחדש של חשבון.
# שימוש: ops/verify_backup.sh DIR   (DIR מכיל work_data.sql, admins.csv, counts.txt). דורש Postgres מקומי (PGHOST/PGUSER).
set -euo pipefail
DIR=$(cd "$1" && pwd)
cd "$(dirname "$0")/../db"
DB="v2_restore_check_$$"
if [ "$(id -u)" = "0" ] && [ -z "${PGUSER:-}" ]; then RUN=(su postgres -c); else RUN=(bash -c); fi
run() { "${RUN[@]}" "$1"; }
trap 'run "psql -X -q -d postgres -c \"drop database if exists $DB\"" >/dev/null 2>&1 || true' EXIT
run "psql -X -q -d postgres -c 'create database $DB'" >/dev/null
run "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f '$PWD/tests/00_supabase_stub.sql'"
run "DATABASE_URL='postgresql:///$DB' bash '$PWD/../ops/apply_migrations.sh'" >/dev/null
admins=$(tail -n +2 "$DIR/admins.csv" | cut -d, -f1 | grep -E '^[0-9a-f-]{36}$' || true)
[ -n "$admins" ] || { echo "אין מנהלים בגיבוי"; exit 1; }
for id in $admins; do run "psql -X -q -v ON_ERROR_STOP=1 -d $DB -c \"insert into auth.users (id) values ('$id')\""; done
run "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f '$DIR/work_data.sql'" >/dev/null
restored=$(run "psql -X -t -A -d $DB -c \"select 'work.manual_link', count(*) from work.manual_link union all select 'work.exclusion', count(*) from work.exclusion union all select 'work.page_lock', count(*) from work.page_lock union all select 'work.scan_feedback', count(*) from work.scan_feedback union all select 'work.admin', count(*) from work.admin\"")
first=$(head -1 <<<"$admins")
admin=$(run "psql -X -t -A -d $DB -c \"set request.jwt.claim.sub = '$first'; select api.is_admin()\"" | tail -1)
echo "בגיבוי:"; cat "$DIR/counts.txt"; echo "משוחזר:"; echo "$restored"; echo "is_admin: $admin"
[ "$restored" = "$(cat "$DIR/counts.txt")" ] && [ "$admin" = "t" ] && echo "ok: השחזור זהה לספירות הייצור" || { echo "FAIL: השחזור אינו זהה"; exit 1; }
