import os
import unittest

from collector.classify import CAT_CREATED, CAT_DICTIONARY, CAT_PAGES_TO_OPEN, classify, parse_update_month
from collector.normalize import mech_key_row, semantic_candidate, title_key
from collector.state import IncompleteResponse, chunks, resolve
from collector.sync import run_sync

BS = chr(92)


def page(pid, title, ns=0, **kw):
    return {"pageid": pid, "title": title, "ns": ns, "lastrevid": pid * 10, **kw}


class NormalizeTests(unittest.TestCase):
    def test_hygiene(self):
        self.assertEqual(title_key("\u200fאבג\u00a0 ״ד״ – ה"), 'אבג "ד" - ה')
        self.assertIsNone(title_key(None))
        self.assertEqual(title_key("  א   ב  "), "א ב")

    def test_semantic(self):
        self.assertEqual(semantic_candidate("קרבן")[0], "קורבן")
        self.assertIsNone(mech_key_row(1, "ירושלים"))
        row = mech_key_row(2, "קרבן פסח")
        self.assertEqual(row["wiki_candidate_key"], "קורבן פסח")

    def test_golden_vs_old_system(self):
        # הפלט נשמר מהקוד של המערכת הקודמת (scripts/normalize.py) ב-tests/golden_normalize.json (JSON עם escape)
        import json
        path = os.path.join(os.path.dirname(__file__), "golden_normalize.json")
        with open(path, encoding="utf-8") as fh:
            cases = json.load(fh)
        self.assertGreaterEqual(len(cases), 20)
        for c in cases:
            self.assertEqual(title_key(c["title"]), c["hygiene"], c["title"])
            candidate, rules = semantic_candidate(c["title"])
            self.assertEqual(candidate, c["normalized"], c["title"])
            self.assertEqual(rules, [r for r in c["rules"]], c["title"])


class ClassifyTests(unittest.TestCase):
    def test_priority_and_flags(self):
        c = classify({CAT_CREATED, CAT_DICTIONARY, CAT_PAGES_TO_OPEN})
        self.assertEqual((c["status"], c["source_type"]), ("created_in_mech", "created"))
        self.assertTrue(c["is_dictionary"] and c["needs_attention"])
        self.assertEqual(classify(set())["status"], "imported_undocumented")

    def test_documented_by_update_month(self):
        self.assertEqual(parse_update_month("קטגוריה:המכלול: ערכים שעודכנו לאחרונה בדצמבר 2020"), "2020-12")
        self.assertEqual(classify({"קטגוריה:המכלול: ערכים שעודכנו לאחרונה בדצמבר 2020"})["status"],
                         "imported_documented")
        self.assertIsNone(parse_update_month("קטגוריה:המכלול: משהו אחר"))


class StateTests(unittest.TestCase):
    def test_live_gone(self):
        by_id = [page(1, "א"), {"pageid": 2, "ns": 0, "missing": True, "title": "ב"},
                 page(3, "ג", redirect=True), page(4, "User:ד", ns=2)]
        live, gone_ids, _ = resolve(by_id, [], {1, 2, 3, 4}, set())
        self.assertEqual([d["page_id"] for d in live], [1])
        self.assertEqual(gone_ids, [2, 3, 4])

    def test_morphine_live_id_beats_title(self):
        # דף 5 הועבר ל"מורפין"; על "Morphine" נשארה הפניה (דף 9) שנמחקה אחר כך
        by_id = [page(5, "מורפין")]
        by_title = [{"title": "Morphine", "ns": 0, "missing": True}, page(5, "מורפין")]
        live, gone_ids, gone_titles = resolve(by_id, by_title, {5}, {"Morphine", "מורפין"})
        self.assertEqual([d["title"] for d in live], ["מורפין"])
        self.assertEqual(gone_titles, ["Morphine"])
        self.assertEqual(gone_ids, [])

    def test_duplicate_titles_fail(self):
        with self.assertRaises(RuntimeError):
            resolve([page(1, "א"), page(2, "א")], [], {1, 2}, set())

    def test_empty_response_is_not_a_deletion(self):
        # תשובה ריקה עבור מזהה שנשאל: לא "נעלם" אלא תשובה חלקית
        with self.assertRaises(IncompleteResponse):
            resolve([], [], {710987}, set())
        with self.assertRaises(IncompleteResponse):
            resolve([], [], set(), {"כותרת"})

    def test_explicit_missing_is_gone(self):
        live, gone_ids, gone_titles = resolve(
            [{"pageid": 710987, "ns": 0, "missing": True}], [{"title": "כותרת_ב", "ns": 0, "missing": True}],
            {710987}, {"כותרת ב"})
        self.assertEqual((live, gone_ids, gone_titles), ([], [710987], ["כותרת_ב"]))

    def test_chunks(self):
        self.assertEqual(list(chunks(range(5), 2)), [[0, 1], [2, 3], [4]])


class FakeMw:
    def __init__(self, ids, titles, events, by_id, by_title, cats=None):
        self._t = (ids, titles, events)
        self._i = (by_id, by_title)
        self._c = cats or {}
        self.window = None

    def touched(self, since, until):
        self.window = (since, until)
        return self._t

    def info(self, ids=(), titles=()):
        return self._i

    def categories(self, ids):
        return {i: self._c.get(i, set()) for i in ids}


