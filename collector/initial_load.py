"""
טעינה ראשונית של מראה ריקה (או השלמה אחרי תקלה: אידמפוטנטית). עוברת על כל הערכים החיים של האתר, כותבת במנות
דרך אותן פונקציות api.sync_apply_*, ורק בסוף מוצלח מציבה את נקודת הדלתא על רגע **תחילת** הטעינה (החפיפה של
הדלתא הראשונה תכסה שינויים שנעשו בזמן הטעינה).
לא מוחקת דבר: gone ריק. טעינה על מסד שאינו ריק משאירה שורות מיושנות; לשם כך יש reconcile.
"""
from .state import is_live
from .sync import APPLY_FN, enrich_mech

BATCH = 1000


class ApiSource:
    """מקור דפים מ-list=allpages. אין נקודת התחלה מראש: המסד קובע אותה (now) בתחילת הטעינה."""
    start = None

    def __init__(self, mw):
        self.mw = mw

    def pages(self):
        return self.mw.all_pages()


def load_site(site, mw, rpc, log=print, source=None):
    source = source or ApiSource(mw)
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

    for page in source.pages():
        if is_live(page):
            batch.append(page)
            if len(batch) >= BATCH:
                flush()
    flush()
    if total == 0:
        raise RuntimeError(f"{site}: הטעינה לא החזירה אף דף; לא מקדמים נקודת דלתא על תשובה ריקה")
    return total


def run_initial_load(mws, rpc, log=print, sources=None):
    """sources: {site: מקור עם start ו-pages()}; אתר בלעדיו נטען מ-API."""
    sources = sources or {}
    started = rpc.call("sync_run_start", {"p_kind": "rebuild"})
    run_id, marks, stats = started["run_id"], {}, {}
    try:
        for site, mw in mws.items():
            source = sources.get(site) or ApiSource(mw)
            start = rpc.call("sync_load_begin", {"p_site": site, "p_start": source.start})
            stats[site] = {"loaded": load_site(site, mw, rpc, log, source), "source": type(source).__name__}
            marks[f"{site}/delta"] = start
    except Exception as exc:
        rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "failed", "p_stats": stats, "p_error": str(exc)[:1000]})
        raise
    rpc.call("sync_run_finish", {"p_run": run_id, "p_status": "succeeded", "p_stats": stats, "p_watermarks": marks})
    return stats
