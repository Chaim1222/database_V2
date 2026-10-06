"""
ההשוואה של `reconcile.py` (דוח בלבד): צילום מקור מול הטבלה הפעילה.

הפונקציות כאן טהורות (בלי רשת, בלי סופרבייס ובלי config) ולכן נבדקות ביחידות; הגישה ל-API מוזרקת.
ראו PLAN_SYNC_REDESIGN.md, שלב 2.

מבנה הממצאים: לכל אתר, לכל סוג שינוי (`only_source`, `only_db`, `title`, `status`, ...), רשימת פריטים.
כל פריט מסומן `explained_by_window` אם הדף (לפי מזהה או כותרת) נגעו בו בחלון **סגור** [since, until]:
`since` = נקודת הדלתא השמורה, `until` = רגע סיום הצילום של אותו אתר. עריכה אחרי `until` אינה יכולה
להסביר פער בצילום, ולכן אינה נספרת. סימון כזה אומר רק שהדף השתנה בחלון, לא שהשינוי גרם לפער:
הדוח מדווח "פערים שלא הוסברו בתזמון" ולא "פספוסי דלתא".
"""

# שדות הסיווג של המכלול שמושווים (בדיוק אלה ש-collector.classify מחזירה); הועתק מ-scripts/reconcile_compare.py של v1, עם קודי הסטטוס של v2
CLASSIFICATION_FIELDS = ("status", "source_type", "needs_attention", "is_dictionary")

# המסד אומר "מיובא ומתועד" והצילום (לפי קטגוריות בלבד) אומר "מיובא ללא תיעוד". match.py אכן מקדם status
# ל"מתועד" אחרי אימות תבנית, אבל גם הסרת תיעוד אמיתית נראית כך. אין כאן ראיה לאף אחד מהם, ולכן זה נשאר
# **פער שמקורו לא אומת** (נספר בסך הפערים, בלי הנחה שהוא קידום).
STATUS_DOCUMENTED = "imported_documented"
STATUS_UNDOCUMENTED = "imported_undocumented"
STATUS_DOC_IN_DB_ONLY = "status_documented_in_db_only"
ORIGIN_UNVERIFIED = frozenset({STATUS_DOC_IN_DB_ONLY})

# סף התחלתי להצעה בלבד (PLAN_SYNC_REDESIGN.md, שלב 4): הדוח מדווח אם היה נחצה, ואינו עוצר דבר
PROVISIONAL_DELETE_RATE = 0.001


def compare_titles(source, db):
    """
    source, db: {page_id: title}. מחזיר dict של רשימות:
      only_source - [(id, title)] קיים במקור ואין בטבלה (היה נוצר)
      only_db     - [(id, title)] קיים בטבלה ואין במקור (היה נמחק)
      title       - [(id, old_title, new_title)] אותו מזהה, כותרת שונה (old = בטבלה, new = במקור)
    """
    only_source = sorted((i, t) for i, t in source.items() if i not in db)
    only_db = sorted((i, t) for i, t in db.items() if i not in source)
    title = sorted((i, db[i], source[i]) for i in source if i in db and db[i] != source[i])
    return {"only_source": only_source, "only_db": only_db, "title": title}


def compare_classification(source, db, fields=CLASSIFICATION_FIELDS):
    """
    source, db: {page_id: {field: value}}. משווה רק מזהים שקיימים בשני הצדדים.
    מחזיר {field: [(id, old, new)]} (old = בטבלה, new = במקור), רק לשדות שיש בהם שינוי.
    status מ"מתועד" (טבלה) ל"ללא תיעוד" (צילום) מדווח תחת STATUS_DOC_IN_DB_ONLY: מקורו לא אומת.
    """
    changes = {}
    for page_id in sorted(set(source) & set(db)):
        for field in fields:
            old, new = db[page_id].get(field), source[page_id].get(field)
            if old != new:
                name = field
                if field == "status" and old == STATUS_DOCUMENTED and new == STATUS_UNDOCUMENTED:
                    name = STATUS_DOC_IN_DB_ONLY
                changes.setdefault(name, []).append((page_id, old, new))
    return changes


