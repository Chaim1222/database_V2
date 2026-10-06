"""
משימות גרסה (N7): בדיקת ערכי מכלול מתועדים מול `גרסה=` בתבנית. הגרסה היא זהות יציבה של דף בוויקיפדיה גם אחרי שינוי שם:
ה-API אומר לאיזה דף היא שייכת. הכללים והנימוקים הועתקו מ-scripts/rev_match.py של v1 (הכרעות חיים 2026-10-01 ו-05):
  גרסה ריקה/0/1 = גרסה שגויה; גרסה שאינה קיימת: גדולה מהאחרונה = שגויה, אחרת הדף נמחק (deleted_by_rev);
  גרסה ממרחב שם אחר = שגויה; דף שהפך להפניה = redirect, אלא אם יעד ההפניה כבר שם התבנית (טופל);
  דף חי (גם בשם אחר) אינו משימה: טאב "הועברו" מכסה זאת. ראו PLAN_STAGE4.md ו-DESIGN.md סעיף 4.2 (rev_check).
"""
import re

from .normalize import semantic_candidate, title_key
from .mw import query_field
from .state import chunks

TASK_REDIRECT, TASK_BAD_REV, TASK_DELETED = "redirect", "bad_rev", "deleted_by_rev"
BATCH = 50
_RAV_PREFIX = re.compile(r"^(הרב|רבי)\s+")
_RAV_SUFFIX = re.compile(r"\s*\(רב\)$")


def _strip_rav(title):
    return _RAV_SUFFIX.sub("", _RAV_PREFIX.sub("", title)).strip()


def names_match(mech_title, wiki_title):
    """כותרות תואמות אחרי נרמול, הכלל הסמנטי והסרת "הרב/רבי" או "(רב)" (מוסכמת המכלול)."""
    if not mech_title or not wiki_title:
        return False
    wiki = title_key(wiki_title)
    wiki_bare = _strip_rav(wiki)
    for candidate in {title_key(mech_title), semantic_candidate(mech_title)[0]}:
        if candidate == wiki or _strip_rav(candidate) == wiki_bare:
            return True
    return False


def resolve_revisions(wiki_mw, rev_ids):
    """{rev_id: {page_id, title, ns, redirect} | None (לא קיימת)} לבקשה אחת (עד 50)."""
    result = {}
    data = wiki_mw.get({"action": "query", "revids": "|".join(map(str, rev_ids)), "prop": "revisions|info", "rvprop": "ids"})
    query = data.get("query")
    if not isinstance(query, dict):
        raise RuntimeError("תשובת גרסאות חסרה")
    bad = query.get("badrevids", {})
    if not isinstance(bad, dict):
        raise RuntimeError("תשובת badrevids לא תקינה")
    for key in bad:
        rev = int(key)
        if rev not in rev_ids:
            raise RuntimeError("מזהה גרסה שלא נשאל")
        result[rev] = None
    for page in query.get("pages", []):
        if not all(k in page for k in ("pageid", "title", "ns")) or page.get("missing"):
            raise RuntimeError("דף גרסה לא תקין")
        info = {"page_id": page["pageid"], "title": page["title"], "ns": page["ns"], "redirect": bool(page.get("redirect"))}
        for revision in page.get("revisions") or []:
            if revision["revid"] not in rev_ids or revision["revid"] in result:
                raise RuntimeError("מזהה גרסה לא צפוי או כפול")
            result[revision["revid"]] = info
    if set(result) != set(rev_ids):
        raise RuntimeError(f"תשובת גרסאות חלקית: {sorted(set(rev_ids) - set(result))[:5]}")
    return result


