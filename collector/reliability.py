"""בדיקת אמינות בקריאה בלבד: מסדים עקביים → צילום משותף → השוואה → קבצים.

אין כאן RPC כותב, תיקון, קידום נקודות סנכרון או החרגה אוטומטית של פערים.
פער בדף שנערך בחלון מסומן לבדיקה; אינו נחשב הוכחה להתאמה.
"""
import argparse
import csv
import gzip
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .mw import MediaWiki
from .reconcile import snapshot
from .reconcile_compare import CLASSIFICATION_FIELDS, collect_window, compare_classification, compare_titles

APIS = {"wikipedia": "https://he.wikipedia.org/w/api.php", "mechalol": "https://www.hamichlol.org.il/w/api.php"}
STATUS_V1 = {
    "נוצר במכלול": "created_in_mech", "מיובא ומתועד": "imported_documented",
    "מיובא ללא תיעוד": "imported_undocumented", 'ייבוא מחב"דפדיה': "chabadpedia",
    "ייבוא מוויקישיבה": "wikishiva", "נשמר במכלול למרות מחיקה בוויקיפדיה": "kept_after_wiki_delete",
    "פוצל מתוכן ויקיפדי": "split_from_wiki",
}
# Common reports only; compare membership AND these shared semantic fields.
REPORTS = {
    "missing": ("report_missing_from_mechalol", ("title", "mechalol_redirect_exists")),
    "undocumented": ("report_undocumented_import", ("title", "source_type")),
    "moves": ("report_wikipedia_moves", ("title", "old_title", "wikipedia_title", "via", "wikipedia_id")),
    "revisions": ("report_rev_tasks", ("title", "rev_task", "sort_template_rev", "rev_page_id", "rev_page_title")),
}
LABELS = {"clean": "תקין", "differences": "נמצאו פערים", "failed": "הבדיקה נכשלה"}


class AuditError(RuntimeError):
    """A deliberately safe, user-readable diagnostic (never a network exception)."""


def iso(value):
    if isinstance(value, str):
        value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise ValueError("חותמת זמן ללא אזור זמן")
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def now():
    return datetime.now(timezone.utc)


class AuditMediaWiki(MediaWiki):
    """Reuse the existing collector, but fail on incomplete or ambiguous source replies."""
    def get(self, params):
        data = super().get(params)
        query = data.get("query") if isinstance(data, dict) else None
        key = params.get("list", "pages")
        rows = query.get(key) if isinstance(query, dict) else None
        if not isinstance(data, dict) or data.get("warnings") or not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
            raise AuditError("תשובת מקור חלקית, פגומה או עם אזהרה")
        if key == "pages":
            seen = set()
            for row in rows:
                pid = row.get("pageid")
                if type(pid) is not int or pid <= 0 or pid in seen or not isinstance(row.get("title"), str) or "missing" in row:
                    raise AuditError("תשובת מקור ללא זהות דף תקינה")
                seen.add(pid)
                if params.get("generator") and (type(row.get("ns")) is not int or row["ns"] != 0):
                    raise AuditError("צילום מקור מחוץ למרחב הראשי")
                if params.get("prop") == "categories":
                    cats = row.get("categories", [])
                    if not isinstance(cats, list) or any(not isinstance(c, dict) or not isinstance(c.get("title"), str) for c in cats):
                        raise AuditError("תשובת קטגוריות פגומה")
            if params.get("pageids") and seen != {int(i) for i in params["pageids"].split("|")}:
                raise AuditError("צילום קטגוריות אינו מכסה את הדפים שנשאלו")
        else:
            for row in rows:
                if not isinstance(row.get("title"), str) or not row.get("timestamp"):
                    raise AuditError("אירוע מקור ללא כותרת או זמן")
                iso(row["timestamp"])
        cont = data.get("continue")
        if cont is not None and (not isinstance(cont, dict) or not cont):
            raise AuditError("מצביע המשך מקור פגום")
        if cont and all(params.get(k) == v for k, v in cont.items()):
            raise AuditError("המקור לא קידם את מצביע ההמשך")
        return data

    def paged(self, params, list_key):
        params, seen = dict(params), set()
        while True:
            data = self.get(params)
            yield from data["query"][list_key]
            if "continue" not in data:
                return
            token = json.dumps(data["continue"], sort_keys=True)
            if token in seen:
                raise AuditError("המקור חזר על אותו מצביע המשך")
            seen.add(token)
            params.update(data["continue"])

    def all_pages(self):
        seen_ids, seen_titles = set(), set()
        for page in super().all_pages():
            if page["pageid"] in seen_ids or page["title"] in seen_titles:
                raise AuditError("צילום מקור מכיל זהות כפולה; ייתכן שהמקור השתנה בזמן הסריקה")
            seen_ids.add(page["pageid"])
            seen_titles.add(page["title"])
            if len(seen_ids) % 10000 == 0:
                print(f"צילום מקור: {len(seen_ids):,} דפים", flush=True)
            yield page


