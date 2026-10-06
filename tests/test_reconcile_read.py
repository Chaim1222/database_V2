"""Regression: server-capped pages and interrupted read-only reconciliation."""
import unittest
from unittest.mock import patch
import requests
from collector.reconcile import read_db
from collector.initial_load import prune_stale


class PagedRpc:
    def __init__(self, events):
        self.events = iter(events)
        self.calls = []

    def call(self, name, payload):
        self.calls.append((name, dict(payload)))
        value = next(self.events)
        if isinstance(value, Exception):
            raise value
        return value


def row(i):
    return {"page_id": i, "title": str(i), "status": "documented"}


class ReconcileReadTests(unittest.TestCase):
    def test_server_cap_does_not_end_snapshot(self):
        rpc = PagedRpc([[row(1), row(4)], [row(8)], []])
        titles, fields = read_db(rpc, "wikipedia", log=lambda *_: None)
        self.assertEqual(titles, {1: "1", 4: "4", 8: "8"})
        self.assertEqual(fields[8]["status"], "documented")
        self.assertEqual([p["p_after"] for _, p in rpc.calls], [0, 4, 8])

    @patch("collector.reconcile.time.sleep")
    def test_retry_same_cursor_preserves_previous_pages(self, sleep):
        rpc = PagedRpc([[row(1)], requests.ReadTimeout(), requests.ConnectionError(), [row(4)], []])
        titles, _ = read_db(rpc, "mechalol", log=lambda *_: None)
        self.assertEqual(titles, {1: "1", 4: "4"})
        self.assertEqual([p["p_after"] for _, p in rpc.calls], [0, 1, 1, 1, 4])
        self.assertEqual(sleep.call_count, 2)
        self.assertTrue(all(n == "reconcile_pages" for n, _ in rpc.calls))

    @patch("collector.reconcile.time.sleep")
    def test_exhausted_read_never_returns_partial_result(self, sleep):
        rpc = PagedRpc([[row(1)]] + [requests.ReadTimeout() for _ in range(3)])
        with self.assertRaises(requests.ReadTimeout):
            read_db(rpc, "wikipedia", log=lambda *_: None)
        self.assertEqual(len(rpc.calls), 4)

    def test_invalid_page_never_counts_as_end(self):
        for value in (None, {}, [row(1), row(1)], [row(2), row(1)], [{"page_id": 1}]):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                read_db(PagedRpc([value]), "wikipedia", log=lambda *_: None)
        with self.assertRaises(RuntimeError):
            read_db(PagedRpc([[row(1)], [row(1)]]), "wikipedia", log=lambda *_: None)

    def test_http_application_error_is_not_retried(self):
        rpc = PagedRpc([RuntimeError("HTTP 403")])
        with self.assertRaises(RuntimeError):
            read_db(rpc, "wikipedia", log=lambda *_: None)
        self.assertEqual(len(rpc.calls), 1)

    @patch("collector.reconcile.time.sleep")
    def test_prune_does_not_write_after_incomplete_read(self, sleep):
        rpc = PagedRpc([[row(1)]] + [requests.ReadTimeout() for _ in range(3)])
        with self.assertRaises(requests.ReadTimeout):
            prune_stale("wikipedia", rpc, {2}, log=lambda *_: None)
        self.assertTrue(all(n == "reconcile_pages" for n, _ in rpc.calls))
