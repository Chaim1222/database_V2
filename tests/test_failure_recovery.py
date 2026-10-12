"""Failure isolation, preservation and idempotent replay with local clients only."""
import contextlib
import io
import os
import tempfile
import subprocess
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from collector import cli, enrich, revcheck, sync, import_v1


class RecoveryTests(unittest.TestCase):
    def test_revision_failure_in_middle_preserves_old_finding_and_later_batch_runs(self):
        rows = [{"mech_id": i, "template_rev": 50} for i in range(1, 4)]
        class Rpc:
            def __init__(self):
                self.saved = {i: {"mech_id": i, "rev_task": "bad_rev"} for i in range(1, 4)}
                self.scopes = []
            def call(self, fn, p):
                if fn == 'rev_scope': return [] if p['p_after'] else rows
                self.scopes.append(p['p_scope_ids'])
                for mid in p['p_scope_ids']: self.saved.pop(mid, None)
                self.saved.update({r['mech_id']: r for r in p['p_rows']})
        rpc = Rpc()
        def check(_mw, part, _max):
            if part[0]['mech_id'] == 2: raise RuntimeError('incomplete reply')
            return []
        with patch.object(revcheck, 'BATCH', 1), patch.object(revcheck, 'fetch_max_rev', return_value=100), patch.object(revcheck, 'check_rows', side_effect=check):
            result = revcheck.run_revcheck(None, rpc, log=lambda _: None)
        self.assertEqual(rpc.scopes, [[1, 3]])
        self.assertEqual(set(rpc.saved), {2})
        self.assertEqual(result['failed_ids'], [2])
        with patch.object(revcheck, 'fetch_max_rev', return_value=100), patch.object(revcheck, 'check_rows', return_value=[]):
            revcheck.run_revcheck(None, rpc, log=lambda _: None)
            revcheck.run_revcheck(None, rpc, log=lambda _: None)
        self.assertEqual(rpc.saved, {})

    def test_revision_write_failure_does_not_block_next_database_page(self):
        applied = []
        def call(fn, p):
            if fn == 'rev_scope':
                return [{'mech_id': p['p_after'] + 1, 'template_rev': 0}] if p['p_after'] < 2 else []
            if p['p_scope_ids'] == [1]: raise RuntimeError('write failed')
            applied.extend(p['p_scope_ids'])
        with patch.object(revcheck, 'fetch_max_rev', return_value=100):
            result = revcheck.run_revcheck(None, SimpleNamespace(call=call), log=lambda _: None)
        self.assertEqual(applied, [2])
        self.assertEqual(result['failed_ids'], [1])

    def test_enrichment_continues_batch_and_retries_pending_next_run(self):
        pending = {i: {'wiki_id': i, 'title': str(i)} for i in (1, 2, 3)}
        written = {}
        def call(fn, p):
            if fn == 'enrich_pending': return [r for i, r in pending.items() if i > p['p_after']]
            for r in p['p_rows']:
                written[r['wiki_id']] = r
                pending.pop(r['wiki_id'], None)
        def fetch(_mw, rows):
            if rows[0]['wiki_id'] == 2: raise RuntimeError('bad response')
            return [{'wiki_id': r['wiki_id'], 'length': 12} for r in rows]
        rpc = SimpleNamespace(call=call)
        with patch.object(enrich, 'BATCH', 1), patch.dict(enrich.FETCHERS, {'length': ('wiki', fetch)}):
            result = enrich.run_group('length', {'wiki': None}, rpc, log=lambda _: None)
        self.assertEqual(set(written), {1, 3})
        self.assertEqual(set(pending), {2})
        self.assertFalse(result['complete'])
        with patch.dict(enrich.FETCHERS, {'length': ('wiki', lambda _, rows: [{'wiki_id': r['wiki_id'], 'length': 12} for r in rows])}):
            result = enrich.run_group('length', {'wiki': None}, rpc, log=lambda _: None)
            repeated = enrich.run_group('length', {'wiki': None}, rpc, log=lambda _: None)
        self.assertTrue(result['complete'])
        self.assertEqual(repeated['done'], 0)
        self.assertEqual(set(written), {1, 2, 3})

    def test_enrichment_outage_has_bounded_group_work(self):
        reads = []
        def fetch(*_):
            reads.append(1)
            raise RuntimeError('outage')
        rpc = SimpleNamespace(call=lambda *_: [{'wiki_id': i} for i in range(1, 10)])
        with patch.object(enrich, 'BATCH', 1), patch.dict(enrich.FETCHERS, {'length': ('wiki', fetch)}):
            result = enrich.run_group('length', {'wiki': None}, rpc, log=lambda _: None)
        self.assertEqual(len(reads), 3)
        self.assertTrue(result['stopped_early'])

    def test_cli_continues_next_group_and_returns_partial_only_at_end(self):
        calls = []
        def run(group, *_):
            calls.append(group)
            if group == 'length': raise RuntimeError('unavailable')
            return {'complete': True, 'done': 4}
        with patch.dict(os.environ, {'SUPABASE_URL': 'fixture', 'SUPABASE_SERVICE_KEY': 'fixture'}), patch.object(cli, 'Rpc'), patch.object(cli, 'MediaWiki'), patch.object(cli, 'run_group', side_effect=run), contextlib.redirect_stdout(io.StringIO()) as out:
            result = cli.main(['enrich', 'length', 'desc'])
        self.assertEqual(calls, ['length', 'desc'])
        self.assertEqual(result, 1)
        self.assertIn('python -m collector.cli enrich length', out.getvalue())

    def test_sync_runs_other_source_and_keeps_watermarks_on_partial_failure(self):
        calls, sites = [], []
        def call(fn, p):
            calls.append((fn, p))
            if fn == 'sync_run_start': return {'run_id': 'r', 'watermarks': {s + '/delta': '2026-10-12T00:00:00Z' for s in ('wikipedia', 'mechalol')}}
        def site(name, *_args, **_kwargs):
            sites.append(name)
            if name == 'wikipedia': raise RuntimeError('read failed')
            return {'live': 2}
        with patch.object(sync, 'sync_site', side_effect=site), self.assertRaises(RuntimeError):
            sync.run_sync({'wikipedia': None, 'mechalol': None}, SimpleNamespace(call=call))
        self.assertEqual(sites, ['wikipedia', 'mechalol'])
        finish = calls[-1][1]
        self.assertNotIn('p_watermarks', finish)
        self.assertEqual(finish['p_stats']['mechalol'], {'live': 2})

    def test_import_preserves_completed_rows_and_continues_categories_then_replays(self):
        saved, broken = set(), {2}
        def call(_fn, p):
            name = next(k for k, key in import_v1.KEYS.items() if p[key])
            ids = [r['id'] for r in p[import_v1.KEYS[name]]]
            if any(i in broken for i in ids): raise RuntimeError('temporary')
            added = len(set(ids) - saved)
            saved.update(ids)
            return {'inserted': {name: added}, 'skipped': {name: []}}
        data = {'manual': [{'id': 1}, {'id': 2}], 'blacklist': [{'id': 3}], 'feedback': [], 'locks': []}
        with patch.object(import_v1, 'CHUNK', 1):
            result = import_v1.import_chunked(SimpleNamespace(call=call), 'u', data)
            self.assertEqual(saved, {1, 3})
            self.assertEqual(result['failed_batches'][0]['offset'], 1)
            broken.clear()
            result = import_v1.import_chunked(SimpleNamespace(call=call), 'u', data)
        self.assertEqual(saved, {1, 2, 3})
        self.assertEqual(sum(result['inserted'].values()), 1)


