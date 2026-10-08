"""בירור ממצאי בדיקת האמינות מול ויקיפדיה והמכלול. קריאה בלבד: לא נוגע במסד ולא כותב לאתרים.

הרצה מתוך שורש הריפו (הקובץ נשמר בתיקיית collector):
    python -m collector.verify_findings [--out-dir findings_check] [--only שם_בדיקה ...]

מייצר findings_check.json (כל הנתונים) ומדפיס סיכום בעברית. את הקובץ אפשר לצרף לשיחה.
הנתונים הקבועים מתייחסים לדוח מ־8.10.2026. בדיקות התבניות קוראות מצב נוכחי;
בדיקת הזמנים מוגבלת לחלון הדוח. הצלחת הריצה פירושה שהקריאות הצליחו, לא שהמסדים תואמים.
זרימה: בחירת בדיקות → קריאת מקור מאומתת → איסוף ראיות → שמירת ביניים וסיכום.
"""
import argparse
import json
from datetime import datetime, timezone
from time import monotonic
from pathlib import Path

from .mw import MediaWiki
from .state import chunks, IncompleteResponse
from .classify import classify
from .templates import (TEMPLATE_START_RE, _find_template_body, _split_params, clean_title, fetch_contents,
                        parse_rev, resolve_wiki_titles, INVALID_TITLE_CHARS, MAX_TITLE_BYTES)

APIS = {"wikipedia": "https://he.wikipedia.org/w/api.php", "mechalol": "https://www.hamichlol.org.il/w/api.php"}
WATERMARK = "2026-10-08T05:36:27Z"   # נקודת הסנכרון האחרונה בצילום של V2
V2_SNAPSHOT = "2026-10-08T09:10:07Z"
SOURCE_END = {"wikipedia": "2026-10-08T09:19:09Z", "mechalol": "2026-10-08T09:52:45Z"}

# ---- נתוני הממצאים (מתוך המסמך) ----
WIKI_NEW = {2581273: "יעקב פיננסים", 2581276: "הוועד הרוחני (בגדאד)", 2581277: "קארי (סרט, 2002)",
            2581284: "שטיפה נרתיקית", 2581291: "ג'יימס ג'יי. ג'פריס", 2581317: "דרנגר"}
MECH_NEW = {1178642: "יחיד רם יערות חושף", 1178643: "אתר אמס", 1178644: "משלחת המחקר מאלורי ואירווין"}
MOVES = [("תמרה קווסיטזדה", "move", "הועברה ל„תמרה קווסיטדזה” ב־07:47:41"),
         ("טיוטה:שיר אציל", "move", "הועבר מטיוטה למרחב הראשי ב־05:42:47")]
EDITED_MECH = ["דאנה איבגי", "סוכנות ADD"]
NINE = {940591: 840992, 623481: 1873477, 964840: 1996080, 746254: 2099928, 910862: 2198864,
        974662: 2259198, 975715: 2345504, 901532: 2402199, 880816: 2489540}   # מזהה מכלול → מזהה ויקיפדיה צפוי
LINKS23 = [(1474, "לילית"), (12175, "עיקרי האמונה"), (13444, "אבלות"), (25415, "מינות"), (44443, "קרבן"),
           (91861, "בית דין"), (115164, "רבה"), (192345, "דיין"), (234396, "שלום"),
           (290737, "רבי עזרא ורבי עזריאל בני שלמה"), (453310, 'כנסיית ה"עלייה לשמים" בקולומנסקויה'),
           (842226, "קטן"), (844527, "רבי משה יהושע בזשיליאנסקי"), (860550, "רבי יהושע יצחק שפירא"),
           (917380, "רבי אושעיא איש טריא"), (1177782, "רבי ישראל ניסן קופרשטוק"), (1204158, "רבי ישכר בער מנדבורנה"),
           (1315381, "רבי שבתי בחבוט"), (1410781, "רבי יעקב ממוגלניצא"), (1515214, "רבי יעקב קופשטיין"),
           (1571498, "הומופיליה"), (1833302, "שערי יושר"), (2301358, "מידות טובות")]