class FakeRpc:
    def __init__(self, marks, load_start="2026-10-05T09:00:00.123+00:00"):
        self.calls = []
        self.marks = marks
        self.load_start = load_start

    def call(self, fn, payload):
        self.calls.append((fn, payload))
        if fn == "sync_load_begin":
            return self.load_start
        if fn == "sync_run_start":
            return {"run_id": "r1", "watermarks": self.marks}
        if fn == "sync_apply_template_checks":
            return {"checked": len(payload["p_rows"]), "gap_changed": 0}
        if fn.startswith("sync_apply"):
            return {"live": len(payload["p_live"]), "deleted": len(payload["p_gone_ids"])}
        return None


class SyncTemplatesTests(unittest.TestCase):
    def test_edited_imported_pages_get_template_check(self):
        from datetime import datetime, timezone

        class Mech(FakeMw):
            def get(self, params):
                return {"query": {"pages": [{"pageid": 2, "revisions": [{"revid": 20, "slots": {"main": {"content": "{{מיון ויקיפדיה|דף=יעד}}"}}}]}]}}

        class Wiki(FakeMw):
            def get(self, params):
                return {"query": {"pages": [{"title": "יעד", "pageid": 50, "ns": 0}]}}
        mech = Mech({2}, {"ב"}, [], [page(2, "ב")], [{"title": "ב", "ns": 0, "pageid": 2}], {2: set()})
        wiki = Wiki({1}, {"א"}, [], [page(1, "א")], [page(1, "א")])
        rpc = FakeRpc({"wikipedia/delta": "2026-10-05T10:00:00Z", "mechalol/delta": "2026-10-05T10:00:00Z"})
        stats = run_sync({"wikipedia": wiki, "mechalol": mech}, rpc, now=datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc))
        check = [c[1] for c in rpc.calls if c[0] == "sync_apply_template_checks"]
        self.assertEqual(len(check), 1)
        self.assertEqual(check[0]["p_rows"][0]["outcome"], "ok")
        self.assertEqual(check[0]["p_rows"][0]["wiki_id"], 50)
        self.assertIn("templates", stats["mechalol"])


class SyncFlowTests(unittest.TestCase):
    def setUp(self):
        from datetime import datetime, timezone
        self.now = datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)
        self.marks = {"wikipedia/delta": "2026-10-05T10:00:00Z", "mechalol/delta": "2026-10-05T10:00:00Z"}

    def mws(self):
        return {
            "wikipedia": FakeMw({1}, {"א"}, [], [page(1, "א")], [page(1, "א")]),
            "mechalol": FakeMw({2}, {"ב"}, [{"kind": "move", "page_id": 2, "title": "ב", "new_title": "ג", "ts": "t"}],
                               [page(2, "ג")], [{"title": "ב", "ns": 0, "redirect": True, "pageid": 8}], {2: {CAT_CREATED}}),
        }

    def test_success_advances_watermarks_and_classifies(self):
        rpc = FakeRpc(self.marks)
        mws = self.mws()
        stats = run_sync(mws, rpc, now=self.now)
        self.assertEqual(mws["wikipedia"].window[0], "2026-10-05T09:50:00Z")
        names = [c[0] for c in rpc.calls]
        self.assertEqual(names[0], "sync_run_start")
        self.assertEqual(names[-1], "sync_run_finish")
        finish = rpc.calls[-1][1]
        self.assertEqual(finish["p_status"], "succeeded")
        self.assertEqual(finish["p_watermarks"], {"wikipedia/delta": "2026-10-05T12:00:00Z",
                                                  "mechalol/delta": "2026-10-05T12:00:00Z"})
        mech = [c for c in rpc.calls if c[0] == "sync_apply_mech_pages"][0][1]["p_live"][0]
        self.assertEqual(mech["status"], "created_in_mech")
        self.assertEqual(stats["mechalol"]["events"], 1)

    def test_failure_does_not_advance(self):
        rpc = FakeRpc(self.marks)
        mws = self.mws()
        mws["mechalol"].info = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
        with self.assertRaises(RuntimeError):
            run_sync(mws, rpc, now=self.now)
        finish = rpc.calls[-1][1]
        self.assertEqual(finish["p_status"], "failed")
        self.assertNotIn("p_watermarks", finish)

    def test_missing_watermark_fails(self):
        rpc = FakeRpc({})
        with self.assertRaises(RuntimeError):
            run_sync(self.mws(), rpc, now=self.now)
        self.assertEqual(rpc.calls[-1][1]["p_status"], "failed")


class InitialLoadTests(unittest.TestCase):
    def _mw(self, pages):
        class Mw(FakeMw):
            def all_pages(self):
                yield from pages
        return Mw(set(), set(), [], [], [], {3: {CAT_CREATED}})

    def test_load_batches_and_uses_stored_start(self):
        from collector import initial_load as il
        pages = [page(1, "א"), page(2, "ב", redirect=True), page(3, "קרבן פסח"), page(4, "User:x", ns=2)]
        old = il.BATCH
        il.BATCH = 1
        try:
            rpc = FakeRpc({})
            il.run_initial_load({"mechalol": self._mw(pages)}, rpc, log=lambda *_: None)
        finally:
            il.BATCH = old
        applies = [c[1] for c in rpc.calls if c[0] == "sync_apply_mech_pages"]
        self.assertEqual([[d["page_id"] for d in a["p_live"]] for a in applies], [[1], [3]])
        self.assertTrue(all(a["p_gone_ids"] == [] and a["p_gone_titles"] == [] for a in applies))
        self.assertEqual(applies[1]["p_live"][0]["wiki_candidate_key"], "קורבן פסח")
        self.assertNotIn("wiki_candidate_key", applies[0]["p_live"][0])
        self.assertEqual(rpc.calls[-1][1]["p_watermarks"], {"mechalol/delta": "2026-10-05T09:00:00.123+00:00"})
        names = [c[0] for c in rpc.calls]
        self.assertLess(names.index("sync_load_begin"), names.index("sync_apply_mech_pages"))

    def test_empty_load_fails_and_keeps_watermark(self):
        from collector import initial_load as il
        rpc = FakeRpc({})
        with self.assertRaises(RuntimeError):
            il.run_initial_load({"wikipedia": self._mw([])}, rpc, log=lambda *_: None)
        finish = rpc.calls[-1][1]
        self.assertEqual(finish["p_status"], "failed")
        self.assertNotIn("p_watermarks", finish)


