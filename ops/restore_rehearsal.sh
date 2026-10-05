#!/usr/bin/env bash
# חזרה על נוהל השחזור (ops/BACKUP_RESTORE.md) על מסדים מקומיים זמניים: גיבוי work ו-auth.users ממסד עם נתונים, שחזור למסד חדש
# שנבנה מהמיגרציות, והשוואת ספירות ובדיקת api.is_admin. מוכיח את המנגנון; בדיקת השחזור מהגיבוי האמיתי של הייצור נשארת ידנית.
set -euo pipefail
cd "$(dirname "$0")/../db"
SRC="v2_rehearse_src_$$"; DST="v2_rehearse_dst_$$"
if [ "$(id -u)" = "0" ] && [ -z "${PGUSER:-}" ]; then RUN=(su postgres -c); else RUN=(bash -c); fi
run() { "${RUN[@]}" "$1"; }
cleanup() { run "psql -X -q -d postgres -c 'drop database if exists $SRC'" >/dev/null 2>&1 || true; run "psql -X -q -d postgres -c 'drop database if exists $DST'" >/dev/null 2>&1 || true; }
trap cleanup EXIT
build() { run "psql -X -q -d postgres -c 'create database $1'" >/dev/null; run "psql -X -q -v ON_ERROR_STOP=1 -d $1 -f '$PWD/tests/00_supabase_stub.sql'"; for f in migrations/*.sql; do run "psql -X -q -v ON_ERROR_STOP=1 -d $1 -f '$PWD/$f'" >/dev/null; done; }
build "$SRC"; build "$DST"
run "psql -X -q -v ON_ERROR_STOP=1 -d $SRC" <<'SQL'
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1');
insert into work.admin (user_id) values ('00000000-0000-0000-0000-0000000000a1');
insert into work.manual_link (mech_id, wiki_id, reason, created_by) values (10, 1, 'x', '00000000-0000-0000-0000-0000000000a1'), (11, 2, 'y', null);
insert into work.exclusion (kind, title, reason) values ('locked_create', 'כותרת חסומה', 'z');
insert into work.scan_feedback (wiki_id, match_key, word, entries, label, user_id) values (1, 'k', 'w', '{e}', 'false', '00000000-0000-0000-0000-0000000000a1');
SQL
run "pg_dump -d $SRC --data-only --no-owner --table=auth.users -f /tmp/rehearsal_users_$$.sql"
run "pg_dump -d $SRC --data-only --no-owner --schema=work -f /tmp/rehearsal_work_$$.sql"
# סדר השחזור: קודם auth.users (מפתחות זרים), ואז work
run "psql -X -q -v ON_ERROR_STOP=1 -d $DST -f /tmp/rehearsal_users_$$.sql -f /tmp/rehearsal_work_$$.sql" >/dev/null
count() { run "psql -X -t -A -d $1 -c \"select (select count(*) from work.admin)||','||(select count(*) from work.manual_link)||','||(select count(*) from work.exclusion)||','||(select count(*) from work.scan_feedback)||','||(select count(*) from auth.users)\""; }
a=$(count "$SRC"); b=$(count "$DST")
admin=$(run "psql -X -t -A -d $DST -c \"set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1'; select api.is_admin()\"" | tail -1)
rm -f /tmp/rehearsal_users_$$.sql /tmp/rehearsal_work_$$.sql
echo "מקור: $a | משוחזר: $b | is_admin: $admin"
[ "$a" = "$b" ] && [ "$admin" = "t" ] && echo "ok: השחזור זהה" || { echo "FAIL"; exit 1; }
