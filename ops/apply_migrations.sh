#!/usr/bin/env bash
# מחיל מיגרציות שטרם הוחלו (לפי ops.schema_migration) לפי הסדר, כל אחת בטרנזקציה אחת.
# שימוש: DATABASE_URL=... ops/apply_migrations.sh [--check]
#   --check: לא מחיל כלום; מדפיס מה ממתין, ויוצא 1 אם יש מיגרציה ממתינה או מיגרציה במסד שאינה בריפו (סטייה).
set -euo pipefail
cd "$(dirname "$0")/../db/migrations"
: "${DATABASE_URL:?חסר DATABASE_URL}"
q() { psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
# A failed read is not an empty migration history. Retry reads only, before any write.
for attempt in 1 2 3; do
  if history_exists=$(q -c "select to_regclass('ops.schema_migration') is not null"); then
    if [ "$history_exists" = f ]; then
      # 0022 creates and backfills the registry during a fresh bootstrap.
      applied=""
      break
    fi
    if [ "$history_exists" = t ] && applied=$(q -c "select version from ops.schema_migration order by version"); then
      break
    fi
  fi
  if [ "$attempt" = 3 ]; then
    echo "לא ניתן לקרוא את היסטוריית המיגרציות; לא הוחלה מיגרציה. יש להריץ שוב אחרי תיקון הגישה." >&2
    exit 1
  fi
  sleep "$attempt"
done
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