class UserAgentTests(unittest.TestCase):
    def test_real_session_gets_our_user_agent(self):
        import requests
        from collector.mw import MediaWiki, USER_AGENT
        mw = MediaWiki("https://example.invalid/w/api.php", session=requests.Session())
        self.assertEqual(mw.session.headers["User-Agent"], USER_AGENT)
        self.assertNotIn("python-requests", USER_AGENT)


STUB = """<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/">
<page><title>א</title><ns>0</ns><id>1</id><revision><id>11</id><timestamp>2026-09-01T00:00:00Z</timestamp></revision></page>
<page><title>הפניה</title><ns>0</ns><id>2</id><redirect title="א" /><revision><id>12</id></revision></page>
<page><title>שיחה:א</title><ns>1</ns><id>3</id><revision><id>13</id></revision></page>
<page><title>ב</title><ns>0</ns><id>4</id><revision><id>14</id></revision></page>
</mediawiki>""".encode("utf-8")


class DumpTests(unittest.TestCase):
    def test_stub_parsing_filters_redirects_and_namespaces(self):
        import io
        from collector.dump import iter_stub_pages
        self.assertEqual(list(iter_stub_pages(io.BytesIO(STUB))), [(1, "א", 11), (4, "ב", 14)])

    def test_find_latest_dump_skips_unfinished(self):
        import json
        from collector.dump import find_latest_dump
        pages = {
            "https://dumps.wikimedia.org/hewiki/": '<a href="20260920/">x</a><a href="20261001/">y</a><a href="latest/">z</a>',
            "https://dumps.wikimedia.org/hewiki/20261001/dumpstatus.json": json.dumps({"jobs": {"stubmetacurrentdump": {"status": "in-progress"}}}),
            "https://dumps.wikimedia.org/hewiki/20260920/dumpstatus.json": json.dumps({"jobs": {"stubmetacurrentdump": {"status": "done"}}}),
        }
        date, url = find_latest_dump(pages.__getitem__)
        self.assertEqual(date, "20260920")
        self.assertTrue(url.endswith("/20260920/hewiki-20260920-stub-meta-current.xml.gz"))

    def test_start_is_before_the_dump_day(self):
        from collector.dump import start_of
        self.assertEqual(start_of("20261001"), "2026-09-30T23:00:00Z")

    def test_too_small_dump_is_rejected(self):
        import gzip
        import io
        from collector.dump import DumpSource

        class Resp:
            def __init__(self, data):
                self.raw = io.BytesIO(data)
                self.text = ""

            def raise_for_status(self):
                pass

        class Sess:
            headers = {}

            def get(self, url, **kw):
                return Resp(gzip.compress(STUB))

        src = DumpSource(session=Sess(), date="20261001")
        with self.assertRaises(RuntimeError):
            list(src.pages())

    def test_load_uses_dump_start_and_dump_pages(self):
        from collector import initial_load as il

        class Src:
            start = "2026-09-30T23:00:00Z"

            def pages(self):
                yield page(1, "א")
                yield page(4, "ב")

        rpc = FakeRpc({}, load_start="2026-09-30T23:00:00+00:00")
        il.run_initial_load({"wikipedia": FakeMw(set(), set(), [], [], [])}, rpc, log=lambda *_: None, sources={"wikipedia": Src()})
        begin = [c for c in rpc.calls if c[0] == "sync_load_begin"][0][1]
        self.assertEqual(begin, {"p_site": "wikipedia", "p_start": "2026-09-30T23:00:00Z"})
        applied = [c[1] for c in rpc.calls if c[0] == "sync_apply_wiki_pages"][0]["p_live"]
        self.assertEqual([d["page_id"] for d in applied], [1, 4])


