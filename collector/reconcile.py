"""
reconcile: צילום מקור אחד לכל אתר מול המראה, בדוח בלבד (לא כותב למראה). PLAN_STAGE4.md 4.4, וההיגיון של v1 (חלון סגור):
פער "הוסבר בחלון" אם הדף נגעו בו בין נקודת הדלתא השמורה לרגע סיום הצילום; זה לא מוכיח סיבה (reconcile_compare.py).
הצילום נלקח מ-API (allpages; במכלול גם קטגוריות), ולכן קרוב לזמן הריצה. התוצאה נרשמת ב-ops.reconcile_run / reconcile_finding.
"""
import os
import uuid
from datetime import datetime, timezone

from .reconcile_compare import (CLASSIFICATION_FIELDS, collect_window, compare_classification, compare_titles, explain,
                                render_markdown, summarize_site)
from .state import is_live
from .sync import enrich_mech

PAGE = 5000
MAX_FINDINGS_PER_CLASS = 2000


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_db(rpc, site):
    """({id: title}, {id: {field: value}}) מהמראה, בעימוד לפי מזהה."""
    titles, fields, after = {}, {}, 0
    while True:
        rows = rpc.call("reconcile_pages", {"p_site": site, "p_after": after, "p_limit": PAGE}) or []
        for r in rows:
            titles[r["page_id"]] = r["title"]
            fields[r["page_id"]] = {f: r.get(f) for f in CLASSIFICATION_FIELDS}
        if len(rows) < PAGE:
            return titles, fields
        after = rows[-1]["page_id"]


def snapshot(site, mw):
    """({id: title}, {id: {field: value}} | {}) מהמקור. כישלון או תוצאה ריקה מפילים את הריצה (אין דוח על צילום חלקי)."""
    live = [p for p in mw.all_pages() if is_live(p)]
    if not live:
        raise RuntimeError(f"{site}: הצילום ריק")
    titles = {p["pageid"]: p["title"] for p in live}
    fields = {}
    if site == "mechalol":
        rows = [{"page_id": p["pageid"], "title": p["title"]} for p in live]
        enrich_mech(mw, rows)
        fields = {r["page_id"]: {"status": r["status"], "source_type": r["source_type"],
                                 "needs_attention": r["needs_attention"], "is_dictionary": r["is_dictionary"]} for r in rows}
    return titles, fields


def run_reconcile(mws, rpc, log=print, skip_mechalol=False):
    started = rpc.call("sync_run_start", {"p_kind": "reconcile"})
    run_id, marks = started["run_id"], started["watermarks"]
    run_key = str(uuid.uuid4())[:8]
    sites, findings, meta = [], [], {"run": run_key, "watermarks": marks}
    try:
        for site, mw in mws.items():
            if site == "mechalol" and skip_mechalol:
                continue
            since = marks.get(f"{site}/delta")
            if not since:
                raise RuntimeError(f"אין נקודת דלתא ל-{site}: reconcile דורש טעינה ראשונית")
            log(f"{site}: צילום מקור")
            src_titles, src_fields = snapshot(site, mw)
            until = _iso(datetime.now(timezone.utc))
            db_titles, db_fields = read_db(rpc, site)
            diff = compare_titles(src_titles, db_titles)
            changes = compare_classification(src_fields, db_fields) if src_fields else {}
            ids, titles, counts = collect_window(mw.get, since, until)
            window = {"since": since, "until": until, "refs": len(ids) + len(titles), "counts": counts}
            sites.append(summarize_site(site, len(src_titles), len(db_titles), diff, changes, ids, titles,
                                        source_titles=src_titles, window=window))
            meta[site] = {"source": len(src_titles), "db": len(db_titles), "window": window}
            findings += _findings(site, diff, changes, ids, titles)
    except Exception as exc:
        rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "failed", "p_stats": {}, "p_error": str(exc)[:1000]})
        raise
    report = {"run_id": run_key, "snapshot": {k: v for k, v in meta.items() if k == "watermarks"}, "sites": sites}
    rpc.call("reconcile_record", {"p_snapshot_meta": meta, "p_summary": {s["site"]: {"classes": s["classes"], "unexplained_pages": s["unexplained_pages"],
                                                                                    "delete_rate": s["delete_rate"]} for s in sites},
                                  "p_findings": findings})
    rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "succeeded", "p_stats": {s["site"]: s["unexplained_pages"] for s in sites}})
    markdown = render_markdown(report)
    print(markdown)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(markdown)
    return report


def _findings(site, diff, changes, ids, titles):
    out = []

    def add(cls, items, detail_of):
        explained, _ = explain([(i, t) for i, t in items], ids, titles)
        explained_ids = {i for i, _t in explained}
        for page_id, title in items[:MAX_FINDINGS_PER_CLASS]:
            out.append({"site": site, "class": cls, "page_id": page_id, "title": title,
                        "detail": detail_of(page_id), "explained_by_window": page_id in explained_ids})

    add("only_source", diff["only_source"], lambda i: None)
    add("only_db", diff["only_db"], lambda i: None)
    olds = {i: old for i, old, _new in diff["title"]}
    add("title", [(i, new) for i, _old, new in diff["title"]], lambda i: {"old": olds[i]})
    for field, rows in changes.items():
        values = {i: (o, n) for i, o, n in rows}
        add(field, [(i, None) for i, _o, _n in rows], lambda i, v=values: {"old": v[i][0], "new": v[i][1]})
    return out
