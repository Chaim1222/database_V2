import unittest
from unittest.mock import patch

from collector import enrich, reconcile
from collector.cli import main


class Reply:
    def __init__(self, data):
        self.data = data

    def get(self, _params):
        return self.data


class EnrichmentRaceTests(unittest.TestCase):
    def setUp(self):
        enrich.SKIP_BUDGET['left'] = 20

    def tearDown(self):
        enrich.SKIP_BUDGET['left'] = 20

    def test_replaced_and_missing_titles_are_not_written(self):
        reply = Reply({'query': {'pages': [
            {'pageid': 9, 'title': 'א', 'length': 999},
            {'title': 'ב', 'missing': ''},
            {'pageid': 3, 'title': 'ג', 'length': 10}]}})
        rows = enrich.fetch_length(reply, [{'wiki_id': i, 'title': t} for i, t in enumerate('אבג', 1)])
        self.assertEqual(rows, [{'wiki_id': 3, 'length': 10}])
        self.assertEqual(enrich.SKIP_BUDGET['left'], 18)

    @patch('collector.enrich.time.sleep')
    def test_created_race_preserves_previous_result(self, _sleep):
        for page in ({'title': 'א', 'missing': True}, {'pageid': 9, 'title': 'א'}):
            self.assertEqual(enrich.fetch_created(Reply({'query': {'pages': [page]}}), [{'wiki_id': 1, 'title': 'א'}]), [])
        self.assertEqual(enrich.SKIP_BUDGET['left'], 18)

    def test_race_budget_stops_widespread_changes(self):
        enrich.SKIP_BUDGET['left'] = 0
        with self.assertRaises(RuntimeError):
            enrich.fetch_length(Reply({'query': {'pages': [{'title': 'א', 'missing': True}]}}), [{'wiki_id': 1, 'title': 'א'}])

    @patch('collector.enrich.time.sleep')
    def test_bad_answers_fail_without_consuming_race_budget(self, _sleep):
        for data in ({}, {'query': {'pages': []}}, {'query': {'pages': [{'pageid': 1, 'title': 'א'}]}},
                     {'query': {'pages': [{'title': 'א', 'length': 10}]}},
                     {'query': {'pages': [{'pageid': 1, 'title': 'א', 'length': -1}]}}):
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                enrich.fetch_length(Reply(data), [{'wiki_id': 1, 'title': 'א'}])
        with self.assertRaises(RuntimeError):
            enrich.fetch_created(Reply({'query': {'pages': [{'pageid': 1, 'title': 'א'}]}}), [{'wiki_id': 1, 'title': 'א'}])
        self.assertEqual(enrich.SKIP_BUDGET['left'], 20)

    def test_skipped_page_remains_pending_next_run(self):
        class Rpc:
            def __init__(self):
                self.applied = []

            def call(self, fn, payload):
                if fn == 'enrich_pending':
                    return [] if payload['p_after'] else [{'wiki_id': 1, 'title': 'א'}]
                self.applied.extend(payload['p_rows'])
        rpc = Rpc()
        self.assertEqual(enrich.run_group('length', {'wiki': Reply({'query': {'pages': [{'pageid': 9, 'title': 'א', 'length': 99}]}})}, rpc), 0)
        self.assertEqual(rpc.applied, [])
        self.assertEqual(enrich.run_group('length', {'wiki': Reply({'query': {'pages': [{'pageid': 1, 'title': 'א', 'length': 12}]}})}, rpc), 1)
        self.assertEqual(rpc.applied, [{'wiki_id': 1, 'length': 12}])


class ReconcilePolicyTests(unittest.TestCase):
    def run_case(self, fix=True, persist=True, fail_verify=False, title_gap=False):
        fields = {'status': 'imported_documented', 'source_type': 'wikipedia_documented',
                  'needs_attention': False, 'is_dictionary': False}
        titles = {i: str(i) for i in range(1, 101)}
        source_fields = {i: dict(fields) for i in titles}

        class Rpc:
            def __init__(self):
                self.changed = False
                self.calls = []

            def call(self, fn, payload):
                self.calls.append((fn, payload))
                if fn == 'sync_run_start':
                    return {'run_id': 'r', 'watermarks': {'mechalol/delta': '2026-10-05T00:00:00Z'}}
                if fn == 'reconcile_pages':
                    if self.changed and fail_verify:
                        raise RuntimeError('verification unavailable')
                    if payload['p_after']:
                        return []
                    rows = [{'page_id': i, 'title': t, **fields} for i, t in titles.items()]
                    if not self.changed or not persist:
                        rows[0]['needs_attention'] = True
                    if title_gap:
                        rows[1]['title'] = 'old title'
                    return rows
                if fn == 'sync_apply_mech_pages':
                    self.changed = True
                    return {}
                if fn == 'match_conflicts':
                    return []
                if fn == 'reconcile_record':
                    self.recorded = payload
        rpc = Rpc()
        with patch.object(reconcile, 'snapshot', return_value=(titles, source_fields)), \
                patch.object(reconcile, 'collect_window', return_value=(set(), set(), {})):
            if fail_verify:
                with self.assertRaises(RuntimeError):
                    reconcile.run_reconcile({'mechalol': Reply({})}, rpc, env={}, fix=fix)
                return rpc, None
            report = reconcile.run_reconcile({'mechalol': Reply({})}, rpc, env={}, fix=fix)
        return rpc, report

    def test_success_is_based_on_verified_state_and_keeps_before(self):
        rpc, report = self.run_case()
        self.assertTrue(report['ok'])
        self.assertEqual(report['sites'][0]['unexplained_pages'], 0)
        meta = rpc.recorded['p_snapshot_meta']['mechalol']
        self.assertEqual(meta['before_fix']['unexplained_pages'], 1)
        self.assertEqual(meta['fixed_classification'], 1)
        self.assertEqual(rpc.calls[-1][1]['p_status'], 'succeeded')

    def test_noop_write_and_uncorrectable_title_gap_stay_failed(self):
        for args in ({'persist': False}, {'title_gap': True}, {'fix': False}):
            with self.subTest(args=args):
                rpc, report = self.run_case(**args)
                self.assertFalse(report['ok'])
                self.assertEqual(rpc.calls[-1][1]['p_status'], 'failed')
                if not args.get('fix', True):
                    self.assertFalse(any(fn == 'sync_apply_mech_pages' for fn, _ in rpc.calls))

    def test_failed_verification_never_reports_success(self):
        rpc, _ = self.run_case(fail_verify=True)
        self.assertEqual(rpc.calls[-1][1]['p_status'], 'failed')
        self.assertFalse(any(fn == 'reconcile_record' for fn, _ in rpc.calls))

    def test_missing_window_reply_cannot_explain_a_gap(self):
        from collector.reconcile_compare import collect_window
        with self.assertRaises(RuntimeError):
            collect_window(lambda _params: {}, '2026-10-05T00:00:00Z', '2026-10-06T00:00:00Z')

    def test_cli_exit_status_matches_report(self):
        for ok, expected in ((True, 0), (False, 1)):
            with patch.dict('os.environ', {'SUPABASE_URL': 'test', 'SUPABASE_SERVICE_KEY': 'test'}), \
                    patch('collector.cli.Rpc'), patch('collector.cli.MediaWiki'), \
                    patch('collector.cli.run_reconcile', return_value={'ok': ok, 'sites': []}):
                self.assertEqual(main(['reconcile']), expected)