class TemplateTests(unittest.TestCase):
    def test_parse(self):
        from collector.templates import referenced_title
        self.assertEqual(referenced_title("טקסט {{מיון ויקיפדיה|דף=[[אבג_דה]]|גרסה=5}}"), "אבג דה")
        self.assertEqual(referenced_title("{{מיון ויקיפדיה|דף=א|תאריך={{x|y}}}} ואחרי {{מיון ויקיפדיה|דף=ב}}"), "ב")
        self.assertIsNone(referenced_title("{{מיון ויקיפדיה|גרסה=5}}"))
        self.assertIsNone(referenced_title("{{מיון ויקיפדיה|דף=א"))   # לא נסגרת
        self.assertIsNone(referenced_title(""))

    def _mw(self, pages_by_id, denied_ids=(), wiki_pages=None, redirects=None):
        from collector.templates import DENIED_CODES

        class Mw:
            def __init__(self):
                self.calls = []

            def get(self, params):
                self.calls.append(params)
                if "pageids" in params:
                    ids = [int(i) for i in params["pageids"].split("|")]
                    if any(i in denied_ids for i in ids):
                        raise RuntimeError("שגיאת API: {'code': 'readapidenied'}")
                    return {"query": {"pages": [
                        {"pageid": i, "revisions": [{"revid": i * 10, "slots": {"main": {"content": pages_by_id[i]}}}]} for i in ids]}}
                titles = params["titles"].split("|")
                query = {"pages": [], "redirects": [], "normalized": []}
                for t in titles:
                    target = (redirects or {}).get(t, t)
                    if (redirects or {}).get(t):
                        query["redirects"].append({"from": t, "to": target})
                    page = (wiki_pages or {}).get(target)
                    query["pages"].append(page if page else {"title": target, "ns": 0, "missing": True})
                return {"query": query}
        return Mw()

    def test_check_pages_outcomes(self):
        from collector.templates import check_pages
        mech = self._mw({
            1: "{{מיון ויקיפדיה|דף=ערך א}}",             # same
            2: "אין תבנית",                                  # none
            3: "{{מיון ויקיפדיה|דף=יעד חי}}",              # ok
            4: "{{מיון ויקיפדיה|דף=לא קיים}}",             # unresolved
            5: "{{מיון ויקיפדיה|דף=הפניה}}",               # ok דרך הפניה
            6: "x", 7: "x"}, denied_ids={7})
        wiki = self._mw({}, wiki_pages={"יעד חי": {"pageid": 50, "title": "יעד חי", "ns": 0},
                                        "יעד סופי": {"pageid": 51, "title": "יעד סופי", "ns": 0}},
                        redirects={"הפניה": "יעד סופי"})
        titles = {1: "ערך א", 2: "ב", 3: "ג", 4: "ד", 5: "ה", 6: "ו", 7: "ז"}
        rows = {r["mech_id"]: r for r in check_pages(mech, wiki, titles, [1, 2, 3, 4, 5, 6, 7])}
        self.assertEqual(rows[1]["outcome"], "same")
        self.assertEqual(rows[2]["outcome"], "none")
        self.assertEqual((rows[3]["outcome"], rows[3]["wiki_id"]), ("ok", 50))
        self.assertEqual((rows[4]["outcome"], rows[4]["wiki_id"], rows[4]["template_ref"]), ("unresolved", None, "לא קיים"))
        self.assertEqual((rows[5]["outcome"], rows[5]["wiki_id"]), ("ok", 51))
        self.assertEqual(rows[6]["outcome"], "none")
        self.assertEqual(rows[7], {"mech_id": 7, "outcome": "denied"})   # נעול: בידוד בחיפוש בינארי, בלי לפגוע בשאר

    def test_html_entities_in_template_title(self):
        from collector.templates import referenced_title
        self.assertEqual(referenced_title("{{מיון ויקיפדיה|דף=ג&#39;ון סאליבן (מתאגרף)}}"), "ג'ון סאליבן (מתאגרף)")
        self.assertEqual(referenced_title("{{מיון ויקיפדיה|דף=אא&#34;ה טאנג}}"), 'אא"ה טאנג')
        self.assertEqual(referenced_title("{{מיון ויקיפדיה|דף=א &amp; ב}}"), "א & ב")

    def test_garbage_title_is_unresolved_without_api_call(self):
        from collector.templates import check_pages
        long_text = "א" * 300
        mech = self._mw({1: "{{מיון ויקיפדיה|דף=" + long_text + "}}", 2: "{{מיון ויקיפדיה|דף=[[x]]y}}"})
        wiki = self._mw({})
        rows = {r["mech_id"]: r for r in check_pages(mech, wiki, {1: "ב", 2: "ג"}, [1, 2])}
        self.assertEqual((rows[1]["outcome"], rows[2]["outcome"]), ("unresolved", "unresolved"))
        self.assertEqual(len(rows[1]["template_ref"]), 200)
        self.assertEqual(wiki.calls, [])

    def test_long_requests_use_post(self):
        from collector.mw import MediaWiki

        class Sess:
            headers = {}

            def __init__(self):
                self.methods = []

            def _resp(self):
                class R:
                    status_code = 200

                    def raise_for_status(self):
                        pass

                    def json(self):
                        return {"query": {}}
                return R()

            def get(self, *a, **k):
                self.methods.append("get")
                return self._resp()

            def post(self, *a, **k):
                self.methods.append("post")
                return self._resp()
        sess = Sess()
        mw = MediaWiki("https://x/api.php", session=sess)
        mw.get({"action": "query", "titles": "|".join(["כותרת ארוכה מאוד"] * 50)})
        mw.get({"action": "query", "titles": "קצר"})
        self.assertEqual(sess.methods, ["post", "get"])

    def test_wiki_response_missing_a_title_fails(self):
        from collector.templates import resolve_wiki_titles

        class Mw:
            def get(self, params):
                return {"query": {"pages": []}}
        with self.assertRaises(RuntimeError):
            resolve_wiki_titles(Mw(), ["כותרת"])


