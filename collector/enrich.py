"""
העשרה של דפי ויקיפדיה "חסרים" (PLAN_STAGE4.md 4.2). קבוצות שדות עצמאיות:
  created  - תאריך הגרסה הראשונה (בקשה לכל דף: rvdir=newer לא נתמך לאצווה)
  length   - אורך הדף (info, אצווה)
  desc     - תיאור בעברית מוויקינתונים (אצווה לפי sitelinks של hewiki)
  redirect - האם הכותרת קיימת במכלול כהפניה (info, אצווה, בלי מעקב הפניות)
  locks    - רמת הנעילה במכלול (inprop=allevel): create = נעול ליצירה (החרגה), read = נעול לקריאה (v1: check_missing_locked.py)
כישלון בבדיקה לא נשלח למסד ולכן אינו דורס ערך קודם; הדף נשאר ממתין ויבדק בריצה הבאה.
"""
from .state import chunks

BATCH = 50
GROUPS = ("redirect", "locks", "length", "desc", "created")
WIKIDATA_API = "https://www.wikidata.org/w/api.php"


def fetch_length(wiki_mw, pages):
    """pages: [{wiki_id, title}] -> שורות {wiki_id, length}. דף שלא חזר (נמחק בינתיים) לא נשלח."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    data = wiki_mw.get({"action": "query", "prop": "info", "titles": "|".join(by_title)})
    rows = []
    for page in data["query"]["pages"]:
        wiki_id = by_title.get(page.get("title"))
        if wiki_id and not page.get("missing") and "length" in page:
            rows.append({"wiki_id": wiki_id, "length": page["length"]})
    return rows


def fetch_redirect(mech_mw, pages):
    """{wiki_id, mech_redirect}: True אם הכותרת במכלול היא הפניה; False אם חסרה או דף רגיל. תשובה חסרה נכשלת."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    data = mech_mw.get({"action": "query", "prop": "info", "titles": "|".join(by_title)})
    query = data["query"]
    original = {n["to"]: n["from"] for n in query.get("normalized", [])}
    rows, seen = [], set()
    for page in query["pages"]:
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
    found = {}
    for entity in (data.get("entities") or {}).values():
        title = ((entity.get("sitelinks") or {}).get("hewiki") or {}).get("title")
        if title:
            found[title] = ((entity.get("descriptions") or {}).get("he") or {}).get("value") or ""
    return [{"wiki_id": wiki_id, "wikidata_desc": found.get(title, "")} for title, wiki_id in by_title.items()]


def fetch_created(wiki_mw, pages):
    """{wiki_id, created_at}: חותמת הגרסה הראשונה, או None כשאין (נשמר כנבדק). כשל API מפיל את הריצה."""
    rows = []
    for p in pages:
        data = wiki_mw.get({"action": "query", "prop": "revisions", "titles": p["title"],
                            "rvprop": "timestamp", "rvlimit": 1, "rvdir": "newer"})
        page = (data["query"]["pages"] or [{}])[0]
        revisions = page.get("revisions") or []
        rows.append({"wiki_id": p["wiki_id"], "created_at": revisions[0]["timestamp"] if revisions and not page.get("missing") else None})
    return rows


def fetch_locks(mech_mw, pages):
    """{wiki_id, title, allevel, pageid}. allevel חסר = none. תשובה שאינה מכסה כותרת מפילה את הריצה."""
    by_title = {p["title"]: p["wiki_id"] for p in pages}
    data = mech_mw.get({"action": "query", "prop": "info", "inprop": "allevel", "titles": "|".join(by_title)})
    query = data["query"]
    original = {n["to"]: n["from"] for n in query.get("normalized", [])}
    rows, seen = [], set()
    for page in query["pages"]:
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
