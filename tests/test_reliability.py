"""Audit acceptance: same source, no waived drift, consistent reads, failed artifacts."""
import copy
import gzip
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

from collector import reliability as audit

AT = datetime(2026, 10, 8, tzinfo=timezone.utc)


def database():
    return {"captured_at": audit.iso(AT), "state": {"watermarks": {s: audit.iso(AT) for s in audit.APIS},
            "weekly": {"phase": "complete", "updated_at": AT}},
            "mirrors": {"wikipedia": {1: {"title": "א"}},
                        "mechalol": {2: {"title": "ב", "status": "imported_documented", "source_type": "wikipedia_documented",
                                          "needs_attention": False, "is_dictionary": False}}},
            "reports": {r: {} for r in audit.REPORTS}}


def sources(db):
    result = {}
    for site, rows in db["mirrors"].items():
        result[site] = {"titles": {i: r["title"] for i, r in rows.items()},
                        "fields": {i: {f: r[f] for f in audit.CLASSIFICATION_FIELDS} for i, r in rows.items()} if site == "mechalol" else {},
                        "started_at": audit.iso(AT), "finished_at": audit.iso(AT),
                        "windows": {v: {"ids": [], "titles": []} for v in ("v1", "v2")}}
    return result


class CompareTests(unittest.TestCase):
    def test_identical_snapshots_and_reports_are_clean(self):
        db = database()
        report = audit.build_report({"v1": db, "v2": copy.deepcopy(db)}, sources(db))
        self.assertEqual(report["status"], "clean")
        self.assertEqual(len(report["comparisons"]), 10)

    def test_matching_databases_still_fail_if_both_disagree_with_source(self):
        db = database()
        src = sources(db)
        src["wikipedia"]["titles"][9] = "חסר בשניהם"
        self.assertEqual(audit.build_report({"v1": db, "v2": db}, src)["status"], "differences")

    def test_equal_counts_do_not_hide_replaced_identity(self):
        left, right = database(), database()
        right["mirrors"]["wikipedia"] = {8: {"title": "א"}}
        result = audit.build_report({"v1": left, "v2": right}, sources(left))
        self.assertEqual(result["status"], "differences")
        self.assertEqual(len(result["comparisons"][1]["findings"]), 2)

    def test_activity_is_never_a_waiver(self):
        left, right = database(), database()
        right["mirrors"]["wikipedia"][1]["title"] = "ישן"
        src = sources(left)
        src["wikipedia"]["windows"]["v2"] = {"ids": [1], "titles": []}
        report = audit.build_report({"v1": left, "v2": right}, src)
        self.assertEqual(report["status"], "differences")
        self.assertTrue(report["comparisons"][1]["findings"][0]["changed_in_window"])

    def test_v1_classification_is_compared_against_source(self):
        left, right = database(), database()
        src = sources(right)
        left["mirrors"]["mechalol"][2]["needs_attention"] = True
        report = audit.build_report({"v1": left, "v2": right}, src)
        self.assertTrue(any(f["kind"] == "needs_attention" for f in report["comparisons"][3]["findings"]))

    def test_report_reason_difference_blocks_clean(self):
        left, right = database(), database()
        left["reports"]["revisions"][2] = {"rev_task": "redirect"}
        right["reports"]["revisions"][2] = {"rev_task": "bad_rev"}
        report = audit.build_report({"v1": left, "v2": right}, sources(left))
        self.assertEqual(report["status"], "differences")
        self.assertEqual(report["comparisons"][-1]["findings"][0]["id"], 2)

    def test_missing_redirect_partition_difference_is_visible(self):
        left, right = database(), database()
        left["reports"]["missing"][1] = {"title": "א", "mechalol_redirect_exists": True}
        right["reports"]["missing"][1] = {"title": "א", "mechalol_redirect_exists": False}
        self.assertEqual(audit.build_report({"v1": left, "v2": right}, sources(left))["status"], "differences")


class StateTests(unittest.TestCase):
    def state(self, version):
        state = database()["state"]
        if version == "v1":
            state["weekly"] = {"phase": "complete", "updated_at": AT}
        else:
            state["runs"] = [{"kind": "sync", "status": "succeeded"}]
        return state

    def test_valid_completed_states(self):
        for version in ("v1", "v2"):
            audit.validate_state(version, self.state(version), AT)

    def test_stale_future_missing_marks_and_partial_weekly_rejected(self):
        for version in ("v1", "v2"):
            for offset in (-40, 1):
                state = self.state(version)
                state["watermarks"]["wikipedia"] = AT + timedelta(hours=offset)
                with self.assertRaises(audit.AuditError):
                    audit.validate_state(version, state, AT)
        state = self.state("v1")
        state["weekly"]["phase"] = "swapped"
        with self.assertRaises(audit.AuditError):
            audit.validate_state("v1", state, AT)
        state = self.state("v2")
        del state["watermarks"]["mechalol"]
        with self.assertRaises(RuntimeError):
            audit.validate_state("v2", state, AT)

    def test_failed_last_sync_and_old_weekly_rejected(self):
        state = self.state("v2")
        state["runs"][0]["status"] = "failed"
        with self.assertRaises(audit.AuditError):
            audit.validate_state("v2", state, AT)
        state = self.state("v1")
        state["weekly"]["updated_at"] = AT - timedelta(days=9)
        with self.assertRaises(audit.AuditError):
            audit.validate_state("v1", state, AT)