def _paged(api_get, params, list_key):
    """מעבר על כל דפי התשובה של list=..., לפי `continue`."""
    params = dict(params)
    while True:
        data = api_get(params)
        from .mw import query_field
        yield from query_field(data, list_key)
        cont = data.get("continue")
        if not cont:
            return
        params.update(cont)


def collect_window(api_get, since, until):
    """
    מזהים וכותרות שנגעו בהם בחלון הסגור [since, until] באתר אחד (api_get(params) -> dict של ה-API):
      עריכות ויצירות במרחב הראשי (recentchanges), והעברות, מחיקות ושחזורים בכל מרחב שם (logevents).
    העברה כוללת את יעד ההעברה (params.target_title) ואת logpage.
    הסוף נאכף פעמיים: rcend/leend בבקשה, וסינון לפי timestamp בתוצאה (תשובה שחורגת לא נספרת).
    מחזיר (ids, titles, counts) כש-counts = {"edit_new": n, "move": n, "delete": n}.
    """
    if since > until:
        raise ValueError(f"חלון הפוך: ההתחלה ({since}) אחרי הסוף ({until}). בשחזור יש להשתמש בנקודות הדלתא שנשמרו בצילום")
    ids, titles, counts = set(), set(), {"edit_new": 0, "move": 0, "delete": 0}

    rc = {
        "action": "query", "list": "recentchanges", "rcnamespace": 0, "rctype": "edit|new",
        "rcdir": "newer", "rcstart": since, "rcend": until, "rcprop": "title|ids|timestamp",
        "rclimit": 500, "formatversion": "2",
    }
    for entry in _paged(api_get, rc, "recentchanges"):
        if entry.get("timestamp", until) > until:
            continue
        counts["edit_new"] += 1
        if entry.get("pageid"):
            ids.add(entry["pageid"])
        if entry.get("title"):
            titles.add(entry["title"])

    for log_type in ("move", "delete"):
        params = {
            "action": "query", "list": "logevents", "letype": log_type, "ledir": "newer",
            "lestart": since, "leend": until, "leprop": "ids|title|type|details|timestamp",
            "lelimit": 500, "formatversion": "2",
        }
        for event in _paged(api_get, params, "logevents"):
            if event.get("timestamp", until) > until:
                continue
            counts[log_type] += 1
            if event.get("logpage"):
                ids.add(event["logpage"])
            if event.get("title"):
                titles.add(event["title"])
            target = (event.get("params") or {}).get("target_title")
            if target:
                titles.add(target)
    return ids, titles, counts


def explain(items, window_ids, window_titles):
    """
    items: [(id, title_or_none)]. מחזיר (explained, unexplained): דף "מוסבר" אם המזהה או הכותרת
    נגעו בו בחלון.
    """
    explained, unexplained = [], []
    for page_id, title in items:
        if page_id in window_ids or (title is not None and title in window_titles):
            explained.append((page_id, title))
        else:
            unexplained.append((page_id, title))
    return explained, unexplained


def _title_findings(diff):
    """מוציא מכל סוג שינוי כותרת רשימת (id, כותרת) לצורך הסבר בחלון."""
    return {
        "only_source": [(i, t) for i, t in diff["only_source"]],
        "only_db": [(i, t) for i, t in diff["only_db"]],
        "title": [(i, new) for i, _old, new in diff["title"]],
    }


