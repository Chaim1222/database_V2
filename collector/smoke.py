"""בדיקת עשן מול האתרים החיים: ה-API עדיין מחזיר את הצורה שהקוד מצפה לה. קורא בלבד, לא נוגע במסד.
מחזיר רשימת כשלים (ריקה = תקין). python -m collector.cli smoke"""
import datetime as dt

SAMPLE = 500


def _fmt(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def check_site(name, mw):
    failures = []

    def fail(msg):
        failures.append(f"{name}: {msg}")

    pages = []
    for page in mw.all_pages():
        pages.append(page)
        if len(pages) >= SAMPLE:
            break
    if len(pages) < SAMPLE:
        fail(f"allpages החזיר רק {len(pages)} ערכים")
    for key in ("pageid", "title", "lastrevid"):
        if pages and any(key not in p for p in pages):
            fail(f"בערכי allpages חסר שדה {key}")
    if not pages:
        return failures
    ids = [p["pageid"] for p in pages[:20]]
    by_id, _ = mw.info(ids=ids)
    got = {p.get("pageid"): p.get("title") for p in by_id}
    expected = {p["pageid"]: p["title"] for p in pages[:20]}
    if got != expected:
        fail("info לפי מזהה לא תואם ל-allpages")
    cats = mw.categories(ids)
    if set(cats) != set(ids):
        fail("categories לא החזיר את כל המזהים")
    now = dt.datetime.now(dt.timezone.utc)
    try:
        touched_ids, touched_titles, events = mw.touched(_fmt(now - dt.timedelta(hours=3)), _fmt(now - dt.timedelta(minutes=5)))
    except Exception as exc:  # noqa: BLE001 - כל כשל הוא ממצא
        fail(f"touched נכשל: {exc}")
        return failures
    if not touched_ids:
        fail("אין שום שינוי ב-3 השעות האחרונות (חשוד)")
    for event in events:
        for key in ("kind", "page_id", "title", "ts"):
            if key not in event:
                fail(f"באירוע חסר שדה {key}")
                break
    return failures


def run_smoke(mws):
    failures = []
    for name, mw in mws.items():
        failures += check_site(name, mw)
    return failures
