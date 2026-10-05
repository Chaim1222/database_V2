"""python -m collector.cli sync   (משתני סביבה: SUPABASE_URL, SUPABASE_SERVICE_KEY)"""
import json
import os
import sys

from .mw import MediaWiki
from .rpc import Rpc
from .sync import run_sync

APIS = {"wikipedia": "https://he.wikipedia.org/w/api.php", "mechalol": "https://www.hamichlol.org.il/w/api.php"}


def main(argv):
    if argv[:1] != ["sync"]:
        print("שימוש: python -m collector.cli sync", file=sys.stderr)
        return 2
    rpc = Rpc(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
    stats = run_sync({site: MediaWiki(url) for site, url in APIS.items()}, rpc)
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
