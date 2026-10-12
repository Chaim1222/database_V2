from collector import revcheck as subject
from types import SimpleNamespace
import unittest

LIVE = {"pageid": 5, "title": "חי", "ns": 0, "revisions": [{"revid": 50}]}


class RevisionResponseTests(unittest.TestCase):
    def test_failed_batch_preserves_findings_and_rerun_is_idempotent(self):
        rows = [{"mech_id": 1, "template_rev": 0}, {"mech_id": 2, "template_rev": 50}]
        class Rpc:
            def __init__(self):
                self.findings = {2: {"mech_id": 2, "rev_task": "bad_rev"}}
                self.applied = []
            def call(self, fn, payload):
                if fn == "rev_scope":
                    return [r for r in rows if r["mech_id"] > payload["p_after"]][:1]
                assert fn == "sync_apply_rev_checks"
                self.applied.append(payload)
                for mid in payload["p_scope_ids"]:
                    self.findings.pop(mid, None)
                self.findings.update({r["mech_id"]: r for r in payload["p_rows"]})
        rpc = Rpc()
        broken = SimpleNamespace(get=lambda p: {"query": {"recentchanges": [{"revid": 1000}]}}
                                 if "list" in p else {"query": {}})
        result = subject.run_revcheck(broken, rpc, log=lambda _: None)
        self.assertFalse(result["complete"])
        self.assertEqual(result["failed_ids"], [2])
        self.assertEqual(len(rpc.applied), 1)
        self.assertEqual(set(rpc.findings), {1, 2})
        healthy = SimpleNamespace(get=lambda p: {"query": {"recentchanges": [{"revid": 1000}]}}
                                  if "list" in p else {"query": {"pages": [LIVE]}})
        self.assertEqual(subject.run_revcheck(healthy, rpc, log=lambda _: None),
                         {"scanned": 2, "findings": 1})
        after = dict(rpc.findings)
        subject.run_revcheck(healthy, rpc, log=lambda _: None)
        self.assertEqual(rpc.findings, after)
        self.assertEqual(set(after), {1})

    def resolve(self, reply, ids=(50, 70)):
        return subject.resolve_revisions(SimpleNamespace(get=lambda params: reply), ids)

    def test_confirmed_missing_and_live(self):
        result = self.resolve({"query": {"pages": [LIVE],
                              "badrevids": {"70": {"revid": 70, "missing": True}}}})
        self.assertEqual(result[50]["page_id"], 5)
        self.assertIsNone(result[70])

    def test_all_confirmed_missing_without_pages(self):
        self.assertEqual(self.resolve({"query": {"badrevids": {
            "70": {"revid": 70, "missing": True}}}}, (70,)), {70: None})

    def test_partial_or_malformed_reply_fails(self):
        for reply in ({}, {"query": {}}, {"query": {"pages": [LIVE]}},
                      {"query": {"pages": None}}, {"query": {"pages": [dict(LIVE, ns=None)]}},
                      {"query": {"badrevids": {"70": {"revid": 70}}}}):
            with self.subTest(reply=reply), self.assertRaises(RuntimeError):
                self.resolve(reply)

    def test_duplicate_unexpected_or_contradictory_identity_fails(self):
        for query in ({"pages": [LIVE, LIVE]},
                      {"pages": [LIVE], "badrevids": {"50": {"revid": 50, "missing": True}}},
                      {"pages": [dict(LIVE, revisions=[{"revid": 99}])]},
                      {"badrevids": {"99": {"revid": 99, "missing": True}}}):
            with self.subTest(query=query), self.assertRaises(RuntimeError):
                self.resolve({"query": query}, (50,))

    def test_continued_reply_is_not_complete(self):
        with self.assertRaises(RuntimeError):
            self.resolve({"continue": {"rvcontinue": "x"}, "query": {"pages": [LIVE]}}, (50,))

    def test_empty_request_does_not_fetch(self):
        self.assertEqual(subject.resolve_revisions(SimpleNamespace(get=lambda _: self.fail('unexpected fetch')), []), {})

    def test_hidden_revision_does_not_change_page_identity(self):
        page = dict(LIVE, revisions=[{"revid": 50, "texthidden": True}])
        self.assertEqual(self.resolve({"query": {"pages": [page]}}, (50,))[50]["page_id"], 5)