def read_rows(conn, query):
    # Server-side cursor: no REST row cap; fetch until genuinely empty.
    with conn.cursor(name="audit_rows") as cursor:
        cursor.execute(query)
        names = [c.name for c in cursor.description]
        while True:
            batch = cursor.fetchmany(1000)
            if not batch:
                return
            yield from (dict(zip(names, row)) for row in batch)


def keyed(rows):
    out = {}
    for row in rows:
        pid = row.get("id")
        if type(pid) is not int or pid <= 0 or pid in out:
            raise AuditError("קריאת מסד עם מזהה חסר או כפול")
        out[pid] = {k: v for k, v in row.items() if k != "id"}
    return out


def validate_state(version, state, captured_at):
    marks = state["watermarks"]
    if set(marks) != set(APIS):
        raise AuditError(f"{version}: חסרות נקודות סנכרון")
    max_age = timedelta(hours=30 if version == "v1" else 15)
    for mark in marks.values():
        age = captured_at - datetime.fromisoformat(iso(mark).replace("Z", "+00:00"))
        if age < timedelta(0) or age > max_age:
            raise AuditError(f"{version}: נקודת סנכרון ישנה או עתידית; יש לסנכרן ולבדוק שוב")
    if version == "v1":
        if state["weekly"].get("phase") != "complete":
            raise AuditError("V1: הסנכרון השבועי טרם הושלם")
        weekly_age = captured_at - datetime.fromisoformat(iso(state["weekly"]["updated_at"]).replace("Z", "+00:00"))
        if weekly_age < timedelta(0) or weekly_age > timedelta(days=8):
            raise AuditError("V1: אין סנכרון שבועי מלא שהושלם בשמונת הימים האחרונים")
    else:
        writes = [r for r in state["runs"] if r["kind"] in ("sync", "rebuild")]
        if not writes:
            raise AuditError("V2: לא נמצאה ריצת סנכרון שהושלמה")
        latest = max(writes, key=lambda r: iso(r["started_at"]))
        if latest["status"] != "succeeded":
            raise AuditError("V2: ריצת הסנכרון או הבנייה האחרונה לא הושלמה בהצלחה")


def configure_connection(conn):
    # Session poolers may reject startup options. Configure before the first
    # data read; keep a read-only session default AND explicit transaction mode.
    conn.execute("SET default_transaction_read_only = on")
    conn.execute("SET statement_timeout = '120s'")
    conn.execute("SET lock_timeout = '5s'")


def read_database(url, version, connect=None):
    if connect is None:
        import psycopg
        connect = psycopg.connect
    # Session pooler/direct URL, not transaction pooler (named cursors).
    with connect(url, autocommit=True, connect_timeout=20, sslmode="require",
                 application_name="v1-v2-reliability-audit") as conn:
        configure_connection(conn)
        with conn.transaction():
            conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            captured_at = conn.execute("SELECT clock_timestamp()").fetchone()[0]
            if version == "v1":
                marks = {r["source"]: r["last_synced_ts"] for r in read_rows(conn,
                    "SELECT source, last_synced_ts FROM public.sync_watermarks")}
                weekly = list(read_rows(conn, "SELECT build_id, phase, updated_at FROM public.weekly_build_state"))
                if len(weekly) != 1:
                    raise AuditError("V1: אין מצב שבועי יחיד")
                state = {"watermarks": marks, "weekly": weekly[0]}
                schema = "public"
                queries = {
                    "wikipedia": "SELECT id, title FROM public.wikipedia_pages",
                    "mechalol": "SELECT id, title, status, source_type, needs_attention, is_dictionary_entry AS is_dictionary FROM public.mechalol_pages",
                }
            else:
                if conn.execute("SELECT count(*) FROM ops.sync_run WHERE status = 'running'").fetchone()[0]:
                    raise AuditError("V2: קיימת ריצה שלא הסתיימה")
                marks = {r["site"]: r["ts"] for r in read_rows(conn,
                    "SELECT site, ts FROM ops.watermark WHERE stream = 'delta'")}
                runs = list(read_rows(conn, """SELECT DISTINCT ON (kind) kind, status, started_at, finished_at
                    FROM ops.sync_run
                    WHERE NOT (kind = 'sync' AND status = 'cancelled' AND error IS NOT DISTINCT FROM 'dry run')
                    ORDER BY kind, started_at DESC, run_id DESC"""))
                state = {"watermarks": marks, "runs": runs}
                schema = "api"
                queries = {
                    "wikipedia": "SELECT page_id AS id, title FROM mirror.wiki_page",
                    "mechalol": "SELECT page_id AS id, title, status, source_type, needs_attention, is_dictionary FROM mirror.mech_page",
                }
            validate_state(version, state, captured_at)
            mirrors = {}
            for site, query in queries.items():
                print(f"{version}/{site}: קריאת המראה", flush=True)
                mirrors[site] = keyed(read_rows(conn, query))
            for site, rows in mirrors.items():
                if not rows or any(not isinstance(r.get("title"), str) or not r["title"] for r in rows.values()):
                    raise AuditError(f"{version}/{site}: מראה ריקה או פגומה")
            for row in mirrors["mechalol"].values():
                if version == "v1":
                    if row["status"] not in STATUS_V1:
                        raise AuditError("V1: סטטוס לא מוכר; יש לעדכן את מיפוי ההשוואה")
                    row["status"] = STATUS_V1[row["status"]]
                if any(type(row[f]) is not bool for f in ("needs_attention", "is_dictionary")):
                    raise AuditError(f"{version}: סיווג חסר או פגום")
            reports = {}
            for name, (view, columns) in REPORTS.items():
                reports[name] = keyed(read_rows(conn, f"SELECT id, {', '.join(columns)} FROM {schema}.{view}"))
            print(f"{version}: צילום מסד הושלם", flush=True)
            return {"captured_at": iso(captured_at), "state": state, "mirrors": mirrors, "reports": reports}


