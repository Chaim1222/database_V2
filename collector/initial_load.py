"""
טעינה ראשונית של מראה ריקה (או השלמה אחרי תקלה: אידמפוטנטית). עוברת על כל הערכים החיים של האתר, כותבת במנות
דרך אותן פונקציות api.sync_apply_*, ורק בסוף מוצלח מציבה את נקודת הדלתא על רגע **תחילת** הטעינה (החפיפה של
הדלתא הראשונה תכסה שינויים שנעשו בזמן הטעינה).
לא מוחקת דבר: gone ריק. טעינה על מסד שאינו ריק משאירה שורות מיושנות; לשם כך יש reconcile.
"""
from datetime import datetime, timezone

from .state import is_live
from .sync import APPLY_FN, _iso, enrich_mech

BATCH = 1000


def load_site(site, mw, rpc, log=print):
    total = 0
    batch = []

    def flush():
        nonlocal total, batch
        if not batch:
            return
        live = [{"page_id": p["pageid"], "title": p["title"], "latest_rev_id": p.get("lastrevid")} for p in batch]
        if site == "mechalol":
            enrich_mech(mw, live)
        rpc.call(APPLY_FN[site], {"p_live": live, "p_gone_ids": [], "p_gone_titles": []})
        total += len(live)
        log(f"{site}: {total:,} ערכים נטענו")
        batch = []

    for page in mw.all_pages():
        if is_live(page):
            batch.append(page)
            if len(batch) >= BATCH:
                flush()
    flush()
    return total


def run_initial_load(mws, rpc, now=None, log=print):
    now = now or datetime.now(timezone.utc)
    started = rpc.call("sync_run_start", {"p_kind": "rebuild"})
    run_id, marks, stats = started["run_id"], {}, {}
    try:
        for site, mw in mws.items():
            stats[site] = {"loaded": load_site(site, mw, rpc, log)}
            marks[f"{site}/delta"] = _iso(now)
    except Exception as exc:
        rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "failed", "p_stats": stats, "p_error": str(exc)[:1000]})
        raise
    rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "succeeded", "p_stats": stats, "p_watermarks": marks})
    return stats