class EnrichTests(unittest.TestCase):
    class Mw:
        def __init__(self, reply):
            self.reply, self.calls = reply, []

        def get(self, params):
            self.calls.append(params)
            return self.reply(params) if callable(self.reply) else self.reply

    def test_length_skips_missing(self):
        from collector.enrich import fetch_length
        mw = self.Mw({"query": {"pages": [{"pageid": 1, "title": "א", "length": 100}, {"title": "ב", "missing": True}]}})
        rows = fetch_length(mw, [{"wiki_id": 1, "title": "א"}, {"wiki_id": 2, "title": "ב"}])
        self.assertEqual(rows, [{"wiki_id": 1, "length": 100}])

    def test_redirect_flags_and_missing_answer(self):
        from collector.enrich import fetch_redirect
        mw = self.Mw({"query": {"pages": [{"title": "א", "redirect": True}, {"title": "ב", "missing": True}]}})
        rows = {r["wiki_id"]: r["mech_redirect"] for r in fetch_redirect(mw, [{"wiki_id": 1, "title": "א"}, {"wiki_id": 2, "title": "ב"}])}
        self.assertEqual(rows, {1: True, 2: False})
        with self.assertRaises(RuntimeError):
            fetch_redirect(self.Mw({"query": {"pages": []}}), [{"wiki_id": 1, "title": "א"}])

    def test_desc_empty_is_a_checked_result(self):
        from collector.enrich import fetch_desc
        mw = self.Mw({"entities": {"Q1": {"sitelinks": {"hewiki": {"title": "א"}}, "descriptions": {"he": {"value": "תיאור"}}},
                                   "-1": {"missing": ""}}})
        rows = {r["wiki_id"]: r["wikidata_desc"] for r in fetch_desc(mw, [{"wiki_id": 1, "title": "א"}, {"wiki_id": 2, "title": "ב"}])}
        self.assertEqual(rows, {1: "תיאור", 2: ""})

    def test_locks(self):
        from collector.enrich import fetch_locks
        mw = self.Mw({"query": {"pages": [{"title": "א", "missing": True, "allevel": "create"}, {"title": "ב", "pageid": 9, "allevel": "read"},
                                          {"title": "ג", "missing": True}]}})
        rows = {r["wiki_id"]: (r["allevel"], r["pageid"]) for r in fetch_locks(mw, [{"wiki_id": 1, "title": "א"}, {"wiki_id": 2, "title": "ב"}, {"wiki_id": 3, "title": "ג"}])}
        self.assertEqual(rows, {1: ("create", None), 2: ("read", 9), 3: ("none", None)})
        with self.assertRaises(RuntimeError):
            fetch_locks(self.Mw({"query": {"pages": []}}), [{"wiki_id": 1, "title": "א"}])

    def test_created(self):
        from collector.enrich import fetch_created
        mw = self.Mw(lambda p: {"query": {"pages": [{"pageid": 1, "title": p["titles"], "revisions": [{"timestamp": "2020-01-01T00:00:00Z"}]}
                                                  if p["titles"] == "א" else {"title": p["titles"], "missing": True}]}})
        rows = fetch_created(mw, [{"wiki_id": 1, "title": "א"}, {"wiki_id": 2, "title": "ב"}])
        self.assertEqual(rows, [{"wiki_id": 1, "created_at": "2020-01-01T00:00:00Z"}])

    def test_run_group_loops_until_empty_and_failure_sends_nothing(self):
        from collector.enrich import run_group

        class Rpc:
            def __init__(self):
                self.calls, self.served = [], False

            def call(self, fn, payload):
                self.calls.append((fn, payload))
                if fn == "enrich_pending":
                    if self.served:
                        return []
                    self.served = True
                    return [{"wiki_id": 1, "title": "א"}]
        rpc = Rpc()
        mw = self.Mw({"query": {"pages": [{"pageid": 1, "title": "א", "length": 5}]}})
        self.assertEqual(run_group("length", {"wiki": mw}, rpc, log=lambda *_: None), 1)
        self.assertEqual([c[0] for c in rpc.calls], ["enrich_pending", "sync_apply_enrichment", "enrich_pending"])

        class Boom:
            def get(self, params):
                raise RuntimeError("api down")
        rpc2 = Rpc()
        with self.assertRaises(RuntimeError):
            run_group("length", {"wiki": Boom()}, rpc2, log=lambda *_: None)
        self.assertNotIn("sync_apply_enrichment", [c[0] for c in rpc2.calls])


    def test_fetch_created_skips_transient_failure(self):
        import requests
        from collector import enrich
        enrich.CREATED_PACE = 0
        enrich.SKIP_BUDGET["left"] = 1

        class Mw:
            def get(self, params):
                if params["titles"] == "ב":
                    raise requests.RequestException("HTTP 429")
                return {"query": {"pages": [{"pageid": {"א": 1, "ג": 3}[params["titles"]], "revisions": [{"timestamp": "2020-01-01T00:00:00Z"}]}]}}
        rows = enrich.fetch_created(Mw(), [{"wiki_id": 1, "title": "א"}, {"wiki_id": 2, "title": "ב"}, {"wiki_id": 3, "title": "ג"}])
        self.assertEqual([r["wiki_id"] for r in rows], [1, 3])
        self.assertEqual(enrich.SKIP_BUDGET["left"], 0)
        enrich.SKIP_BUDGET["left"] = 0
        with self.assertRaises(RuntimeError):
            enrich.fetch_created(Mw(), [{"wiki_id": 2, "title": "ב"}])
        enrich.SKIP_BUDGET["left"] = 20