def compare_records(left, right):
    return [{"id": pid, "left": left.get(pid), "right": right.get(pid)}
            for pid in sorted(set(left) | set(right)) if left.get(pid) != right.get(pid)]


def build_report(databases, sources):
    comparisons = []
    for site, source in sources.items():
        for version, db in databases.items():
            rows = db["mirrors"][site]
            diff = compare_titles(source["titles"], {i: r["title"] for i, r in rows.items()})
            fields = {i: {f: r[f] for f in CLASSIFICATION_FIELDS} for i, r in rows.items()} if site == "mechalol" else {}
            changes = compare_classification(source["fields"], fields) if fields else {}
            findings = []
            for kind in ("only_source", "only_db"):
                findings.extend({"id": i, "kind": kind, "title": t} for i, t in diff[kind])
            findings.extend({"id": i, "kind": "title", "old": old, "new": new} for i, old, new in diff["title"])
            for kind, values in changes.items():
                findings.extend({"id": i, "kind": kind, "old": old, "new": new} for i, old, new in values)
            window = source["windows"][version]
            window_ids, window_titles = set(window["ids"]), set(window["titles"])
            for f in findings:
                # Evidence of activity is context, never a waiver or proof of causation.
                f["changed_in_window"] = (f["id"] in window_ids or
                    any(t in window_titles for t in (f.get("title"), source["titles"].get(f["id"]), rows.get(f["id"], {}).get("title"))))
            comparisons.append({"name": f"{version}/{site}/source", "left_count": len(source["titles"]),
                                "right_count": len(rows), "findings": findings})
        comparisons.append({"name": f"v1/v2/{site}",
                            "left_count": len(databases["v1"]["mirrors"][site]),
                            "right_count": len(databases["v2"]["mirrors"][site]),
                            "findings": compare_records(databases["v1"]["mirrors"][site], databases["v2"]["mirrors"][site])})
    for name in REPORTS:
        left, right = databases["v1"]["reports"][name], databases["v2"]["reports"][name]
        comparisons.append({"name": f"reports/{name}", "left_count": len(left), "right_count": len(right),
                            "findings": compare_records(left, right)})
    return {"status": "differences" if any(c["findings"] for c in comparisons) else "clean",
            "comparisons": comparisons,
            "database_state": {v: {k: db[k] for k in ("captured_at", "state")} for v, db in databases.items()},
            "source_times": {s: {k: src[k] for k in ("started_at", "finished_at")} for s, src in sources.items()}}


def json_default(value):
    if isinstance(value, datetime):
        return iso(value)
    return str(value)


