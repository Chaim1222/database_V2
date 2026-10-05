"""
אימות תבניות: {{מיון ויקיפדיה|דף=X}} בערך מכלול. רק כותרת שונה מכותרת הערך נבדקת מול ויקיפדיה (קישור לאותה כותרת
מכוסה בהתאמה הרגילה). הפענוח הועתק מ-scripts/sort_template.py של המערכת הקודמת (רק `דף=`; גרסה ותאריך מחוץ להיקף).
ראו PLAN_STAGE4.md סעיף 4.1.
"""
import re

from .normalize import title_key
from .state import chunks, is_live

TEMPLATE_START_RE = re.compile(r"\{\{\s*מיון\s+ויקיפדיה\s*\|")
DENIED_CODES = {"readapidenied", "permissiondenied", "accessdenied"}
FETCH_BATCH = 50
MAX_TITLE_BYTES = 255            # מגבלת כותרת ב-MediaWiki
INVALID_TITLE_CHARS = set('[]{}|<>#')
SEND_BATCH = 500


def _find_template_body(text, start):
    depth, i, n = 1, start, len(text)
    while i < n - 1:
        pair = text[i:i + 2]
        if pair == "{{":
            depth += 1
            i += 2
        elif pair == "}}":
            depth -= 1
            if depth == 0:
                return text[start:i]
            i += 2
        else:
            i += 1
    return None


def _split_params(body):
    params, current, curly, square, i, n = [], [], 0, 0, 0, len(body)
    while i < n:
        pair = body[i:i + 2]
        if pair == "{{":
            curly += 1
            current.append(pair)
            i += 2
        elif pair == "}}":
            curly -= 1
            current.append(pair)
            i += 2
        elif pair == "[[":
            square += 1
            current.append(pair)
            i += 2
        elif pair == "]]":
            square -= 1
            current.append(pair)
            i += 2
        elif body[i] == "|" and curly == 0 and square == 0:
            params.append("".join(current))
            current = []
            i += 1
        else:
            current.append(body[i])
            i += 1
    params.append("".join(current))
    return params


def clean_title(raw):
    value = re.sub(r"^\[\[(.+)\]\]$", r"\1", raw.strip()).strip().replace("_", " ")
    return re.sub(r"\s+", " ", value).strip() or None


def parse_rev(raw):
    """מספר גרסה תקין (גדול מ-1; 1 היא גרסת העמוד הראשי), או None (ריק, 0, 1, לא מספרי)."""
    value = (raw or "").strip()
    if not re.fullmatch(r"\d+", value):
        return None
    number = int(value)
    return number if number > 1 else None


def parse_template(text):
    """{"title", "rev"} לתבנית האחרונה בטקסט, או None כשאין תבנית (או שאינה נסגרת)."""
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
                values.setdefault(key.strip(), value)
        return {"title": clean_title(values["דף"]) if "דף" in values else None, "rev": parse_rev(values.get("גרסה"))}
    return None


def referenced_title(text):
    """הכותרת שב-`דף=` בתבנית האחרונה בטקסט, או None (אין תבנית, לא נסגרת, או אין דף=)."""
    parsed = parse_template(text)
    return parsed["title"] if parsed else None


def fetch_contents(mw, page_ids):
    """{page_id: {rev_id, content} | "denied" | None (לא קיים)}. אצווה שנדחתה מפוצלת עד לבידוד הדף הנעול."""
    result = {pid: None for pid in page_ids}
    try:
        data = mw.get({"action": "query", "pageids": "|".join(map(str, page_ids)), "prop": "revisions",
                       "rvprop": "ids|content", "rvslots": "main"})
    except RuntimeError as exc:
        if not any(code in str(exc) for code in DENIED_CODES):
            raise
        if len(page_ids) == 1:
            result[page_ids[0]] = "denied"
            return result
        mid = len(page_ids) // 2
        result.update(fetch_contents(mw, page_ids[:mid]))
        result.update(fetch_contents(mw, page_ids[mid:]))
        return result
    for page in data["query"]["pages"]:
        revisions = page.get("revisions") or []
        if page.get("missing") or not revisions:
            continue
        rev = revisions[0]
        result[page["pageid"]] = {"rev_id": rev["revid"], "content": rev.get("slots", {}).get("main", {}).get("content", "")}
    return result


