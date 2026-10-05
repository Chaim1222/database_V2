"""python -m collector.cli sync | load | templates   (משתני סביבה: SUPABASE_URL, SUPABASE_SERVICE_KEY)"""
import json
import os
import sys

from .mw import USER_AGENT, MediaWiki
from .rpc import Rpc
from .dump import DumpSource
from .initial_load import run_initial_load
from .sync import run_sync
from .templates import run_pending

APIS = {"wikipedia": "https://he.wikipedia.org/w/api.php", "mechalol": "https://www.hamichlol.org.il/w/api.php"}


def main(argv):
    if argv[:1] not in (["sync"], ["load"], ["templates"]):
        print("שימוש: python -m collector.cli sync | load | templates", file=sys.stderr)
        return 2
    rpc = Rpc(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
    mws = {site: MediaWiki(url) for site, url in APIS.items()}
    if argv[0] == "sync":
        stats = run_sync(mws, rpc)
    elif argv[0] == "templates":
        stats = {"checked": run_pending(mws["mechalol"], mws["wikipedia"], rpc)}
    else:
        # ויקיפדיה מדמפ (מהיר ועקבי); המכלול מה-API. --api לטעינת ויקיפדיה גם היא מה-API. DUMP_DATE (YYYYMMDD) מקבע דמפ.
        sources = {} if "--api" in argv else {
            "wikipedia": DumpSource(user_agent=USER_AGENT, date=os.environ.get("DUMP_DATE") or None)}
        if "wikipedia" in sources:
            print(f"דמפ ויקיפדיה: {sources['wikipedia'].date} ({sources['wikipedia'].url})")
        stats = run_initial_load(mws, rpc, sources=sources)
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
