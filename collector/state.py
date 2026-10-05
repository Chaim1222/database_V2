"""
מצב נוכחי מתוך תשובות prop=info (פונקציות טהורות). דף "חי" = ערך במרחב הראשי, לא הפניה, לא חסר.
כל השאר שנשאל עליו נחשב נעלם. מזהה חי גובר על כל טענה לפי כותרת (זה מה שמונע את תקלת Morphine).
"""


def is_live(page):
    return page.get("ns") == 0 and not page.get("redirect") and not page.get("missing") and bool(page.get("pageid"))


def resolve(pages_by_id, pages_by_title, asked_ids, asked_titles):
    """
    pages_by_id / pages_by_title: רשימות עמודים מתשובות info (לפי מזהים / לפי כותרות).
    מחזיר (live, gone_ids, gone_titles); live = [{page_id, title, latest_rev_id}] ללא כפילויות.
    """
    live = {}
    for page in list(pages_by_id) + list(pages_by_title):
        if is_live(page):
            live[page["pageid"]] = {"page_id": page["pageid"], "title": page["title"],
                                    "latest_rev_id": page.get("lastrevid")}
    gone_ids = sorted(i for i in set(asked_ids) if i not in live)
    returned_titles = {p["title"]: p for p in pages_by_title if p.get("title")}
    gone_titles = sorted(
        t for t, p in returned_titles.items() if p.get("ns") == 0 and not is_live(p)
    )
    # כותרת שנשאלה ולא חזרה בכלל (למשל כותרת לא חוקית) אינה מחזיקה שורה
    titles = [d["title"] for d in live.values()]
    if len(titles) != len(set(titles)):
        raise RuntimeError("שני דפים חיים באותה כותרת בתשובה אחת; ההרצה נכשלת ותופעל מחדש")
    return sorted(live.values(), key=lambda d: d["page_id"]), gone_ids, gone_titles


def chunks(items, size):
    items = list(items)
    for start in range(0, len(items), size):
        yield items[start:start + size]
