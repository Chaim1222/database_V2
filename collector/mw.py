"""לקוח MediaWiki קטן: בקשות עם ניסיונות חוזרים, איסוף שינויים בחלון סגור, מצב נוכחי וקטגוריות."""
import time

import requests

from .state import chunks

USER_AGENT = "MechalolWikipediaCompareBot/2.0 (https://www.hamichlol.org.il/; bot@hamichlol.org.il)"
BATCH = 50
POST_THRESHOLD = 600   # תווים לפני קידוד; מעליו POST


class MediaWiki:
    def __init__(self, api_url, session=None, sleep=time.sleep):
        self.api_url = api_url
        self.session = session or requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT  # לא setdefault: ל-requests כבר יש ברירת מחדל שוויקימדיה חוסמת
        self.sleep = sleep

    def get(self, params):
        params = {"format": "json", "formatversion": "2", "maxlag": 5, **params}
        attempts = 8
        for attempt in range(attempts):
            wait = 2 ** min(attempt, 6)
            try:
                # כותרות בעברית מקודדות פי כמה: בקשה ארוכה (למשל 50 כותרות) חורגת ממגבלת ה-URL (414). action=query נתמך גם ב-POST.
                if sum(len(str(v)) for v in params.values()) > POST_THRESHOLD:
                    response = self.session.post(self.api_url, data=params, timeout=60)
                else:
                    response = self.session.get(self.api_url, params=params, timeout=60)
                if response.status_code in (429, 503):
                    # הגבלת קצב: מכבדים Retry-After (עד 2 דקות), אחרת המתנה מעריכית; ההעשרה שולחת עשרות אלפי בקשות
                    try:
                        wait = min(max(wait, int(response.headers.get("Retry-After", 0))), 120)
                    except (TypeError, ValueError):
                        pass
                    raise requests.RequestException(f"HTTP {response.status_code}")
                response.raise_for_status()
                data = response.json()
                if data.get("error", {}).get("code") == "maxlag":
                    raise requests.RequestException("maxlag")
                if "error" in data:
                    raise RuntimeError(f"שגיאת API: {data['error']}")
                return data
            except (requests.RequestException, ValueError):
                if attempt == attempts - 1:
                    raise
                self.sleep(wait)

    def paged(self, params, list_key):
        params = dict(params)
        while True:
            data = self.get(params)
            yield from data.get("query", {}).get(list_key, [])
            if "continue" not in data:
                return
            params.update(data["continue"])

    def touched(self, since, until):
        """
        מה נגעו בו בחלון הסגור [since, until]: (ids, titles, events).
        עריכות ויצירות במרחב הראשי; העברות ומחיקות ושחזורים בכל מרחב שם (כולל יעד ההעברה).
        """
        if since > until:
            raise ValueError(f"חלון הפוך: {since} אחרי {until}")
        ids, titles, events = set(), set(), []
        rc = {"action": "query", "list": "recentchanges", "rcnamespace": 0, "rctype": "edit|new",
              "rcdir": "newer", "rcstart": since, "rcend": until, "rcprop": "title|ids|timestamp|loginfo",
              "rclimit": 500}
        for e in self.paged(rc, "recentchanges"):
            if e.get("timestamp", until) > until:
                continue
            if e.get("pageid"):
                ids.add(e["pageid"])
            titles.add(e["title"])
            if e.get("type") == "new":
                events.append({"kind": "create", "page_id": e.get("pageid") or 0, "title": e["title"], "new_title": None, "ts": e["timestamp"]})
        for log_type in ("move", "delete"):
            le = {"action": "query", "list": "logevents", "letype": log_type, "ledir": "newer",
                  "lestart": since, "leend": until, "leprop": "ids|title|type|details|timestamp", "lelimit": 500}
            for e in self.paged(le, "logevents"):
                ts = e.get("timestamp", until)
                if ts > until or e.get("action") == "delete_redir":
                    continue
                if e.get("logpage"):
                    ids.add(e["logpage"])
                titles.add(e["title"])
                kind = {"delete": "restore" if e.get("action") == "restore" else "delete"}.get(log_type, "move")
                new_title = (e.get("params") or {}).get("target_title")
                if new_title:
                    titles.add(new_title)
                events.append({"kind": kind, "page_id": e.get("logpage") or 0, "title": e["title"],
                               "new_title": new_title, "ts": ts})
        return ids, titles, events

    def info(self, ids=(), titles=()):
        by_id, by_title = [], []
        for part in chunks(sorted(ids), BATCH):
            data = self.get({"action": "query", "prop": "info", "pageids": "|".join(map(str, part))})
            by_id.extend(data["query"]["pages"])
        for part in chunks(sorted(titles), BATCH):
            data = self.get({"action": "query", "prop": "info", "titles": "|".join(part)})
            by_title.extend(data["query"]["pages"])
        return by_id, by_title

    def categories(self, ids):
        """{page_id: set(קטגוריות)} (קטגוריות של הדף עצמו, לא כולל תבניות)."""
        result = {i: set() for i in ids}
        for part in chunks(sorted(ids), BATCH):
            params = {"action": "query", "prop": "categories", "cllimit": "max",
                      "pageids": "|".join(map(str, part))}
            while True:
                data = self.get(params)
                for page in data["query"]["pages"]:
                    result.setdefault(page.get("pageid"), set()).update(c["title"] for c in page.get("categories", []))
                if "continue" not in data:
                    break
                params.update(data["continue"])
        return result

    def all_pages(self):
        """כל הערכים החיים במרחב הראשי (בלי הפניות): {pageid, title, lastrevid, ns}, לפי סדר הכותרות."""
        params = {"action": "query", "generator": "allpages", "gapnamespace": 0, "gapfilterredir": "nonredirects",
                  "gaplimit": 500, "prop": "info"}
        yield from self.paged(params, "pages")
