var levelParams = (typeof levelParams !== 'undefined') ? levelParams : require('./filters.js').levelParams;
// הגדרת הטאבים. כל טאב קורא view אחד ב-api, בעמודות קבועות, עם עימוד. ראו DESIGN.md סעיף 8.
var LEVELS = [
	{ value: 'problem', label: 'בעיה ודאית' }, { value: 'review', label: 'לבדיקה' }, { value: 'high', label: 'חשד גבוה (הקשר)' },
	{ value: 'medium', label: 'חשד בינוני (הקשר)' }, { value: 'low', label: 'חשד נמוך (הקשר)' }, { value: 'wording', label: 'דורש ניסוח' },
	{ value: 'clean', label: 'נקי' }, { value: 'not_scanned', label: 'לא נסרק' }, { value: 'stale', label: 'תוצאה ישנה' }
];
var YES_NO = [{ value: 'true', label: 'כן' }, { value: 'false', label: 'לא' }];

var TAB_GROUPS = [
	{ key: 'import', label: 'ייבוא', tabs: ['missing', 'requests', 'missing_redirect', 'rav', 'culture'] },
	{ key: 'maint', label: 'תחזוקה', tabs: ['undoc', 'template', 'moved', 'locked', 'redirect', 'badrev', 'deletedrev'] },
	{ key: 'stats', label: 'מערכת', tabs: ['stats', 'system'] }
];