class ImportV1Tests(unittest.TestCase):
    def test_read_v1_pages_and_dry_run(self):
        from collector import import_v1

        class Resp:
            def __init__(self, rows):
                self.rows = rows

            def raise_for_status(self):
                pass

            def json(self):
                return self.rows

        class Sess:
            def __init__(self):
                self.ranges = []

            def get(self, url, headers=None, params=None, timeout=None):
                self.ranges.append(headers["Range"])
                n = 1000 if len(self.ranges) % 2 == 1 and "manual_matches" in url else 3
                return Resp([{"id": i} for i in range(n)])
        sess = Sess()
        rows = import_v1.read_v1("https://x", "k", "manual_matches", "id", "id", session=sess)
        self.assertEqual((len(rows), sess.ranges), (1003, ["0-999", "1000-1999"]))
        env = {"V1_SUPABASE_URL": "https://x", "V1_SUPABASE_SERVICE_KEY": "k"}
        self.assertEqual(import_v1.main(["--dry-run"], env=env, session=Sess()), 0)


    def test_import_chunked_splits_and_sums(self):
        from collector import import_v1

        class Rpc:
            def __init__(self):
                self.calls = []

            def call(self, fn, payload):
                self.calls.append(payload)
                name = next(k for k, p in import_v1.KEYS.items() if payload[p])
                return {"inserted": {name: len(payload[import_v1.KEYS[name]])}, "skipped": {name: [{"x": 1}] if len(self.calls) == 1 else []}}
        rpc = Rpc()
        data = {"manual": [{}] * 5, "blacklist": [{}] * 250, "feedback": [], "locks": [{}] * 100}
        total = import_v1.import_chunked(rpc, "u", data)
        self.assertEqual(total["inserted"], {"manual": 5, "blacklist": 250, "feedback": 0, "locks": 100})
        self.assertEqual(len(rpc.calls), 1 + 3 + 0 + 1)
        self.assertEqual(total["skipped"]["manual"], [{"x": 1}])
        self.assertTrue(all(sum(1 for p in import_v1.KEYS.values() if c[p]) == 1 for c in rpc.calls))


class EnrichBlockedTitleTests(unittest.TestCase):
    class Mw:
        """מחזיר 403 לכל בקשה שמכילה את הכותרת החסומה."""
        def __init__(self, blocked):
            self.blocked = blocked
            self.calls = 0

        def get(self, params):
            import requests
            self.calls += 1
            titles = params["titles"].split("|")
            if self.blocked in titles:
                resp = requests.Response()
                resp.status_code = 403
                raise requests.HTTPError("403", response=resp)
            return {"query": {"pages": [{"title": t, "pageid": i + 1} for i, t in enumerate(titles)]}}

    def test_bisect_skips_only_the_blocked_title(self):
        from collector import enrich
        pages = [{"wiki_id": i, "title": f"כ{i}"} for i in range(10)]
        mw = self.Mw("כ7")
        rows = enrich.fetch_redirect(mw, pages)
        self.assertEqual(sorted(r["wiki_id"] for r in rows), [i for i in range(10) if i != 7])
        self.assertLess(mw.calls, 12)

    def test_general_block_fails_the_run(self):
        from collector import enrich
        enrich.SKIP_BUDGET["left"] = 2
        class All(self.Mw):
            def get(self, params):
                self.blocked = params["titles"].split("|")[0]
                return super().get(params)
        pages = [{"wiki_id": i, "title": f"כ{i}"} for i in range(8)]
        class Always:
            def get(self, params):
                import requests
                resp = requests.Response()
                resp.status_code = 403
                raise requests.HTTPError("403", response=resp)
        with self.assertRaises(RuntimeError):
            enrich.fetch_redirect(Always(), pages)
        enrich.SKIP_BUDGET["left"] = 20


class ReconcileTests(unittest.TestCase):
    def test_reconcile_report_and_findings(self):
        from collector.reconcile import run_reconcile

        class Mw(FakeMw):
            def __init__(self, pages):
                super().__init__(set(), set(), [], [], [])
                self.pages = pages

            def all_pages(self):
                return iter(self.pages)

            def get(self, params):
                return {"query": {"recentchanges": [], "logevents": []}}

        class Rpc(FakeRpc):
            def call(self, fn, payload):
                if fn == "reconcile_pages":
                    if payload["p_after"]:
                        return []
                    return [{"page_id": 1, "title": "א"}, {"page_id": 2, "title": "ב ישן"}, {"page_id": 9, "title": "נמחק"}]
                if fn == "reconcile_record":
                    self.recorded = payload
                    return "run-1"
                return super().call(fn, payload)
        rpc = Rpc({"wikipedia/delta": "2026-10-05T00:00:00Z"})
        mws = {"wikipedia": Mw([page(1, "א"), page(2, "ב חדש"), page(3, "חדש")])}
        report = run_reconcile(mws, rpc, log=lambda *_: None, env={})
        classes = report["sites"][0]["classes"]
        self.assertEqual((classes["only_source"]["n"], classes["only_db"]["n"], classes["title"]["n"]), (1, 1, 1))
        kinds = sorted((f["class"], f["page_id"]) for f in rpc.recorded["p_findings"])
        self.assertEqual(kinds, [("only_db", 9), ("only_source", 3), ("title", 2)])
        self.assertEqual(rpc.calls[-1][1]["p_status"], "failed")
        self.assertFalse(report["ok"])

    def test_v1_comparison_and_conflicts(self):
        from collector.reconcile import run_reconcile, v1_vs_v2

        shared = v1_vs_v2("wikipedia", {1: "א", 2: "ב", 3: "ג"}, {1: "א", 2: "ב", 5: "ה"}, {1: "א", 4: "ד", 2: "ב ישן"})
        self.assertEqual(shared["v1_vs_v2"], {"only_source": 1, "only_db": 1, "title": 1})
        self.assertEqual(sorted(f["class"] for f in shared["findings"]), ["title_v1_vs_v2", "v1_only", "v2_only"])

        class Mw(FakeMw):
            def all_pages(self):
                return iter([page(1, "א")])

            def get(self, params):
                return {"query": {"recentchanges": [], "logevents": []}}

        class Rpc(FakeRpc):
            def call(self, fn, payload):
                if fn == "reconcile_pages":
                    return [] if payload["p_after"] else [{"page_id": 1, "title": "א"}]
                if fn == "match_conflicts":
                    return [{"kind": "template_vs_title", "mech_id": 10, "mech_title": "ערך", "wiki_id": 1, "other_wiki_id": 2}]
                if fn == "reconcile_record":
                    self.recorded = payload
                    return "r"
                return super().call(fn, payload)
        rpc = Rpc({"wikipedia/delta": "2026-10-05T00:00:00Z"})
        run_reconcile({"wikipedia": Mw(set(), set(), [], [], [])}, rpc, log=lambda *_: None, env={})
        self.assertIn("conflict_template_vs_title", [f["class"] for f in rpc.recorded["p_findings"]])

    def test_empty_snapshot_fails(self):
        from collector.reconcile import run_reconcile

        class Mw(FakeMw):
            def all_pages(self):
                return iter([])
        rpc = FakeRpc({"wikipedia/delta": "2026-10-05T00:00:00Z"})
        with self.assertRaises(RuntimeError):
            run_reconcile({"wikipedia": Mw(set(), set(), [], [], [])}, rpc, log=lambda *_: None, env={})
        self.assertEqual(rpc.calls[-1][1]["p_status"], "failed")


