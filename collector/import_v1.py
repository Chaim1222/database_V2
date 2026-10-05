"""
העברת נתוני אדם מ-v1 (manual_matches, blacklist_titles, page_lock_levels, word_filter_feedback) ל-v2 דרך api.import_human_data.
קורא את v1 במפתח service (קריאה בלבד), מאמת כל שורה מול המראה ב-v2 ומדפיס את מה שדולג. אידמפוטנטי. --dry-run: רק ספירות.
משתני סביבה: V1_SUPABASE_URL, V1_SUPABASE_SERVICE_KEY, SUPABASE_URL, SUPABASE_SERVICE_KEY, V2_ADMIN_UID (חשבון Supabase Auth של המנהל ב-v2).
"""
import json
import os
import sys

import requests

TABLES = {
    "manual": ("manual_matches", "mechalol_page_id,wikipedia_page_id,reason,added_at", "id"),
    "blacklist": ("blacklist_titles", "title,reason,added_at", "id"),
    "locks": ("page_lock_levels", "mechalol_id,allevel,checked_at", "mechalol_id"),
    "feedback": ("word_filter_feedback",
                 "wikipedia_id,match_key,word,entries,topic,hidden,label,level,before,after,lists_version,created_at", "id"),
}


def read_v1(url, key, table, columns, order, session=None):
    """כל השורות בעימוד לפי מפתח (1000 לבקשה). מזהה מפתח הוא עמודה; לעימוד משתמשים ב-offset יציב לפי order."""
    session = session or requests.Session()
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    rows, offset = [], 0
    while True:
        response = session.get(f"{url.rstrip('/')}/rest/v1/{table}", headers={**headers, "Range-Unit": "items", "Range": f"{offset}-{offset + 999}"},
                               params={"select": columns, "order": f"{order}.asc"}, timeout=60)
        response.raise_for_status()
        batch = response.json()
        rows.extend(batch)
        if len(batch) < 1000:
            return rows
        offset += 1000


CHUNK = 100   # הקריאה ל-API מוגבלת בכ-8 שניות, והטריגרים רצים לכל שורה
KEYS = {"manual": "p_manual", "blacklist": "p_blacklist", "feedback": "p_feedback", "locks": "p_locks"}


def import_chunked(rpc, admin, data):
    """שולח כל טבלה במנות; מחבר את הנוספו והדולגו. אידמפוטנטי (on conflict do nothing), ולכן בטוח להריץ שוב אחרי כשל."""
    total = {"inserted": {k: 0 for k in KEYS}, "skipped": {k: [] for k in KEYS}}
    for name, param in KEYS.items():
        rows = data[name]
        for i in range(0, len(rows), CHUNK):
            payload = {"p_admin": admin, "p_manual": [], "p_blacklist": [], "p_feedback": [], "p_locks": [], param: rows[i:i + CHUNK]}
            result = rpc.call("import_human_data", payload)
            total["inserted"][name] += result["inserted"].get(name, 0)
            total["skipped"][name] += result["skipped"].get(name, [])
    return total


def main(argv, env=os.environ, session=None):
    dry = "--dry-run" in argv
    data = {name: read_v1(env["V1_SUPABASE_URL"], env["V1_SUPABASE_SERVICE_KEY"], *spec, session=session)
            for name, spec in TABLES.items()}
    print("נקראו מ-v1: " + ", ".join(f"{name}={len(rows)}" for name, rows in data.items()))
    if dry:
        return 0
    from .rpc import Rpc
    rpc = Rpc(env["SUPABASE_URL"], env["SUPABASE_SERVICE_KEY"])
    result = import_chunked(rpc, env["V2_ADMIN_UID"], data)
    rpc.call("maintenance_refresh_counts", {})
    print(json.dumps(result, ensure_ascii=False, indent=2))
    skipped = sum(len(v) for v in result["skipped"].values())
    print(f"דולגו {skipped} שורות (לא קיימות במראה או רמה לא מוכרת): יש לבדוק אותן ידנית" if skipped else "לא דולגה אף שורה")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