class SourceTests(unittest.TestCase):
    def test_bad_api_replies_fail(self):
        mw = audit.AuditMediaWiki("https://example.test/api")
        for value in (None, {}, {"query": {"pages": None}}, {"query": {"pages": [{"pageid": 1}]}},
                      {"warnings": {"x": {}}, "query": {"pages": []}},
                      {"query": {"pages": [{"pageid": 1, "title": "א", "missing": True}]}},
                      {"query": {"pages": []}, "continue": "bad"}):
            with self.subTest(value=value), patch.object(audit.MediaWiki, "get", return_value=value):
                with self.assertRaises(RuntimeError):
                    mw.get({"prop": "info"})

    def test_missing_category_page_rejected(self):
        mw = audit.AuditMediaWiki("https://example.test/api")
        with patch.object(audit.MediaWiki, "get", return_value={"query": {"pages": [{"pageid": 1, "title": "א"}]}}):
            with self.assertRaises(RuntimeError):
                mw.get({"prop": "categories", "pageids": "1|2"})

    def test_categoryless_page_is_valid(self):
        mw = audit.AuditMediaWiki("https://example.test/api")
        with patch.object(audit.MediaWiki, "get", return_value={"query": {"pages": [{"pageid": 1, "title": "א"}]}}):
            mw.get({"prop": "categories", "pageids": "1"})

    def test_duplicate_page_across_batches_rejected(self):
        mw = audit.AuditMediaWiki("https://example.test/api")
        page = {"pageid": 1, "title": "א", "ns": 0}
        with patch.object(audit.MediaWiki, "all_pages", return_value=iter([page, page])):
            with self.assertRaises(RuntimeError):
                list(mw.all_pages())

    def test_repeated_continuation_rejected(self):
        mw = audit.AuditMediaWiki("https://example.test/api")
        data = {"query": {"pages": []}, "continue": {"continue": "-||", "gapcontinue": "א"}}
        with patch.object(audit.MediaWiki, "get", return_value=data):
            with self.assertRaises(audit.AuditError):
                list(mw.paged({"prop": "info"}, "pages"))


class ReadTests(unittest.TestCase):
    def test_fetch_until_empty_not_short_batch(self):
        cursor = Mock()
        cursor.description = [Mock(name="id"), Mock(name="title")]
        cursor.description[0].name, cursor.description[1].name = "id", "title"
        cursor.fetchmany.side_effect = [[(1, "א")], [(4, "ב")], []]
        cursor.__enter__ = Mock(return_value=cursor)
        cursor.__exit__ = Mock(return_value=False)
        conn = Mock()
        conn.cursor.return_value = cursor
        self.assertEqual(list(audit.read_rows(conn, "SELECT id, title FROM test")), [{"id": 1, "title": "א"}, {"id": 4, "title": "ב"}])

    def test_duplicate_or_bad_identity_rejected(self):
        for rows in ([{"id": 1}, {"id": 1}], [{"id": None}], [{"id": True}]):
            with self.assertRaises(RuntimeError):
                audit.keyed(rows)

    def test_database_uses_read_only_repeatable_read_and_aborts_on_writer(self):
        from unittest.mock import MagicMock
        conn = MagicMock()
        conn.__enter__.return_value = conn
        conn.execute.side_effect = [Mock(), Mock(fetchone=Mock(return_value=(AT,))), Mock(fetchone=Mock(return_value=(1,)))]
        connect = Mock(return_value=conn)
        with self.assertRaises(audit.AuditError):
            audit.read_database("secret-url", "v1", connect=connect)
        self.assertIn("default_transaction_read_only=on", connect.call_args.kwargs["options"])
        self.assertEqual(conn.execute.call_args_list[0].args[0], "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        self.assertTrue(all(call.args[0].lstrip().startswith(("SELECT", "SET TRANSACTION")) for call in conn.execute.call_args_list))


class RunTests(unittest.TestCase):
    def test_missing_secrets_produces_failed_downloadable_report(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            code = audit.run(out, env={}, read=Mock())
            report = json.loads((out / "report.json").read_text())
            self.assertEqual(code, 2)
            self.assertEqual(report["status"], "failed")
            self.assertIn("V1_DB_URL", report["reason"])
            self.assertTrue((out / "report.md").is_file())
            self.assertTrue((out / "findings.csv").is_file())

    def test_failed_connection_does_not_leak_credentials(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            audit.run(out, env={"V1_DB_URL": "one", "V2_DB_URL": "two"}, read=Mock(side_effect=RuntimeError("password=private")))
            self.assertNotIn("private", (out / "report.json").read_text())
            self.assertNotIn("private", (out / "report.md").read_text())

    def test_one_snapshot_per_site_and_full_artifacts(self):
        db = database()
        def take_snapshot(site, mw):
            src = sources(db)[site]
            return src["titles"], src["fields"]
        with tempfile.TemporaryDirectory() as temp, patch.object(audit, "snapshot", side_effect=take_snapshot) as snap, \
                patch.object(audit, "collect_window", return_value=(set(), set(), {})), patch.object(audit, "now", return_value=AT):
            out = Path(temp)
            code = audit.run(out, env={"V1_DB_URL": "one", "V2_DB_URL": "two"}, read=lambda *_: copy.deepcopy(db), mw_factory=Mock())
            self.assertEqual(code, 0)
            self.assertEqual(snap.call_count, 2)
            with gzip.open(out / "snapshot.json.gz", "rt") as fh:
                self.assertEqual(set(json.load(fh)["sources"]), set(audit.APIS))

    def test_partial_source_read_never_returns_clean(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(audit, "snapshot", side_effect=RuntimeError("partial")):
            out = Path(temp)
            code = audit.run(out, env={"V1_DB_URL": "one", "V2_DB_URL": "two"}, read=lambda *_: database(), mw_factory=Mock())
            self.assertEqual(code, 2)
            self.assertEqual(json.loads((out / "report.json").read_text())["stage"], "source/wikipedia")


if __name__ == "__main__":
    unittest.main()