class RevCheckTests(unittest.TestCase):
    def test_parse_template_rev(self):
        from collector.templates import parse_template
        self.assertEqual(parse_template("{{מיון ויקיפדיה|דף=א|גרסה=12345}}"), {"title": "א", "rev": 12345})
        self.assertIsNone(parse_template("{{מיון ויקיפדיה|דף=א|גרסה=1}}")["rev"])
        self.assertIsNone(parse_template("{{מיון ויקיפדיה|דף=א|גרסה=0}}")["rev"])
        self.assertIsNone(parse_template("{{מיון ויקיפדיה|דף=א}}")["rev"])

    def test_decide_rules(self):
        from collector.revcheck import decide
        live = {"page_id": 5, "title": "ב", "ns": 0, "redirect": False}
        redirect = {"page_id": 6, "title": "הפניה", "ns": 0, "redirect": True}
        self.assertEqual(decide({"template_rev": 0}, None, 100, None)[0], "bad_rev")
        self.assertEqual(decide({"template_rev": 500}, None, 100, None)[0], "bad_rev")          # גדולה מהאחרונה
        self.assertEqual(decide({"template_rev": 50}, None, 100, None)[0], "deleted_by_rev")    # נמחקה
        self.assertEqual(decide({"template_rev": 50}, {**live, "ns": 2}, 100, None)[0], "bad_rev")
        self.assertEqual(decide({"template_rev": 50, "template_title": "א"}, live, 100, None)[0], None)   # דף חי (גם בשם אחר)
        self.assertEqual(decide({"template_rev": 50, "template_title": "א"}, redirect, 100, "יעד")[0], "redirect")
        # יעד ההפניה כבר שם התבנית (גם עם הרב): טופל
        self.assertEqual(decide({"template_rev": 50, "template_title": "יצחק כהן"}, redirect, 100, "הרב יצחק כהן")[0], None)

    def test_check_rows_and_run(self):
        from collector.revcheck import check_rows, run_revcheck

        class Wiki:
            def get(self, params):
                if "revids" in params:
                    pages = [{"pageid": 5, "title": "חי", "ns": 0, "revisions": [{"revid": 50}]},
                             {"pageid": 6, "title": "הפניה", "ns": 0, "redirect": True, "revisions": [{"revid": 60}]}]
                    return {"query": {"pages": pages}}
                if "titles" in params:
                    return {"query": {"redirects": [{"from": "הפניה", "to": "יעד אחר"}]}}
                return {"query": {"recentchanges": [{"revid": 1000}]}}
        rows = [{"mech_id": 1, "template_rev": 50, "template_title": "חי"}, {"mech_id": 2, "template_rev": 60, "template_title": "משהו"},
                {"mech_id": 3, "template_rev": 0}, {"mech_id": 4, "template_rev": 70, "template_title": "x"}]
        found = {f["mech_id"]: f["rev_task"] for f in check_rows(Wiki(), rows, 1000)}
        self.assertEqual(found, {2: "redirect", 3: "bad_rev", 4: "deleted_by_rev"})

        class Rpc:
            def __init__(self):
                self.calls = []

            def call(self, fn, payload):
                self.calls.append((fn, payload))
                if fn == "rev_scope":
                    return rows if payload["p_after"] == 0 else []
        rpc = Rpc()
        stats = run_revcheck(Wiki(), rpc, log=lambda *_: None)
        self.assertEqual(stats, {"scanned": 4, "findings": 3})
        applied = [c for c in rpc.calls if c[0] == "sync_apply_rev_checks"][0][1]
        self.assertEqual(applied["p_scope_ids"], [1, 2, 3, 4])


