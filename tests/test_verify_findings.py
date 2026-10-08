import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from collector import verify_findings as v


class FakeMW:
    def __init__(self, replies):
        self.replies = iter(replies)
        self.calls = []

    def get(self, params):
        self.calls.append(dict(params))
        return next(self.replies)


class VerifyFindingsTests(unittest.TestCase):
    def strict(self, response, params):
        with patch.object(v.MediaWiki, 'get', return_value=response), contextlib.redirect_stdout(io.StringIO()):
            return v.VerificationMediaWiki('https://example.invalid').get(params)

    def test_omitted_title_is_failure_not_absence(self):
        with self.assertRaises(v.IncompleteResponse):
            v.ids_by_title(FakeMW([{'query': {'pages': []}}]), ['ערך'])

    def test_explicit_missing_is_absence(self):
        result = v.ids_by_title(FakeMW([{'query': {'pages': [{'title': 'ערך', 'missing': True}]}}]), ['ערך'])
        self.assertIsNone(result['ערך'])

    def test_omitted_content_page_is_failure(self):
        with self.assertRaises(v.IncompleteResponse):
            self.strict({'query': {'pages': []}}, {'pageids': '5', 'prop': 'revisions'})

    def test_hidden_content_is_failure(self):
        response = {'query': {'pages': [{'pageid': 5, 'revisions': [{'revid': 20, 'slots': {'main': {}}}]}]}}
        with self.assertRaises(v.IncompleteResponse):
            self.strict(response, {'pageids': '5', 'prop': 'revisions', 'rvprop': 'ids|content'})

    def test_warnings_fail_instead_of_partial_success(self):
        with self.assertRaises(v.IncompleteResponse):
            self.strict({'warnings': {'x': 'partial'}, 'query': {'pages': []}}, {'prop': 'info'})

    def test_raw_template_preserves_date_and_invalid_revision(self):
        raw = v.raw_template('{{מיון ויקיפדיה|דף=שם|גרסה=1|תאריך=אוקטובר 2026}}')
        self.assertEqual(raw['תאריך'], 'אוקטובר 2026')
        self.assertEqual(raw['גרסה'], '1')
        self.assertIsNone(v.parse_rev(raw['גרסה']))
        self.assertIsNone(v.raw_template('{{מיון ויקיפדיה|דף=שם}}')['תאריך'])

    def test_time_window_excludes_future_and_includes_source_interval(self):
        self.assertFalse(v.in_window('2026-10-09T00:00:00Z', 'wikipedia'))
        self.assertFalse(v.in_window(v.WATERMARK, 'wikipedia'))
        self.assertTrue(v.in_window('2026-10-08T09:15:00Z', 'wikipedia'))
        self.assertFalse(v.in_window('2026-10-08T09:30:00Z', 'wikipedia'))
        self.assertTrue(v.in_window('2026-10-08T09:30:00Z', 'mechalol'))

    def test_missing_creation_revision_does_not_prove_creation_date(self):
        mw = FakeMW([{'query': {'pages': [{'revisions': [{'timestamp': '2026-10-08T07:00:00Z', 'parentid': 99}]}]}}])
        self.assertIsNone(v.first_revision(mw, 1))

    def test_categories_collect_all_continuations(self):
        mw = FakeMW([{'query': {'pages': [{'categories': [{'title': 'א'}]}]}, 'continue': {'clcontinue': 'next'}},
                     {'query': {'pages': [{'categories': [{'title': 'ב'}]}]}}])
        self.assertEqual(v.categories_for(mw, 1), ['א', 'ב'])
        self.assertEqual(mw.calls[1]['clcontinue'], 'next')

    def test_category_continuation_loop_fails(self):
        response = {'query': {'pages': [{}]}, 'continue': {'clcontinue': 'same'}}
        with self.assertRaises(v.IncompleteResponse):
            v.categories_for(FakeMW([response, response]), 1)

    def test_omitted_revision_owner_is_failure(self):
        with self.assertRaises(v.IncompleteResponse):
            v.rev_owners(FakeMW([{'query': {'pages': []}}]), [123])
        self.assertEqual(v.rev_owners(FakeMW([{'query': {'pages': []}, 'badrevids': {'123': {}}}]), [123]), {123: None})

    def test_kept_uses_source_id_not_local_title(self):
        data = {'מצב': 'נקרא', 'כותרת_בתבנית': 'ישראל חיים וייס', 'דף_בוויקיפדיה': 42}
        with patch.object(v, 'template_info', return_value={v.KEPT_AFTER_DELETE: data}), \
             patch.object(v, 'page_by_id', return_value={'קיים': True, 'ns': 0, 'redirect': False}) as lookup, \
             patch.object(v, 'log_events', return_value=[]):
            result = v.check_kept(None, None)
        lookup.assert_called_once_with(None, 42)
        self.assertIn('מועמד מקור חי', result['מסקנה'])

    def test_missing_source_does_not_prove_deletion(self):
        with patch.object(v, 'template_info', return_value={v.KEPT_AFTER_DELETE: {'מצב': 'נקרא'}}):
            result = v.check_kept(None, None)
        self.assertIn('מחיקה לא הוכחה', result['מסקנה'])

    def test_existing_redirect_is_not_live_source(self):
        data = {'מצב': 'נקרא', 'דף_בוויקיפדיה': 42}
        with patch.object(v, 'template_info', return_value={v.KEPT_AFTER_DELETE: data}), \
             patch.object(v, 'page_by_id', return_value={'קיים': True, 'ns': 0, 'redirect': True}):
            self.assertIn('מחיקה לא הוכחה', v.check_kept(None, None)['מסקנה'])

    def test_missing_date_does_not_get_promoted_by_valid_link(self):
        data = {'מצב': 'נקרא', 'תבנית': {'דף': 'שם', 'גרסה': '12', 'תאריך': None}, 'דף_בוויקיפדיה': 42}
        with patch.object(v, 'NINETEEN', [1]), patch.object(v, 'template_info', return_value={1: data}), \
             patch.object(v, 'categories_for', return_value=[]):
            row = v.check_classification(None, None)['שורות'][0]
        self.assertIsNone(row['תאריך_גולמי'])
        self.assertEqual(row['סיווג_נוכחי_לפי_הכללים']['status'], 'imported_undocumented')

    def test_checkpoint_and_progress_survive_later_failure(self):
        def first(*args):
            return {'שאלה': 'א', 'שורות': [], 'מסקנה': 'נבדק'}
        def second(*args):
            raise v.IncompleteResponse('partial')
        with tempfile.TemporaryDirectory() as folder, patch.dict(v.CHECKS, {'first': first, 'second': second}, clear=True), \
             patch.object(v, 'VerificationMediaWiki'), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(v.run(Path(folder)), 1)
            data = json.loads((Path(folder) / 'findings_check.json').read_text())
        self.assertIn('מסקנה', data['first'])
        self.assertIn('שגיאה', data['second'])
        self.assertIn('התחלה: first', output.getvalue())
        self.assertIn('סיום: second', output.getvalue())


if __name__ == '__main__':
    unittest.main()