class MigrationReadTests(unittest.TestCase):
    def run_migration(self, fail_count, history="present", check=False):
        source = Path(__file__).resolve().parents[1] / 'ops/apply_migrations.sh'
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base/'ops').mkdir(); (base/'db/migrations').mkdir(parents=True); (base/'bin').mkdir()
            (base/'ops/apply_migrations.sh').write_text(source.read_text())
            (base/'db/migrations/0001_test.sql').write_text('select 1;')
            stub = base/'bin/psql'
            stub.write_text('#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\np=Path(os.environ["FIXTURE_LOG"])\ns=p.read_text() if p.exists() else ""\np.write_text(s+" ".join(sys.argv[1:])+"\\n")\nif "-c" in sys.argv:\n    n=s.count("-c")\n    if n<int(os.environ["FIXTURE_FAILURES"]): sys.exit(1)\n    if "to_regclass" in " ".join(sys.argv):\n        print("f" if os.environ["FIXTURE_HISTORY"] == "missing" else "t")\n    elif os.environ["FIXTURE_HISTORY"] == "denied":\n        sys.exit(1)\n    else:\n        print("0001")\nelif os.environ["FIXTURE_HISTORY"] != "missing":\n    sys.exit(77)\n')
            stub.chmod(0o755)
            sleep = base/'bin/sleep'; sleep.write_text('#!/bin/sh\nexit 0\n'); sleep.chmod(0o755)
            env = dict(os.environ, PATH=str(base/'bin')+os.pathsep+os.environ['PATH'], DATABASE_URL='fixture', FIXTURE_LOG=str(base/'calls'), FIXTURE_FAILURES=str(fail_count), FIXTURE_HISTORY=history)
            result = subprocess.run(['bash', str(base/'ops/apply_migrations.sh')] + (['--check'] if check else []), env=env, capture_output=True, text=True)
            return result, (base/'calls').read_text()

    def test_history_outage_never_attempts_migrations(self):
        result, calls = self.run_migration(3)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls.count('-c'), 3)
        self.assertNotIn('-f ', calls)

    def test_history_recovers_before_any_write(self):
        result, calls = self.run_migration(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('-c'), 3)
        self.assertNotIn('-f ', calls)

    def test_missing_registry_bootstraps_only_after_successful_catalog_read(self):
        result, calls = self.run_migration(0, history='missing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('to_regclass', calls)
        self.assertNotIn('select version', calls)
        self.assertIn('-f 0001_test.sql', calls)

    def test_missing_registry_check_mode_lists_pending_without_writes(self):
        result, calls = self.run_migration(0, history='missing', check=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('0001_test.sql', result.stdout)
        self.assertNotIn('-f ', calls)

    def test_existing_registry_read_failure_never_bootstraps(self):
        result, calls = self.run_migration(0, history='denied')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls.count('select version'), 3)
        self.assertNotIn('-f ', calls)


class MaxlagRetryTests(unittest.TestCase):
    def response(self, code=200, body=None, retry=None):
        import requests
        response = requests.Response()
        response.status_code = code
        response.headers = {} if retry is None else {'Retry-After': retry}
        response.json = lambda: body if body is not None else {'query': {}}
        return response

    def run_recovery(self, first, use_post=False):
        from collector.mw import MediaWiki
        from unittest.mock import Mock
        session, waits = Mock(headers={}), []
        method = session.post if use_post else session.get
        method.side_effect = [first, self.response()]
        mw = MediaWiki('https://fixture.invalid/api.php', session=session, sleep=waits.append)
        result = mw.get({'titles': 'a' * 700} if use_post else {'action': 'query'})
        self.assertEqual(result, {'query': {}})
        self.assertEqual(method.call_count, 2)
        return waits

    def test_http_200_maxlag_honors_retry_after_on_get_and_post(self):
        for use_post in (False, True):
            with self.subTest(post=use_post):
                self.assertEqual(self.run_recovery(self.response(body={'error': {'code': 'maxlag'}}, retry='17'), use_post), [17])

    def test_missing_or_invalid_lag_header_waits_at_least_five_seconds(self):
        for header in (None, 'invalid', '-1', '1'):
            with self.subTest(header=header):
                self.assertEqual(self.run_recovery(self.response(body={'error': {'code': 'maxlag'}}, retry=header)), [5])

    def test_server_wait_is_not_shortened_to_previous_120_second_cap(self):
        self.assertEqual(self.run_recovery(self.response(body={'error': {'code': 'maxlag'}}, retry='180')), [180])

    def test_http_throttling_still_honors_header(self):
        for code in (429, 503):
            with self.subTest(code=code):
                self.assertEqual(self.run_recovery(self.response(code=code, retry='17')), [17])

    def test_persistent_lag_is_bounded_and_does_not_sleep_after_last_attempt(self):
        import requests
        from collector.mw import MediaWiki
        from unittest.mock import Mock
        waits, session = [], Mock(headers={})
        session.get.return_value = self.response(body={'error': {'code': 'maxlag'}})
        with self.assertRaises(requests.RequestException):
            MediaWiki('https://fixture.invalid/api.php', session=session, sleep=waits.append).get({})
        self.assertEqual(session.get.call_count, 8)
        self.assertEqual(waits, [5, 5, 5, 8, 16, 32, 64])
