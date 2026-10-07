import unittest
from unittest.mock import patch
from collector.revcheck import move_proof, resolve_revisions, run_movecheck


class MoveSourceTests(unittest.TestCase):
    def setUp(self):
        self.row = {"mech_id": 1178550, "local_rev_id": 3837860,
                    "template_rev": 44032199, "template_title": "מקדש קונקורדיה"}
        self.fetched = {"rev_id": 3837860, "content": "{{מיון ויקיפדיה|דף=מקדש קונקורדיה|גרסה=44032199}}"}
        self.source = {"page_id": 2580912, "title": "מקדש קונקורדיה", "ns": 0, "redirect": False}

    def proof(self, row=None, fetched=None, source=None):
        return move_proof(row or self.row, fetched or self.fetched, {44032199: source or self.source})

    def test_recreated_title_proves_new_identity(self):
        self.assertEqual(self.proof()["wiki_id"], 2580912)

    def test_real_move_at_reused_title_is_not_hidden(self):
        self.assertIsNone(self.proof(source=dict(self.source, page_id=555733, title="מקדש קונקורדיה (רומא)"))["wiki_id"])

    def test_stale_baseline_or_changed_template_cannot_suppress(self):
        for field in ("local_rev_id", "template_rev", "template_title"):
            self.assertIsNone(self.proof(row=dict(self.row, **{field: "שונה" if field == "template_title" else 999}))["wiki_id"])
        for content in ("", "{{מיון ויקיפדיה|גרסה=44032199}}", "{{מיון ויקיפדיה|דף=אחר|גרסה=44032199}}"):
            self.assertIsNone(self.proof(fetched=dict(self.fetched, content=content))["wiki_id"])
        for item in (None, "denied"):
            self.assertIsNone(move_proof(self.row, item, {})["wiki_id"])
        for change in ({"ns": 118}, {"redirect": True}):
            self.assertIsNone(self.proof(source=dict(self.source, **change))["wiki_id"])

    def test_strict_reply_coverage(self):
        class MW:
            def __init__(self, data): self.data = data
            def get(self, _): return self.data
        page = {"pageid": 1, "ns": 0, "title": "א", "revisions": [{"revid": 300}]}
        for data in ({}, {"query": {"pages": []}}, {"query": {"pages": [page, page]}},
                     {"query": {"pages": [dict(page, pageid=None)]}}):
            with self.assertRaises(RuntimeError): resolve_revisions(MW(data), [300], strict=True)
        self.assertEqual(resolve_revisions(MW({"query": {"pages": [], "badrevids": {"300": {}}}}), [300], strict=True), {300: None})
        self.assertEqual(resolve_revisions(MW({"query": {"pages": [page]}}), [300], strict=True)[300]["page_id"], 1)

    @patch("collector.templates.fetch_contents")
    @patch("collector.revcheck.resolve_revisions")
    def test_rechecks_hidden_candidates_and_clears_unreadable_proof(self, resolve, fetch):
        fixture = self
        class RPC:
            def __init__(self): self.writes = []
            def call(self, fn, payload):
                if fn == "move_source_scope": return [fixture.row] if payload["p_after"] == 0 else []
                self.writes.extend(payload["p_rows"])
        resolve.return_value = {44032199: self.source}
        for item, expected in ((self.fetched, 1), ("denied", 0)):
            rpc = RPC(); fetch.return_value = {1178550: item}
            self.assertEqual(run_movecheck(None, None, rpc), {"checked": 1, "proven": expected})
            self.assertEqual(rpc.writes[0]["wiki_id"], 2580912 if expected else None)
        resolve.side_effect = RuntimeError("network failed")
        rpc = RPC()
        with self.assertRaises(RuntimeError): run_movecheck(None, None, rpc)
        self.assertEqual(rpc.writes, [])
