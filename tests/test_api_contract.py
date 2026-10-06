"""תשובה חלקית אינה הוכחת מחיקה; עצירה משאירה אפשרות להרצה חוזרת."""
import unittest
from unittest.mock import patch

from collector.mw import MediaWiki
from collector.templates import fetch_contents, check_and_apply
from collector.revcheck import resolve_revisions, resolve_redirect_targets, fetch_max_rev, run_revcheck
from collector.enrich import fetch_created, fetch_desc, fetch_length
from collector.sync import run_sync


class Reply:
    def __init__(self, data):
        self.data = data

    def get(self, params):
        return self.data


class ApiContractTests(unittest.TestCase):
    def test_missing_revision_requires_explicit_badrevid(self):
        for data in ({}, {"query": {}}, {"query": {"pages": []}},
                     {"query": {"badrevids": {"11": {"revid": 11}}}}):
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                resolve_revisions(Reply(data), [10])
        self.assertEqual(resolve_revisions(Reply({"query": {"badrevids": {"10": {"revid": 10}}}}), [10]), {10: None})
        live = {"pageid": 1, "title": "א", "ns": 0, "revisions": [{"revid": 10}]}
        with self.assertRaises(RuntimeError):
            resolve_revisions(Reply({"query": {"pages": [live]}}), [10, 20])

    def test_content_missing_or_suppressed_preserves_previous_result(self):
        class Rpc:
            calls = []

            def call(self, *args):
                self.calls.append(args)
        for data in ({"query": {"pages": []}}, {"query": {"pages": [{"pageid": 1}]}},
                     {"query": {"pages": [{"pageid": 1, "revisions": [{"revid": 10, "slots": {"main": {}}}]}]}}):
            rpc = Rpc()
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                check_and_apply(Reply(data), Reply({}), rpc, {1: "א"}, [1])
            self.assertEqual(rpc.calls, [])
        self.assertEqual(fetch_contents(Reply({"query": {"pages": [{"pageid": 1, "missing": True}]}}), [1]), {1: None})
        empty = {"pageid": 1, "revisions": [{"revid": 10, "slots": {"main": {"content": ""}}}]}
        self.assertEqual(fetch_contents(Reply({"query": {"pages": [empty]}}), [1])[1]["content"], "")

    def test_missing_category_page_is_not_empty_categories(self):
        mw = MediaWiki("https://example.invalid/api.php")
        mw.get = Reply({"query": {"pages": [{"pageid": 1, "categories": []}]}}).get
        with self.assertRaises(RuntimeError):
            mw.categories([1, 2])
        self.assertEqual(mw.categories([1]), {1: set()})

    def test_partial_change_window_never_advances_watermark_and_retry_works(self):
        class Rpc:
            def __init__(self):
                self.calls = []

            def call(self, name, body):
                self.calls.append((name, body))
                if name == "sync_run_start":
                    return {"run_id": "r", "watermarks": {"wikipedia/delta": "2026-10-01T00:00:00Z"}}
        mw = MediaWiki("https://example.invalid/api.php")
        mw.get = Reply({}).get
        rpc = Rpc()
        with self.assertRaises(RuntimeError):
            run_sync({"wikipedia": mw}, rpc)
        self.assertEqual(rpc.calls[-1][1]["p_status"], "failed")
        self.assertNotIn("p_watermarks", rpc.calls[-1][1])
        mw.get = lambda params: {"query": {params["list"]: []}}
        run_sync({"wikipedia": mw}, rpc)
        self.assertEqual(rpc.calls[-1][1]["p_status"], "succeeded")
        self.assertIn("p_watermarks", rpc.calls[-1][1])

    def test_revision_batch_fails_before_any_write(self):
        class Rpc:
            def __init__(self):
                self.calls = []

            def call(self, name, body):
                self.calls.append(name)
                return [{"mech_id": 1, "template_rev": 10}] if name == "rev_scope" else None
        class Wiki:
            def get(self, params):
                return {"query": {"recentchanges": [{"revid": 100}]}} if "list" in params else {"query": {"pages": []}}
        rpc = Rpc()
        with self.assertRaises(RuntimeError):
            run_revcheck(Wiki(), rpc)
        self.assertNotIn("sync_apply_rev_checks", rpc.calls)

    def test_redirect_chain_and_max_revision_require_complete_answer(self):
        with self.assertRaises(RuntimeError):
            resolve_redirect_targets(Reply({"query": {"pages": []}}), ["א"])
        answer = {"query": {"redirects": [{"from": "א", "to": "ב"}, {"from": "ב", "to": "ג"}],
                            "pages": [{"pageid": 3, "title": "ג"}]}}
        self.assertEqual(resolve_redirect_targets(Reply(answer), ["א"]), {"א": "ג"})
        for answer in ({}, {"query": {"recentchanges": []}}):
            with self.assertRaises(RuntimeError):
                fetch_max_rev(Reply(answer))

    def test_enrichment_incomplete_answer_never_becomes_empty_data(self):
        pages = [{"wiki_id": 1, "title": "א"}]
        with patch("collector.enrich.time.sleep"):
            for answer in ({"query": {"pages": []}}, {"query": {"pages": [{"pageid": 1}]}}):
                with self.assertRaises(RuntimeError):
                    fetch_created(Reply(answer), pages)
        for fetch in (fetch_desc, fetch_length):
            with self.assertRaises(RuntimeError):
                fetch(Reply({}), pages)
        with self.assertRaises(RuntimeError):
            fetch_desc(Reply({"entities": {"Q1": {"sitelinks": {"hewiki": {"title": "א"}}}}}), pages + [{"wiki_id": 2, "title": "ב"}])

    def test_length_keeps_page_identity_and_missing_description_is_valid(self):
        pages = [{"wiki_id": 1, "title": "א"}]
        with self.assertRaises(RuntimeError):
            fetch_length(Reply({"query": {"pages": [{"pageid": 2, "title": "א", "length": 99}]}}), pages)
        self.assertEqual(fetch_length(Reply({"query": {"pages": [{"pageid": 1, "title": "א", "length": 0}]}}), pages), [{"wiki_id": 1, "length": 0}])
        self.assertEqual(fetch_desc(Reply({"entities": {"-1": {"missing": True}}}), pages), [{"wiki_id": 1, "wikidata_desc": ""}])
        with self.assertRaises(RuntimeError):
            fetch_desc(Reply({"entities": {"Q1": {"sitelinks": {"hewiki": {"title": "לא נשאל"}}}, "-1": {"missing": True}}}), pages)

    def test_latest_revision_uses_edits_not_log_entries(self):
        class Wiki:
            def get(self, params):
                self.params = params
                return {"query": {"recentchanges": [{"revid": 100}]}}
        wiki = Wiki()
        self.assertEqual(fetch_max_rev(wiki), 100)
        self.assertEqual(wiki.params["rctype"], "edit|new")

    def test_reconcile_cli_returns_failure_for_unexplained_differences(self):
        from collector.cli import main
        with patch.dict('os.environ', {'SUPABASE_URL': 'https://example.invalid', 'SUPABASE_SERVICE_KEY': 'test'}), \
                patch('collector.cli.Rpc'), patch('collector.cli.run_reconcile') as reconcile:
            for ok, expected in [(False, 1), (True, 0)]:
                reconcile.return_value = {'ok': ok, 'sites': [{'site': 'wikipedia', 'unexplained_pages': 0 if ok else 1}]}
                self.assertEqual(main(['reconcile']), expected)


if __name__ == "__main__":
    unittest.main()
