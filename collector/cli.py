"""python -m collector.cli sync [--dry-run] | load | rebuild | templates | health | enrich [group...] | reconcile [--skip-mechalol] [--fix] | maintenance | revcheck   (משתני סביבה: SUPABASE_URL, SUPABASE_SERVICE_KEY)"""
import json
import os
import sys

from .mw import USER_AGENT, MediaWiki
from .rpc import Rpc
from .dump import DumpSource
from .enrich import GROUPS, run_group
from .initial_load import run_initial_load
from .reconcile import run_reconcile
from .revcheck import run_revcheck
from .sync import run_sync
from .templates import run_pending

APIS = {"wikipedia": "https://he.wikipedia.org/w/api.php", "mechalol": "https://www.hamichlol.org.il/w/api.php"}


def main(argv):
    if argv[:1] not in (["sync"], ["load"], ["rebuild"], ["templates"], ["health"]) and argv[:1] not in (["enrich"], ["reconcile"], ["maintenance"], ["revcheck"]):
        print("שימוש: python -m collector.cli sync [--dry-run] | load | rebuild | templates | health | enrich [group...] | reconcile [--skip-mechalol] [--fix] | maintenance | revcheck", file=sys.stderr)
        return 2
    rpc = Rpc(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
    if argv[0] == "maintenance":
        after, changed = 0, 0
        # רענון מלא של "חסר" במנות (רשת ביטחון להחלה המצטברת). 500 ולא 2,000: החסרים מרוכזים בדפים החדשים (העשירון
        # האחרון לפי מזהה - 19,683 מ-28,000), ומנה של 2,000 שם לקחה 2-4 שניות ועברה את ה-8 של authenticator בעומס (17.10).
        while True:
            result = rpc.call("maintenance_refresh_gap", {"p_after": after, "p_limit": 500})
            if result["last_id"] is None:
                break
            after, changed = result["last_id"], changed + result["changed"]
        prune = rpc.call("maintenance_prune", {})
        # אחרון: המחיקה ב-prune מסמנת את סיכום "חסר" (0043) כלא עדכני, והרענון בונה אותו מחדש. בסדר ההפוך הדשבורד
        # נשאר על החישוב החי (שגיאות 500 על Nano) עד הריצה הבאה.
        rpc.call("maintenance_refresh_counts", {})
        print(json.dumps({"gap_changed": changed, "prune": prune}, ensure_ascii=False))
        return 0
    if argv[0] == "health":
        problems = rpc.call("health_check", {})
        print(json.dumps(problems, ensure_ascii=False, indent=2))
        return 1 if problems else 0
    mws = {site: MediaWiki(url) for site, url in APIS.items()}
    if argv[0] == "sync":
        stats = run_sync(mws, rpc, dry_run="--dry-run" in argv)
    elif argv[0] == "revcheck":
        stats = run_revcheck(mws["wikipedia"], rpc)
    elif argv[0] == "reconcile":
        report = run_reconcile(mws, rpc, skip_mechalol="--skip-mechalol" in argv, fix="--fix" in argv)
        print(json.dumps({"unexplained": {s["site"]: s["unexplained_pages"] for s in report["sites"]}}, ensure_ascii=False, indent=2))
        return 0 if report["ok"] else 1
    elif argv[0] == "enrich":
        clients = {"wiki": mws["wikipedia"], "mech": mws["mechalol"]}
        groups = argv[1:] or list(GROUPS)
        unknown = set(groups) - set(GROUPS)
        if unknown:
            raise ValueError(f"Unknown enrichment groups: {sorted(unknown)}")
        stats = {}
        for group in groups:
            try:
                stats[group] = run_group(group, clients, rpc)
            except Exception as exc:
                stats[group] = {"complete": False, "error_type": type(exc).__name__}
            if stats[group].get("complete") is False:
                stats[group]["retry"] = f"python -m collector.cli enrich {group}"
        # All independent groups finish before reporting partial completion.
    elif argv[0] == "templates":
        stats = {"checked": run_pending(mws["mechalol"], mws["wikipedia"], rpc)}
    else:   # load | rebuild
        # ויקיפדיה מדמפ (מהיר ועקבי); המכלול מה-API. --api לטעינת ויקיפדיה גם היא מה-API. DUMP_DATE (YYYYMMDD) מקבע דמפ.
        # rebuild חייב צילום עדכני (API): דמפ ישן היה מסמן דפים חדשים כמיושנים וגורם למחיקתם
        sources = {} if ("--api" in argv or argv[0] == "rebuild") else {
            "wikipedia": DumpSource(user_agent=USER_AGENT, date=os.environ.get("DUMP_DATE") or None)}
        if "wikipedia" in sources:
            print(f"דמפ ויקיפדיה: {sources['wikipedia'].date} ({sources['wikipedia'].url})")
        stats = run_initial_load(mws, rpc, sources=sources, prune=argv[0] == "rebuild")
    if argv[0] in ("enrich", "templates", "revcheck"):   # sync, load ו-rebuild מרעננים ב-sync_run_finish
        # המספרים השמורים (סיכום "חסר" מ-0043, משימות גרסה) - גם אחרי ריצה חלקית; בלי רענון הם נשארים עד הסנכרון הבא
        rpc.call("maintenance_refresh_counts", {})
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return int(stats.get("complete") is False or any(
        isinstance(value, dict) and value.get("complete") is False for value in stats.values()))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