NORMALIZED_FOUR = [("מדן (דמות מקראית)", "מדן (אישיות מהתנ״ך)"), ("שוח (דמות מקראית)", "שוח (אישיות מהתנ״ך)"),
                   ("בת אהובת אל", "בת אהובת א-ל"), ("שם אל קמתי לברך", "שם א-ל קמתי לברך")]
NINETEEN = [180652, 192168, 218581, 227192, 227207, 240217, 249105, 329437, 329607, 355375, 380017, 380018,
            380217, 380810, 428311, 428696, 445822, 446339, 461523]
KEPT_AFTER_DELETE = 346893
BAD_REV_TITLES = ["דוד המלך", "רבי מאיר", "ל״ג בעומר", "רבי משה שפירא", "רבי מתתיהו שציגל",
                  "רבי שמואל מקאמינקא (השני)", "רבי שלמה זלמן אולמן"]
# (תווית, מזהה מכלול או כותרת, מספר גרסה שנטען במסמך/במסד)
REV_OWNERS = [("מקדש קונקורדיה", 1178550, 44032199), ("ג'ון דה מיין", 253717, 37017112), ("צילה פרידמן", 897213, 31804870),
              ("הרקע לשפל הגדול", 264725, 22192152),
              ("חקר המלריה בארץ ישראל", 1004509, 37202368)]
LINK_MECH_IDS = {1474: 325201, 12175: 114266, 13444: 149285, 25415: 318253, 44443: 14279, 91861: 104926, 115164: 6851, 192345: 9760, 234396: 345570, 290737: 7403, 453310: 366130, 842226: 5740, 844527: 113822, 860550: 8924, 917380: 381137, 1177782: 10763, 1204158: 152941, 1315381: 185176, 1410781: 220652, 1515214: 288359, 1571498: 873117, 1833302: 562464, 2301358: 1056671}
BAD_REV_IDS = [5247, 5359, 17276, 17332, 57442, 220691, 428311]
NORMALIZED_IDS = [(1928920, 723225), (1954681, 818341), (2014713, 548003), (2476308, 672999)]
CONCORDIA_WIKI = {555733: "מקדש קונקורדיה (רומא)", 2580912: "מקדש קונקורדיה"}

CHECKS = {}


def log(message):
    print(message, flush=True)


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("חותמת זמן ללא אזור זמן")
    return parsed.astimezone(timezone.utc)


def in_window(value, site):
    return bool(value) and timestamp(WATERMARK) < timestamp(value) <= timestamp(SOURCE_END[site])


class VerificationMediaWiki(MediaWiki):
    """כשל קריאה ותשובה חלקית אינם ראיה להיעדר דף או תבנית."""
    def get(self, params):
        label = params.get("pageids") or params.get("titles") or params.get("letitle") or params.get("revids") or ""
        log(f"קריאת מקור: {params.get('list', params.get('prop', 'query'))} {str(label)[:100]}")
        data = super().get(params)
        query = data.get("query")
        if params.get("revids") and isinstance(data.get("badrevids"), dict) and query is None:
            query = data["query"] = {"pages": []}
        key = params.get("list", "pages")
        if data.get("warnings") or not isinstance(query, dict) or not isinstance(query.get(key), list):
            raise IncompleteResponse("תשובת מקור חלקית או עם אזהרות")
        if "continue" in data:
            cont = data["continue"]
            if not isinstance(cont, dict) or not cont or all(params.get(k) == v for k, v in cont.items()):
                raise IncompleteResponse("מצביע המשך מקור לא תקין")
        if key == "pages":
            pages = query[key]
            if any(not isinstance(p, dict) for p in pages):
                raise IncompleteResponse("תשובת דפים לא תקינה")
            if params.get("pageids"):
                expected = {int(i) for i in str(params["pageids"]).split("|")}
                actual = [p.get("pageid") for p in pages]
                if set(actual) != expected or len(actual) != len(expected):
                    raise IncompleteResponse("תשובת המקור אינה מכסה את כל המזהים")
            if params.get("titles"):
                forwards = {n["from"]: n["to"] for n in query.get("normalized", [])}
                forwards.update({n["from"]: n["to"] for n in query.get("redirects", [])})
                returned = {p.get("title") for p in pages}
                for title in params["titles"].split("|"):
                    seen = set()
                    while title in forwards:
                        if title in seen:
                            raise IncompleteResponse("לולאה בפתרון כותרת")
                        seen.add(title)
                        title = forwards[title]
                    if title not in returned:
                        raise IncompleteResponse("תשובת המקור השמיטה כותרת")
            if "revisions" in params.get("prop", "").split("|"):
                for page in pages:
                    if page.get("missing") or page.get("invalid"):
                        continue
                    revisions = page.get("revisions")
                    if not isinstance(revisions, list) or not revisions:
                        raise IncompleteResponse("דף קיים הוחזר ללא גרסאות")
                    for revision in revisions:
                        if "content" in params.get("rvprop", "").split("|"):
                            if not isinstance(revision.get("slots", {}).get("main", {}).get("content"), str):
                                raise IncompleteResponse("תוכן הגרסה חסר או מוסתר")
        return data


