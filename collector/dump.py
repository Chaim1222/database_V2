"""
דמפ של ויקיפדיה לטעינה ראשונית: stub-meta-current (XML בלי טקסט), מפוענח בזרימה בזיכרון קבוע.
נקודת ההתחלה של הדלתא היא תחילת יום הדמפ פחות שעה (שם הדמפ הוא תאריך תחילת הייצור), ולכן כל מה שנערך אחריו
יאומת מחדש מול ה-API בדלתא הראשונה. הפענוח הועתק מ-scripts/wiki_dump.py של המערכת הקודמת.
"""
import gzip
import json
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

import requests

BASE = "https://dumps.wikimedia.org/hewiki/"
JOB = "stubmetacurrentdump"
STUB_NAME = "hewiki-{date}-stub-meta-current.xml.gz"
MIN_PAGES = 300_000   # בדיקת שפיות: ל-he.wikipedia כ-406 אלף ערכים; פחות מזה = קובץ חתוך או שגוי


def _local(tag):
    return tag.rsplit("}", 1)[-1]


def iter_stub_pages(fileobj):
    """(page_id, title, rev_id) לכל ערך במרחב הראשי שאינו הפניה, בגרסה הנוכחית שבדמפ."""
    root = None
    for event, elem in ET.iterparse(fileobj, events=("start", "end")):
        if root is None:
            root = elem
        if event != "end" or _local(elem.tag) != "page":
            continue
        ns = page_id = rev_id = title = None
        is_redirect = False
        for child in elem:
            name = _local(child.tag)
            if name == "ns":
                ns = child.text
            elif name == "title":
                title = child.text
            elif name == "id":
                page_id = child.text
            elif name == "redirect":
                is_redirect = True
            elif name == "revision":
                for part in child:
                    if _local(part.tag) == "id":
                        rev_id = part.text
        elem.clear()
        root.clear()
        if ns == "0" and not is_redirect and page_id and rev_id and title:
            yield int(page_id), title, int(rev_id)


def find_latest_dump(fetch):
    """
    fetch(url) -> טקסט. מחזיר (תאריך YYYYMMDD, כתובת הקובץ) של הדמפ האחרון שה-job שלו הסתיים.
    עוברים מהחדש לישן, כי הדמפ האחרון עשוי להיות בייצור.
    """
    dates = sorted(set(re.findall(r'href="(\d{8})/"', fetch(BASE))), reverse=True)
    for date in dates[:5]:
        try:
            status = json.loads(fetch(f"{BASE}{date}/dumpstatus.json"))
        except Exception:
            continue
        if status.get("jobs", {}).get(JOB, {}).get("status") == "done":
            return date, f"{BASE}{date}/{STUB_NAME.format(date=date)}"
    raise RuntimeError("לא נמצא דמפ שהסתיים מבין 5 האחרונים")


def start_of(date):
    """נקודת ההתחלה של הדלתא לדמפ: תחילת יום הדמפ פחות שעה (UTC), כמחרוזת ISO."""
    day = datetime.strptime(date, "%Y%m%d").replace(tzinfo=timezone.utc)
    return (day - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")


class DumpSource:
    """מקור דפים לטעינה ראשונית מדמפ. start ידוע מראש (לפי תאריך הדמפ)."""

    def __init__(self, session=None, user_agent=None, date=None):
        self.session = session or requests.Session()
        if user_agent:
            self.session.headers["User-Agent"] = user_agent
        text = lambda url: self._get(url).text   # noqa: E731
        if date:
            self.date, self.url = date, f"{BASE}{date}/{STUB_NAME.format(date=date)}"
        else:
            self.date, self.url = find_latest_dump(text)
        self.start = start_of(self.date)

    def _get(self, url, **kw):
        response = self.session.get(url, timeout=(15, 120), **kw)
        response.raise_for_status()
        return response

    def pages(self):
        response = self._get(self.url, stream=True)
        count = 0
        with gzip.GzipFile(fileobj=response.raw) as stream:
            for page_id, title, rev_id in iter_stub_pages(stream):
                count += 1
                yield {"pageid": page_id, "title": title, "lastrevid": rev_id, "ns": 0}
        if count < MIN_PAGES:
            raise RuntimeError(f"הדמפ החזיר רק {count} ערכים (מינימום {MIN_PAGES}); נדחה כשגוי או חתוך")