var TABS = {
	missing: {
		label: 'חסר במכלול', view: 'v_missing', order: 'created_at.asc.nullslast,id.asc', baseFilters: [['mech_redirect', 'eq.false']],
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'topic', label: 'נושא' }, { key: 'level', label: 'רמה', computed: true },
			{ key: 'has_images', label: 'תמונות' }, { key: 'created_at', label: 'נוצר בוויקיפדיה' }, { key: 'wikidata_desc', label: 'תיאור' }],
		filters: [
			{ key: 'level', label: 'רמה', options: LEVELS, toParams: function (v, s) { return levelParams(s.method, s.mode, v); } },
			{ key: 'has_images', label: 'תמונות', options: YES_NO, toParams: function (v) { return [['has_images', 'eq.' + v]]; } },
			{ key: 'topic', label: 'נושא', text: true }
		],
		wiki: true, details: true, actions: ['import', 'manual', 'exclude']
	},
	missing_redirect: {
		label: 'קיים במכלול כהפניה', view: 'v_missing', order: 'created_at.asc.nullslast,id.asc', baseFilters: [['mech_redirect', 'eq.true']],
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'topic', label: 'נושא' }, { key: 'level', label: 'רמה', computed: true }, { key: 'created_at', label: 'נוצר בוויקיפדיה' }],
		filters: [{ key: 'level', label: 'רמה', options: LEVELS, toParams: function (v, s) { return levelParams(s.method, s.mode, v); } }],
		wiki: true, details: true, actions: ['manual', 'exclude']
	},
	rav: {
		label: 'התאמות "הרב/רבי" לבדיקה', view: 'v_rav_review', order: 'wiki_title.asc,mech_title.asc', searchColumn: 'wiki_title',
		columns: [{ key: 'wiki_title', label: 'ערך בוויקיפדיה' }, { key: 'mech_title', label: 'ערך במכלול' }, { key: 'mech_status', label: 'סטטוס במכלול' }],
		filters: [], actions: ['manual'], idKey: 'wiki_id', rowKey: function (r) { return r.wiki_id + '-' + r.mech_id; }
	},
	undoc: {
		label: 'ללא תבנית מיון', view: 'v_undocumented', order: 'title.asc,id.asc', mech: true,
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'source_type', label: 'מקור' }], filters: [], actions: []
	},
	template: {
		label: 'בעיות תבנית', view: 'v_template_issues', order: 'title.asc,id.asc', mech: true,
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'outcome', label: 'מצב' }, { key: 'template_ref', label: 'כותרת בתבנית' }, { key: 'checked_at', label: 'נבדק' }],
		filters: [{ key: 'outcome', label: 'מצב', options: [{ value: 'unresolved', label: 'כותרת לא קיימת' }, { value: 'denied', label: 'דף נעול' }] }], actions: []
	},
	moved: {
		label: 'הועברו בוויקיפדיה', view: 'v_moves', order: 'moved_at.desc,id.asc', mech: true,
		columns: [{ key: 'title', label: 'כותרת במכלול' }, { key: 'wikipedia_title', label: 'כותרת חדשה בוויקיפדיה' }, { key: 'moved_at', label: 'הועבר' }], filters: [], actions: []
	},
	locked: {
		label: 'נעולים', view: 'v_locks', order: 'title.asc', searchColumn: 'title',
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'level', label: 'סוג נעילה' }, { key: 'detected_by', label: 'זוהה על ידי' }, { key: 'detected_at', label: 'זוהה' }],
		filters: [{ key: 'level', label: 'סוג נעילה', options: [{ value: 'read', label: 'קריאה' }, { value: 'read-semi', label: 'קריאה (חלקית)' }, { value: 'create', label: 'יצירה' }] }],
		actions: [], rowKey: function (r) { return r.site + '-' + r.page_id + '-' + r.title; }
	},
	// משימות גרסה (N7): view אחד, ארבעה טאבים לפי rev_task (collector/revcheck.py; הכללים בהערת המודול)
	redirect: {
		label: 'הפכו להפניה', view: 'v_rev_tasks', order: 'title.asc,id.asc', mech: true, baseFilters: [['rev_task', 'eq.redirect']],
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'rev_page_title', label: 'הפניה בוויקיפדיה' }, { key: 'rev_id', label: 'גרסה' }, { key: 'linked_title', label: 'מקושר אל' }], filters: [], actions: []
	},
	badrev: {
		label: 'גרסה שגויה', view: 'v_rev_tasks', order: 'title.asc,id.asc', mech: true, baseFilters: [['rev_task', 'eq.bad_rev']],
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'rev_id', label: 'גרסה בתבנית' }, { key: 'rev_page_title', label: 'דף הגרסה' }, { key: 'linked_title', label: 'מקושר אל' }], filters: [], actions: []
	},
	deletedrev: {
		label: 'נמחקו לפי גרסה', view: 'v_rev_tasks', order: 'title.asc,id.asc', mech: true, baseFilters: [['rev_task', 'eq.deleted_by_rev']],
		columns: [{ key: 'title', label: 'כותרת' }, { key: 'rev_id', label: 'גרסה בתבנית' }, { key: 'linked_title', label: 'מקושר אל' }], filters: [], actions: []
	},
	requests: { label: 'בקשות ייבוא', special: 'requests' },
	culture: { label: 'דפים לטיפול - תרבות', special: 'culture' },
	stats: { label: 'סטטיסטיקה', special: 'stats' },
	system: { label: 'מצב המערכת', special: 'system' }
};

var STAT_LABELS = { wiki_pages: 'דפי ויקיפדיה', mech_pages: 'ערכי מכלול', missing: 'חסר במכלול', rav_review: 'התאמות הרב/רבי', locks: 'נעולים', rev_tasks: 'משימות גרסה' };

// הרמה המוצגת לשורה לפי השיטה והמצב שנבחרו
function rowLevel(row, method, mode) {
	if (row.scan_state === 'not_scanned') return 'not_scanned';
	var level = row[(method === 'ctx' ? 'verdict_ctx_' : 'verdict_list_') + mode];
	if (method === 'ctx' && level === 'review') return row['suspicion_' + mode] || 'review';
	return level || '';
}

if (typeof module !== 'undefined') module.exports = { TABS: TABS, TAB_GROUPS: TAB_GROUPS, rowLevel: rowLevel, STAT_LABELS: STAT_LABELS };