def categories_for(mw, pid):
    params = {"action": "query", "pageids": pid, "prop": "categories", "cllimit": "max"}
    result, seen = set(), set()
    while True:
        data = mw.get(params)
        page = data["query"]["pages"][0]
        if page.get("missing") or page.get("invalid"):
            raise IncompleteResponse("הדף אינו זמין לקריאת קטגוריות")
        result.update(c["title"] for c in page.get("categories", []))
        if "continue" not in data:
            return sorted(result)
        token = json.dumps(data["continue"], sort_keys=True)
        if token in seen:
            raise IncompleteResponse("מצביע קטגוריות חוזר")
        seen.add(token)
        params.update(data["continue"])


def check(name):
    def register(fn):
        CHECKS[name] = fn
        return fn
    return register


# ---- כלים ----
def ids_by_title(mw, titles):
    """{כותרת: {id, title, ns, redirect} | None}, בלי מעקב הפניות."""
    result = {}
    for part in chunks(sorted(set(titles)), 50):
        q = mw.get({"action": "query", "prop": "info", "titles": "|".join(part)})["query"]
        forward = {n["from"]: n["to"] for n in q.get("normalized", [])}
        pages = {p["title"]: p for p in q.get("pages", [])}
        for title in part:
            page = pages.get(forward.get(title, title))
            if page is None:
                raise IncompleteResponse(f"המקור השמיט את הכותרת {title!r}")
            missing = page.get("missing") or page.get("invalid")
            result[title] = None if missing else {"id": page["pageid"], "title": page["title"], "ns": page["ns"],
                                                  "redirect": bool(page.get("redirect"))}
    return result


def page_by_id(mw, pid):
    page = mw.get({"action": "query", "prop": "info", "pageids": pid})["query"]["pages"][0]
    if page.get("missing"):
        return {"id": pid, "קיים": False}
    info = {"id": pid, "קיים": True, "title": page["title"], "ns": page["ns"], "redirect": bool(page.get("redirect"))}
    if info["redirect"]:
        redirects = mw.get({"action": "query", "titles": page["title"], "redirects": 1})["query"].get("redirects") or []
        info["יעד_הפניה"] = redirects[0]["to"] if redirects else None
    return info


def first_revision(mw, pid):
    page = mw.get({"action": "query", "pageids": pid, "prop": "revisions", "rvprop": "timestamp|ids",
                   "rvdir": "newer", "rvlimit": 1})["query"]["pages"][0]
    revisions = page.get("revisions") or []
    return revisions[0]["timestamp"] if revisions and revisions[0].get("parentid") == 0 else None


def recent_revisions(mw, title, count=5, until=None):
    page = mw.get({"action": "query", "titles": title, "prop": "revisions", "rvprop": "timestamp|ids",
                   "rvlimit": count, **({"rvstart": until} if until else {})})["query"]["pages"][0]
    return [{"ts": r["timestamp"], "rev": r["revid"]} for r in page.get("revisions") or []]