def resolve_wiki_titles(wiki_mw, titles):
    """{כותרת שנשאלה: page_id של דף חי (אחרי מעקב הפניות) | None}. תשובה שאינה מכסה כותרת נכשלת."""
    result, asked = {}, sorted(set(titles))
    for part in chunks(asked, FETCH_BATCH):
        data = wiki_mw.get({"action": "query", "prop": "info", "titles": "|".join(part), "redirects": 1})
        query = data["query"]
        forward = {}
        for item in query.get("normalized", []):
            forward[item["from"]] = item["to"]
        redirects = {item["from"]: item["to"] for item in query.get("redirects", [])}
        pages = {p["title"]: p for p in query.get("pages", [])}
        for title in part:
            current = forward.get(title, title)
            for _ in range(3):
                current = redirects.get(current, current)
            if current not in pages:
                raise RuntimeError(f"המקור לא החזיר תשובה עבור הכותרת {title!r}")
            page = pages[current]
            result[title] = page["pageid"] if is_live(page) else None
    return result


def check_pages(mech_mw, wiki_mw, titles_by_id, page_ids):
    """
    titles_by_id: {mech_id: כותרת הערך}. מחזיר שורות ל-api.sync_apply_template_checks.
    """
    rows, pending = [], {}
    contents = {}
    for part in chunks(sorted(page_ids), FETCH_BATCH):
        contents.update(fetch_contents(mech_mw, part))
    for mech_id in sorted(page_ids):
        item = contents.get(mech_id)
        if item is None:
            continue  # הערך נעלם בין ההחלה לבדיקה: הסנכרון הבא יטפל
        if item == "denied":
            rows.append({"mech_id": mech_id, "outcome": "denied"})
            continue
        parsed = parse_template(item["content"]) or {"title": None, "rev": None}
        ref = parsed["title"]
        # template_rev: 0 = אין גרסה תקינה (לבדיקת הגרסאות: גרסה שגויה); template_title: `דף=` כפי שנקרא
        row = {"mech_id": mech_id, "rev_id": item["rev_id"], "template_rev": parsed["rev"] or 0, "template_title": ref}
        if not ref:
            rows.append({**row, "outcome": "none"})
        elif title_key(ref) == title_key(titles_by_id[mech_id]):
            rows.append({**row, "outcome": "same"})
        elif len(ref.encode("utf-8")) > MAX_TITLE_BYTES or INVALID_TITLE_CHARS & set(ref):
            # לא כותרת (למשל טקסט שנשבר לתוך `דף=`): לא נשאל את ה-API, ונרשם כבעיית שם
            rows.append({**row, "outcome": "unresolved", "wiki_id": None, "template_ref": ref[:200]})
        else:
            pending[mech_id] = (row, ref)
    if pending:
        resolved = resolve_wiki_titles(wiki_mw, [ref for _row, ref in pending.values()])
        for mech_id, (row, ref) in pending.items():
            wiki_id = resolved[ref]
            rows.append({**row, "outcome": "ok" if wiki_id else "unresolved", "wiki_id": wiki_id, "template_ref": ref})
    return rows


def check_and_apply(mech_mw, wiki_mw, rpc, titles_by_id, page_ids):
    totals = {"checked": 0, "gap_changed": 0}
    rows = check_pages(mech_mw, wiki_mw, titles_by_id, page_ids)
    for part in chunks(rows, SEND_BATCH):
        result = rpc.call("sync_apply_template_checks", {"p_rows": part}) or {}
        for key in totals:
            totals[key] += result.get(key, 0)
    return totals


def run_pending(mech_mw, wiki_mw, rpc, limit=None, log=print):
    """המסלול הראשוני: עוברים על כל הערכים שטרם נבדקו (מזהה עולה). כשל מפיל את הריצה; ההמשך מהמקום שנפסק."""
    after, done = 0, 0
    while True:
        rows = rpc.call("template_pending", {"p_after": after, "p_limit": 1000}) or []
        if not rows:
            return done
        ids = [r["page_id"] for r in rows]
        check_and_apply(mech_mw, wiki_mw, rpc, {r["page_id"]: r["title"] for r in rows}, ids)
        done += len(ids)
        after = ids[-1]
        log(f"תבניות: {done:,} ערכים נבדקו")
        if limit and done >= limit:
            return done
