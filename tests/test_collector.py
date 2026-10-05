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
        if fn.startswith("sync_apply"):
            return {"live": len(payload["p_live"]), "deleted": len(payload["p_gone_ids"])}
        return None


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


if __name__ == "__main__":
    unittest.main()