class RebuildAndDryRunTests(unittest.TestCase):
    def test_prune_stale_gate_and_apply(self):
        from collector import initial_load as il

        class Rpc(FakeRpc):
            def call(self, fn, payload):
                if fn == "reconcile_pages":
                    return [] if payload["p_after"] else [{"page_id": i, "title": str(i)} for i in range(1, 201)]
                return super().call(fn, payload)
        rpc = Rpc({})
        self.assertEqual(il.prune_stale("wikipedia", rpc, set(range(1, 199)), log=lambda *_: None), 2)   # 1% בדיוק מותר
        applied = [c[1] for c in rpc.calls if c[0] == "sync_apply_wiki_pages"]
        self.assertEqual(applied, [{"p_live": [], "p_gone_ids": [199, 200], "p_gone_titles": []}])
        rpc2 = Rpc({})
        with self.assertRaises(RuntimeError):
            il.prune_stale("wikipedia", rpc2, set(range(1, 100)), log=lambda *_: None)    # חצי נעלם: שער המחיקה
        self.assertFalse([c for c in rpc2.calls if c[0].startswith("sync_apply")])

    def test_dry_run_writes_nothing(self):
        from datetime import datetime, timezone
        marks = {"wikipedia/delta": "2026-10-05T10:00:00Z", "mechalol/delta": "2026-10-05T10:00:00Z"}
        rpc = FakeRpc(marks)
        mws = {"wikipedia": FakeMw({1}, {"א"}, [{"kind": "move", "page_id": 1, "title": "א", "new_title": "ב", "ts": "t"}],
                                   [page(1, "א")], [page(1, "א")]),
               "mechalol": FakeMw(set(), set(), [], [], [])}
        stats = run_sync(mws, rpc, now=datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc), dry_run=True)
        self.assertTrue(stats["wikipedia"]["dry_run"])
        names = [c[0] for c in rpc.calls]
        self.assertFalse([n for n in names if n.startswith("sync_apply") or n == "sync_record_events"])
        finish = rpc.calls[-1][1]
        self.assertEqual(finish["p_status"], "cancelled")
        self.assertNotIn("p_watermarks", finish)

    def test_create_events_from_recentchanges(self):
        from collector.mw import MediaWiki

        class Sess:
            headers = {}

            def get(self, url, params=None, timeout=None):
                class R:
                    status_code = 200

                    def raise_for_status(self):
                        pass

                    def json(self_inner):
                        if params.get("list") == "recentchanges":
                            return {"query": {"recentchanges": [{"type": "new", "pageid": 7, "title": "חדש", "timestamp": "2026-10-05T11:00:00Z"},
                                                                {"type": "edit", "pageid": 8, "title": "עריכה", "timestamp": "2026-10-05T11:01:00Z"}]}}
                        return {"query": {"logevents": []}}
                return R()
        ids, titles, events = MediaWiki("https://x/api.php", session=Sess()).touched("2026-10-05T10:00:00Z", "2026-10-05T12:00:00Z")
        self.assertEqual(ids, {7, 8})
        self.assertEqual([(e["kind"], e["page_id"]) for e in events], [("create", 7)])


class ReconcileFixTests(unittest.TestCase):
    def test_fix_classification_only_unexplained_and_gated(self):
        from collector.reconcile import fix_classification

        class Rpc(FakeRpc):
            pass
        src_titles = {1: "א", 2: "ב", 3: "קרבן ג"}
        src_fields = {i: {"status": "imported_documented", "source_type": "wikipedia_documented", "needs_attention": False, "is_dictionary": False} for i in src_titles}
        changes = {"status": [(1, "created_in_mech", "imported_documented"), (2, "created_in_mech", "imported_documented"), (3, "x", "imported_documented")],
                   "status_documented_in_db_only": [(9, "d", "u")]}
        rpc = Rpc({})
        # דף 2 נערך בחלון: לא מתקנים; 9 מקורו לא אומת: לא מתקנים
        n = fix_classification(rpc, src_titles, src_fields, changes, {2}, set(), 1000, log=lambda *_: None)
        self.assertEqual(n, 2)
        live = [c for c in rpc.calls if c[0] == "sync_apply_mech_pages"][0][1]["p_live"]
        self.assertEqual([d["page_id"] for d in live], [1, 3])
        self.assertEqual(live[1]["wiki_candidate_key"], "קורבן ג")          # גם המפתח הסמנטי מחושב
        self.assertNotIn("wiki_candidate_key", live[0])
        # שער: 3 מתוך 100 > 2%
        with self.assertRaises(RuntimeError):
            fix_classification(Rpc({}), src_titles, src_fields, changes, set(), set(), 100, log=lambda *_: None)

    def test_nothing_to_fix(self):
        from collector.reconcile import fix_classification
        rpc = FakeRpc({})
        self.assertEqual(fix_classification(rpc, {}, {}, {}, set(), set(), 1000), 0)
        self.assertEqual(rpc.calls, [])


if __name__ == "__main__":
    unittest.main()


class SmokeTests(unittest.TestCase):
    class Mw:
        def __init__(self, n=600, drop_key=None, quiet=False):
            self.pages = [{"pageid": i + 1, "title": f"ד{i}", "lastrevid": i, **({} if drop_key else {})} for i in range(n)]
            if drop_key:
                for p in self.pages:
                    p.pop(drop_key)
            self.quiet = quiet

        def all_pages(self):
            yield from self.pages

        def info(self, ids=(), titles=()):
            return [p for p in self.pages if p.get("pageid") in set(ids)], []

        def categories(self, ids):
            return {i: set() for i in ids}

        def touched(self, since, until):
            return (set() if self.quiet else {1}), set(), [{"kind": "create", "page_id": 1, "title": "א", "ts": "x"}]

    def test_healthy(self):
        from collector.smoke import run_smoke
        self.assertEqual(run_smoke({"s": self.Mw()}), [])

    def test_missing_field_and_quiet(self):
        from collector.smoke import run_smoke
        self.assertTrue(any("lastrevid" in f for f in run_smoke({"s": self.Mw(drop_key="lastrevid")})))
        self.assertTrue(any("חשוד" in f for f in run_smoke({"s": self.Mw(quiet=True)})))
        self.assertTrue(any("allpages" in f for f in run_smoke({"s": self.Mw(n=10)})))