def log_events(mw, log_type, title, since=None, until=None):
    events = mw.paged({"action": "query", "list": "logevents", "letype": log_type, "letitle": title,
                       "leprop": "ids|title|type|timestamp|details", "lelimit": 500,
                       **({"leend": since} if since else {}), **({"lestart": until} if until else {})}, "logevents")
    return [{"ts": e["timestamp"], "title": e.get("title"), "page_id": e.get("logpage"), "action": e.get("action"), "יעד": (e.get("params") or {}).get("target_title")}
            for e in events]


def rev_owners(wiki_mw, revids):
    """{מספר גרסה: {id, title, ns} | None}: הדף שאליו שייכת כל גרסה."""
    result = {rev: None for rev in revids}
    response = wiki_mw.get({"action": "query", "revids": "|".join(map(str, revids)), "prop": "info|revisions",
                     "rvprop": "ids"})
    q = response["query"]
    for page in q.get("pages", []):
        for revision in page.get("revisions") or []:
            result[revision["revid"]] = {"id": page["pageid"], "title": page["title"], "ns": page["ns"],
                                         "redirect": bool(page.get("redirect"))}
    missing = {rev for rev, owner in result.items() if owner is None}
    reported_bad = {int(rev) for rev in response.get("badrevids", {})}
    if missing - reported_bad:
        raise IncompleteResponse("תשובת המקור השמיטה גרסאות שנשאלו")
    return result


def raw_template(text):
    """הפרמטרים הגולמיים של התבנית האחרונה (כולל ערך הגרסה כפי שנכתב, גם כשהוא פסול)."""
    if not text:
        return None
    for start in reversed([m.end() for m in TEMPLATE_START_RE.finditer(text)]):
        body = _find_template_body(text, start)
        if body is None:
            continue
        values = {}
        for param in _split_params(body):
            if "=" in param:
                key, _, value = param.partition("=")
                values.setdefault(key.strip(), value.strip())
        return {"דף": values.get("דף"), "גרסה": values.get("גרסה"), "תאריך": values.get("תאריך"), "מקטע": "{{מיון ויקיפדיה|" + body[:160]}
    return None


def template_info(mech_mw, wiki_mw, mech_ids):
    """לכל מזהה במכלול: מצב הקריאה, הפרמטרים הגולמיים, הגרסה התקינה, והדף בוויקיפדיה שהכותרת שבתבנית נפתרת אליו."""
    mech_ids = list(mech_ids)
    contents = {}
    for part in chunks(mech_ids, 50):
        log(f"קריאת תבניות: {len(contents):,}/{len(mech_ids):,}")
        contents.update(fetch_contents(mech_mw, part))
    info, to_resolve = {}, {}
    for pid in mech_ids:
        item = contents.get(pid)
        if item is None:
            info[pid] = {"מצב": "הערך לא נמצא"}
        elif item == "denied":
            info[pid] = {"מצב": "חסום לקריאה"}
        else:
            raw = raw_template(item["content"])
            row = {"מצב": "נקרא", "גרסת_ערך": item["rev_id"], "תבנית": raw,
                   "גרסה_תקינה": parse_rev(raw["גרסה"]) if raw else None}
            ref = clean_title(raw["דף"]) if raw and raw["דף"] else None
            row["כותרת_בתבנית"] = ref
            if ref and (len(ref.encode("utf-8")) > MAX_TITLE_BYTES or INVALID_TITLE_CHARS & set(ref)):
                row["הערה"] = "הכותרת בתבנית אינה כותרת תקינה"
            elif ref:
                to_resolve[pid] = ref
            info[pid] = row
    resolved = resolve_wiki_titles(wiki_mw, list(to_resolve.values())) if to_resolve else {}
    for pid, ref in to_resolve.items():
        info[pid]["דף_בוויקיפדיה"] = resolved[ref]
    return info