def summarize_site(site, source_count, db_count, title_diff, class_changes, window_ids, window_titles,
                   source_titles=None, window=None, examples_per_class=20):
    """
    דוח של אתר אחד. מחזיר dict:
      counts: מספר שורות במקור ובטבלה
      window: {"since", "until", ...} כפי שהועבר (לתיעוד)
      classes: {class: {"n", "explained_by_window", "unexplained", "origin_unverified", "examples", ...}}
      unexplained_findings: הפרשי שדות שלא הוסברו בחלון (ערך עם שני שדות שונים נספר פעמיים)
      unexplained_pages: מספר ערכים **ייחודיים** שיש בהם לפחות הפרש אחד שלא הוסבר (המדד להחלטות)
      (שניהם כוללים מחלקות שמקורן לא אומת)
      delete_rate: only_db / שורות בטבלה, ו-would_exceed_provisional_gate (מידע בלבד)
    source_titles: {id: title} של המקור, להסבר שינויי סיווג גם לפי כותרת.
    """
    source_titles = source_titles or {}
    classes = {}
    unexplained_ids = set()

    def add(name, findings, examples):
        explained, unexplained = explain(findings, window_ids, window_titles)
        unexplained_ids.update(page_id for page_id, _title in unexplained)
        classes[name] = {
            "n": len(findings),
            "explained_by_window": len(explained),
            "unexplained": len(unexplained),
            "origin_unverified": name in ORIGIN_UNVERIFIED,
            "examples": examples[:examples_per_class],
            "unexplained_examples": [{"id": i, "title": t} for i, t in unexplained[:examples_per_class]],
        }

    for name, findings in _title_findings(title_diff).items():
        add(name, findings, [{"id": i, "title": t} for i, t in findings])

    # שינוי כותרת: הדוגמאות כוללות את הכותרת הישנה
    classes["title"]["examples"] = [
        {"id": i, "old": old, "new": new} for i, old, new in title_diff["title"][:examples_per_class]
    ]

    for field, changes in sorted(class_changes.items()):
        findings = [(i, source_titles.get(i)) for i, _o, _n in changes]
        add(field, findings, [{"id": i, "old": o, "new": n} for i, o, n in changes])

    n_delete = len(title_diff["only_db"])
    rate = n_delete / db_count if db_count else 0.0
    return {
        "site": site,
        "counts": {"source": source_count, "db": db_count},
        "window": window or {},
        "classes": classes,
        "unexplained_findings": sum(c["unexplained"] for c in classes.values()),
        "unexplained_pages": len(unexplained_ids),
        "delete_rate": {
            "n": n_delete,
            "rate": rate,
            "would_exceed_provisional_gate": rate > PROVISIONAL_DELETE_RATE,
        },
    }


def render_markdown(report):
    """דוח קריא לסיכום הריצה. report = {"run_id", "snapshot": {...}, "sites": [summarize_site(...)]}."""
    lines = [f"# דוח reconcile | ריצה {report['run_id']}", ""]
    for key, value in sorted(report.get("snapshot", {}).items()):
        lines.append(f"- {key}: {value}")
    lines.append("")
    for site in report["sites"]:
        c = site["counts"]
        w = site.get("window") or {}
        lines.append(f"## {site['site']} | מקור {c['source']:,} | טבלה {c['db']:,}")
        if w:
            lines.append(f"חלון: {w.get('since')} עד {w.get('until')} "
                         f"({w.get('refs', 0)} דפים נגעו בהם; {w.get('counts', {})})")
        lines.append("")
        lines.append("| סוג | סה\"כ | הוסבר בחלון | לא הוסבר בתזמון | הערה |")
        lines.append("|---|---|---|---|---|")
        for name, info in sorted(site["classes"].items()):
            note = "מקור לא אומת" if info.get("origin_unverified") else ""
            lines.append(f"| {name} | {info['n']} | {info['explained_by_window']} | {info['unexplained']} | {note} |")
        d = site["delete_rate"]
        lines.append("")
        lines.append(
            f"ערכים ייחודיים עם פער שלא הוסבר בתזמון: {site.get('unexplained_pages', 0)} "
            f"(הפרשי שדות: {site.get('unexplained_findings', 0)}; ערך עם כמה שדות שונים נספר בהם כמה פעמים)"
        )
        lines.append(
            f"שיעור מחיקות: {d['n']} מתוך {c['db']:,} ({d['rate']:.4%}); "
            f"{'חורג' if d['would_exceed_provisional_gate'] else 'לא חורג'} מהסף ההתחלתי "
            f"({PROVISIONAL_DELETE_RATE:.1%}, מידע בלבד)"
        )
        lines.append("")
    lines.append(
        "הערה: \"הוסבר בחלון\" פירושו שהדף נגעו בו בין נקודת הדלתא השמורה לרגע סיום הצילום; "
        "זה לא מוכיח שהעריכה גרמה לפער. \"לא הוסבר בתזמון\" אינו פספוס מוכח. "
        "מחלקות עם \"מקור לא אומת\" אינן מסווגות כקידום של match.py או כהסרת תיעוד."
    )
    return "\n".join(lines) + "\n"
