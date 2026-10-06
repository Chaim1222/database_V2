"""
העשרה של דפי ויקיפדיה "חסרים" (PLAN_STAGE4.md 4.2). קבוצות שדות עצמאיות:
  created  - תאריך הגרסה הראשונה (בקשה לכל דף: rvdir=newer לא נתמך לאצווה)
  length   - אורך הדף (info, אצווה)
  desc     - תיאור בעברית מוויקינתונים (אצווה לפי sitelinks של hewiki)
  redirect - האם הכותרת קיימת במכלול כהפניה (info, אצווה, בלי מעקב הפניות)
  locks    - רמת הנעילה במכלול (inprop=allevel): create = נעול ליצירה (החרגה), read = נעול לקריאה (v1: check_missing_locked.py)
כישלון בבדיקה לא נשלח למסד ולכן אינו דורס ערך קודם; הדף נשאר ממתין ויבדק בריצה הבאה.
"""
import time
import requests

from .state import chunks
from .mw import query_field

BATCH = 50
GROUPS = ("redirect", "locks", "length", "desc", "created")
WIKIDATA_API = "https://www.wikidata.org/w/api.php"

SKIP_BUDGET = {"left": 20}   # כמה כותרות בודדות מותר לדלג עליהן (403) בריצת העשרה אחת; יותר מזה = חסימה כללית, והריצה נכשלת


def query_titles(mw, titles, extra, log=print):
    """שאילתת action=query לפי כותרות. HTTP 403 על מנה (חסימת סינון של האתר לכותרת מסוימת) מפוצל לחצאים עד הכותרת הבודדת,
    שמדולגת ונרשמת. מחזיר (pages, normalized, skipped)."""
    try:
        data = mw.get({"action": "query", "titles": "|".join(titles), **extra})
        query = data["query"]
        return query["pages"], query.get("normalized", []), []
    except requests.HTTPError as exc:
        if exc.response is None or exc.response.status_code != 403:
            raise
        if len(titles) == 1:
            SKIP_BUDGET["left"] -= 1
            if SKIP_BUDGET["left"] < 0:
                raise RuntimeError("יותר מדי כותרות נחסמו (403): כנראה חסימה כללית של הכתובת") from exc
            log(f"403 על כותרת בודדת, מדלג: {titles[0]!r}")
            return [], [], list(titles)
        mid = len(titles) // 2
        a = query_titles(mw, titles[:mid], extra, log)
        b = query_titles(mw, titles[mid:], extra, log)
        return a[0] + b[0], a[1] + b[1], a[2] + b[2]


def fetch_length(wiki_mw, pages):
    """pages: [{wiki_id, title}] -> שורות {wiki_id, length}. דף שלא חזר (נמחק בינתיים) לא נשלח."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    data = wiki_mw.get({"action": "query", "prop": "info", "titles": "|".join(by_title)})
    rows = []
    normalized = {n["to"]: n["from"] for n in data.get("query", {}).get("normalized", [])}
    seen = set()
    for page in query_field(data, "pages"):
        wiki_id = by_title.get(normalized.get(page.get("title"), page.get("title")))
        if wiki_id is None:
            raise RuntimeError("תשובת אורך עם כותרת שלא נשאלה")
        seen.add(wiki_id)
        if not page.get("missing") and "length" not in page:
            raise RuntimeError("תשובת אורך ללא אורך הדף")
        if wiki_id and not page.get("missing") and "length" in page:
            rows.append({"wiki_id": wiki_id, "length": page["length"]})
    if seen != set(by_title.values()):
        raise RuntimeError("תשובת אורך חלקית")
    return rows


def fetch_redirect(mech_mw, pages):
    """{wiki_id, mech_redirect}: True אם הכותרת במכלול היא הפניה; False אם חסרה או דף רגיל. תשובה חסרה נכשלת."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    pages_out, normalized, skipped = query_titles(mech_mw, list(by_title), {"prop": "info"})
    original = {n["to"]: n["from"] for n in normalized}
    rows, seen = [], {by_title[t] for t in skipped}
    for page in pages_out:
        title = original.get(page["title"], page["title"])
        wiki_id = by_title.get(title)
        if wiki_id is None:
            continue
        seen.add(wiki_id)
        rows.append({"wiki_id": wiki_id, "mech_redirect": bool(page.get("redirect")) and not page.get("missing")})
    absent = sorted(set(by_title.values()) - seen)
    if absent:
        raise RuntimeError(f"המכלול לא החזיר תשובה עבור {len(absent)} כותרות, למשל {absent[:5]}")
    return rows