# ---- הבדיקות ----
@check("זמנים")
def check_timing(wiki_mw, mech_mw):
    rows = []
    for pid, title in WIKI_NEW.items():
        ts = first_revision(wiki_mw, pid)
        rows.append({"אתר": "ויקיפדיה", "id": pid, "דף": title, "נוצר": ts,
                     "תוצאה": "יצירה בחלון הדוח" if in_window(ts, "wikipedia") else "אין יצירה מוכחת בחלון הדוח"})
    for pid, title in MECH_NEW.items():
        ts = first_revision(mech_mw, pid)
        rows.append({"אתר": "המכלול", "id": pid, "דף": title, "נוצר": ts,
                     "תוצאה": "יצירה בחלון הדוח" if in_window(ts, "mechalol") else "אין יצירה מוכחת בחלון הדוח"})
    for title, kind, note in MOVES:
        events = log_events(wiki_mw, kind, title, WATERMARK, SOURCE_END["wikipedia"])
        expected_id, expected_target = ((2576577, "תמרה קווסיטדזה") if title == "תמרה קווסיטזדה"
                                        else (2579039, "שיר אציל"))
        rows.append({"אתר": "ויקיפדיה", "דף": title, "טענה": note, "אירועי_העברה": events,
                     "תוצאה": "העברה צפויה בחלון הדוח" if any(in_window(e["ts"], "wikipedia") and e["page_id"] == expected_id
                                                                  and e["יעד"] == expected_target for e in events)
                     else "לא נמצאה ההעברה הצפויה בחלון הדוח"})
    for title in EDITED_MECH:
        revisions = recent_revisions(mech_mw, title, until=SOURCE_END["mechalol"])
        rows.append({"אתר": "המכלול", "דף": title, "עריכות_אחרונות": revisions,
                     "תוצאה": "עריכה בחלון; שינוי הסיווג לא הוכח" if any(in_window(r["ts"], "mechalol") for r in revisions)
                     else "לא נמצאה עריכה בחלון הדוח"})
    after = sum(1 for r in rows if r["תוצאה"].startswith(("יצירה", "העברה", "עריכה")))
    return {"שאלה": "אילו ראיות נמצאו בחלון שבין סנכרון V2 לסיום צילום המקור?", "שורות": rows,
            "מסקנה": f"{after} מתוך {len(rows)} שורות עם ראיה בחלון; עריכה לבדה אינה מוכיחה את סיבת הפער"}


@check("תשעה_חסרים")
def check_nine(wiki_mw, mech_mw):
    info = template_info(mech_mw, wiki_mw, NINE)
    rows = []
    for pid, expected in NINE.items():
        row = {"id_מכלול": pid, "ויקיפדיה_צפוי": expected, **info[pid]}
        if info[pid]["מצב"] != "נקרא":
            row["תוצאה"] = info[pid]["מצב"]
        elif not info[pid]["תבנית"]:
            row["תוצאה"] = "אין תבנית: הטענה על קישור לפי תבנית אינה נתמכת"
        elif info[pid].get("דף_בוויקיפדיה") == expected:
            row["תוצאה"] = "התבנית מפנה לדף הצפוי"
        else:
            row["תוצאה"] = f"התבנית מפנה לדף אחר: {info[pid].get('דף_בוויקיפדיה')}"
        rows.append(row)
    good = sum(1 for r in rows if r["תוצאה"] == "התבנית מפנה לדף הצפוי")
    return {"שאלה": "האם בתשעת הערכים „נוצר במכלול” יש תבנית שמפנה לדף הוויקיפדי הצפוי?", "שורות": rows,
            "מסקנה": f"{good} מתוך {len(rows)} תואמים; קשר בתבנית אינו משנה את סיווג מקור הערך"}


@check("קישורים_23")
def check_links23(wiki_mw, mech_mw):
    by_title = {t: page_by_id(mech_mw, LINK_MECH_IDS[w]) for w, t in LINKS23}
    ids = [p["id"] for p in by_title.values() if p.get("קיים")]
    info = template_info(mech_mw, wiki_mw, ids)
    rows = []
    for wiki_id, title in LINKS23:
        page = by_title[title]
        row = {"ויקיפדיה_צפוי": wiki_id, "ערך_מכלול": title}
        if not page.get("קיים"):
            row["תוצאה"] = "המזהה אינו קיים במכלול"
        else:
            data = info[page["id"]]
            row.update({"id_מכלול": page["id"], "כותרת_נוכחית": page["title"], "הפניה_במכלול": page["redirect"], "כותרת_בתבנית": data.get("כותרת_בתבנית"),
                        "דף_בוויקיפדיה": data.get("דף_בוויקיפדיה")})
            if data["מצב"] != "נקרא" or not data.get("תבנית"):
                row["תוצאה"] = data["מצב"] if data["מצב"] != "נקרא" else "אין תבנית"
            elif data.get("דף_בוויקיפדיה") == wiki_id:
                row["תוצאה"] = "תואם"
            else:
                row["תוצאה"] = "לא תואם"
        rows.append(row)
    good = sum(1 for r in rows if r["תוצאה"] == "תואם")
    return {"שאלה": "האם התבנית הנוכחית בכל אחד מ־23 ערכי המכלול נפתרת למזהה הצפוי בצילום V2?", "שורות": rows,
            "מסקנה": f"{good} מתוך {len(rows)} תואמים"}


