"""python -m collector.cli sync [--dry-run] | load | rebuild | templates | health | enrich [group...] | reconcile [--skip-mechalol] [--fix] | maintenance | revcheck | smoke   (משתני סביבה: SUPABASE_URL, SUPABASE_SERVICE_KEY)"""
import json
import os
import sys

from .mw import USER_AGENT, MediaWiki
from .rpc import Rpc
from .dump import DumpSource
from .enrich import GROUPS, WIKIDATA_API, run_group
from .initial_load import run_initial_load
from .reconcile import run_reconcile
from .revcheck import run_revcheck
from .smoke import run_smoke
from .sync import run_sync
from .templates import run_pending

APIS = {"wikipedia": "https://he.wikipedia.org/w/api.php", "mechalol": "https://www.hamichlol.org.il/w/api.php"}


def main(argv):
    if argv[:1] not in (["sync"], ["load"], ["rebuild"], ["templates"], ["health"]) and argv[:1] not in (["enrich"], ["reconcile"], ["maintenance"], ["revcheck"], ["smoke"]):
        print("שימוש: python -m collector.cli sync [--dry-run] | load | rebuild | templates | health | enrich [group...] | reconcile [--skip-mechalol] [--fix] | maintenance | revcheck | smoke", file=sys.stderr)
        return 2
    if argv[0] == "smoke":   # קורא בלבד מהאתרים, בלי מסד
        failures = run_smoke({site: MediaWiki(url) for site, url in APIS.items()})
        print(json.dumps(failures, ensure_ascii=False, indent=2))
        return 1 if failures else 0
    rpc = Rpc(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
    if argv[0] == "maintenance":
        after, changed = 0, 0
        while True:   # רענון מלא של "חסר" במנות (רשת ביטחון להחלה המצטברת)
            result = rpc.call("maintenance_refresh_gap", {"p_after": after, "p_limit": 2000})
            if result["last_id"] is None:
                break
            after, changed = result["last_id"], changed + result["changed"]
        rpc.call("maintenance_refresh_counts", {})
        print(json.dumps({"gap_changed": changed, "prune": rpc.call("maintenance_prune", {})}, ensure_ascii=False))
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
        clients = {"wiki": mws["wikipedia"], "mech": mws["mechalol"], "wikidata": MediaWiki(WIKIDATA_API)}
        groups = argv[1:] or list(GROUPS)
        stats = {g: run_group(g, clients, rpc) for g in groups}
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
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