def write_report(out, report):
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, default=json_default), encoding="utf-8")
    lines = ["# בדיקת אמינות V1 ו־V2", "", f"**{LABELS[report['status']]}**", "",
             "הבדיקה בקריאה בלבד. שינוי בחלון אינו פוטר פער מבדיקה.", ""]
    for version, db in report.get("database_state", {}).items():
        marks = db["state"]["watermarks"]
        lines.append(f"- {version}: צילום מסד {db['captured_at']}; סנכרון ויקיפדיה {iso(marks['wikipedia'])}; סנכרון המכלול {iso(marks['mechalol'])}.")
        if version == "v1":
            lines.append(f"- V1: סנכרון שבועי הושלם {iso(db['state']['weekly']['updated_at'])}.")
    for site, times in report.get("source_times", {}).items():
        lines.append(f"- {site}: צילום מקור {times['started_at']} עד {times['finished_at']}.")
    lines.extend(["", "כל הזמנים UTC.", "", "| השוואה | צד ראשון | צד שני | פערים |", "|---|---:|---:|---:|"])
    for c in report.get("comparisons", []):
        lines.append(f"| {c['name']} | {c['left_count']:,} | {c['right_count']:,} | {len(c['findings']):,} |")
    if report.get("error"):
        lines.extend(["", "הקריאה או תנאי הקדם נכשלו. אין להסיק התאמה מהחלק שנקרא.", f"שלב: {report.get('stage', '')}",
                      f"סוג כשל: {report['error']}"])
        if report.get("reason"):
            lines.extend(["", report["reason"]])
    lines.extend(["", "כל הפערים ב־findings.csv וב־report.json; הצילומים ב־snapshot.json.gz.",
                  "דוחות משותפים: חסרים (כולל הפניה), ללא תבנית מיון, העברות ומשימות גרסה.",
                  "אין כאן אימות תוכן הערכים, תוצאות סינון, נעילות, או הוכחה עצמאית לנכונות כללי התחזוקה."])
    markdown = "\n".join(lines) + "\n"
    (out / "report.md").write_text(markdown, encoding="utf-8")
    with (out / "findings.csv").open("w", encoding="utf-8-sig", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["comparison", "page_id", "detail_json"])
        for c in report.get("comparisons", []):
            for finding in c["findings"]:
                writer.writerow([c["name"], finding["id"], json.dumps(finding, ensure_ascii=False, default=json_default)])
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(markdown)
    print(markdown, flush=True)


def run(out, env=os.environ, read=read_database, mw_factory=AuditMediaWiki):
    report = {"status": "failed", "started_at": iso(now())}
    databases, sources = {}, {}
    stage = "configuration"
    try:
        # Check both before reading either; never silently omit one database.
        urls = {v: env.get(f"{v.upper()}_DB_URL") for v in ("v1", "v2")}
        missing = [f"{v.upper()}_DB_URL" for v, url in urls.items() if not url]
        if missing:
            raise AuditError("חסרים סודות חיבור בריפו V2: " + ", ".join(missing))
        if urls["v1"] == urls["v2"]:
            raise AuditError("שני חיבורי המסד זהים; יש להגדיר חיבור נפרד לכל פרויקט")
        for version, url in urls.items():
            stage = f"database/{version}"
            databases[version] = read(url, version)
        for site, api in APIS.items():
            stage = f"source/{site}"
            mw = mw_factory(api)
            started = iso(now())
            titles, fields = snapshot(site, mw)
            finished = iso(now())
            windows = {}
            for version, db in databases.items():
                since = iso(db["state"]["watermarks"][site])
                # Existing closed-window collector shared with reconciliation.
                ids, touched_titles, counts = collect_window(mw.get, since, finished)
                windows[version] = {"since": since, "until": finished, "ids": sorted(ids),
                                    "titles": sorted(touched_titles), "counts": counts}
            sources[site] = {"titles": titles, "fields": fields, "started_at": started,
                             "finished_at": finished, "windows": windows}
        stage = "comparison"
        report.update(build_report(databases, sources))
    except Exception as exc:
        # Never print exception messages: connection errors can contain DSNs/passwords.
        report.update(status="failed", stage=stage, error=type(exc).__name__)
        if isinstance(exc, AuditError):
            report["reason"] = str(exc)
    finally:
        report["finished_at"] = iso(now())
        out.mkdir(parents=True, exist_ok=True)
        with gzip.open(out / "snapshot.json.gz", "wt", encoding="utf-8") as fh:
            json.dump({"databases": databases, "sources": sources}, fh, ensure_ascii=False, default=json_default)
        write_report(out, report)
    return {"clean": 0, "differences": 1, "failed": 2}[report["status"]]


def main():
    parser = argparse.ArgumentParser(description="בדיקת אמינות V1 ו־V2 — קריאה בלבד")
    parser.add_argument("--out-dir", default="reliability_out")
    args = parser.parse_args()
    return run(Path(args.out_dir))


if __name__ == "__main__":
    raise SystemExit(main())