@check("נורמול_ארבעה")
def check_normalized(wiki_mw, mech_mw):
    rows = []
    for (w, m), (wiki_id, mech_id) in zip(NORMALIZED_FOUR, NORMALIZED_IDS):
        wp, mp = page_by_id(wiki_mw, wiki_id), page_by_id(mech_mw, mech_id)
        rows.append({"ויקיפדיה": w, "מכלול": m, "דף_ויקיפדיה": wp, "דף_מכלול": mp,
                     "תוצאה": "שני הדפים קיימים" if wp.get("קיים") and mp.get("קיים") else "אחד הדפים לא נמצא",
                     "הערה": "קיום שני דפים לבדו אינו אימות זהות התוכן או פעולת הנרמול במסד"})
    return {"שאלה": "האם ארבעת זוגות הכתיב באמת קיימים בשני האתרים?", "שורות": rows,
            "מסקנה": f"{sum(1 for r in rows if r['תוצאה'] == 'שני הדפים קיימים')} מתוך 4"}


@check("סיווג_19")
def check_classification(wiki_mw, mech_mw):
    info = template_info(mech_mw, wiki_mw, NINETEEN)
    rows = []
    for pid in NINETEEN:
        data = info[pid]
        if data["מצב"] != "נקרא":
            rows.append({"id_מכלול": pid, "מצב": data["מצב"], "תוצאה": "הסיווג לא אומת"})
            continue
        categories = categories_for(mech_mw, pid)
        rows.append({"id_מכלול": pid, "קטגוריות": categories, "סיווג_נוכחי_לפי_הכללים": classify(categories),
                     "תאריך_גולמי": (data.get("תבנית") or {}).get("תאריך"),
                     "גרסה_גולמית": (data.get("תבנית") or {}).get("גרסה"),
                     "גרסה_תקינה": data.get("גרסה_תקינה"), "כותרת_בתבנית": data.get("כותרת_בתבנית"),
                     "דף_בוויקיפדיה": data.get("דף_בוויקיפדיה"), "מצב": data["מצב"]})
    return {"שאלה": "מה הקטגוריות והתבנית של 19 הערכים שסיווגם שונה בין V1 ל־V2 (וגם האם יש בהם גרסה תקינה)?",
            "שורות": rows, "מסקנה": "הסיווג חושב לפי כללי הקטגוריות הקיימים; קישור מאומת אינו מוכיח תיעוד מלא"}


