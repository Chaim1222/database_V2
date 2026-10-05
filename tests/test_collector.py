import importlib.util
import os
import unittest

from collector.classify import CAT_CREATED, CAT_DICTIONARY, CAT_PAGES_TO_OPEN, classify, parse_update_month
from collector.normalize import mech_key_row, semantic_candidate, title_key
from collector.state import chunks, resolve
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
        old = "/home/user/database/scripts/normalize.py"
        if not os.path.exists(old):
            self.skipTest("המערכת הקודמת אינה זמינה")
        spec = importlib.util.spec_from_file_location("old_normalize", old)
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
        except Exception as exc:
            self.skipTest(f"טעינת המודול הישן נכשלה: {exc}")
        cases = ["אלוקים", "קרבן פסח", "מרכז הנאולוגי", "ה'תשפ\"כ", "אליל", "א-ל", "דף רגיל", "\u200fאבג\u00a0 \u05f4ד\u05f4 \u2013 ה",
                 '"קדוש" השם', "אישיות (אישיות מהתנ\"ך)"]
        for title in cases:
            self.assertEqual(title_key(title), mod.hygiene(title), title)
            self.assertEqual(semantic_candidate(title)[0], mod.normalize_title(title)[0], title)


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
    def __init__(self, marks):
        self.calls = []
        self.marks = marks

    def call(self, fn, payload):
        self.calls.append((fn, payload))
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
            "wikipedia": FakeMw({1}, {"א"}, [], [page(1, "א")], []),
            "mechalol": FakeMw({2}, {"ב"}, [{"kind": "move", "page_id": 2, "title": "ב", "new_title": "ג", "ts": "t"}],
                               [page(2, "ג")], [], {2: {CAT_CREATED}}),
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
    def test_load_batches_and_sets_watermark_at_start(self):
        from datetime import datetime, timezone
        from collector import initial_load as il

        class Mw(FakeMw):
            def all_pages(self):
                yield page(1, "א")
                yield page(2, "ב", redirect=True)
                yield page(3, "קרבן פסח")
                yield page(4, "User:x", ns=2)

        old = il.BATCH
        il.BATCH = 1
        try:
            rpc = FakeRpc({})
            mw = Mw(set(), set(), [], [], [], {3: {CAT_CREATED}})
            il.run_initial_load({"mechalol": mw}, rpc, now=datetime(2026, 10, 5, 9, 0, tzinfo=timezone.utc), log=lambda *_: None)
        finally:
            il.BATCH = old
        applies = [c[1] for c in rpc.calls if c[0] == "sync_apply_mech_pages"]
        self.assertEqual([[d["page_id"] for d in a["p_live"]] for a in applies], [[1], [3]])
        self.assertTrue(all(a["p_gone_ids"] == [] and a["p_gone_titles"] == [] for a in applies))
        self.assertEqual(applies[1]["p_live"][0]["wiki_candidate_key"], "קורבן פסח")
        self.assertNotIn("wiki_candidate_key", applies[0]["p_live"][0])
        finish = rpc.calls[-1][1]
        self.assertEqual(finish["p_watermarks"], {"mechalol/delta": "2026-10-05T09:00:00Z"})


class UserAgentTests(unittest.TestCase):
    def test_real_session_gets_our_user_agent(self):
        import requests
        from collector.mw import MediaWiki, USER_AGENT
        mw = MediaWiki("https://example.invalid/w/api.php", session=requests.Session())
        self.assertEqual(mw.session.headers["User-Agent"], USER_AGENT)
        self.assertNotIn("python-requests", USER_AGENT)


if __name__ == "__main__":
    unittest.main()