def fetch_desc(wikidata_mw, pages):
    """{wiki_id, wikidata_desc}: מחרוזת ריקה אם אין ישות או תיאור (תוצאה לגיטימית: נשמרת כנבדק)."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    data = wikidata_mw.get({"action": "wbgetentities", "sites": "hewiki", "titles": "|".join(by_title),
                            "props": "descriptions|sitelinks", "languages": "he"})
    entities = data.get("entities")
    if not isinstance(entities, dict) or not entities:
        raise RuntimeError("תשובת ויקינתונים חסרה")
    found, missing = {}, 0
    for entity in entities.values():
        if "missing" in entity:
            missing += 1
            continue
        title = ((entity.get("sitelinks") or {}).get("hewiki") or {}).get("title")
        if title:
            found[title] = ((entity.get("descriptions") or {}).get("he") or {}).get("value") or ""
    if len(set(by_title) - set(found)) != missing:
        raise RuntimeError("תשובת ויקינתונים אינה מכסה את כל הכותרות")
    return [{"wiki_id": wiki_id, "wikidata_desc": found.get(title, "")} for title, wiki_id in by_title.items()]


CREATED_PACE = 0.05


def fetch_created(wiki_mw, pages):
    """{wiki_id, created_at}: חותמת הגרסה הראשונה, או None כשאין (נשמר כנבדק). כשל API מפיל את הריצה."""
    rows = []
    for p in pages:
        time.sleep(CREATED_PACE)   # בקשה לכל כותרת (25 אלף ויותר): הקצב מונע 429 מוויקיפדיה
        try:
            data = wiki_mw.get({"action": "query", "prop": "revisions", "titles": p["title"],
                                "rvprop": "timestamp", "rvlimit": 1, "rvdir": "newer"})
        except requests.RequestException as exc:   # כמו ב-v1: כשל זמני בכותרת בודדת מדולג וייבדק בריצה הבאה; הרבה כשלים = בעיה כללית
            SKIP_BUDGET["left"] -= 1
            if SKIP_BUDGET["left"] < 0:
                raise RuntimeError("יותר מדי כותרות נכשלו בשליפת תאריך יצירה: כנראה הגבלה או חסימה כללית") from exc
            print(f"תאריך יצירה: כשל על {p['title']!r} ({exc}), מדלג")
            continue
        returned = query_field(data, "pages")
        if len(returned) != 1:
            raise RuntimeError("תשובת תאריך יצירה חסרה או כפולה")
        page = returned[0]
        if "pageid" in page and not page.get("missing") and page["pageid"] != p["wiki_id"]:
            raise RuntimeError("מזהה הדף השתנה בשליפת תאריך יצירה")
        revisions = page.get("revisions") or []
        if not page.get("missing") and (not revisions or not revisions[0].get("timestamp")):
            raise RuntimeError("תאריך יצירה חסר לדף חי")
        rows.append({"wiki_id": p["wiki_id"], "created_at": revisions[0]["timestamp"] if revisions and not page.get("missing") else None})
    return rows


def fetch_locks(mech_mw, pages):
    """{wiki_id, title, allevel, pageid}. allevel חסר = none. תשובה שאינה מכסה כותרת מפילה את הריצה."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    pages_out, normalized, skipped = query_titles(mech_mw, list(by_title), {"prop": "info", "inprop": "allevel"})
    original = {n["to"]: n["from"] for n in normalized}
    rows, seen = [], {by_title[t] for t in skipped}
    for page in pages_out:
        title = original.get(page.get("title"), page.get("title"))
        wiki_id = by_title.get(title)
        if wiki_id is None:
            continue
        seen.add(wiki_id)
        rows.append({"wiki_id": wiki_id, "title": title, "allevel": page.get("allevel", "none"), "pageid": page.get("pageid")})
    absent = sorted(set(by_title.values()) - seen)
    if absent:
        raise RuntimeError(f"המכלול לא החזיר תשובה עבור {len(absent)} כותרות, למשל {absent[:5]}")
    return rows


FETCHERS = {"locks": ("mech", fetch_locks), "length": ("wiki", fetch_length), "created": ("wiki", fetch_created),
            "desc": ("wikidata", fetch_desc), "redirect": ("mech", fetch_redirect)}


def run_group(group, clients, rpc, limit=None, log=print):
    """clients: {"wiki": MediaWiki, "mech": MediaWiki, "wikidata": MediaWiki}. ממשיך עד שאין ממתינים."""
    kind, fetch = FETCHERS[group]
    client = clients[kind]
    SKIP_BUDGET["left"] = 20
    after, done = 0, 0
    while True:
        pending = rpc.call("enrich_pending", {"p_group": group, "p_after": after, "p_limit": 500}) or []
        if not pending:
            return done
        for part in chunks(pending, BATCH if group != "created" else 100):
            rows = fetch(client, part)
            if rows:
                rpc.call("sync_apply_enrichment", {"p_group": group, "p_rows": rows})
            done += len(rows)
        after = pending[-1]["wiki_id"]
        log(f"העשרה {group}: {done:,}")
        if limit and done >= limit:
            return done
