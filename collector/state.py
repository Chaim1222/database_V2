"""
מצב נוכחי מתוך תשובות prop=info (פונקציות טהורות). דף "חי" = ערך במרחב הראשי, לא הפניה, לא חסר.
כל השאר שנשאל עליו נחשב נעלם. מזהה חי גובר על כל טענה לפי כותרת (זה מה שמונע את תקלת Morphine).
"""
from .normalize import title_key


class IncompleteResponse(RuntimeError):
    """תשובת המקור אינה מכסה את כל מה שנשאל: אין להסיק מכך מחיקה."""


def _key(title):
    return title_key(title.replace("_", " "))


def is_live(page):
    return page.get("ns") == 0 and not page.get("redirect") and not page.get("missing") and bool(page.get("pageid"))


def resolve(pages_by_id, pages_by_title, asked_ids, asked_titles):
    """
    pages_by_id / pages_by_title: רשימות עמודים מתשובות info (לפי מזהים / לפי כותרות).
    מחזיר (live, gone_ids, gone_titles); live = [{page_id, title, latest_rev_id}] ללא כפילויות.
    """
    asked_ids, asked_titles = set(asked_ids), set(asked_titles)
    returned_ids = {p["pageid"] for p in pages_by_id if p.get("pageid")}
    absent = sorted(asked_ids - returned_ids)
    if absent:
        raise IncompleteResponse(f"המקור לא החזיר תשובה (חי או חסר) עבור {len(absent)} מזהים, למשל {absent[:5]}")
    returned_keys = {_key(p["title"]) for p in pages_by_title if p.get("title")}
    absent_titles = sorted(t for t in asked_titles if _key(t) not in returned_keys)
    if absent_titles:
        raise IncompleteResponse(f"המקור לא החזיר תשובה עבור {len(absent_titles)} כותרות, למשל {absent_titles[:5]}")
    live = {}
    for page in list(pages_by_id) + list(pages_by_title):
        if is_live(page):
            live[page["pageid"]] = {"page_id": page["pageid"], "title": page["title"],
                                    "latest_rev_id": page.get("lastrevid")}
    gone_ids = sorted(i for i in asked_ids if i not in live)
    returned_titles = {p["title"]: p for p in pages_by_title if p.get("title")}
    gone_titles = sorted(
        t for t, p in returned_titles.items() if p.get("ns") == 0 and not is_live(p)
    )
    titles = [d["title"] for d in live.values()]
    if len(titles) != len(set(titles)):
        raise RuntimeError("שני דפים חיים באותה כותרת בתשובה אחת; ההרצה נכשלת ותופעל מחדש")
    return sorted(live.values(), key=lambda d: d["page_id"]), gone_ids, gone_titles


def chunks(items, size):
    items = list(items)
    for start in range(0, len(items), size):
        yield items[start:start + size]