def resolve_redirect_targets(wiki_mw, titles):
    """{כותרת הפניה: כותרת היעד | None}. redirects=1 מפענח גם שרשראות."""
    result = {t: None for t in set(titles)}
    for part in chunks(sorted(result), BATCH):
        data = wiki_mw.get({"action": "query", "titles": "|".join(part), "redirects": 1})
        pages = {p["title"]: p for p in query_field(data, "pages")}
        query = data["query"]
        normalized = {n["from"]: n["to"] for n in query.get("normalized", [])}
        redirects = {r["from"]: r["to"] for r in query.get("redirects", [])}
        for title in part:
            start = current = normalized.get(title, title)
            seen = set()
            while current in redirects:
                if current in seen:
                    raise RuntimeError("לולאת הפניות בתשובת API")
                seen.add(current)
                current = redirects[current]
            if current not in pages:
                raise RuntimeError(f"תשובת הפניה חסרה עבור {title!r}")
            result[title] = current if current != start and not pages[current].get("missing") else None
    return result


def fetch_max_rev(wiki_mw):
    data = wiki_mw.get({"action": "query", "list": "recentchanges", "rctype": "edit|new", "rclimit": 1, "rcprop": "ids"})
    rows = query_field(data, "recentchanges")
    maximum = max((c["revid"] for c in rows), default=0)
    if maximum <= 1:
        raise RuntimeError("לא התקבל מספר גרסה אחרונה תקין")
    return maximum


def decide(row, resolved, max_rev, redirect_target):
    """(rev_task | None, page_id, title). row: {template_rev, template_title}. redirect_target: רק כשהדף הוא הפניה."""
    rev = row.get("template_rev")
    if not rev or rev <= 1:
        return TASK_BAD_REV, None, None
    if resolved is None:
        return (TASK_BAD_REV if max_rev and rev > max_rev else TASK_DELETED), None, None
    if resolved["ns"] != 0:
        return TASK_BAD_REV, resolved["page_id"], resolved["title"]
    if resolved["redirect"]:
        if redirect_target and row.get("template_title") and names_match(row["template_title"], redirect_target):
            return None, None, None
        return TASK_REDIRECT, resolved["page_id"], resolved["title"]
    return None, None, None


def check_rows(wiki_mw, rows, max_rev):
    """rows: שורות api.rev_scope. מחזיר רשימת ממצאים לכתיבה (רק משימות)."""
    valid = sorted({r["template_rev"] for r in rows if r.get("template_rev") and r["template_rev"] > 1})
    resolved = {}
    for part in chunks(valid, BATCH):
        resolved.update(resolve_revisions(wiki_mw, part))
    redirects = [resolved[r["template_rev"]]["title"] for r in rows
                 if r.get("template_rev") in resolved and resolved[r["template_rev"]] and resolved[r["template_rev"]]["redirect"]]
    targets = resolve_redirect_targets(wiki_mw, redirects) if redirects else {}
    findings = []
    for row in rows:
        res = resolved.get(row.get("template_rev"))
        target = targets.get(res["title"]) if res and res["redirect"] else None
        task, page_id, title = decide(row, res, max_rev, target)
        if task:
            findings.append({"mech_id": row["mech_id"], "rev_task": task, "rev_id": row.get("template_rev") or None,
                             "linked_wiki_id": row.get("linked_wiki_id"), "rev_page_id": page_id, "rev_page_title": title})
    return findings


def run_revcheck(wiki_mw, rpc, log=print):
    """סריקה מלאה במנות לפי מזהה: כל מנה נכתבת ונבדקת בנפרד (אידמפוטנטי); שורה שתוקנה נמחקת."""
    max_rev = fetch_max_rev(wiki_mw)
    after, scanned, found = 0, 0, 0
    while True:
        rows = rpc.call("rev_scope", {"p_after": after, "p_limit": 2000}) or []
        if not rows:
            return {"scanned": scanned, "findings": found}
        findings = check_rows(wiki_mw, rows, max_rev)
        rpc.call("sync_apply_rev_checks", {"p_rows": findings, "p_scope_ids": [r["mech_id"] for r in rows]})
        scanned, found, after = scanned + len(rows), found + len(findings), rows[-1]["mech_id"]
        log(f"גרסאות: נבדקו {scanned:,}, ממצאים {found:,}")
