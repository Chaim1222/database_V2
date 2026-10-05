"""
סנכרון דלתא של אתר אחד: איסוף מה נגעו בו בחלון סגור, שאילת המצב הנוכחי, והחלה אטומית דרך RPC.
נקודת ההתקדמות מתקדמת רק בסיום מוצלח של כל הריצה (api.sync_run_finish).
"""
from datetime import datetime, timedelta, timezone

from .classify import classify
from .normalize import mech_key_row
from .state import chunks, resolve

OVERLAP = timedelta(minutes=10)
APPLY_CHUNK = 2000
APPLY_FN = {"wikipedia": "sync_apply_wiki_pages", "mechalol": "sync_apply_mech_pages"}


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def enrich_mech(mw, live):
    """מוסיף לדפי המכלול סיווג (לפי קטגוריות הדף) ומפתח סמנטי (רק כשהכותרת השתנתה בכללים)."""
    if not live:
        return
    cats = mw.categories([d["page_id"] for d in live])
    for d in live:
        c = classify(cats.get(d["page_id"], set()))
        d.update(status=c["status"], source_type=c["source_type"],
                 needs_attention=c["needs_attention"], is_dictionary=c["is_dictionary"])
        row = mech_key_row(d["page_id"], d["title"])
        if row:
            d.update(wiki_candidate_key=row["wiki_candidate_key"], rules=row["rules"])


def sync_site(site, mw, rpc, run_id, since, until):
    """מחזיר סטטיסטיקה. since/until: מחרוזות ISO (UTC)."""
    ids, titles, events = mw.touched(since, until)
    by_id, by_title = mw.info(ids, titles)
    live, gone_ids, gone_titles = resolve(by_id, by_title, ids, titles)
    if site == "mechalol":
        enrich_mech(mw, live)
    totals = {"touched_ids": len(ids), "touched_titles": len(titles), "live": len(live),
              "gone_ids": len(gone_ids), "gone_titles": len(gone_titles)}
    parts = list(chunks(live, APPLY_CHUNK)) or [[]]
    for n, part in enumerate(parts):
        result = rpc.call(APPLY_FN[site], {"p_live": part,
                                           "p_gone_ids": gone_ids if n == 0 else [],
                                           "p_gone_titles": gone_titles if n == 0 else []})
        for key, value in (result or {}).items():
            totals[key] = totals.get(key, 0) + value
    if events:
        rpc.call("sync_record_events", {"p_events": [{"site": site, **e} for e in events], "p_run": run_id})
    totals["events"] = len(events)
    return totals


def run_sync(mws, rpc, now=None, overlap=OVERLAP):
    """mws: {"wikipedia": MediaWiki, "mechalol": MediaWiki}. נכשל בלי נקודת התחלה (נדרשת טעינה ראשונית)."""
    now = now or datetime.now(timezone.utc)
    started = rpc.call("sync_run_start", {"p_kind": "sync"})
    run_id, marks = started["run_id"], started["watermarks"]
    until = _iso(now)
    stats, new_marks = {}, {}
    try:
        for site, mw in mws.items():
            key = f"{site}/delta"
            if key not in marks:
                raise RuntimeError(f"אין נקודת התחלה ל-{key}: נדרשת טעינה ראשונית")
            since = _iso(datetime.fromisoformat(marks[key].replace("Z", "+00:00")) - overlap)
            stats[site] = sync_site(site, mw, rpc, run_id, since, until)
            new_marks[key] = until
    except Exception as exc:
        rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "failed", "p_stats": stats, "p_error": str(exc)[:1000]})
        raise
    rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "succeeded", "p_stats": stats, "p_watermarks": new_marks})
    return stats