@check("גרסאות_ובעלות")
def check_revision_owners(wiki_mw, mech_mw):
    titles = [ref for _, ref, _ in REV_OWNERS if isinstance(ref, str)]
    by_title = ids_by_title(mech_mw, titles)
    mech_ids = {label: (ref if isinstance(ref, int) else (by_title[ref] or {}).get("id")) for label, ref, _ in REV_OWNERS}
    info = template_info(mech_mw, wiki_mw, [i for i in mech_ids.values() if i])
    owners = rev_owners(wiki_mw, [rev for _, _, rev in REV_OWNERS])
    rows = []
    for label, _ref, rev in REV_OWNERS:
        mech_id = mech_ids[label]
        data = info.get(mech_id, {"מצב": "הערך לא נמצא"}) if mech_id else {"מצב": "הערך לא נמצא"}
        owner = owners.get(rev)
        current = data.get("גרסה_תקינה")
        current_owner = (rev_owners(wiki_mw, [current]).get(current) if current != rev else owner) if current else None
        resolved = data.get("דף_בוויקיפדיה")
        row = {"ערך": label, "id_מכלול": mech_id, "גרסה_במסמך": rev, "גרסה_נוכחית_בתבנית": current,
               "בעלי_הגרסה_במסמך": owner, "בעלי_הגרסה_הנוכחית": current_owner,
               "כותרת_בתבנית": data.get("כותרת_בתבנית"), "דף_לפי_התבנית": resolved}
        if owner:
            row["תיאור_בעלי_הגרסה"] = page_by_id(wiki_mw, owner["id"])
        if current_owner and resolved:
            row["תוצאה"] = ("הגרסה הנוכחית שייכת לדף שהתבנית מפנה אליו" if current_owner["id"] == resolved
                            else "הגרסה הנוכחית שייכת לדף אחר מזה שהתבנית מפנה אליו")
        else:
            row["תוצאה"] = "חסר מידע להכרעה"
        rows.append(row)
    return {"שאלה": "לאיזה דף בוויקיפדיה שייכת כל גרסה, ואיך זה מתיישב עם הכותרת שבתבנית (קונקורדיה, שפל, טיוטות)?",
            "שורות": rows, "מסקנה": "ראו בעלי הגרסה מול דף לפי התבנית בכל שורה"}


@check("קונקורדיה_היסטוריה")
def check_concordia(wiki_mw, mech_mw):
    rows = []
    for pid, title in CONCORDIA_WIKI.items():
        rows.append({"id": pid, "כותרת_צפויה": title, "תיאור": page_by_id(wiki_mw, pid),
                     "נוצר": first_revision(wiki_mw, pid), "העברות_לפי_כותרת": log_events(wiki_mw, "move", title),
                     "הערה": "היומן לפי כותרת עשוי לכלול מזהים אחרים ואינו ההיסטוריה המלאה של המזהה"})
    return {"שאלה": "מה ההיסטוריה של שני הדפים „מקדש קונקורדיה” ו„מקדש קונקורדיה (רומא)”: מי הועבר, מתי, ומי נוצר מחדש?",
            "שורות": rows, "מסקנה": "השוו את מועדי היצירה וההעברה לשני המזהים"}


@check("גרסה_פסולה")
def check_bad_revs(wiki_mw, mech_mw):
    by_title = {t: page_by_id(mech_mw, pid) for t, pid in zip(BAD_REV_TITLES, BAD_REV_IDS)}
    ids = [p["id"] for p in by_title.values() if p.get("קיים")]
    info = template_info(mech_mw, wiki_mw, ids)
    rows = []
    for title in BAD_REV_TITLES:
        page = by_title[title]
        if not page.get("קיים"):
            rows.append({"ערך": title, "תוצאה": "המזהה אינו קיים במכלול"})
            continue
        data = info[page["id"]]
        raw = (data.get("תבנית") or {}).get("גרסה")
        rows.append({"ערך": title, "id_מכלול": page["id"], "גרסה_גולמית": raw, "תאריך_גולמי": (data.get("תבנית") or {}).get("תאריך"),
                     "מצב": data["מצב"], "גרסה_תקינה": data.get("גרסה_תקינה"),
                     "כותרת_בתבנית": data.get("כותרת_בתבנית"), "דף_בוויקיפדיה": data.get("דף_בוויקיפדיה"),
                     "תוצאה": (data["מצב"] if data["מצב"] != "נקרא" else
                               "הערך הגולמי פסול לפי כללי הפענוח של V2" if raw is not None and data.get("גרסה_תקינה") is None
                               else "יש גרסה תקינה" if data.get("גרסה_תקינה") else "אין ערך גרסה")})
    return {"שאלה": "מהו הערך הגולמי של הגרסה בשבעת הערכים (שש משימות „גרסה שגויה” ואולמן), ומה קורה בו?",
            "שורות": rows, "מסקנה": "אלה הערכים הנוכחיים בתבניות; אין כאן הוכחה למצב המסד בזמן הצילום"}


