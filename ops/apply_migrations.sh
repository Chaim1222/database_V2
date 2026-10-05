#!/usr/bin/env bash
# מחיל מיגרציות שטרם הוחלו (לפי ops.schema_migration) לפי הסדר, כל אחת בטרנזקציה אחת.
# שימוש: DATABASE_URL=... ops/apply_migrations.sh [--check]
#   --check: לא מחיל כלום; מדפיס מה ממתין, ויוצא 1 אם יש מיגרציה ממתינה או מיגרציה במסד שאינה בריפו (סטייה).
set -euo pipefail
cd "$(dirname "$0")/../db/migrations"
: "${DATABASE_URL:?חסר DATABASE_URL}"
q() { psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
applied=$(q -c "select version from ops.schema_migration order by version" 2>/dev/null || true)
pending=(); in_repo=()
for f in [0-9]*.sql; do
  v=${f%%_*}; in_repo+=("$v")
  grep -qx "$v" <<<"$applied" || pending+=("$f")
done
orphans=$(comm -13 <(printf '%s\n' "${in_repo[@]}" | sort) <(sort <<<"$applied") | grep -v '^$' || true)
[ -n "$orphans" ] && echo "סטייה: במסד מיגרציות שאינן בריפו: $orphans"
echo "ממתינות: ${#pending[@]} ${pending[*]:-}"
if [ "${1:-}" = "--check" ]; then
  [ "${#pending[@]}" = 0 ] && [ -z "$orphans" ]; exit
fi
for f in "${pending[@]}"; do
  echo "מחיל $f"
  q -1 -f "$f"
done
echo "הסתיים"
