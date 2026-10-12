"""
משימות גרסה (N7): בדיקת ערכי מכלול מתועדים מול `גרסה=` בתבנית. הגרסה היא זהות יציבה של דף בוויקיפדיה גם אחרי שינוי שם:
ה-API אומר לאיזה דף היא שייכת. הכללים והנימוקים הועתקו מ-scripts/rev_match.py של v1 (הכרעות חיים 2026-10-01 ו-05):
  גרסה ריקה/0/1 = גרסה שגויה; גרסה שאינה קיימת: גדולה מהאחרונה = שגויה, אחרת הדף נמחק (deleted_by_rev);
  גרסה ממרחב שם אחר = שגויה; דף שהפך להפניה = redirect, אלא אם יעד ההפניה כבר שם התבנית (טופל);
  דף חי (גם בשם אחר) אינו משימה: טאב "הועברו" מכסה זאת. ראו PLAN_STAGE4.md ו-DESIGN.md סעיף 4.2 (rev_check).
"""
import re

from .normalize import semantic_candidate, title_key
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
    # Only explicit badrevids means missing; incomplete replies stop before writes.
    asked = set(rev_ids)
    if not asked:
        return {}
    data = wiki_mw.get({"action": "query", "revids": "|".join(map(str, rev_ids)), "prop": "revisions|info", "rvprop": "ids"})
    query = data.get("query") if isinstance(data, dict) else None
    if not isinstance(query, dict) or "error" in data or "continue" in data:
        raise RuntimeError("תשובת גרסאות חסרה או לא הושלמה")
    pages, missing = query.get("pages", []), query.get("badrevids", {})
    if isinstance(missing, dict):
        missing = list(missing.values())
    if not isinstance(pages, list) or not isinstance(missing, list):
        raise RuntimeError("מבנה תשובת גרסאות לא תקין")
    result = {}
    for item in missing:
        if (not isinstance(item, dict) or item.get("missing") is not True
                or type(item.get("revid")) is not int or item["revid"] not in asked
                or item["revid"] in result):
            raise RuntimeError("מזהה גרסה חסרה לא תקין או כפול")
        result[item["revid"]] = None
    for page in pages:
        if (not isinstance(page, dict) or type(page.get("pageid")) is not int
                or page["pageid"] <= 0 or type(page.get("ns")) is not int
                or not isinstance(page.get("title"), str) or not page["title"]
                or not isinstance(page.get("revisions"), list) or not page["revisions"]):
            raise RuntimeError("תשובת גרסאות ללא זהות דף תקינה")
        info = {"page_id": page["pageid"], "title": page["title"],
                "ns": page["ns"], "redirect": bool(page.get("redirect"))}
        for revision in page["revisions"]:
            rev = revision.get("revid") if isinstance(revision, dict) else None
            if type(rev) is not int or rev not in asked or rev in result:
                raise RuntimeError("מזהה גרסה לא צפוי או כפול")
            result[rev] = info
    if set(result) != asked:
        raise RuntimeError("תשובת גרסאות חלקית; אין להסיק שהגרסאות החסרות נמחקו")
    return result


def resolve_redirect_targets(wiki_mw, titles):
    """{כותרת הפניה: כותרת היעד | None}. redirects=1 מפענח גם שרשראות."""
    result = {t: None for t in set(titles)}
    for part in chunks(sorted(result), BATCH):
        query = wiki_mw.get({"action": "query", "titles": "|".join(part), "redirects": 1}).get("query", {})
        normalized = {n["from"]: n["to"] for n in query.get("normalized", [])}
        redirects = {r["from"]: r["to"] for r in query.get("redirects", [])}
        for title in part:
            result[title] = redirects.get(normalized.get(title, title))
    return result


def fetch_max_rev(wiki_mw):
    data = wiki_mw.get({"action": "query", "list": "recentchanges", "rclimit": 1, "rcprop": "ids"})
    return max((c["revid"] for c in data.get("query", {}).get("recentchanges") or []), default=0)


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
    # Validate API-sized batches independently; cleanup is scoped to verified rows only.
    # rev_scope has no durable scan cursor: skipped rows are retried by the next full run.
    after, scanned, found = 0, 0, 0
    failed_ids = []
    while True:
        rows = rpc.call("rev_scope", {"p_after": after, "p_limit": 2000}) or []
        if not rows:
            result = {"scanned": scanned, "findings": found}
            if failed_ids:
                result.update(complete=False, failed_ids=failed_ids, retry="python -m collector.cli revcheck")
            return result
        findings, verified = [], []
        for part in chunks(rows, BATCH):
            for attempt in range(2):
                try:
                    batch_findings = check_rows(wiki_mw, part, max_rev)
                    break
                except Exception as exc:
                    if attempt == 1:
                        ids = [r["mech_id"] for r in part]
                        failed_ids.extend(ids)
                        log(f"גרסאות: נשמר המצב הקודם עבור {ids}; {type(exc).__name__}; ניסיון חוזר בריצה הבאה")
            else:
                continue
            findings.extend(batch_findings)
            verified.extend(r["mech_id"] for r in part)
        if verified:
            try:
                rpc.call("sync_apply_rev_checks", {"p_rows": findings, "p_scope_ids": verified})
                scanned, found = scanned + len(verified), found + len(findings)
            except Exception as exc:
                failed_ids.extend(verified)
                log(f"גרסאות: כתיבה לא אושרה עבור {verified}; {type(exc).__name__}; הרצה חוזרת בטוחה")
        after = rows[-1]["mech_id"]
        log(f"גרסאות: נבדקו {scanned:,}, ממצאים {found:,}, לא הושלמו {len(failed_ids):,}")