@check("נשמר_למרות_מחיקה")
def check_kept(wiki_mw, mech_mw):
    data = template_info(mech_mw, wiki_mw, [KEPT_AFTER_DELETE])[KEPT_AFTER_DELETE]
    owner = None
    if data.get("גרסה_תקינה"):
        owner = rev_owners(wiki_mw, [data["גרסה_תקינה"]]).get(data["גרסה_תקינה"])
    resolved = data.get("דף_בוויקיפדיה")
    identities = sorted({i for i in [resolved, (owner or {}).get("id")] if i})
    candidates = [page_by_id(wiki_mw, i) for i in identities]
    live = [p for p in candidates if p.get("קיים") and p.get("ns") == 0 and not p.get("redirect")]
    title = data.get("כותרת_בתבנית")
    row = {"id_מכלול": KEPT_AFTER_DELETE, **data, "בעלי_הגרסה": owner, "מועמדי_מקור": candidates,
           "יומן_מחיקות": log_events(wiki_mw, "delete", title) if title else [],
           "זהויות_מקור_סותרות": bool(resolved and owner and resolved != owner["id"]),
           "תוצאה": "נמצא מועמד מקור חי; אין להסיק מהקטגוריה שהוא עדיין מחוק" if live
                     else "אין מקור חי מאומת; מחיקה לא הוכחה"}
    return {"שאלה": "מה מצב מקור הערך לפי התבנית ובעלות הגרסה, ולא לפי הכותרת המקומית?",
            "שורות": [row], "מסקנה": row["תוצאה"]}


def print_report(results):
    for name, result in results.items():
        print(f"\n=== {name} ===")
        if "שגיאה" in result:
            print("הבדיקה נכשלה:", result["שגיאה"])
            continue
        print("שאלה:", result["שאלה"])
        for row in result["שורות"]:
            brief = {k: v for k, v in row.items() if k in ("דף", "ערך", "id", "id_מכלול", "ויקיפדיה_צפוי", "ערך_מכלול", "כותרת", "תוצאה")}
            print("  •", " | ".join(f"{k}: {v}" for k, v in brief.items()))
        print("מסקנה:", result["מסקנה"])


def run(out_dir, only=None):
    out_dir.mkdir(parents=True, exist_ok=True)
    mws = {site: VerificationMediaWiki(url) for site, url in APIS.items()}
    results = {}
    for name, fn in CHECKS.items():
        if only and name not in only:
            continue
        log(f"התחלה: {name}")
        started = monotonic()
        started_at = datetime.now(timezone.utc).isoformat()
        try:
            results[name] = fn(mws["wikipedia"], mws["mechalol"])
        except Exception as exc:   # בדיקה שנכשלה לא עוצרת את האחרות; אין כאן סודות
            results[name] = {"שגיאה": f"{type(exc).__name__}: {str(exc)[:300]}"}
        results[name]["משך_שניות"] = round(monotonic() - started, 2)
        results[name]["התחלה"] = started_at
        results[name]["סיום"] = datetime.now(timezone.utc).isoformat()
        results[name]["חלון_הדוח"] = {"נקודת_סנכרון": WATERMARK, "סיום_צילום_מקור": SOURCE_END,
                                      "צילום_מסד_V2": V2_SNAPSHOT}
        results[name]["בדיקת_מצב"] = "מצב מקור בזמן הריצה; אינו צילום המסד ההיסטורי"
        temporary = out_dir / "findings_check.json.tmp"
        temporary.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(out_dir / "findings_check.json")
        print_report({name: results[name]})
        log(f"סיום: {name} ({results[name]['משך_שניות']} שניות)")
    print(f"\nהקובץ המלא: {out_dir / 'findings_check.json'}")
    return 1 if any("שגיאה" in r for r in results.values()) else 0


def main():
    parser = argparse.ArgumentParser(description="בירור ממצאי האמינות מול האתרים (קריאה בלבד)")
    parser.add_argument("--out-dir", default="findings_check")
    parser.add_argument("--only", nargs="*", choices=sorted(CHECKS), help="להריץ רק בדיקות מסוימות")
    args = parser.parse_args()
    return run(Path(args.out_dir), set(args.only) if args.only else None)


if __name__ == "__main__":
    raise SystemExit(main())
