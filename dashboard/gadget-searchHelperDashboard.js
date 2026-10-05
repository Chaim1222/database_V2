(function () {
	'use strict';

	// ===== זיהוי העמוד - רק מיוחד:דף ריק/ניהול ייבוא, לא בשום עמוד אחר =====
	if (mw.config.get('wgCanonicalSpecialPageName') !== 'Blankpage') return;
	var wgPageName = mw.config.get('wgPageName') || '';
	if (!/\/ניהול_ייבוא$/.test(wgPageName)) return;

	// ===== הגדרות חיבור - לערוך כאן אם צריך =====
	// שני מסדים: הישן (v1, public) והחדש (v2, סכמת api עם views בשמות של v1; ראו database_V2 מיגרציה 0014).
	// הבחירה נשמרת בדפדפן ומשתנה מפאנל הניהול (מנהלים בלבד, כמו שאר הפאנל). ברירת המחדל: v1.
	var BACKENDS = {
		v1: { label: 'מסד ישן (v1)', url: 'https://hgsyzaghedqsypisbvev.supabase.co', key: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhnc3l6YWdoZWRxc3lwaXNidmV2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYzNTY2ODgsImV4cCI6MjEwMTkzMjY4OH0.eDPO3n3OHvmndWDvgF-istBP2NhY5W20erG3zztm7vs', profile: null },
		v2: { label: 'מסד חדש (v2)', url: 'https://ukzijtrpchvmoxlslxpz.supabase.co', key: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVremlqdHJwY2h2bW94bHNseHB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyMTU1MzMsImV4cCI6MjEwNjc5MTUzM30.QCUKSOb1oOSwUPurOOhubPJFoSrQCUsClCSHEBp0BH8', profile: 'api' }
	};
	var BACKEND_STORAGE_KEY = 'mchl-backend';
	function readBackendName() {
		try { var v = localStorage.getItem(BACKEND_STORAGE_KEY); if (v && BACKENDS[v]) return v; } catch (e) { /* ברירת מחדל */ }
		return 'v1';
	}
	var BACKEND_NAME = readBackendName();
	var SUPABASE_URL = BACKENDS[BACKEND_NAME].url;
	var SUPABASE_ANON_KEY = BACKENDS[BACKEND_NAME].key;
	var PG_PROFILE = BACKENDS[BACKEND_NAME].profile;   // null = public (v1); 'api' = v2
	// רענון התחזוקה (maintRpc) נתמך רק ב-v1; שיוך ידני ומשוב סינון נתמכים בשני המסדים
	function assertWritable() {
		if (PG_PROFILE) throw new Error('הפעולה אינה נתמכת במסד החדש (v2). אפשר לחזור למסד הישן בפאנל הניהול.');
	}
	function profileHeaders(h) {
		if (PG_PROFILE) { h['Accept-Profile'] = PG_PROFILE; h['Content-Profile'] = PG_PROFILE; }
		return h;
	}

	var NEW_ARTICLE_CUTOFF_DAYS = 14;
	function newArticleCutoffIso() {
		return new Date(Date.now() - NEW_ARTICLE_CUTOFF_DAYS * 24 * 60 * 60 * 1000).toISOString();
	}

	var SOURCE_TYPE_LABELS = {
		created: 'נוצר במכלול', translated: 'תורגם במכלול', pirushon: 'פירושון',
		chabadpedia: 'ייבוא מחב"דפדיה', wikishiva: 'ייבוא מוויקישיבה',
		wikipedia_documented: 'מתועד מוויקיפדיה', missing_sort: 'חסר תבנית מיון', unknown: 'לא ידוע'
	};
	var COLUMN_LABELS = {
		title: 'כותרת', status: 'סטטוס', source_type: 'מקור',
		match_type: 'סוג התאמה', wikipedia_id: 'קישור לוויקיפדיה', checked_at: 'נבדק בתאריך',
		wikidata_desc: 'תיאור (ויקינתונים)', created_at: 'תאריך יצירה בוויקיפדיה',
		mechalol_redirect_exists: 'קיים במכלול כהפניה', task_type: 'סוג משימה', old_title: 'השם הקודם בוויקיפדיה', renamed_at: 'הועבר בתאריך', via: 'זוהה לפי', rev_page_title: 'הדף של הגרסה', linked_title: 'מקושר היום',
		manual_match_action: 'שיוך ידני',
		wikipedia_title: 'ערך בוויקיפדיה', mechalol_title: 'דף מקביל במכלול',
		mechalol_status: 'סטטוס במכלול', candidate_count: 'מספר מועמדים',
		mechalol_id: 'מזהה מכלול', lock_level: 'סוג נעילה', lock_source: 'איך זוהה', detected_at: 'זוהה בתאריך',
		update_date: 'עודכן לאחרונה', update_bucket: 'טווח עדכון',
		update_change: 'שינוי בוויקיפדיה', update_action: '', fix_source_action: '',
		sort_template_date: 'עודכן לאחרונה (חודש)', sort_template_rev: 'גרסת הבסיס',
		verdict: 'רמת תוכן', has_images: 'תמונות', topic: 'נושא', wf_matches: 'מילים', import_action: '', expand: ''
	};

	// ===== סינון תוכן (word-filter) - טאבי "חסר במכלול" =====
	// התוצאות מחושבות מראש ב-word-filter/tools/scan-missing.js (GitHub Actions)
	// ונשמרות ב-word_filter_results; ה-view report_missing_word_filter מצרף אותן
	// לדוח. לכל ערך שתי פסיקות: לפי הרשימות המאושרות (verdict) ולפי הרשימות
	// כולל ההצעות שעוד לא אושרו (verdict_suggested) - בורר "רשימות" בסרגל.
	// פרטי ההתאמות (המילה והמשפט שלה) נשלפים רק כשפותחים שורה.
	var WF_LEVELS = {
		problem: { label: 'בעיה ודאית', cls: 'mchl-alert' },
		review: { label: 'לבדיקה', cls: 'mchl-review' },
		wording: { label: 'דורש ניסוח', cls: 'mchl-neutral' },
		clean: { label: 'נקי', cls: 'mchl-wiki' },
		names: { label: 'שמות הקודש', cls: 'mchl-neutral' }
	};
	var WF_TOPICS = { modesty: 'צניעות', age: 'גיל העולם', names: 'שמות הקודש', faith: 'אמונה ונצרות', dating: 'תיארוך ומדע', wiki: 'שאריות מוויקיפדיה' };
	var wfMode = 'a'; // a = רשימות מאושרות, s = כולל הצעות
	// שיטה: ctx = לפי הקשר (רמות חשד בתוך "לבדיקה" - המילה והמשפט שלה, ראו
	// word-filter/analysis/word-rates.md); list = לפי הרמה שברשימה בלבד.
	var wfMethod = 'ctx';
	var wfLevelChoice = 'clean';
	var wfDetailsCache = new Map();
	var wfSummary = null; // שורות report_missing_word_filter_summary (למחוון)
	// רשת ביטחון: התאמות בקוד שהקורא לא רואה (יעד קישור, הערה מוסתרת, קובץ...).
	// לא נספרות ברמה; מסנן נפרד (hidden_count) ורשימה נפרדת בשורת ההקשר.
	var wfHiddenChoice = ''; // '' / 'with' / 'without'
	var WF_HIDDEN_KINDS = { l: 'יעד קישור', c: 'הערה מוסתרת', f: 'קובץ', m: 'תבנית', p: 'שם פרמטר', k: 'קטגוריה / מיון', u: 'כתובת', h: 'תגית', x: 'קוד' };
	function wfHiddenColumn() { return wfMode === 's' ? 'hidden_count_suggested' : 'hidden_count'; }
	// שמות הקודש (נושא names) - קטגוריה נפרדת, לא בעיה, לא חשד ולא ניסוח (הכרעת חיים 2026-09-27):
	// לא משפיעים על הרמה; מסנן נפרד (names_count) וקבוצה נפרדת בשורת ההקשר.
	var wfNamesChoice = ''; // '' / 'with' / 'without'
	function wfNamesColumn() { return wfMode === 's' ? 'names_count_suggested' : 'names_count'; }
	// מועמד לייבוא מילוני (עמודת dictionary - word-filter/dictionary.js): ערכי ספורט,
	// מוזיקה, סרטים, שחקנים, טלוויזיה וספרות, לפי תבנית המידע והקטגוריות. לא משפיע על הרמה.
	var wfDictChoice = ''; // '' / 'without' / 'only'
	// נושא הערך (עמודת topic - word-filter/topics.js). בחירה של כמה נושאים; ריק = הכול.
	// הקודים והשמות - אותו סדר כמו TOPICS ב-topics.js.
	var WF_TOPIC_GROUPS = [
		{ label: 'מיוחדים', items: [['disambig', 'פירושונים'], ['years', 'ערכי שנים ותאריכים'], ['lists', 'רשימות'],
			['dictionary', 'ערך מילוני'], ['sensitive', 'נושאים בעייתיים']] },
		{ label: 'אישים', items: [['people_science', 'מדע, רפואה ואקדמיה'], ['people_politics', 'פוליטיקה, ממשל ואצולה'], ['people_congress', 'חברי קונגרס אמריקאים'],
			['people_art', 'אמנות חזותית ואדריכלות'], ['people_literature', 'ספרות ועיתונות'], ['people_stage', 'קולנוע, במה ובידור'],
			['people_military', 'צבא וביטחון'], ['people_public', 'חינוך ופעילות ציבורית'], ['people_rabbis', 'רבנים ואישי יהדות'],
			['people_clergy', 'אנשי דת אחרים'], ['people_business', 'עסקים'], ['people_law', 'משפט'], ['people_crime', 'פשע'], ['people_other', 'אחר']] },
		{ label: 'יצירות ותרבות', items: [['art', 'יצירות אמנות'], ['culture', 'תרבות, ספורט ופרסים']] },
		{ label: 'מקומות ומבנים', items: [['geo', 'גאוגרפיה ומקומות'], ['buildings', 'מבנים ואתרים']] },
		{ label: 'היסטוריה וחברה', items: [['history', 'היסטוריה וצבא'], ['politics', 'פוליטיקה, משפט וכלכלה'], ['religion', 'דת ואמונה'],
			['orgs', 'ארגונים, מוסדות וחברות'], ['society', 'חברה, שפה ואורח חיים']] },
		{ label: 'מדע וטכנולוגיה', items: [['nature', 'טבע, מדעים ומתמטיקה'], ['medicine', 'רפואה ובריאות'], ['tech', 'טכנולוגיה ותחבורה']] },
		{ label: 'לא סווג', items: [['other', 'אחר']] }
	];
	var WF_TOPIC_LABELS = {};
	WF_TOPIC_GROUPS.forEach(function (g) {
		g.items.forEach(function (it) { WF_TOPIC_LABELS[it[0]] = g.label === 'אישים' ? 'אישים: ' + it[1] : it[1]; });
	});
	var wfTopicChoice = []; // קודים שנבחרו
	var WF_SUSPICION = {
		high: { label: 'לבדיקה – חשד גבוה', cls: 'mchl-review-high' },
		medium: { label: 'לבדיקה – חשד בינוני', cls: 'mchl-review' },
		low: { label: 'לבדיקה – חשד נמוך', cls: 'mchl-review-low' }
	};
	function wfColumn() {
		var base = wfMethod === 'ctx' ? 'ctx_verdict' : 'verdict';
		return wfMode === 's' ? base + '_suggested' : base;
	}
	function wfSuspicionColumn() { return wfMode === 's' ? 'ctx_suspicion_suggested' : 'ctx_suspicion'; }
	// הרמה של שורה (בעמודות ה-view) לפי השיטה והרשימות שנבחרו:
	// problem / high / medium / low / review (בשיטת הרשימה) / wording / clean / null.
	function wfRowLevel(row) {
		var level = row[wfColumn()];
		if (level === 'review' && wfMethod === 'ctx') return row[wfSuspicionColumn()] || 'review';
		return level || null;
	}
	// מפתח ייחודי לשורה. ברוב ה-views זה id; ב-report_rav_prefix_normalization
	// אין id - כל שורה היא זוג (ערך ויקיפדיה, מועמד במכלול).
	function rowIdOf(row) {
		var cfg = VIEWS[activeTab];
		return String(cfg && cfg.rowId ? cfg.rowId(row) : row.id);
	}
	var VIEWS = {
		// ארבעת טאבי הגרסה: סינון של report_rev_tasks לפי rev_task, ש-match.py מחשב לפי `גרסה=` בתבנית
		// (scripts/rev_match.py; migrations/migration_add_rev_task.sql). ההחלטות לפי כללי חיים (2026-10-01).
		// ערכים שהדף שלהם בוויקיפדיה הועבר ואצלנו עדיין השם הישן (בכותרת או בתבנית). נבנה ישר מטבלת הדלתא wikipedia_renames,
		// ולכן מתעדכן כל לילה (migrations/migration_add_wikipedia_moves_report.sql).
		moved: {
			view: 'report_wikipedia_moves', label: 'הועברו בוויקיפדיה',
			columns: ['title', 'old_title', 'wikipedia_title', 'renamed_at', 'via', 'status'], filters: [],
			order: 'renamed_at.desc,id.asc'
		},
		redirect: {
			view: 'report_rev_tasks', label: 'הפכו להפניה',
			columns: ['title', 'rev_page_title', 'sort_template_rev', 'linked_title', 'status'], filters: [],
			baseFilters: [['rev_task', 'eq.redirect']]
		},
		// גרסה 0/1/חסרה/לא קיימת, גרסה של מרחב שם אחר, או של דף אחר מזה שהכותרת מקשרת אליו (לא ידוע אם
		// הכותרת הייתה נכונה והדף הועבר, או שהגרסה שגויה מלכתחילה).
		badrev: {
			view: 'report_rev_tasks', label: 'גרסה שגויה',
			columns: ['title', 'sort_template_rev', 'rev_page_title', 'linked_title', 'status'], filters: [],
			displayColumns: ['title', 'sort_template_rev', 'rev_page_title', 'linked_title', 'status', 'fix_source_action'],
			baseFilters: [['rev_task', 'eq.bad_rev']]
		},
		deletedrev: {
			view: 'report_rev_tasks', label: 'נמחקו לפי גרסה',
			columns: ['title', 'sort_template_rev', 'linked_title', 'status'], filters: [],
			displayColumns: ['title', 'sort_template_rev', 'linked_title', 'status', 'fix_source_action'],
			baseFilters: [['rev_task', 'eq.deleted_by_rev']]
		},
		undoc: { view: 'report_undocumented_import', label: 'ללא תבנית מיון', columns: ['title', 'source_type', 'match_type', 'wikipedia_id'], displayColumns: ['title', 'source_type', 'match_type', 'wikipedia_id', 'fix_source_action'], filters: [] },
		// "חסר במכלול" מופרד לשני טאבים: כותרות שבאמת אין להן כלום במכלול,
		// מול כותרות שקיימות במכלול כהפניה (הערך כנראה קיים שם בשם אחר -
		// פעולה שונה לגמרי: לבדוק את יעד ההפניה, לא לייבא).
		missing: {
			view: 'report_missing_word_filter', label: 'חסר במכלול',
			// columns - לייצוא; displayColumns - מה שמוצג בטבלה (התיאור מוויקינתונים מתחת לכותרת).
			columns: ['title', 'verdict', 'topic', 'has_images', 'created_at', 'mechalol_redirect_exists', 'checked_at', 'wikidata_desc'], filters: [],
			displayColumns: ['title', 'topic', 'verdict', 'wf_matches', 'has_images', 'created_at', 'import_action', 'expand'],
			baseFilters: [['mechalol_redirect_exists', 'not.is.true']],
			// הישנים קודם (תאריך יצירה בוויקיפדיה); בלי תאריך (כ-9%) בסוף; id לסדר יציב בדפדוף. הייצוא משתמש באותו סדר.
			order: 'created_at.asc.nullslast,id.asc',
			titleLink: 'edit', wikidata: true, easyImport: true, redirectFilter: true, lockable: true, manualMatch: true
		},
		missing_redirect: {
			view: 'report_missing_word_filter', label: 'קיים במכלול כהפניה',
			columns: ['title', 'verdict', 'topic', 'has_images', 'created_at', 'checked_at', 'wikidata_desc'], filters: [],
			displayColumns: ['title', 'topic', 'verdict', 'wf_matches', 'has_images', 'created_at', 'import_action', 'expand'],
			baseFilters: [['mechalol_redirect_exists', 'is.true']],
			titleLink: 'edit', wikidata: true, easyImport: true, manualMatch: true
		},
		// ערכים שוויקיפדיה התקדמה בהם מאז העדכון האחרון (source_state = 'ahead', ראו
		// SOURCE_TRACKING_NOTES.md). זה גבול עליון: גם שחזור או עריכה קטנה נספרים, ולכן
		// כל שורה מקושרת להשוואת גרסאות בוויקיפדיה. הממוין לפי חודש העדכון המתועד
		// (`תאריך=`), הישנים קודם. שובר שוויון לפי id, כי החודש לא ייחודי והעימוד יקפוץ בלעדיו.
		update: {
			view: 'report_source_update', label: 'עדכון',
			columns: ['title', 'sort_template_date', 'update_bucket', 'sort_template_rev', 'wikipedia_id'],
			displayColumns: ['title', 'update_date', 'update_change', 'update_action'],
			filters: [{
				key: 'update_bucket', label: 'עודכן',
				options: ['בשנה האחרונה', 'לפני שנה עד שנתיים', '2020 עד לפני שנתיים', 'לפני 2020', 'ללא תאריך']
			}],
			order: 'sort_template_date.asc.nullslast,id.asc', titleLink: 'edit', freshness: true, liveChange: true,
			group: 'wikiupdate',
			// זמני: מוצג רק למי שמחובר עם משתמש וסיסמה (פאנל הניהול), כמו שיוך כותרות. להסרה: למחוק את השורה.
			requiresLogin: true
		},
		// דפים נעולים שהמערכת יודעת עליהם: נעולים לקריאה (בדיקת התבנית נדחתה, או שזוהו בבדיקת החסרים) ונעולים
		// ליצירה (הרשימה השחורה). ה-view: report_locked_pages (migrations/migration_add_locked_pages_report.sql).
		locked: {
			view: 'report_locked_pages', label: 'נעולים',
			columns: ['title', 'lock_level', 'lock_source', 'wikipedia_id', 'detected_at'],
			filters: [{ key: 'lock_level', label: 'סוג נעילה', options: ['נעול לקריאה', 'נעול ליצירה'] }],
			order: 'lock_level.asc,title.asc', titleLink: 'mechalol-read',
			// נעולים לקריאה - פתוח לכולם; נעולים ליצירה (הרשימה השחורה) - רק למי שמחובר עם משתמש וסיסמה (פאנל הניהול).
			// בצד הלקוח בלבד, כמו requiresLogin: הנתונים עצמם קריאים ל-anon.
			loginOnly: { key: 'lock_level', values: ['נעול ליצירה'] }
		},
		// ערכי ויקיפדיה שהוצאו מ"חסר במכלול" רק בגלל כותרת זהה אחרי הסרת
		// "הרב"/"רבי" - לא התאמה ודאית, דורש אישור אנושי. ה-view היה קיים
		// אבל לא הוצג בגאדג'ט.
		rav: {
			view: 'report_rav_prefix_normalization', label: 'התאמות "הרב/רבי" לבדיקה',
			columns: ['wikipedia_title', 'mechalol_title', 'mechalol_status', 'candidate_count'], filters: [],
			rowId: function (r) { return r.wikipedia_id + '-' + r.mechalol_id; },
			countColumn: 'wikipedia_id', searchColumn: 'wikipedia_title', titleColumn: 'wikipedia_title',
			order: 'wikipedia_title.asc', exportIdColumns: ['wikipedia_id', 'mechalol_id']
		}
	};
	// טאב "דפים לטיפול - תרבות" - לא מבוסס Supabase כמו VIEWS למעלה,
	// אלא שליפה חיה מה-API של המכלול עצמו (רשימת חברי קטגוריה בלבד -
	// אין תוכן בדפים האלה מלבד תבנית הסיווג, אז אין טעם/צורך לשלוף
	// אותם דרך מסד הנתונים בכלל). ראו EXTRA_TABS, cultureState,
	// loadCultureSubcats/loadCultureMembers למטה.
	var EXTRA_TABS = { requests: { label: 'בקשות ייבוא' }, culture: { label: 'דפים לטיפול - תרבות' }, stats: { label: 'נתונים סטטיסטיים' } };
	// הטאבים בשתי שורות: קבוצה, ומתחתיה הטאבים שלה.
	var TAB_GROUPS = [
		{ key: 'import', label: 'ייבוא', tabs: ['missing', 'requests', 'missing_redirect', 'rav', 'culture'] },
		{ key: 'update', label: 'עדכון', tabs: ['update'] },
		{ key: 'maint', label: 'תחזוקה', tabs: ['moved', 'redirect', 'badrev', 'deletedrev', 'undoc', 'locked'] },
		{ key: 'stats', label: 'נתונים סטטיסטיים', tabs: ['stats'] }
	];
	// טאב עם group (ב-VIEWS) מוצג רק למי שדרגתו לפחות כדרגת הקבוצה. זו בדיקת נראות בצד
	// הלקוח בלבד, לא הגנה: הנתונים עצמם קריאים ל-anon.
	function tabAllowed(key) {
		var v = VIEWS[key];
		if (v && v.requiresLogin && !serviceKeyConnected) return false;
		return !(v && v.group && userLevel < (GROUP_LEVELS[v.group] || Infinity));
	}
	function groupOfTab(key) { return TAB_GROUPS.filter(function (g) { return g.tabs.indexOf(key) >= 0; })[0] || TAB_GROUPS[0]; }
	var CATEGORY_MAINTENANCE_CULTURE = 'קטגוריה:דפים לטיפול תרבות';
	// יחסי בכוונה, לא כתובת מלאה - הגאדג'ט רץ כבר בתוך הדומיין של
	// המכלול (בניגוד לקובץ dashboard.html העצמאי, שצריך כתובת מלאה +
	// origin=* ל-CORS). wgScriptPath מתאים את עצמו אוטומטית לכל
	// התקנת מדיה-ויקי, לא קבוע-קשיח.
	var MECHALOL_API = mw.config.get('wgScriptPath') + '/api.php';
	var STAT_DEFS = [
		{ key: 'wiki', table: 'wikipedia_pages', estimated: true, statId: 'mchl-stat-wiki-total', spinId: 'mchl-spin-wiki', warnId: 'mchl-warn-wiki', warnMsg: 'לא ניתן לקרוא את wikipedia_pages — יש לבדוק RLS/הרשאות.' },
		{ key: 'mechalol', table: 'mechalol_pages', estimated: true, statId: 'mchl-stat-mechalol-total', spinId: 'mchl-spin-mechalol', warnId: 'mchl-warn-mechalol', warnMsg: 'לא ניתן לקרוא את mechalol_pages — יש לבדוק RLS/הרשאות.' },
		{ key: 'tasks', table: 'report_rev_tasks', statId: 'mchl-stat-tasks', spinId: 'mchl-spin-tasks', warnId: 'mchl-warn-tasks', warnMsg: 'לא ניתן לקרוא את report_rev_tasks.' },
		{ key: 'undoc', table: 'report_undocumented_import', statId: 'mchl-stat-undoc', spinId: 'mchl-spin-undoc', warnId: 'mchl-warn-undoc', warnMsg: 'לא ניתן לקרוא את report_undocumented_import.', tabCount: 'mchl-tab-count-undoc' },
		{ key: 'missing', table: 'report_missing_from_mechalol', viewKey: 'missing', statId: 'mchl-stat-missing', spinId: 'mchl-spin-missing', warnId: 'mchl-warn-missing', warnMsg: 'לא ניתן לקרוא את report_missing_from_mechalol.', tabCount: 'mchl-tab-count-missing' }
	];

	// ===== מצב האפליקציה =====
	var wikidataCache = new Map();
	var wikidataInFlight = new Set();
	// הצעה אוטומטית לכלי השיוך הידני, מבוססת הפניה קיימת במכלול (ראו
	// mechalol_redirect_exists) - title -> {targetTitle, mechalolId} |
	// null (אין הפניה בפועל/כשלון פתרון) | (לא ב-Map בכלל = טרם נבדק).
	var mechalolRedirectTargetCache = new Map();
	var mechalolRedirectTargetInFlight = new Set();
	var activeTab = 'missing';
	// סולם ההרשאות: קבוצה גבוהה יותר רואה גם את מה שנועד לקבוצות נמוכות ממנה.
	var GROUP_LEVELS = {
		sysop: 20, bot: 18, aspaklarya2: 16, aspaklaryaEditor: 14,
		patroller: 12, wikiupdate: 10, wikimport: 8
	};
	var userLevel = 0;
	var currentPage = 0;
	var pageSize = 50;
	var totalRows = 0;
	var countUnknown = false;
	var totalPages = 1;
	var currentPageRows = [];
	var activeFilters = {};
	var searchDebounce = null;
	var loadRequestId = 0;
	var selectedRows = new Map();
	var cultureState = { subcats: null, selected: null, members: [], continueToken: null, loading: false };
	// שמור ב-sessionStorage (לא localStorage) - נשאר בין רענוני דף כל
	// עוד הטאב פתוח, נעלם כשסוגרים אותו. לא עוגייה בכוונה: העוגייה
	// הייתה נשמרת על דומיין המכלול, לא של סופרבייס - היינו צריכים בכל
	// מקרה לקרוא אותה ולצרף ידנית לכותרת Authorization, בדיוק כמו
	// sessionStorage - בלי שום יתרון, ועם המגבלות של עוגייה (גודל,
	// שליחה אוטומטית ללא-קשר לבקשות אחרות) בלי סיבה.
	var SESSION_STORAGE_KEY = 'mchl-auth-session' + (BACKEND_NAME === 'v1' ? '' : '-' + BACKEND_NAME);   // טוקן נפרד לכל מסד
	var serviceKeyConnected = false;

	function $id(id) { return document.getElementById(id); }
	// העדפות תצוגה של המשתמש (תפריט האתר, פאנל המסננים, מקטעים מקופלים) - localStorage, עם fallback.
	var UI_PREFS_KEY = 'mchl-ui-prefs';
	var uiPrefs = (function () { try { return JSON.parse(localStorage.getItem(UI_PREFS_KEY) || '{}') || {}; } catch (e) { return {}; } }());
	function saveUiPrefs() { try { localStorage.setItem(UI_PREFS_KEY, JSON.stringify(uiPrefs)); } catch (e) { /* לא נשמר - לא נורא */ } }
	// עיצוב כהה (ברירת מחדל) או בהיר - נשמר בדפדפן, ומוחל על #mchl-dash.
	function applyTheme() { var d = $id('mchl-dash'); if (d) d.classList.toggle('mchl-light', uiPrefs.theme === 'light'); }
	function setTheme(theme) {
		uiPrefs.theme = theme === 'light' ? 'light' : 'dark';
		saveUiPrefs();
		applyTheme();
		document.querySelectorAll('#mchl-side .mchl-theme-toggle button').forEach(function (b) { b.classList.toggle('mchl-on', b.getAttribute('data-v') === uiPrefs.theme); });
	}
	function mechalolUrl(id) { return 'https://www.hamichlol.org.il/w/index.php?curid=' + id; }
	function wikipediaUrl(id) { return 'https://he.wikipedia.org/w/index.php?curid=' + id; }
	function mechalolReadUrl(title) { return 'https://www.hamichlol.org.il/w/index.php?title=' + encodeURIComponent(title.replace(/ /g, '_')); }
	// קישור להיסטוריית הערך עם fixsrc=1: הסקריפט "משתמש:גאון הירדן/הוספת תאריך למיון ויקיפדיה.js" (עותק בריפו: gadget/gadget-sortTemplateFix.js)
	// מכין שם את הלחצנים מיד. בדשבורד משמש רק כקישור גיבוי בפאנל "קביעת גרסת מקור" (fixSrc); הפאנל עצמו לא תלוי בסקריפט.
	function mechalolFixSourceUrl(title) { return 'https://www.hamichlol.org.il/w/index.php?title=' + encodeURIComponent(title.replace(/ /g, '_')) + '&action=history&fixsrc=1'; }
	function mechalolEditUrl(title) { return 'https://www.hamichlol.org.il/w/index.php?title=' + encodeURIComponent(title.replace(/ /g, '_')) + '&action=edit'; }
	function rowKey(row) { return activeTab + ':' + rowIdOf(row); }
	function escapeHtml(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m]; }); }
	function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

	var RETRY_ATTEMPTS = 3, RETRY_DELAY_MS = 900;
	function withRetry(fn, attempts) {
		attempts = attempts || RETRY_ATTEMPTS;
		var i = 0;
		function attempt() {
			i++;
			return fn().catch(function (e) {
				// timeout של השרת (57014): ניסיון חוזר רק מכפיל את העומס על אותו מסד איטי, ולכן לא מנסים שוב.
				if (i < attempts && !(e && e.code === '57014')) return sleep(RETRY_DELAY_MS * i).then(attempt);
				throw e;
			});
		}
		return attempt();
	}

	/*
	 * מזהה שגיאה "זמנית" (המסד באמצע עדכון תקופתי שבועי - ראו
	 * mirror_architecture_design.md, שלב 5: ALTER TABLE RENAME תחת
	 * lock_timeout קצר, ורענון מטמון PostgREST מיד אחרי ה-commit)
	 * לעומת שגיאה "קבועה" (כתובת/מפתח/הרשאות שגויים - לא ייפתר לבד).
	 *
	 * חתימות ידועות לשגיאה זמנית:
	 * - HTTP 503 - PostgREST באמצע בניית מטמון סכימה מחדש
	 * - קוד PGRST002 - "Could not query the database for the schema cache"
	 * - SQLSTATE 55P03 (lock_not_available) / 57014 (query_canceled) -
	 *   בדיוק התרחיש של lock_timeout על ALTER TABLE RENAME תוך כדי swap
	 * שים לב: זיהוי משוער לפי מיטב הידיעה על צורת השגיאות של Supabase/
	 * PostgREST - אם מתגלה בעתיד תבנית נוספת שמעידה על אותה תופעה, יש
	 * להוסיף אותה כאן.
	 */
	function isTransientMaintenanceError(e) {
		var status = e && e.status;
		var code = (e && e.code) ? String(e.code) : '';
		var msg = ((e && e.message) ? e.message : '').toLowerCase();
		return status === 503
			|| code === 'PGRST002'
			|| code === '55P03'
			|| code === '57014'
			|| msg.indexOf('schema cache') !== -1
			|| msg.indexOf('lock') !== -1;
	}

	// ===== שכבת גישה ל-PostgREST של סופרבייס - במקום ספריית supabase-js =====
	// משכפלת בכוונה את אותה תחביר בדיוק שה-URL שסופרבייס-js היה שולח,
	// כדי לשמור על התנהגות זהה (כולל '%' כתו-כללי בתוך ilike/or - זה
	// עובד תקין אחרי קידוד URL רגיל על ידי URLSearchParams, בדיוק כמו
	// שסופרבייס-js עצמו עושה).
	function pgHeaders(extra) {
		var h = profileHeaders({ apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY });
		if (extra) for (var k in extra) h[k] = extra[k];
		return h;
	}

	// כמו pgHeaders, אבל עם הטוקן של המשתמש המחובר (authenticated) -
	// לא מפתח ה-anon - לפעולות שדורשות RLS ברמת authenticated (כרגע:
	// שיוך התאמה ידנית ל-manual_matches בלבד). נופל בחזרה למפתח ה-anon
	// אם אין סשן שמור (לא אמור לקרות בפועל - הכפתורים שמשתמשים בזה
	// מוסתרים כש-serviceKeyConnected=false, אבל הגנה נוספת לא מזיקה).
	function authHeaders(extra) {
		var token = SUPABASE_ANON_KEY;
		try {
			var raw = sessionStorage.getItem(SESSION_STORAGE_KEY);
			if (raw) {
				var parsed = JSON.parse(raw);
				if (parsed && parsed.access_token) token = parsed.access_token;
			}
		} catch (e) { /* מתעלמים - נופל בחזרה למפתח ה-anon */ }
		var h = profileHeaders({ apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + token });
		if (extra) for (var k in extra) h[k] = extra[k];
		return h;
	}

	// בונה שגיאה עם status וקוד PostgREST (אם קיים בגוף התשובה) מצורפים
	// כמאפיינים אמיתיים - לא רק מחרוזת - כדי ש-isTransientMaintenanceError
	// יוכל לסווג אותה בלי להסתמך רק על ניחוש טקסט.
	function makePgError(status, bodyText) {
		var code = null, message = 'HTTP ' + status;
		if (bodyText) {
			try {
				var parsed = JSON.parse(bodyText);
				if (parsed && parsed.code) code = parsed.code;
				if (parsed && parsed.message) message = parsed.message;
			} catch (parseErr) {
				message = 'HTTP ' + status + ': ' + bodyText;
			}
		}
		var err = new Error(message);
		err.status = status;
		if (code) err.code = code;
		return err;
	}

	// ספירה בלבד (ל-STAT_DEFS ולמונה ה"תואמים") - שולף שורה אחת בלבד
	// ומסתמך על כותרת Content-Range לספירה, כדי לא למשוך נתונים מיותרים.
	// estimated: הערכה מהמתכנן (Prefer: count=estimated) במקום ספירה מדויקת - לטבלאות הגדולות, שם ספירה מדויקת לוקחת שניות.
	function pgCount(table, rawFilterParams, countColumn, estimated) {
		return withRetry(function () {
			var params = new URLSearchParams();
			params.set('select', countColumn || 'id');
			if (rawFilterParams) rawFilterParams.forEach(function (pair) { params.append(pair[0], pair[1]); });
			var url = SUPABASE_URL + '/rest/v1/' + table + '?' + params.toString();
			return fetch(url, { headers: pgHeaders({ Range: '0-0', Prefer: estimated ? 'count=estimated' : 'count=exact' }) }).then(function (res) {
				if (!res.ok) return res.text().then(function (t) { throw makePgError(res.status, t); });
				var cr = res.headers.get('Content-Range') || '';
				var total = parseInt(cr.split('/')[1], 10);
				// ספירה חסרה היא "לא ידוע", לא אפס.
				if (isNaN(total)) throw new Error('הספירה לא התקבלה מהמסד');
				return total;
			});
		});
	}

	// שליפת דף עם נתונים + ספירה מדויקת מקבילה - למסכי הטבלה, לייצוא,
	// ול"בחר את כל התוצאות התואמות".
	// כל השורות שעונות לסינון, בדפים של 1,000 (סופבייס מחזיר עד 1,000 שורות לבקשה).
	// סדר יציב (עם שובר שוויון), כדי שדפים לא יחפפו או ידלגו. onProgress(שנטענו, סך הכול).
	var PG_CHUNK = 1000;
	function pgSelectAll(view, opts, onProgress) {
		var rows = [], expected = null;
		function next() {
			return pgSelect(view, { filterParams: opts.filterParams, order: opts.order, from: rows.length, to: rows.length + PG_CHUNK - 1 }).then(function (res) {
				var data = res.data || [];
				if (res.count != null) expected = res.count;
				rows = rows.concat(data);
				if (onProgress) onProgress(rows.length, expected);
				var more = expected != null ? rows.length < expected : data.length === PG_CHUNK;
				if (data.length && more) return next();
				return { data: rows, expected: expected, complete: expected == null || rows.length >= expected };
			});
		}
		return next();
	}
	function stableOrder(cfg) {
		var order = cfg.order || 'title.asc';
		var tie = cfg.rowId ? 'mechalol_id.asc' : 'id.asc';
		return order.indexOf(tie.split('.')[0] + '.') >= 0 ? order : order + ',' + tie;
	}

	function pgSelect(view, opts) {
		return withRetry(function () {
			var params = new URLSearchParams();
			params.set('select', '*');
			(opts.filterParams || []).forEach(function (pair) { params.append(pair[0], pair[1]); });
			if (opts.order) params.set('order', opts.order);
			var url = SUPABASE_URL + '/rest/v1/' + view + '?' + params.toString();
			var headers = pgHeaders({ Range: opts.from + '-' + opts.to, 'Range-Unit': 'items', Prefer: 'count=exact' });
			return fetch(url, { headers: headers }).then(function (res) {
				if (!res.ok) return res.text().then(function (t) { throw makePgError(res.status, t); });
				var cr = res.headers.get('Content-Range') || '';
				var total = parseInt(cr.split('/')[1], 10);
				return res.json().then(function (data) { return { data: data, count: isNaN(total) ? null : total }; });
			});
		});
	}

	// ערכים שמוצגים רק למי שמחובר (loginOnly ב-VIEWS): למי שלא מחובר מוחרגים מהשאילתה, מהמונה ומהמסנן.
	function baseFiltersOf(cfg) {
		var out = (cfg.baseFilters || []).slice();
		if (cfg.loginOnly && !serviceKeyConnected) {
			out.push([cfg.loginOnly.key, 'not.in.(' + cfg.loginOnly.values.map(function (v) { return '"' + v + '"'; }).join(',') + ')']);
		}
		return out;
	}
	function allowedFilterOptions(cfg, f) {
		var lo = cfg.loginOnly;
		if (!lo || lo.key !== f.key || serviceKeyConnected) return f.options;
		return f.options.filter(function (o) { return lo.values.indexOf(o) < 0; });
	}

	// בונה את רשימת פרמטרי הסינון (כזוגות [שם, ערך], כדי לתמוך במפתחות
	// חוזרים כמו 'or') מתוך activeFilters + חיפוש חופשי, בדיוק כמו
	// buildQuery() בגרסת ה-HTML המקורית.
	function buildFilterParams() {
		var cfg = VIEWS[activeTab];
		var out = baseFiltersOf(cfg);
		var search = ($id('mchl-search-input').value || '').trim();
		if (search) {
			var searchColumn = cfg.searchColumn || 'title';
			if (cfg.wikidata) {
				// בתוך or=(...) ערך עם סוגריים/פסיקים/מירכאות (נפוצים בכותרות:
				// "X (סרט)", "ג'יטו, קיסרית יפן", זק"א) שובר את התחביר של PostgREST -
				// חייבים לעטוף במירכאות כפולות ולבצע escape ל-" ול-\.
				var quoted = '"%' + search.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '%"';
				out.push(['or', '(' + searchColumn + '.ilike.' + quoted + ',wikidata_desc.ilike.' + quoted + ')']);
			} else {
				out.push([searchColumn, 'ilike.%' + search + '%']);
			}
		}
		Object.keys(activeFilters).forEach(function (k) {
			var v = activeFilters[k];
			if (v && typeof v === 'object') {
				out.push([k, v.op + '.' + v.value]);
			} else {
				out.push([k, 'eq.' + v]);
			}
		});
		return out;
	}

	// ===== תיאורים מוויקינתונים (לטבלת "חסר במכלול" בלבד) =====
	function fetchWikidataDescriptions(titles) {
		titles.forEach(function (t) { wikidataInFlight.add(t); });
		var chunks = [];
		for (var i = 0; i < titles.length; i += 50) chunks.push(titles.slice(i, i + 50));
		var chain = Promise.resolve();
		chunks.forEach(function (chunk) {
			chain = chain.then(function () {
				var url = 'https://www.wikidata.org/w/api.php?action=wbgetentities&sites=hewiki&titles=' +
					chunk.map(encodeURIComponent).join('|') +
					'&props=descriptions%7Csitelinks&languages=he&format=json&origin=*';
				return withRetry(function () {
					return fetch(url).then(function (res) {
						if (!res.ok) throw new Error('HTTP ' + res.status);
						return res.json();
					});
				}, 2).then(function (data) {
					chunk.forEach(function (t) { if (!wikidataCache.has(t)) wikidataCache.set(t, ''); });
					if (data.entities) {
						Object.keys(data.entities).forEach(function (k) {
							var ent = data.entities[k];
							if (ent.missing !== undefined) return;
							var linkedTitle = ent.sitelinks && ent.sitelinks.hewiki ? ent.sitelinks.hewiki.title : null;
							var desc = ent.descriptions && ent.descriptions.he ? ent.descriptions.he.value : '';
							if (linkedTitle) wikidataCache.set(linkedTitle, desc);
						});
					}
				}).catch(function () {
					chunk.forEach(function (t) { wikidataCache.set(t, null); });
				});
			});
		});
		chain.then(function () {
			titles.forEach(function (t) { wikidataInFlight.delete(t); });
			paintWikidataDescriptions();
		});
	}

	function paintWikidataDescriptions() {
		document.querySelectorAll('#mchl-dash [data-desc-title]').forEach(function (el) {
			var t = el.getAttribute('data-desc-title');
			if (!wikidataCache.has(t)) return;
			var val = wikidataCache.get(t);
			el.classList.remove('mchl-skeleton', 'mchl-muted');
			if (val === null) { el.textContent = 'שגיאה בשליפה'; el.classList.add('mchl-muted'); }
			else if (val === '') { el.textContent = '—'; el.classList.add('mchl-muted'); }
			else { el.textContent = val; }
		});
	}

	function loadWikidataDescriptionsForCurrentPage() {
		if (!VIEWS[activeTab] || !VIEWS[activeTab].wikidata) return;
		currentPageRows.forEach(function (r) {
			if (r.wikidata_desc !== null && r.wikidata_desc !== undefined && !wikidataCache.has(r.title)) {
				wikidataCache.set(r.title, r.wikidata_desc);
			}
		});
		var need = currentPageRows.map(function (r) { return r.title; }).filter(function (t) { return !wikidataCache.has(t) && !wikidataInFlight.has(t); });
		if (need.length === 0) { paintWikidataDescriptions(); return; }
		fetchWikidataDescriptions(need);
	}

	// ===== הצעה אוטומטית לשיוך ידני, מהפניה קיימת במכלול (לטבלת "חסר
	// במכלול" בלבד, ורק כש-serviceKeyConnected - אין טעם לבדוק בכלל אם
	// עמודת השיוך הידני עצמה לא מוצגת) =====
	function loadRedirectTargetsForCurrentPage() {
		if (!VIEWS[activeTab] || !VIEWS[activeTab].manualMatch || !serviceKeyConnected) return;
		var need = currentPageRows
			.filter(function (r) { return r.mechalol_redirect_exists === true; })
			.map(function (r) { return r.title; })
			.filter(function (t) { return !mechalolRedirectTargetCache.has(t) && !mechalolRedirectTargetInFlight.has(t); });
		if (need.length === 0) { paintRedirectTargetSuggestions(); return; }
		resolveMechalolRedirectTargets(need);
	}

	// שלב 1: לאן ההפניה במכלול מצביעה בפועל - action=query&redirects=1
	// באותו api.php יחסי כמו lockSelectedTitles (אותו דומיין, אין צורך
	// ב-origin=*). אצוות של 50 (כמו fetchWikidataDescriptions).
	function resolveMechalolRedirectTargets(titles) {
		titles.forEach(function (t) { mechalolRedirectTargetInFlight.add(t); });
		var chunks = [];
		for (var i = 0; i < titles.length; i += 50) chunks.push(titles.slice(i, i + 50));
		var chain = Promise.resolve();
		chunks.forEach(function (chunk) {
			chain = chain.then(function () {
				var url = MECHALOL_API + '?action=query&titles=' + chunk.map(encodeURIComponent).join('|') +
					'&redirects=1&formatversion=2&format=json';
				return withRetry(function () {
					return fetch(url).then(function (res) {
						if (!res.ok) throw new Error('HTTP ' + res.status);
						return res.json();
					});
				}, 2).then(function (data) {
					chunk.forEach(function (t) { if (!mechalolRedirectTargetCache.has(t)) mechalolRedirectTargetCache.set(t, null); });
					var redirectMap = {};
					((data.query && data.query.redirects) || []).forEach(function (r) { redirectMap[r.from] = r.to; });
					chunk.forEach(function (t) {
						var target = redirectMap[t];
						if (target) mechalolRedirectTargetCache.set(t, { targetTitle: target, mechalolId: null });
					});
				}).catch(function () {
					chunk.forEach(function (t) { mechalolRedirectTargetCache.set(t, null); });
				});
			});
		});
		chain.then(function () {
			titles.forEach(function (t) { mechalolRedirectTargetInFlight.delete(t); });
			return resolveMechalolIdsForRedirectTargets();
		}).then(function () {
			paintRedirectTargetSuggestions();
		});
	}

	// שלב 2: id בפועל ב-mechalol_pages עבור כותרות היעד שנפתרו בשלב 1 -
	// PostgREST רגיל (anon), title=in.(...) - באצוות של PG_IN_BATCH בגלל אורך הכתובת (ראו PG_IN_BATCH).
	function resolveMechalolIdsForRedirectTargets() {
		var targets = [];
		mechalolRedirectTargetCache.forEach(function (v) {
			if (v && v.targetTitle && v.mechalolId === null) targets.push(v.targetTitle);
		});
		targets = Array.from(new Set(targets));
		if (targets.length === 0) return Promise.resolve();
		return Promise.all(batches(targets, PG_IN_BATCH).map(function (batch) {
			var params = new URLSearchParams();
			params.set('select', 'id,title');
			params.set('title', 'in.(' + batch.map(function (t) { return '"' + t.replace(/"/g, '\\"') + '"'; }).join(',') + ')');
			return fetch(SUPABASE_URL + '/rest/v1/mechalol_pages?' + params.toString(), { headers: pgHeaders() })
				.then(function (res) { if (!res.ok) throw new Error('HTTP ' + res.status); return res.json(); })
				.then(function (rows) {
					var byTitle = {};
					(rows || []).forEach(function (r) { byTitle[r.title] = r.id; });
					mechalolRedirectTargetCache.forEach(function (v) {
						if (v && v.targetTitle && byTitle[v.targetTitle] !== undefined) v.mechalolId = byTitle[v.targetTitle];
					});
				}).catch(function () { /* אצווה שנכשלה: משאירים mechalolId=null - עדיין יש הצעת-טקסט בלי id */ });
		}));
	}

	// מעדכן ישירות תאים שכבר מצוירים (כמו paintWikidataDescriptions) -
	// לא renderTable מלא, כדי לא לאבד טקסט שהמשתמש כבר הקליד בינתיים
	// בתאים אחרים באותו עמוד.
	function paintRedirectTargetSuggestions() {
		document.querySelectorAll('#mchl-dash .mchl-manual-match-cell[data-redirect-check-title]').forEach(function (cell) {
			var title = cell.getAttribute('data-redirect-check-title');
			var cached = mechalolRedirectTargetCache.get(title);
			if (cached === undefined) return;
			applyRedirectSuggestion(cell, cached);
		});
	}

	function applyRedirectSuggestion(cell, cached) {
		var input = cell.querySelector('.mchl-manual-match-input');
		var btn = cell.querySelector('button[data-action="assign-manual-match"]');
		var hint = cell.querySelector('.mchl-manual-match-hint');
		if (input.value) {
			// המשתמש כבר הקליד/בחר בעצמו לפני שהבדיקה החיה הספיקה
			// לחזור - לא דורסים תוך כדי.
			if (hint) hint.remove();
			return;
		}
		if (!cached || !cached.targetTitle) {
			if (hint) hint.remove();
			return;
		}
		input.value = cached.targetTitle;
		if (cached.mechalolId) {
			cell.dataset.selectedMechalolId = cached.mechalolId;
			btn.disabled = false;
		}
		if (hint) hint.textContent = 'הצעה אוטומטית מהפניה קיימת - אפשר לשנות';
	}

	// ===== בניית הממשק =====
	// מצב ההתחברות קובע אילו לשוניות מוצגות (requiresLogin): בונים את הלשוניות מחדש, ואם הפעילה הוסתרה חוזרים ל"חסר במכלול".
	function syncAuthTabs() {
		syncMaintRow();
		if (!$id('mchl-tabs')) return;
		buildTabs();
		if (!tabAllowed(activeTab)) switchTab('missing');
		countsLoaded = {};
		loadStats(); // ממלא מחדש את מוני הלשונית הפעילה; השאר מוצגים מהשמור
		// טאב עם ערכים למחוברים בלבד: המסנן והרשימה משתנים עם ההתחברות/ההתנתקות.
		if (VIEWS[activeTab] && VIEWS[activeTab].loginOnly) { buildDynamicFilters(); currentPage = 0; loadActiveView(); }
	}
	function buildTabs() {
		var nav = $id('mchl-tabs');
		nav.innerHTML = '';
		var groupsRow = document.createElement('div');
		groupsRow.className = 'mchl-tab-groups';
		nav.appendChild(groupsRow);
		TAB_GROUPS.forEach(function (g) {
			if (!g.tabs.some(tabAllowed)) return; // קבוצה בלי לשוניות מותרות (למשל "עדכון" למי שלא מחובר) לא מוצגת
			var gb = document.createElement('button');
			gb.type = 'button';
			gb.className = 'mchl-tab-group';
			gb.id = 'mchl-tabgroup-' + g.key;
			gb.textContent = g.label;
			gb.addEventListener('click', function () {
				var last = uiPrefs['lastTab:' + g.key];
				switchTab(g.tabs.indexOf(last) >= 0 && tabAllowed(last) ? last : g.tabs[0]);
			});
			groupsRow.appendChild(gb);
			// הטאבים של הקבוצה - תמיד ב-DOM (המונים שלהם מתעדכנים גם כשהקבוצה סגורה).
			var sub = document.createElement('div');
			sub.className = 'mchl-subtabs';
			sub.id = 'mchl-subtabs-' + g.key;
			if (g.tabs.length < 2) sub.classList.add('mchl-single');
			g.tabs.forEach(function (key) {
				if (!tabAllowed(key)) return;
				var v = VIEWS[key] || EXTRA_TABS[key];
				var btn = document.createElement('button');
				btn.className = 'mchl-tab';
				btn.id = 'mchl-tab-' + key;
				btn.type = 'button';
				var countHtml = VIEWS[key] ? '<span class="mchl-count" id="mchl-tab-count-' + key + '">–</span>' : '';
				btn.innerHTML = escapeHtml(v.label) + countHtml;
				btn.addEventListener('click', function () { switchTab(key); });
				sub.appendChild(btn);
			});
			nav.appendChild(sub);
		});
		// הערכים האחרונים השמורים מוצגים מיד (אחרי שהלשוניות מחוברות ל-DOM), עד שהספירה החיה חוזרת.
		Object.keys(VIEWS).forEach(function (k) { paintCachedCount('mchl-tab-count-' + k); });
		markActiveTab();
	}

	function markActiveTab() {
		var g = groupOfTab(activeTab);
		TAB_GROUPS.forEach(function (x) {
			var gb = $id('mchl-tabgroup-' + x.key), sub = $id('mchl-subtabs-' + x.key);
			if (!gb || !sub) return; // קבוצה מוסתרת
			gb.classList.toggle('mchl-active', x === g);
			sub.classList.toggle('mchl-open', x === g);
		});
		document.querySelectorAll('#mchl-dash .mchl-tab').forEach(function (t) { t.classList.toggle('mchl-active', t.id === 'mchl-tab-' + activeTab); });
		uiPrefs['lastTab:' + g.key] = activeTab;
		saveUiPrefs();
	}

	function switchTab(key) {
		activeTab = key;
		loadRequestId++; // תשובות שעוד באוויר מהטאב הקודם - לא יצוירו
		currentPage = 0;
		activeFilters = {};
		selectedRows.clear();
		markActiveTab();
		loadGroupCounts(groupOfTab(key)); // ספירות הקבוצה נטענות כשהיא נפתחת (פעם אחת בכל מחזור רענון)
		updateSelectionBar();
		var isStats = key === 'stats';
		$id('mchl-stats-area').style.display = isStats ? 'block' : 'none';
		$id('mchl-body').style.display = isStats ? 'none' : '';
		if (EXTRA_TABS[key]) {
			$id('mchl-filter-bar').style.display = 'none';
			$id('mchl-pager').style.display = 'none';
			$id('mchl-body').classList.remove('mchl-with-side');
			$id('mchl-side').style.display = 'none';
			$id('mchl-wf-meter').style.display = 'none';
			renderChips();
			if (key === 'requests') loadRequestsTab();
			else if (!isStats) loadCultureTab();
			return;
		}
		$id('mchl-filter-bar').style.display = 'flex';
		var searchInput = $id('mchl-search-input');
		searchInput.value = '';
		searchInput.placeholder = VIEWS[key].columns.indexOf('wikidata_desc') !== -1 ? 'חיפוש בכותרת או בתיאור ויקינתונים…' : 'חיפוש בכותרת…';
		buildDynamicFilters();
		loadActiveView();
	}

	// ===== טאב "דפים לטיפול - תרבות" - שליפה חיה מה-API של המכלול =====
	function mwApiFetch(params) {
		var p = new URLSearchParams(params);
		p.set('format', 'json');
		p.set('formatversion', '2');
		return withRetry(function () {
			return fetch(MECHALOL_API + '?' + p.toString()).then(function (res) {
				if (!res.ok) throw new Error('HTTP ' + res.status);
				return res.json();
			}).then(function (data) {
				// MediaWiki מחזירה שגיאות API גם בתשובת 200.
				if (data && data.error) throw new Error('API: ' + (data.error.code || '') + ' ' + (data.error.info || ''));
				return data;
			});
		});
	}


	// ===== טאב "בקשות ייבוא" - הדף המכלול:בקשת ייבוא ערך, עם מה שכבר ידוע לנו על כל ערך =====
	// כל בקשה = מקטע ברמה 2 שהכותרת שלו קישור לערך. לכל בקשה: מי ביקש ומתי, התגובות (בוצע / תגובה אחרת),
	// האם הערך כבר קיים במכלול, והנתונים שלנו על הגרסה בוויקיפדיה (רמת תוכן, מילים, תמונות, מילוני) - ומכאן ייבוא.
	var REQUESTS_PAGE = 'המכלול:בקשת ייבוא ערך';
	var requestsState = { rows: null, filter: 'open', openTitle: null };
	var HE_MONTHS = { 'בינואר': 0, 'בפברואר': 1, 'במרץ': 2, 'באפריל': 3, 'במאי': 4, 'ביוני': 5, 'ביולי': 6, 'באוגוסט': 7, 'בספטמבר': 8, 'באוקטובר': 9, 'בנובמבר': 10, 'בדצמבר': 11 };
	var NON_MAIN_NS = /^\s*:?\s*(המכלול|ויקיפדיה|תבנית|קטגוריה|משתמש|קובץ|תמונה|עזרה|פורטל|מדיה ויקי|מודול|שיחה|שיחת [^:]+|מיוחד|מש|שמש|וק)\s*:/;

	function wikiPlain(t) {
		return String(t || '')
			.replace(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/g, '$1')
			.replace(/\{\{[^{}]*\}\}/g, ' ')
			.replace(/<[^>]+>/g, ' ')
			.replace(/'{2,}/g, '')
			.replace(/\s+/g, ' ').trim();
	}
	function sigDate(t) {
		var all = String(t).match(/(\d{1,2}):(\d{2}), (\d{1,2}) (ב[א-ת]+) (\d{4})/g);
		if (!all) return null;
		var m = /(\d{1,2}):(\d{2}), (\d{1,2}) (ב[א-ת]+) (\d{4})/.exec(all[0]);
		if (!(m[4] in HE_MONTHS)) return null;
		return new Date(+m[5], HE_MONTHS[m[4]], +m[3], +m[1], +m[2]);
	}
	function parseRequests(text) {
		var lines = text.split('\n'), reqs = [], cur = null, section = 0;
		lines.forEach(function (line) {
			var h = /^(={1,6})\s*(.*?)\s*\1\s*$/.exec(line);
			if (h) {
				section++;
				if (h[1].length !== 2) { if (cur) cur.body.push(line); return; }
				var link = /\[\[([^\]|]+)(?:\|[^\]]*)?\]\]/.exec(h[2]);
				var title = (link ? link[1] : wikiPlain(h[2])).replace(/_/g, ' ').trim();
				cur = { title: title, section: section, body: [], main: !!title && !NON_MAIN_NS.test(title) };
				reqs.push(cur);
				return;
			}
			if (cur) cur.body.push(line);
		});
		return reqs.filter(function (r) { return r.main; }).map(function (r) {
			var ask = r.body.filter(function (l) { return l.trim() && !/^:/.test(l); }).join(' ');
			var replies = r.body.filter(function (l) { return /^:/.test(l); });
			var who = /\[\[(?:משתמש|מש|User)\s*:\s*([^\]|]+)/.exec(ask) || /\[\[מיוחד:תרומות\/([^\]|]+)/.exec(ask);
			var note = wikiPlain(ask.split(/--|\[\[(?:משתמש|מש|מיוחד:תרומות)/)[0]).replace(/^תודה( רבה)?!?\s*$/, '');
			var rtext = replies.join('\n');
			var status = /\{\{\s*בוצע/.test(rtext) ? 'done' : replies.length ? 'replied' : 'open';
			var lastReply = replies.length ? wikiPlain(replies[replies.length - 1].replace(/^:+/, '').split(/\[\[(?:משתמש|מש)\s*:/)[0]) : '';
			return { title: r.title, section: r.section, requester: who ? who[1].trim() : '', date: sigDate(ask), note: note, status: status,
				replyTemplates: (rtext.match(/\{\{\s*([^|}]+)/g) || []).map(function (x) { return x.replace(/^\{\{\s*/, '').trim(); }).filter(function (x) { return x !== 'א'; }),
				lastReply: lastReply };
		});
	}

	// כתובות PostgREST עם כותרות בעברית ארוכות מאוד אחרי קידוד (~130 תווים לכותרת), ושרתים ופרוקסי מגבילים אורך כתובת
	// (לרוב 8-16KB), ולכן in.(...) של כותרות מפוצל לאצוות קטנות. (ב-API של מדיה-ויקי המגבלה היא 50 בבקשה.)
	var PG_IN_BATCH = 20;
	function batches(arr, n) { var out = []; for (var i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n)); return out; }
	// קיום במכלול: missing / exists / redirect. וקיום בוויקיפדיה: מזהה וכותרת (אחרי הפניה).
	function lookupTitles(titles) {
		var mech = {}, wiki = {};
		var mechJobs = batches(titles, 50).map(function (b) {
			return mwApiFetch({ action: 'query', titles: b.join('|'), prop: 'info' }).then(function (d) {
				var q = d.query || {}, norm = {};
				(q.normalized || []).forEach(function (n) { norm[n.to] = n.from; });
				(q.pages || []).forEach(function (pg) {
					var t = norm[pg.title] || pg.title;
					mech[t] = pg.missing ? 'missing' : pg.redirect ? 'redirect' : 'exists';
				});
			});
		});
		var wikiJobs = batches(titles, 50).map(function (b) {
			var p = new URLSearchParams({ action: 'query', titles: b.join('|'), redirects: '1', format: 'json', formatversion: '2', origin: '*' });
			return withRetry(function () {
				return fetch('https://he.wikipedia.org/w/api.php?' + p.toString()).then(function (res) {
					if (!res.ok) throw new Error('HTTP ' + res.status);
					return res.json();
				});
			}).then(function (d) {
				var q = d.query || {}, back = {};
				(q.normalized || []).forEach(function (n) { back[n.to] = n.from; });
				(q.redirects || []).forEach(function (r) { back[r.to] = back[r.from] || r.from; });
				(q.pages || []).forEach(function (pg) {
					var t = back[pg.title] || pg.title;
					wiki[t] = pg.missing ? null : { id: pg.pageid, title: pg.title };
				});
			});
		});
		return Promise.all(mechJobs.concat(wikiJobs)).then(function () { return { mech: mech, wiki: wiki }; });
	}

	function loadRequestsTab() {
		var target = $id('mchl-table-target');
		target.innerHTML = skeletonRows();
		var myId = ++loadRequestId;
		var reqs;
		mwApiFetch({ action: 'query', prop: 'revisions', rvprop: 'content', rvslots: 'main', titles: REQUESTS_PAGE }).then(function (d) {
			var pg = d.query && d.query.pages && d.query.pages[0];
			if (!pg || !pg.revisions) throw new Error('הדף "' + REQUESTS_PAGE + '" לא נמצא');
			reqs = parseRequests(pg.revisions[0].slots.main.content);
			return lookupTitles(reqs.map(function (r) { return r.title; }));
		}).then(function (found) {
			reqs.forEach(function (r) {
				r.mech = found.mech[r.title] || 'missing';
				r.wiki = found.wiki[r.title] || null;
				// ערך שכבר קיים במכלול - הבקשה נחשבת בוצעה, גם בלי {{בוצע}} (חיים, 2026-09-29).
				if (r.mech === 'exists' && r.status !== 'done') { r.status = 'done'; r.doneBy = 'exists'; }
			});
			var ids = reqs.filter(function (r) { return r.wiki; }).map(function (r) { return r.wiki.id; });
			if (!ids.length) return [];
			// בדוח יש רק ערכים שחסרים במכלול - ממילא אין טעם לשאול על השאר.
			return Promise.all(batches(ids, 150).map(function (b) {
				return pgSelect('report_missing_word_filter', { filterParams: [['id', 'in.(' + b.join(',') + ')']], from: 0, to: b.length - 1 }).then(function (res) { return res.data || []; });
			})).then(function (parts) { return [].concat.apply([], parts); });
		}).then(function (dbRows) {
			if (myId !== loadRequestId || activeTab !== 'requests') return;
			var byId = {};
			dbRows.forEach(function (r) { byId[r.id] = r; });
			requestsState.rows = reqs.map(function (r) {
				var db = r.wiki ? byId[r.wiki.id] : null;
				var row = db ? Object.assign({}, db) : { id: r.wiki ? r.wiki.id : null, title: r.wiki ? r.wiki.title : r.title };
				row.req = r;
				row.inDb = !!db;
				return row;
			}).sort(function (a, b) { return (b.req.date || 0) - (a.req.date || 0); });
			renderRequests();
		}).catch(function (e) {
			if (myId === loadRequestId && activeTab === 'requests') showError(e);
		});
	}

	var REQ_STATUS = { open: 'ממתינה', replied: 'יש תגובה', done: 'בוצע' };
	function requestsVisible() {
		var f = requestsState.filter;
		return (requestsState.rows || []).filter(function (r) {
			if (f === 'open') return r.req.status !== 'done';
			if (f === 'importable') return r.req.status !== 'done' && r.req.mech === 'missing' && r.req.wiki && r.inDb;
			if (f === 'done') return r.req.status === 'done';
			return true;
		});
	}
	function renderRequests() {
		var rows = requestsVisible();
		currentPageRows = rows.filter(function (r) { return r.id; });
		var all = requestsState.rows || [];
		var count = function (f) { var keep = requestsState.filter; requestsState.filter = f; var n = requestsVisible().length; requestsState.filter = keep; return n; };
		var seg = [['open', 'פתוחות'], ['importable', 'אפשר לייבא'], ['done', 'בוצעו'], ['all', 'הכול']].map(function (o) {
			return '<button type="button" data-action="req-filter" data-v="' + o[0] + '"' + (requestsState.filter === o[0] ? ' class="mchl-on"' : '') + '>' +
				escapeHtml(o[1]) + ' <span class="mchl-muted">' + count(o[0]).toLocaleString('he-IL') + '</span></button>';
		}).join('');
		var pageUrl = mw.util.getUrl(REQUESTS_PAGE);
		var head = '<div class="mchl-req-head"><div class="mchl-seg">' + seg + '</div>' +
			'<a href="' + pageUrl + '" target="_blank" rel="noopener" class="mchl-muted">לדף הבקשות ↗</a></div>';
		if (!rows.length) {
			$id('mchl-table-target').innerHTML = head + '<div class="mchl-state"><div class="mchl-big">אין בקשות</div>' + (all.length ? 'אין בקשות שעונות לסינון.' : '') + '</div>';
			return;
		}
		var th = ['הבקשה', 'נוצר בוויקיפדיה', 'במכלול', 'נושא', 'רמת תוכן', 'מילים', 'תמונות', '', ''];
		var body = rows.map(function (row) {
			var r = row.req;
			var editUrl = mw.util.getUrl(REQUESTS_PAGE, { action: 'edit', section: r.section });
			var titleHtml = '<span class="mchl-title"><a href="' + mw.util.getUrl(r.title) + '" target="_blank" rel="noopener">' + escapeHtml(r.title) + '</a></span>' +
				(r.wiki ? ' <a class="mchl-muted" href="' + wikipediaUrl(r.wiki.id) + '" target="_blank" rel="noopener" title="הערך בוויקיפדיה">ויקיפדיה ↗</a>' : '');
			var meta = [r.date ? r.date.toLocaleDateString('he-IL') : '', r.requester].filter(Boolean).join(' · ');
			var reqHtml = titleHtml + '<div class="mchl-row-desc">' + escapeHtml(meta) +
				(r.note ? ' · <span title="' + escapeHtml(r.note) + '">' + escapeHtml(r.note.length > 90 ? r.note.slice(0, 90) + '…' : r.note) + '</span>' : '') + '</div>' +
				'<div class="mchl-row-desc"><span class="mchl-badge ' + (r.status === 'done' ? 'mchl-wiki' : r.status === 'replied' ? 'mchl-review' : 'mchl-neutral') + '"' +
				(r.lastReply ? ' title="' + escapeHtml(r.lastReply) + '"' : '') + '>' + REQ_STATUS[r.status] + (r.doneBy === 'exists' ? ' (קיים במכלול)' : '') +
				(r.status === 'replied' && r.replyTemplates.length ? ': ' + escapeHtml(r.replyTemplates.join(', ')) : '') + '</span> ' +
				'<button type="button" class="mchl-link mchl-req-open" data-action="req-open">💬 בקשה ותגובות</button> ' +
				'<a href="' + editUrl + '" target="_blank" rel="noopener" class="mchl-muted">עריכה בדף ↗</a></div>';
			var mechHtml = r.mech === 'exists' ? '<span class="mchl-badge mchl-wiki">קיים</span>' :
				r.mech === 'redirect' ? '<span class="mchl-badge mchl-neutral">הפניה</span>' : '<span class="mchl-muted">אין</span>';
			var known = row.inDb;
			var noData = !r.wiki ? '<span class="mchl-muted" title="לא נמצא ערך בשם הזה בוויקיפדיה">לא בוויקיפדיה</span>' :
				r.mech !== 'missing' ? '<span class="mchl-muted">—</span>' : '<span class="mchl-muted" title="הערך עוד לא נסרק (נוסף לאחרונה או שהכותרת במכלול שונה)">טרם נסרק</span>';
			var cells = [
				reqHtml, '<span data-created-for="' + escapeHtml(r.title) + '">' + createdHtml(row.created_at) + '</span>', mechHtml,
				known ? renderCell('topic', row) : '<span class="mchl-muted">—</span>',
				known ? renderCell('verdict', row) : noData,
				known ? renderCell('wf_matches', row) : '',
				known ? renderCell('has_images', row) : '',
				r.wiki && r.mech === 'missing' ? renderCell('import_action', row) : '',
				known ? renderCell('expand', row) : ''
			];
			return '<tr class="mchl-req-row' + (known && wfHasDetails(row) ? ' mchl-expandable' : '') + '" data-req-title="' + escapeHtml(r.title) + '">' + cells.map(function (c, i) { return '<td data-label="' + th[i] + '">' + c + '</td>'; }).join('') + '</tr>';
		}).join('');
		$id('mchl-table-target').innerHTML = head + '<div class="mchl-table-wrap"><table><thead><tr>' +
			th.map(function (h, i) { return '<th' + (i >= 7 ? ' class="mchl-narrow-col"' : '') + '>' + h + '</th>'; }).join('') + '</tr></thead><tbody>' + body + '</tbody></table></div>';
		loadMissingCreationDates(rows);
		if (requestsState.openTitle) {
			var tr = $id('mchl-table-target').querySelector('tr[data-req-title="' + window.CSS.escape(requestsState.openTitle) + '"]');
			if (tr) openRequestPanel(tr);
		}
	}

	// תאריך היצירה בוויקיפדיה, ותג "טרי" לערך שנוצר בפחות מ-NEW_ARTICLE_CUTOFF_DAYS ימים.
	function createdHtml(iso) {
		if (!iso) return '<span class="mchl-muted">—</span>';
		var d = new Date(iso);
		var fresh = Date.now() - d.getTime() < NEW_ARTICLE_CUTOFF_DAYS * 864e5;
		return '<span class="mchl-num-cell">' + d.toLocaleDateString('he-IL') + '</span>' + (fresh ? ' <span class="mchl-badge mchl-review" title="נוצר בוויקיפדיה לפני פחות מ-' + NEW_ARTICLE_CUTOFF_DAYS + ' יום">טרי</span>' : '');
	}
	// ערכים שאין לנו במסד (בדרך כלל החדשים ביותר) - תאריך הגרסה הראשונה מוויקיפדיה, אחד-אחד, 4 במקביל.
	function loadMissingCreationDates(rows) {
		var todo = rows.filter(function (r) { return r.req.wiki && !r.created_at && !r.createdLoading; });
		var run = function () {
			var r = todo.shift();
			if (!r) return;
			r.createdLoading = true;
			var p = new URLSearchParams({ action: 'query', pageids: String(r.req.wiki.id), prop: 'revisions', rvprop: 'timestamp', rvdir: 'newer', rvlimit: '1', format: 'json', formatversion: '2', origin: '*' });
			fetch('https://he.wikipedia.org/w/api.php?' + p.toString()).then(function (res) { return res.json(); }).then(function (d) {
				var pg = d.query && d.query.pages && d.query.pages[0];
				r.created_at = pg && pg.revisions && pg.revisions[0] ? pg.revisions[0].timestamp : null;
				var el = $id('mchl-table-target').querySelector('[data-created-for="' + window.CSS.escape(r.req.title) + '"]');
				if (el) el.innerHTML = createdHtml(r.created_at);
			}).catch(function () { /* נשאר "—" */ }).then(run);
		};
		for (var i = 0; i < 4; i++) run();
	}

	// ===== פסקת הבקשה ותגובה - לחיצה על שורה =====
	function requestRowOf(title) { return (requestsState.rows || []).filter(function (x) { return x.req.title === title; })[0]; }
	function panelRowOf(tr) {
		for (var n = tr.nextElementSibling; n && !n.classList.contains('mchl-req-row'); n = n.nextElementSibling) if (n.classList.contains('mchl-req-panel-row')) return n;
		return null;
	}
	function toggleRequestPanel(tr) {
		var panel = panelRowOf(tr);
		if (panel) { panel.remove(); requestsState.openTitle = null; return; }
		openRequestPanel(tr);
	}
	// הפסקה נשלפת לפי מספרה, ונבדק שהכותרת שלה היא עדיין של אותו ערך (הדף משתנה - מספרי הפסקאות זזים).
	function fetchRequestSection(r) {
		return mwApiFetch({ action: 'parse', page: REQUESTS_PAGE, section: String(r.section), prop: 'wikitext' }).then(function (d) {
			var wikitext = (d.parse && d.parse.wikitext) || '';
			var first = parseRequests(wikitext)[0];
			if (!first || first.title !== r.title) throw new Error('moved');
			return { html: threadHtml(wikitext), req: first };
		});
	}
	// הבקשה והתגובות כשרשור פשוט: כל הודעה בשורה, עם הזחה לפי מספר הנקודתיים, הכותב והתאריך.
	function threadHtml(wikitext) {
		var msgs = [];
		wikitext.split('\n').slice(1).forEach(function (line) {
			if (!line.trim()) return;
			var m = /^(:*)(.*)$/.exec(line), depth = m[1].length, body = m[2];
			var who = /\[\[(?:משתמש|מש|User)\s*:\s*([^\]|]+)/.exec(body) || /\[\[מיוחד:תרומות\/([^\]|]+)/.exec(body);
			var date = sigDate(body);
			var text = wikiPlain(body.replace(/\{\{\s*(בוצע[^}]*)\}\}/g, '✔ $1').replace(/\{\{\s*א\|[^}]*\}\}/g, '').split(/--\s*\[\[|\[\[(?:משתמש|מש|User)\s*:|\[\[מיוחד:תרומות/)[0]);
			if (depth === 0 && msgs.length && !who && !date) { msgs[msgs.length - 1].text += ' ' + text; return; }
			msgs.push({ depth: depth, text: text, who: who ? who[1].trim() : '', date: date });
		});
		if (!msgs.length) return '<div class="mchl-muted">אין תוכן בבקשה.</div>';
		return msgs.map(function (x) {
			return '<div class="mchl-msg" style="margin-inline-start:' + Math.min(x.depth, 6) * 18 + 'px">' +
				'<div class="mchl-msg-text">' + (escapeHtml(x.text) || '<span class="mchl-muted">(בלי טקסט)</span>') + '</div>' +
				'<div class="mchl-msg-meta">' + escapeHtml([x.who, x.date ? x.date.toLocaleString('he-IL', { day: 'numeric', month: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : ''].filter(Boolean).join(' · ')) + '</div></div>';
		}).join('');
	}
	function openRequestPanel(tr) {
		var title = tr.getAttribute('data-req-title');
		var row = requestRowOf(title);
		if (!row) return;
		requestsState.openTitle = title;
		var old = panelRowOf(tr);
		if (old) old.remove();
		var panelTr = document.createElement('tr');
		panelTr.className = 'mchl-req-panel-row';
		panelTr.innerHTML = '<td colspan="' + tr.children.length + '"><div class="mchl-req-panel"><div class="mchl-req-section mchl-muted">טוען את הבקשה…</div>' +
			'<div class="mchl-req-reply">' +
			'<textarea class="mchl-search" rows="2" placeholder="תגובה (החתימה תתווסף אוטומטית)"></textarea>' +
			'<div class="mchl-req-reply-btns">' +
			'<button type="button" class="mchl-export-btn" data-action="req-reply" data-kind="text">הגב</button>' +
			'<button type="button" class="mchl-export-btn" data-action="req-reply" data-kind="done">{{בוצע}}</button>' +
			'<button type="button" class="mchl-export-btn" data-action="req-reply" data-kind="fresh">טרי</button>' +
			'<span class="mchl-req-reply-msg mchl-muted"></span></div></div></div></td>';
		tr.parentNode.insertBefore(panelTr, tr.nextSibling);
		if (requestsState.flash) { panelTr.querySelector('.mchl-req-reply-msg').textContent = requestsState.flash; requestsState.flash = null; }
		var box = panelTr.querySelector('.mchl-req-section');
		fetchRequestSection(row.req).then(function (sec) {
			box.classList.remove('mchl-muted');
			box.innerHTML = sec.html;
		}).catch(function (e) {
			box.innerHTML = e.message === 'moved'
				? '<span class="mchl-alert">הדף השתנה מאז הטעינה - לחץ "רענון" וחזור לבקשה.</span>'
				: '<span class="mchl-alert">שגיאה בטעינת הבקשה: ' + escapeHtml(e.message || e) + '</span>';
		});
	}
	function replyToRequest(btn) {
		var panelTr = btn.closest('tr.mchl-req-panel-row');
		var tr = panelTr && panelTr.previousElementSibling;
		while (tr && !tr.classList.contains('mchl-req-row')) tr = tr.previousElementSibling;
		var row = tr && requestRowOf(tr.getAttribute('data-req-title'));
		if (!row) return;
		var kind = btn.getAttribute('data-kind');
		var textarea = panelTr.querySelector('textarea');
		var msg = panelTr.querySelector('.mchl-req-reply-msg');
		var text = kind === 'done' ? '{{בוצע}}' : kind === 'fresh' ? 'טרי' : textarea.value.trim();
		if (!text) { msg.textContent = 'כתוב תגובה.'; return; }
		var buttons = panelTr.querySelectorAll('button[data-action="req-reply"]');
		buttons.forEach(function (b) { b.disabled = true; });
		msg.textContent = 'שומר…';
		var done = function (m, bad) { buttons.forEach(function (b) { b.disabled = false; }); msg.textContent = m; msg.classList.toggle('mchl-alert', !!bad); };
		// בדיקה מחדש מיד לפני הכתיבה: הפסקה עדיין של אותו ערך?
		fetchRequestSection(row.req).then(function () {
			return mw.loader.using('mediawiki.api');
		}).then(function () {
			return new mw.Api().postWithToken('csrf', {
				action: 'edit', title: REQUESTS_PAGE, section: String(row.req.section),
				// חתימה: ארבע טילדות ברצף בקוד הגאדג'ט (בדף JS במכלול) מומרות לחתימה בשמירה, ולכן מפוצלות בכוונה.
				appendtext: '\n:' + text + ' ~~' + '~~', summary: '/* ' + row.req.title + ' */ תגובה', nocreate: 1
			});
		}).then(function () {
			textarea.value = '';
			done('נשמר.');
			return fetchRequestSection(row.req).then(function (sec) {
				row.req.status = sec.req.status === 'done' || row.req.mech === 'exists' ? 'done' : sec.req.status;
				row.req.lastReply = sec.req.lastReply;
				row.req.replyTemplates = sec.req.replyTemplates;
				requestsState.flash = 'התגובה נשמרה ✓';
				renderRequests(); // מצייר מחדש ופותח שוב את הפסקה (openTitle)
			});
		}).catch(function (e) {
			done(e && e.message === 'moved' ? 'הדף השתנה מאז הטעינה - לא נשמר. לחץ "רענון".' : 'שגיאה - לא נשמר: ' + (e && (e.message || e.code) || e), true);
		});
	}

	function loadCultureTab() {
		cultureState.selected = null;
		var target = $id('mchl-table-target');
		if (cultureState.subcats) { renderCulturePicker(); return; }
		target.innerHTML = skeletonRows();
		var myId = ++loadRequestId;
		mwApiFetch({
			action: 'query', generator: 'categorymembers',
			gcmtitle: CATEGORY_MAINTENANCE_CULTURE, gcmtype: 'subcat', gcmlimit: '50',
			prop: 'categoryinfo'
		}).then(function (data) {
			var pages = (data.query && data.query.pages) || [];
			cultureState.subcats = pages.map(function (p) {
				return { title: p.title, count: (p.categoryinfo && p.categoryinfo.pages) || 0 };
			}).sort(function (a, b) { return a.title.localeCompare(b.title, 'he'); });
			if (myId !== loadRequestId || activeTab !== 'culture') return;
			renderCulturePicker();
		}).catch(function (e) { if (activeTab === 'culture') showError(e); });
	}

	function renderCulturePicker() {
		var target = $id('mchl-table-target');
		if (!cultureState.subcats || cultureState.subcats.length === 0) {
			target.innerHTML = '<div class="mchl-state"><div class="mchl-big">לא נמצאו תתי-קטגוריות</div>ייתכן ששם קטגוריית האם השתנה במכלול.</div>';
			return;
		}
		var html = '<div class="mchl-culture-picker">' + cultureState.subcats.map(function (s) {
			var shortLabel = s.title.replace(CATEGORY_MAINTENANCE_CULTURE + '/', '');
			return '<button type="button" class="mchl-culture-pill" data-action="select-culture-subcat" data-subcat="' + escapeHtml(s.title) + '">' +
				escapeHtml(shortLabel) + ' <span class="mchl-count">' + s.count.toLocaleString('he-IL') + '</span></button>';
		}).join('') + '</div>';
		target.innerHTML = html;
	}

	function selectCultureSubcat(subcat) {
		cultureState.selected = subcat;
		cultureState.members = [];
		cultureState.continueToken = null;
		loadCultureMembers();
	}

	function loadCultureMembers() {
		cultureState.loading = true;
		renderCultureList();
		var params = {
			action: 'query', list: 'categorymembers',
			cmtitle: cultureState.selected, cmtype: 'page', cmnamespace: '0', cmlimit: '50'
		};
		if (cultureState.continueToken) params.cmcontinue = cultureState.continueToken;
		var myId = ++loadRequestId, mySubcat = cultureState.selected;
		mwApiFetch(params).then(function (data) {
			if (myId !== loadRequestId || activeTab !== 'culture' || cultureState.selected !== mySubcat) { cultureState.loading = false; return; }
			var members = (data.query && data.query.categorymembers) || [];
			cultureState.members = cultureState.members.concat(members);
			cultureState.continueToken = (data.continue && data.continue.cmcontinue) || null;
			cultureState.loading = false;
			renderCultureList();
		}).catch(function (e) {
			cultureState.loading = false;
			if (activeTab === 'culture') showError(e);
		});
	}

	function renderCultureList() {
		if (!cultureState.selected) return;
		var target = $id('mchl-table-target');
		var shortLabel = cultureState.selected.replace(CATEGORY_MAINTENANCE_CULTURE + '/', '');
		var backBtn = '<button type="button" class="mchl-clear-filters" data-action="culture-back" style="display:block;margin-bottom:10px;">‹ חזרה לרשימת תתי-הקטגוריות</button>';
		var header = '<div class="mchl-eyebrow" style="margin-bottom:10px;">' + escapeHtml(shortLabel) + '</div>';
		if (cultureState.members.length === 0 && !cultureState.loading) {
			target.innerHTML = backBtn + header + '<div class="mchl-state"><div class="mchl-big">אין דפים</div></div>';
			return;
		}
		var list = '<table><tbody>' + cultureState.members.map(function (m) {
			return '<tr><td class="mchl-title"><a href="' + mechalolEditUrl(m.title) + '" target="_blank" rel="noopener">' + escapeHtml(m.title) + '</a></td></tr>';
		}).join('') + '</tbody></table>';
		var loadMore = cultureState.continueToken ?
			'<div style="padding:14px;text-align:center;"><button type="button" class="mchl-export-btn" data-action="culture-load-more" ' + (cultureState.loading ? 'disabled' : '') + '>' +
			(cultureState.loading ? 'טוען…' : 'טען עוד') + '</button></div>' :
			(cultureState.loading ? '<div style="padding:14px;text-align:center;" class="mchl-muted">טוען…</div>' : '');
		target.innerHTML = backBtn + header + list + loadMore;
	}

	function buildDynamicFilters() {
		var host = $id('mchl-dynamic-filters');
		host.innerHTML = '';
		var cfg = VIEWS[activeTab];
		cfg.filters.forEach(function (f) {
			var options = allowedFilterOptions(cfg, f);
			// ערך שנבחר ואינו מותר עוד (יציאה מהחשבון) - מנוקה; ואם נשארה אפשרות אחת, אין מה לסנן.
			if (activeFilters[f.key] && options.indexOf(activeFilters[f.key]) < 0) delete activeFilters[f.key];
			if (options.length < 2 && cfg.loginOnly && cfg.loginOnly.key === f.key) return;
			var sel = document.createElement('select');
			sel.className = 'mchl-filter-select';
			sel.id = 'mchl-filter-' + f.key;
			var opts = '<option value="">' + escapeHtml(f.label) + ' — הכול</option>';
			options.forEach(function (o) {
				var label = f.display ? f.display[o] : o;
				opts += '<option value="' + escapeHtml(o) + '">' + escapeHtml(label) + '</option>';
			});
			sel.innerHTML = opts;
			sel.addEventListener('change', function () {
				if (sel.value) activeFilters[f.key] = sel.value; else delete activeFilters[f.key];
				currentPage = 0;
				loadActiveView();
				toggleClearFiltersBtn();
			});
			host.appendChild(sel);
		});
		var side = $id('mchl-side');
		$id('mchl-body').classList.toggle('mchl-with-side', !!cfg.easyImport);
		side.style.display = cfg.easyImport ? 'block' : 'none';
		if (cfg.easyImport) buildEasyImportFilters(side, cfg);
		else { side.innerHTML = ''; $id('mchl-wf-meter').style.display = 'none'; renderChips(); }
		toggleClearFiltersBtn();
	}

	// ===== פאנל המסננים בצד - טאבי "חסר במכלול" =====
	// כל מסנן הוא משתנה מצב (wf...), ו-applyContentLevelFilter מתרגם את כולם ל-activeFilters.
	// ליד כל אפשרות - מספר הערכים (מתוך report_missing_word_filter_summary, בהתחשב בשאר
	// המסננים שבסיכום: רמה, מילוני, תמונות, נושא). חיפוש, ערכים חדשים, קוד מוסתר ואורך
	// לא נכללים בסיכום, ולכן המספרים לא מושפעים מהם.
	var wfImagesChoice = ''; // '' / 'with' / 'without'
	var wfExcludeNew = true; // בלי ערכים שנוצרו בשבועיים האחרונים
	var wfRedirectChoice = ''; // '' / 'absent' / 'unchecked' (רק בטאב "חסר במכלול")
	var wfMaxLen = '';
	var wfSettingsOpen = false;
	var wfTopicOpen = { 0: true, 1: false, 2: true }; // אילו קבוצות נושא פתוחות
	var WF_LEVEL_OPTIONS = {
		ctx: [['clean', 'נקי', '#5C9686'], ['clean_wording', 'נקי או דורש ניסוח', null], ['wording', 'דורש ניסוח', '#7C8C99'],
			['review_low', 'חשד נמוך', '#A8A860'], ['review_medium', 'חשד בינוני', '#D9B44A'], ['review_high', 'חשד גבוה', '#D98B3A'],
			['problem', 'בעיה ודאית', '#C1634A'], ['unscanned', 'טרם נסרק', '#3A4A52']],
		list: [['clean', 'נקי', '#5C9686'], ['clean_wording', 'נקי או דורש ניסוח', null], ['wording', 'דורש ניסוח', '#7C8C99'],
			['review', 'לבדיקה', '#D9B44A'], ['problem', 'בעיה ודאית', '#C1634A'], ['unscanned', 'טרם נסרק', '#3A4A52']]
	};
	var WF_LEVEL_LABELS = { review_medium_up: 'חשד בינוני וגבוה' };
	WF_LEVEL_OPTIONS.ctx.concat(WF_LEVEL_OPTIONS.list).forEach(function (o) { WF_LEVEL_LABELS[o[0]] = o[1]; });

	function buildEasyImportFilters(side, cfg) {
		if (!cfg.redirectFilter) wfRedirectChoice = '';
		applyContentLevelFilter();
		renderSide();
		side.onclick = onSideClick;
		side.onchange = onSideChange;
		side.oninput = onSideInput;
		renderWfMeter();
		renderChips();
	}

	function segHtml(kind, current, options) {
		return '<div class="mchl-seg">' + options.map(function (o) {
			return '<button type="button" data-side="' + kind + '" data-v="' + o[0] + '"' + (current === o[0] ? ' class="mchl-on"' : '') + '>' +
				escapeHtml(o[1]) + (o[2] ? ' <span class="mchl-n" data-count="' + kind + ':' + o[0] + '"></span>' : '') + '</button>';
		}).join('') + '</div>';
	}

	function renderSide() {
		var side = $id('mchl-side');
		var cfg = VIEWS[activeTab];
		if (!side || !cfg || !cfg.easyImport) return;
		var html = '<div class="mchl-side-top"><span>מסננים</span><button type="button" data-action="toggle-side" title="הסתרת המסננים">‹ הסתרה</button></div>';
		// הגדרות החישוב - נקבעות פעם אחת, ולכן מקופלות.
		html += '<div class="mchl-side-sec"><div class="mchl-settings-line"><span>רמה ' +
			(wfMethod === 'ctx' ? '<b>לפי המילה והמשפט</b>' : '<b>לפי המילה בלבד</b>') + ' · ' +
			(wfMode === 's' ? '<b>כולל מילים מוצעות</b>' : '<b>מילים שאושרו</b>') + '</span>' +
			'<button type="button" data-side="settings">⚙ ' + (wfSettingsOpen ? 'סגירה' : 'שינוי') + '</button></div>';
		if (wfSettingsOpen) {
			html += '<div class="mchl-settings-box">' +
				'<div class="mchl-side-h">איך נקבעת רמת התוכן</div>' +
				'<label class="mchl-radio"><input type="radio" name="wf-method" value="ctx"' + (wfMethod === 'ctx' ? ' checked' : '') + '> לפי המילה והמשפט שלה <span class="mchl-hint">(מומלץ) - מילה בעייתית, או מילה דו-משמעית במשפט חשוד, קובעת "בעיה ודאית"; אחרת חשד גבוה, בינוני או נמוך</span></label>' +
				'<label class="mchl-radio"><input type="radio" name="wf-method" value="list"' + (wfMethod === 'list' ? ' checked' : '') + '> לפי המילה בלבד <span class="mchl-hint">- הרמה שכתובה ליד המילה ברשימה: "בעיה ודאית" או "לבדיקה"</span></label>' +
				'<div class="mchl-side-h">אילו מילים נבדקות</div>' +
				'<label class="mchl-radio"><input type="radio" name="wf-mode" value="a"' + (wfMode === 'a' ? ' checked' : '') + '> רק מילים שאושרו</label>' +
				'<label class="mchl-radio"><input type="radio" name="wf-mode" value="s"' + (wfMode === 's' ? ' checked' : '') + '> גם מילים שהוצעו וטרם אושרו</label>' +
				'</div>';
		}
		html += '</div>';
		// רמת תוכן
		html += '<div class="mchl-side-sec"><div class="mchl-side-h">רמת תוכן' +
			(wfLevelChoice ? ' <button type="button" class="mchl-link" data-side="level" data-v="">הכול</button>' : '') + '</div>';
		WF_LEVEL_OPTIONS[wfMethod].forEach(function (o) {
			html += '<button type="button" class="mchl-opt' + (wfLevelChoice === o[0] ? ' mchl-on' : '') + (o[2] ? '' : ' mchl-opt-sub') + '" data-side="level" data-v="' + o[0] + '">' +
				(o[2] ? '<span class="mchl-dot-c" style="background:' + o[2] + '"></span>' : '') + escapeHtml(o[1]) +
				'<span class="mchl-n" data-count="level:' + o[0] + '"></span></button>';
		});
		html += '</div>';
		// ייבוא מילוני ותמונות - שורות כפתורים, זו מעל זו
		html += '<div class="mchl-side-sec"><div class="mchl-side-h">ייבוא מילוני</div>' +
			segHtml('dict', wfDictChoice, [['', 'הכול'], ['without', 'ללא מילוני', 1], ['only', 'מילוני בלבד', 1]]) +
			'<div class="mchl-side-h" style="margin-top:10px;">תמונות</div>' +
			segHtml('img', wfImagesChoice, [['', 'הכול'], ['with', 'עם תמונות', 1], ['without', 'בלי תמונות', 1]]) + '</div>';
		// נושא
		html += '<div class="mchl-side-sec"><div class="mchl-side-h">נושא' +
			(wfTopicChoice.length ? ' <button type="button" class="mchl-link" data-side="topic-none">ניקוי</button>' : '') + '</div>';
		WF_TOPIC_GROUPS.forEach(function (g, gi) {
			var all = g.items.every(function (it) { return wfTopicChoice.indexOf(it[0]) >= 0; });
			var some = !all && g.items.some(function (it) { return wfTopicChoice.indexOf(it[0]) >= 0; });
			html += '<div class="mchl-tgroup"><div class="mchl-thead"><label><input type="checkbox" data-tgroup="' + gi + '"' + (all ? ' checked' : '') +
				(some ? ' data-some="1"' : '') + '> ' + escapeHtml(g.label) + '</label><span class="mchl-n" data-count="tgroup:' + gi + '"></span>' +
				'<button type="button" class="mchl-tg-toggle" data-side="tg-toggle" data-g="' + gi + '">' + (wfTopicOpen[gi] ? '▾' : '▸') + '</button></div>';
			if (wfTopicOpen[gi]) {
				html += '<div class="mchl-titems">' + g.items.map(function (it) {
					return '<label class="mchl-titem"><input type="checkbox" value="' + it[0] + '"' + (wfTopicChoice.indexOf(it[0]) >= 0 ? ' checked' : '') + '> ' +
						escapeHtml(it[1]) + '<span class="mchl-n" data-count="topic:' + it[0] + '"></span></label>';
				}).join('') + '</div>';
			}
			html += '</div>';
		});
		html += '</div>';
		// עוד
		html += '<div class="mchl-side-sec"><div class="mchl-side-h">מילים בקוד המוסתר</div>' +
			segHtml('hidden', wfHiddenChoice, [['', 'הכול'], ['with', 'יש'], ['without', 'אין']]) +
			'<div class="mchl-side-h" style="margin-top:10px;">שמות הקודש</div>' +
			segHtml('names', wfNamesChoice, [['', 'הכול'], ['with', 'יש'], ['without', 'אין']]);
		if (cfg.redirectFilter) {
			html += '<div class="mchl-side-h" style="margin-top:10px;">הפניה במכלול</div>' +
				segHtml('redirect', wfRedirectChoice, [['', 'הכול'], ['absent', 'נבדק - אין'], ['unchecked', 'טרם נבדק']]);
		}
		html += '<label class="mchl-check"><input type="checkbox" data-side-check="new"' + (wfExcludeNew ? ' checked' : '') + '> בלי ערכים חדשים (' + NEW_ARTICLE_CUTOFF_DAYS + ' יום)</label>' +
			'<label class="mchl-check">אורך מקסימלי <input type="number" min="0" class="mchl-filter-number" data-side-input="maxlen" placeholder="בתים" value="' + escapeHtml(wfMaxLen) + '"></label>' +
			'<div class="mchl-hint" style="margin-top:8px;">המספרים ליד האפשרויות לא מושפעים מחיפוש, מערכים חדשים, מהקוד המוסתר ומאורך.</div></div>';
		var theme = uiPrefs.theme === 'light' ? 'light' : 'dark';
		html += '<div class="mchl-side-sec"><div class="mchl-side-h">עיצוב</div><div class="mchl-theme-toggle">' +
			'<button type="button" data-action="set-theme" data-v="dark"' + (theme === 'dark' ? ' class="mchl-on"' : '') + '>כהה</button>' +
			'<button type="button" data-action="set-theme" data-v="light"' + (theme === 'light' ? ' class="mchl-on"' : '') + '>בהיר</button></div></div>';
		$id('mchl-side').innerHTML = html;
		applySideCollapse();
		$id('mchl-side').querySelectorAll('input[data-some]').forEach(function (cb) { cb.indeterminate = true; });
		renderSideCounts();
	}

	function onEasyChange(keepSide) {
		applyContentLevelFilter();
		currentPage = 0; loadActiveView();
		if (!keepSide) renderSide();
		renderWfMeter();
		renderChips();
	}

	function onSideClick(e) {
		var head = e.target.closest('.mchl-side-h.mchl-collapsible');
		if (head && !e.target.closest('button, input, label')) { toggleSideSection(head); return; }
		var b = e.target.closest('[data-side]');
		if (!b) return;
		var kind = b.getAttribute('data-side'), v = b.getAttribute('data-v');
		if (kind === 'settings') { wfSettingsOpen = !wfSettingsOpen; renderSide(); return; }
		if (kind === 'tg-toggle') { var g = b.getAttribute('data-g'); wfTopicOpen[g] = !wfTopicOpen[g]; renderSide(); return; }
		if (kind === 'level') wfLevelChoice = (wfLevelChoice === v ? '' : v);
		else if (kind === 'dict') wfDictChoice = v;
		else if (kind === 'img') wfImagesChoice = v;
		else if (kind === 'hidden') wfHiddenChoice = v;
		else if (kind === 'names') wfNamesChoice = v;
		else if (kind === 'redirect') wfRedirectChoice = v;
		else if (kind === 'topic-none') wfTopicChoice = [];
		else return;
		onEasyChange();
	}

	function onSideChange(e) {
		var t = e.target;
		if (t.name === 'wf-method') {
			wfMethod = t.value;
			// "לבדיקה" ורמות החשד לא קיימים בשתי השיטות
			if (!WF_LEVEL_OPTIONS[wfMethod].some(function (o) { return o[0] === wfLevelChoice; })) wfLevelChoice = /^review/.test(wfLevelChoice) ? (wfMethod === 'list' ? 'review' : '') : wfLevelChoice;
		} else if (t.name === 'wf-mode') wfMode = t.value;
		else if (t.hasAttribute('data-tgroup')) {
			var codes = WF_TOPIC_GROUPS[+t.getAttribute('data-tgroup')].items.map(function (it) { return it[0]; });
			wfTopicChoice = wfTopicChoice.filter(function (c) { return codes.indexOf(c) < 0; });
			if (t.checked) wfTopicChoice = wfTopicChoice.concat(codes);
		} else if (t.getAttribute('data-side-check') === 'new') wfExcludeNew = t.checked;
		else if (t.type === 'checkbox' && t.value && WF_TOPIC_LABELS[t.value]) {
			wfTopicChoice = wfTopicChoice.filter(function (c) { return c !== t.value; });
			if (t.checked) wfTopicChoice.push(t.value);
		} else return;
		onEasyChange();
	}

	var wfLenDebounce = null;
	function onSideInput(e) {
		if (e.target.getAttribute('data-side-input') !== 'maxlen') return;
		wfMaxLen = e.target.value.trim();
		clearTimeout(wfLenDebounce);
		wfLenDebounce = setTimeout(function () { onEasyChange(true); }, 450);
	}

	// האם שורה (בעמודות ה-view או הסיכום) מתאימה לבחירת הרמה.
	function wfLevelMatches(row, choice) {
		var level = wfRowLevel(row);
		switch (choice) {
			case '': return true;
			case 'unscanned': return !level;
			case 'clean_wording': return level === 'clean' || level === 'wording';
			case 'review': return level === 'review' || level === 'high' || level === 'medium' || level === 'low';
			case 'review_low': return level === 'low';
			case 'review_medium': return level === 'medium';
			case 'review_high': return level === 'high';
			case 'review_medium_up': return level === 'high' || level === 'medium';
			default: return level === choice;
		}
	}

	// שורת סיכום עוברת את המסננים הנוכחיים, חוץ מ-skip (כדי לספור את האפשרויות שלו).
	function wfSummaryPasses(r, skip) {
		if (r.redirect !== (activeTab === 'missing_redirect')) return false;
		if (skip !== 'img' && wfImagesChoice && r.has_images !== (wfImagesChoice === 'with')) return false;
		if (skip !== 'dict' && wfDictChoice && r.dictionary !== (wfDictChoice === 'only')) return false;
		if (skip !== 'topic' && wfTopicChoice.length && wfTopicChoice.indexOf(r.topic) < 0) return false;
		if (skip !== 'level' && !wfLevelMatches(r, wfLevelChoice)) return false;
		return true;
	}

	// מקטעים בפאנל המסננים - לחיצה על הכותרת מקפלת/פותחת (נזכר בין כניסות).
	function applySideCollapse() {
		var collapsed = uiPrefs.sideCollapsed || {};
		document.querySelectorAll('#mchl-side .mchl-side-sec').forEach(function (sec) {
			var h = sec.querySelector(':scope > .mchl-side-h');
			if (!h) return;
			var key = (h.firstChild && h.firstChild.nodeType === 3 ? h.firstChild.nodeValue : h.textContent).trim();
			sec.setAttribute('data-sec', key);
			h.classList.add('mchl-collapsible');
			sec.classList.toggle('mchl-collapsed', !!collapsed[key]);
		});
	}
	function toggleSideSection(h) {
		var sec = h.closest('.mchl-side-sec');
		var key = sec && sec.getAttribute('data-sec');
		if (!key) return;
		uiPrefs.sideCollapsed = uiPrefs.sideCollapsed || {};
		uiPrefs.sideCollapsed[key] = !uiPrefs.sideCollapsed[key];
		if (!uiPrefs.sideCollapsed[key]) delete uiPrefs.sideCollapsed[key];
		saveUiPrefs();
		sec.classList.toggle('mchl-collapsed', !!uiPrefs.sideCollapsed[key]);
	}
	function applySidePanel() {
		var hidden = !!uiPrefs.sideHidden;
		$id('mchl-body').classList.toggle('mchl-side-hidden', hidden);
	}
	// תפריט הצד של האתר (Vector) - מוסתר כברירת מחדל בדשבורד, כדי שיהיה מקום לטבלה.
	// לשונית קטנה בקצה המסך, צמודה לתפריט האתר: "תפריט ›" כשהוא מוסתר, "‹ הסתרה" לידו כשהוא מוצג.
	function applySiteNav() {
		var hidden = uiPrefs.siteNavHidden !== false;
		document.body.classList.toggle('mchl-no-site-nav', hidden);
		var b = $id('mchl-sitenav-btn');
		if (!b) {
			b = document.createElement('button');
			b.type = 'button';
			b.id = 'mchl-sitenav-btn';
			b.className = 'mchl-sitenav-tab';
			b.addEventListener('click', function () { uiPrefs.siteNavHidden = !(uiPrefs.siteNavHidden !== false); saveUiPrefs(); applySiteNav(); });
			document.body.appendChild(b);
		}
		b.textContent = hidden ? '☰ תפריט האתר' : '✕ הסתרת התפריט';
		b.title = hidden ? 'הצגת תפריט הצד של האתר' : 'הסתרת תפריט הצד של האתר';
	}

	function renderSideCounts() {
		var side = $id('mchl-side');
		if (!side || !wfSummary) return;
		var counts = {};
		var add = function (k, n) { counts[k] = (counts[k] || 0) + n; };
		wfSummary.forEach(function (r) {
			if (wfSummaryPasses(r, 'level')) WF_LEVEL_OPTIONS[wfMethod].forEach(function (o) { if (wfLevelMatches(r, o[0])) add('level:' + o[0], r.n); });
			if (wfSummaryPasses(r, 'dict')) add('dict:' + (r.dictionary ? 'only' : 'without'), r.n);
			if (wfSummaryPasses(r, 'img')) add('img:' + (r.has_images ? 'with' : 'without'), r.n);
			if (wfSummaryPasses(r, 'topic') && r.topic) {
				add('topic:' + r.topic, r.n);
				WF_TOPIC_GROUPS.forEach(function (g, gi) { if (g.items.some(function (it) { return it[0] === r.topic; })) add('tgroup:' + gi, r.n); });
			}
		});
		side.querySelectorAll('[data-count]').forEach(function (el) {
			var n = counts[el.getAttribute('data-count')] || 0;
			el.textContent = n.toLocaleString('he-IL');
			var opt = el.closest('.mchl-opt');
			if (opt && el.getAttribute('data-count') === 'level:unscanned') opt.style.display = n ? '' : 'none';
		});
	}

	// שורת התגיות: כל מסנן פעיל, עם ✕ להסרה, ומספר התוצאות.
	function renderChips() {
		var host = $id('mchl-chips');
		var cfg = VIEWS[activeTab];
		if (!host) return;
		if (!cfg || !cfg.easyImport) { host.style.display = 'none'; return; }
		var chips = [];
		if (wfLevelChoice) chips.push(['level', 'רמה: ' + (WF_LEVEL_LABELS[wfLevelChoice] || wfLevelChoice)]);
		if (wfDictChoice) chips.push(['dict', wfDictChoice === 'only' ? 'מילוני בלבד' : 'ללא מילוני']);
		if (wfImagesChoice) chips.push(['img', wfImagesChoice === 'with' ? 'עם תמונות' : 'בלי תמונות']);
		if (wfTopicChoice.length) chips.push(['topic', wfTopicChoice.length === 1 ? 'נושא: ' + WF_TOPIC_LABELS[wfTopicChoice[0]] : wfTopicChoice.length + ' נושאים']);
		if (wfHiddenChoice) chips.push(['hidden', wfHiddenChoice === 'with' ? 'יש מילים בקוד המוסתר' : 'אין מילים בקוד המוסתר']);
		if (wfNamesChoice) chips.push(['names', wfNamesChoice === 'with' ? 'יש שמות הקודש' : 'אין שמות הקודש']);
		if (wfRedirectChoice) chips.push(['redirect', wfRedirectChoice === 'absent' ? 'נבדק - אין הפניה' : 'הפניה - טרם נבדק']);
		if (wfMaxLen) chips.push(['maxlen', 'עד ' + Number(wfMaxLen).toLocaleString('he-IL') + ' בתים']);
		if (wfExcludeNew) chips.push(['new', 'בלי ערכים חדשים']);
		var search = ($id('mchl-search-input').value || '').trim();
		if (search) chips.push(['search', 'חיפוש: ' + search]);
		host.style.display = 'flex';
		host.innerHTML = chips.map(function (c) {
			return '<button type="button" class="mchl-chip" data-action="chip-remove" data-chip="' + c[0] + '" title="הסרת המסנן">' + escapeHtml(c[1]) + ' ✕</button>';
		}).join('') + (chips.length > 1 ? '<button type="button" class="mchl-link" data-action="clear-filters">ניקוי הכול</button>' : '') +
			'<span class="mchl-chips-total" id="mchl-chips-total">' + (totalRows ? totalRows.toLocaleString('he-IL') + ' ערכים' : '') + '</span>';
	}

	function removeChip(kind) {
		if (kind === 'level') wfLevelChoice = '';
		else if (kind === 'dict') wfDictChoice = '';
		else if (kind === 'img') wfImagesChoice = '';
		else if (kind === 'topic') wfTopicChoice = [];
		else if (kind === 'hidden') wfHiddenChoice = '';
		else if (kind === 'names') wfNamesChoice = '';
		else if (kind === 'redirect') wfRedirectChoice = '';
		else if (kind === 'maxlen') wfMaxLen = '';
		else if (kind === 'new') wfExcludeNew = false;
		else if (kind === 'search') $id('mchl-search-input').value = '';
		onEasyChange();
	}

	function applyContentLevelFilter() {
		['verdict', 'verdict_suggested', 'ctx_verdict', 'ctx_verdict_suggested', 'ctx_suspicion', 'ctx_suspicion_suggested',
			'hidden_count', 'hidden_count_suggested', 'names_count', 'names_count_suggested', 'dictionary', 'topic', 'has_images', 'created_at', 'mechalol_redirect_exists', 'easy_import_length']
			.forEach(function (c) { delete activeFilters[c]; });
		if (wfTopicChoice.length) activeFilters.topic = { op: 'in', value: '(' + wfTopicChoice.join(',') + ')' };
		if (wfDictChoice) activeFilters.dictionary = { op: wfDictChoice === 'only' ? 'not.is' : 'is', value: 'null' };
		if (wfImagesChoice) activeFilters.has_images = { op: 'eq', value: wfImagesChoice === 'with' };
		if (wfExcludeNew) activeFilters.created_at = { op: 'lt', value: newArticleCutoffIso() };
		if (wfRedirectChoice === 'absent') activeFilters.mechalol_redirect_exists = { op: 'eq', value: false };
		else if (wfRedirectChoice === 'unchecked') activeFilters.mechalol_redirect_exists = { op: 'is', value: 'null' };
		if (wfMaxLen && !isNaN(Number(wfMaxLen))) activeFilters.easy_import_length = { op: 'lte', value: Number(wfMaxLen) };
		if (wfHiddenChoice) activeFilters[wfHiddenColumn()] = wfHiddenChoice === 'with' ? { op: 'gt', value: 0 } : { op: 'eq', value: 0 };
		if (wfNamesChoice) activeFilters[wfNamesColumn()] = wfNamesChoice === 'with' ? { op: 'gt', value: 0 } : { op: 'eq', value: 0 };
		var col = wfColumn(), v = wfLevelChoice;
		if (!v) return;
		var sub = /^review_(high|medium|low|medium_up)$/.exec(v);
		if (v === 'unscanned') activeFilters[col] = { op: 'is', value: 'null' };
		else if (v === 'clean_wording') activeFilters[col] = { op: 'in', value: '(clean,wording)' };
		else if (sub) {
			activeFilters[col] = { op: 'eq', value: 'review' };
			// בשיטת הרשימה אין רמות חשד - "לבדיקה" כולו.
			if (wfMethod === 'ctx') {
				activeFilters[wfSuspicionColumn()] = sub[1] === 'medium_up' ? { op: 'in', value: '(high,medium)' } : { op: 'eq', value: sub[1] };
			}
		} else activeFilters[col] = { op: 'eq', value: v };
	}

	// ===== מחוון הפילוח - כמה ערכים בכל רמה (לפי הטאב ושאר המסננים שבסיכום) =====
	var WF_METER_SEGMENTS = [
		{ key: 'problem', label: 'בעיה ודאית', color: '#C1634A', filter: 'problem' },
		{ key: 'high', label: 'חשד גבוה', color: '#D98B3A', filter: 'review_high' },
		{ key: 'medium', label: 'חשד בינוני', color: '#D9B44A', filter: 'review_medium' },
		{ key: 'low', label: 'חשד נמוך', color: '#A8A860', filter: 'review_low' },
		{ key: 'review', label: 'לבדיקה', color: '#D9B44A', filter: 'review' },
		{ key: 'wording', label: 'דורש ניסוח', color: '#7C8C99', filter: 'wording' },
		{ key: 'clean', label: 'נקי', color: '#5C9686', filter: 'clean' },
		{ key: null, label: 'טרם נסרק', color: '#3A4A52', filter: 'unscanned' }
	];

	function loadWfSummary(force) {
		if (wfSummary && !force) return Promise.resolve(wfSummary);
		// בדפים של 1,000 שורות - סופבייס מגביל תשובה אחת (max rows).
		var rows = [];
		function page(from) {
			return pgSelect('report_missing_word_filter_summary', { filterParams: [], order: 'n.desc,redirect.asc,has_images.asc,verdict.asc,verdict_suggested.asc,ctx_verdict.asc,ctx_suspicion.asc,ctx_verdict_suggested.asc,ctx_suspicion_suggested.asc,dictionary.asc,topic.asc', from: from, to: from + 999 })
				.then(function (res) {
					var data = res.data || [];
					rows = rows.concat(data);
					if (data.length && (res.count != null ? rows.length < res.count : data.length === 1000)) return page(rows.length);
					wfSummary = rows;
					return wfSummary;
				});
		}
		return page(0);
	}

	function renderWfMeter() {
		var host = $id('mchl-wf-meter');
		var cfg = VIEWS[activeTab];
		if (!cfg || !cfg.easyImport) { host.style.display = 'none'; return; }
		host.style.display = 'block';
		loadWfSummary().then(function (rows) {
			if (!VIEWS[activeTab] || !VIEWS[activeTab].easyImport) return;
			var counts = {}, total = 0;
			rows.forEach(function (r) {
				if (!wfSummaryPasses(r, 'level')) return;
				var level = wfRowLevel(r);
				counts[level] = (counts[level] || 0) + r.n;
				total += r.n;
			});
			var segs = WF_METER_SEGMENTS.filter(function (g) {
				if (wfMethod === 'ctx' && g.key === 'review') return (counts.review || 0) > 0;
				if (wfMethod === 'list' && (g.key === 'high' || g.key === 'medium' || g.key === 'low')) return false;
				return true;
			});
			var bar = '', legend = '';
			segs.forEach(function (g) {
				var n = counts[g.key] || 0;
				if (!n && g.key === null) return;
				var pct = total ? (100 * n / total) : 0;
				var active = wfLevelChoice === g.filter ? ' mchl-wf-active' : '';
				bar += '<div class="mchl-wf-seg" data-action="wf-meter-filter" data-filter="' + g.filter + '" style="width:' + pct.toFixed(2) +
					'%;background:' + g.color + ';" title="' + escapeHtml(g.label) + ': ' + n.toLocaleString('he-IL') + '"></div>';
				legend += '<button type="button" class="mchl-wf-legend' + active + '" data-action="wf-meter-filter" data-filter="' + g.filter + '">' +
					'<span class="mchl-wf-dot" style="background:' + g.color + ';"></span>' + escapeHtml(g.label) + ' <b>' +
					n.toLocaleString('he-IL') + '</b> <span class="mchl-muted">' + pct.toFixed(1) + '%</span></button>';
			});
			host.innerHTML = '<div class="mchl-wf-meter-head">פילוח לפי רמת תוכן · ' + total.toLocaleString('he-IL') +
				' ערכים <span class="mchl-muted">(לפי שאר המסננים; לחיצה מסננת)</span></div>' +
				'<div class="mchl-wf-bar">' + bar + '</div><div class="mchl-wf-legends">' + legend + '</div>';
			renderSideCounts();
		}).catch(function () {
			host.innerHTML = '<div class="mchl-muted">לא ניתן לטעון את פילוח התוכן (report_missing_word_filter_summary).</div>';
		});
	}

	function setWfLevel(value) {
		wfLevelChoice = value;
		onEasyChange();
	}

	function toggleClearFiltersBtn() {
		var hasFilters = Object.keys(activeFilters).length > 0 || $id('mchl-search-input').value.trim().length > 0;
		// בטאבי "חסר במכלול" - שורת התגיות מחליפה את הכפתור.
		var easy = VIEWS[activeTab] && VIEWS[activeTab].easyImport;
		$id('mchl-clear-filters-btn').style.display = hasFilters && !easy ? 'inline' : 'none';
	}

	function clearFilters() {
		activeFilters = {};
		wfLevelChoice = '';
		wfHiddenChoice = '';
		wfNamesChoice = '';
		wfDictChoice = '';
		wfTopicChoice = [];
		wfImagesChoice = '';
		wfRedirectChoice = '';
		wfMaxLen = '';
		wfExcludeNew = true;
		$id('mchl-search-input').value = '';
		currentPage = 0;
		buildDynamicFilters();
		loadActiveView();
	}

	function onPageSizeChange() {
		pageSize = parseInt($id('mchl-page-size').value, 10);
		currentPage = 0;
		loadActiveView();
	}

	function loadCurrentTab() {
		if (activeTab === 'stats') return loadStats();
		if (activeTab === 'requests') return Promise.resolve(loadRequestsTab());
		if (EXTRA_TABS[activeTab]) {
			cultureState.subcats = null; // כפתור רענון אמור לשלוף מחדש, לא להסתפק במטמון
			return Promise.resolve(loadCultureTab());
		}
		return loadActiveView();
	}

	function refreshAll() {
		var btn = $id('mchl-refresh-btn');
		// רענון מלא: גם הפרטים שנטענו (הקשר, הפניות) נשלפים מחדש.
		wfDetailsCache.clear();
		if (updateMod) updateMod.clear();
		mechalolRedirectTargetCache.clear();
		btn.classList.add('mchl-spinning');
		wfSummary = null;
		countsLoaded = {}; // רענון סופר מחדש רק את הקבוצה הפעילה
		if (VIEWS[activeTab] && VIEWS[activeTab].easyImport) renderWfMeter();
		return Promise.all([loadStats(), loadCurrentTab(), fetchLastSyncTime().catch(function () { return undefined; })]).then(function (results) {
			btn.classList.remove('mchl-spinning');
			var lastSync = results[2];
			var note = $id('mchl-sync-note');
			if (lastSync) {
				note.textContent = 'עדכון אחרון מהתהליך — ' + new Date(lastSync).toLocaleString('he-IL', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
			} else {
				note.textContent = 'נבדק בדפדפן — ' + new Date().toLocaleTimeString('he-IL', { hour: '2-digit', minute: '2-digit' }) + ' (לא ניתן לשלוף את זמן העדכון האמיתי)';
			}
		});
	}

	function fetchLastSyncTime() {
		return withRetry(function () {
			// זמן הריצה האחרונה של העדכון הלילי (sync_watermarks, שתי שורות).
			// קודם: מיון כל wikipedia_pages לפי checked_at - סריקה מלאה של
			// 405 אלף שורות בכל רענון, שחרגה מזמן הריצה המותר כשהמטמון קר.
			var params = new URLSearchParams();
			params.set('select', 'last_synced_ts');
			params.set('order', 'last_synced_ts.desc');
			var url = SUPABASE_URL + '/rest/v1/sync_watermarks?' + params.toString();
			return fetch(url, { headers: pgHeaders({ Range: '0-0' }) }).then(function (res) {
				if (!res.ok) throw new Error('HTTP ' + res.status);
				return res.json();
			}).then(function (data) {
				return (data && data.length) ? data[0].last_synced_ts : null;
			});
		});
	}

	// מריץ פונקציות שמחזירות הבטחות, לכל היותר limit במקביל (המסד קטן, וכ-13 ספירות בבת אחת חורגות מ-15 השניות של anon).
	// מחזיר תוצאות לפי הסדר; פונקציה שנכשלה נותנת null.
	var STATS_CONCURRENCY = 3;
	function runLimited(fns, limit) {
		var results = new Array(fns.length), next = 0;
		function worker() {
			if (next >= fns.length) return Promise.resolve();
			var idx = next++;
			return Promise.resolve().then(fns[idx]).then(function (r) { results[idx] = r; }, function () { results[idx] = null; }).then(worker);
		}
		var workers = [];
		for (var w = 0; w < Math.min(limit, fns.length); w++) workers.push(worker());
		return Promise.all(workers).then(function () { return results; });
	}

	// ===== ספירות: רק לקבוצה הפעילה, והערך האחרון השמור מוצג עד הרענון =====
	// פתיחת הדשבורד לא סופרת עוד את כל הלשוניות: ספירות של קבוצה נטענות כשהיא נפתחת (switchTab), ורענון סופר רק את הפעילה.
	// הערך האחרון נשמר ב-localStorage (בדפדפן של כל משתמש) ומוצג מיד, מעומעם ועם זמן העדכון, עד שהספירה החיה חוזרת.
	var COUNTS_CACHE_KEY = 'mchl-counts-cache';
	var countsLoaded = {}; // group key -> true אחרי שנטענו הספירות שלה במחזור הנוכחי
	function readCountCache() { try { return JSON.parse(localStorage.getItem(COUNTS_CACHE_KEY) || '{}') || {}; } catch (e) { return {}; } }
	function writeCountCache(id, val) {
		try { var c = readCountCache(); c[id] = { v: val, t: Date.now() }; localStorage.setItem(COUNTS_CACHE_KEY, JSON.stringify(c)); } catch (e) { /* לא נשמר - לא נורא */ }
	}
	function setCountBadge(id, val) {
		var el = $id(id);
		if (!el) return;
		el.textContent = val.toLocaleString('he-IL');
		el.classList.remove('mchl-count-stale');
		el.removeAttribute('title');
		writeCountCache(id, val);
	}
	function paintCachedCount(id) {
		var el = $id(id), c = readCountCache()[id];
		if (!el || !c || typeof c.v !== 'number') return;
		el.textContent = c.v.toLocaleString('he-IL');
		el.classList.add('mchl-count-stale');
		el.title = 'נכון ל-' + new Date(c.t).toLocaleString('he-IL', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) + ' - יתרענן כשהקבוצה נפתחת';
	}

	function loadStats() { return loadGroupCounts(groupOfTab(activeTab)); }

	function loadGroupCounts(g) {
		if (countsLoaded[g.key]) return Promise.resolve();
		countsLoaded[g.key] = true;
		var isStats = g.key === 'stats';
		var tabIds = g.tabs.map(function (k) { return 'mchl-tab-count-' + k; });
		// כרטיסי הסטטיסטיקה: כולם בקבוצת "נתונים סטטיסטיים"; בשאר הקבוצות רק מה שמוצג כמונה של לשונית שלהן.
		var defs = STAT_DEFS.filter(function (d) { return isStats || (d.tabCount && tabIds.indexOf(d.tabCount) >= 0); });
		defs.forEach(function (d) {
			$id(d.spinId).style.display = 'inline-block';
			$id(d.warnId).style.display = 'none';
		});
		var statValues = {};
		var jobs = defs.map(function (d) { return function () {
			var viewCfg = d.viewKey ? VIEWS[d.viewKey] : null;
			return pgCount(d.table, viewCfg ? baseFiltersOf(viewCfg) : null, undefined, d.estimated).then(function (val) {
				statValues[d.key] = val;
				// ספירה משוערת (מהמתכנן) מסומנת ב-~ ובתיאור.
				$id(d.statId).textContent = (d.estimated ? '~' : '') + val.toLocaleString('he-IL');
				$id(d.statId).title = d.estimated ? 'ספירה משוערת' : '';
				if (d.tabCount) setCountBadge(d.tabCount, val);
			}).catch(function (e) {
				statValues[d.key] = null;
				var w = $id(d.warnId);
				w.style.display = 'inline';
				w.title = isTransientMaintenanceError(e)
					? 'המסד באמצע עדכון תקופתי - ינסה שוב אוטומטית ברענון הבא'
					: d.warnMsg + ' (' + (e.message || e) + ')';
			}).finally(function () {
				$id(d.spinId).style.display = 'none';
			});
		}; });
		// מוני לשוניות של ה-views שאין להם כרטיס סטטיסטיקה משלהם (רק של הקבוצה הזו).
		var coveredTabs = {};
		defs.forEach(function (d) { if (d.tabCount) coveredTabs[d.tabCount] = true; });
		g.tabs.forEach(function (key) {
			var tabCountId = 'mchl-tab-count-' + key;
			if (!VIEWS[key] || coveredTabs[tabCountId] || !tabAllowed(key)) return;
			var cfg = VIEWS[key];
			jobs.push(function () {
				return pgCount(cfg.view, baseFiltersOf(cfg), cfg.countColumn).then(function (val) {
					setCountBadge(tabCountId, val);
				}).catch(function () { /* המונה נשאר כמו שהיה */ });
			});
		});
		var fns = jobs;
		if (isStats) {
			// "תואמים" = דפי מכלול עם קישור לוויקיפדיה, *פחות* אלה שגם מופיעים
			// במשימות הגרסה (למשל "העברת שם" - מקושרים אבל עדיין משימה),
			// אחרת הם נספרים פעמיים בפס.
			var matchedJob = function () { return pgCount('mechalol_pages', [['wikipedia_id', 'not.is.null']], undefined, true).catch(function () { return null; }); };
			var tasksLinkedJob = function () { return pgCount('report_rev_tasks', [['wikipedia_id', 'not.is.null']]).catch(function () { return null; }); };
			fns = [matchedJob, tasksLinkedJob].concat(jobs);
		}
		return runLimited(fns, STATS_CONCURRENCY).then(function (results) {
			if (!isStats) return;
			var matched = (results[0] != null && results[1] != null) ? results[0] - results[1] : null;
			var tasks = statValues.tasks, missing = statValues.missing;
			if (matched != null && tasks != null && missing != null) {
				var total = matched + tasks + missing;
				var pct = function (n) { return total ? (100 * n / total).toFixed(1) : 0; };
				var bar = $id('mchl-ledger-bar');
				bar.children[0].style.width = pct(matched) + '%';
				bar.children[1].style.width = pct(tasks) + '%';
				bar.children[2].style.width = pct(missing) + '%';
			}
		});
	}

	function loadActiveView(isAutoRetry) {
		var myRequestId = ++loadRequestId;
		var target = $id('mchl-table-target');
		target.innerHTML = skeletonRows();
		$id('mchl-pager').style.display = 'none';
		var cfg = VIEWS[activeTab];
		var from = currentPage * pageSize, to = from + pageSize - 1;
		return pgSelect(cfg.view, { filterParams: buildFilterParams(), order: cfg.order || 'title.asc', from: from, to: to }).then(function (res) {
			if (myRequestId !== loadRequestId) return;
			currentPageRows = res.data || [];
			countUnknown = res.count == null;
			// ספירה לא ידועה: מאפשרים "הבא" רק אם הדף מלא.
			totalRows = countUnknown ? from + currentPageRows.length + (currentPageRows.length === pageSize ? 1 : 0) : res.count;
			totalPages = Math.max(1, Math.ceil(totalRows / pageSize));
			renderTable();
			renderPager();
			var chipsTotal = $id('mchl-chips-total');
			if (chipsTotal) chipsTotal.textContent = countUnknown ? 'מספר הערכים לא ידוע' : totalRows.toLocaleString('he-IL') + ' ערכים';
			loadWikidataDescriptionsForCurrentPage();
			loadRedirectTargetsForCurrentPage();
			markExistingInMechalol();
			ensureUpdateForTab(cfg);
		}).catch(function (e) {
			if (myRequestId !== loadRequestId) return;
			// אם זו שגיאה שנראית כמו חלון העדכון השבועי ועוד לא ניסינו
			// ניסיון-נוסף מושהה - מחכים עוד קצת (מעבר לשלוש הניסיונות
			// המהירות של withRetry) לפני שמציגים למשתמש הודעת שגיאה בכלל.
			// חלון ה-swap עצמו קצר מאוד (lock_timeout של כמה שניות לכל
			// היותר) - סביר שהניסיון הזה יצליח בשקט, בלי שהמשתמש בכלל
			// יבחין שהיה עיכוב.
			if (!isAutoRetry && isTransientMaintenanceError(e) && e.code !== '57014') {
				sleep(4000).then(function () {
					if (myRequestId === loadRequestId) loadActiveView(true);
				});
				return;
			}
			showError(e, isAutoRetry && isTransientMaintenanceError(e));
		});
	}

	function skeletonRows() {
		var html = '<table><tbody>';
		for (var i = 0; i < 8; i++) html += '<tr><td style="padding:14px 16px;"><div class="mchl-skeleton" style="height:14px;width:' + (60 + Math.random() * 30) + '%;"></div></td></tr>';
		return html + '</tbody></table>';
	}

	function showError(e, isMaintenance) {
		if (isMaintenance) {
			// חלון העדכון השבועי - לא באג, לא תקלה. אין ערך למשתמש
			// בפרטים הטכניים (SQLSTATE/PGRST וכו') - רק הודעה ברורה ודרך
			// להמשיך הלאה.
			$id('mchl-table-target').innerHTML =
				'<div class="mchl-state"><div class="mchl-big">המסד באמצע עדכון תקופתי</div>' +
				'<div>זה קורה כל מוצאי שבת ונמשך בדרך כלל שניות בודדות. הנתונים יחזרו להיות זמינים מיד עם סיום העדכון.</div>' +
				'<button type="button" class="mchl-refresh" data-action="retry" style="margin:16px auto 0;"><span class="mchl-dot"></span> ניסיון נוסף</button></div>';
			return;
		}
		$id('mchl-table-target').innerHTML =
			'<div class="mchl-state mchl-error"><div class="mchl-big">שגיאה בטעינת הנתונים</div>' +
			'<div>נכשלו כמה ניסיונות חיבור ברצף. יש לבדוק חסימת CSP, ואת ה-RLS/הרשאות הקריאה על הטבלאות והתצוגות.</div>' +
			'<pre>' + escapeHtml(e && e.message ? e.message : JSON.stringify(e)) + '</pre>' +
			'<button type="button" class="mchl-refresh" data-action="retry" style="margin:16px auto 0;"><span class="mchl-dot"></span> ניסיון נוסף</button></div>';
	}

	// ===== ייבוא - כמו הכפתורים של הקישורים האדומים (Gadget-redLinksForImport) =====
	// דרך mw.import של Gadget-mw-import: הקוד מוויקיפדיה עם ההחלפות האוטומטיות, {{וח}} ו-{{מיון ויקיפדיה}},
	// ונפתח בלשונית חדשה בתצוגה מקדימה - שום דבר לא נשמר בלי לחיצה על "שמירה".
	// ערך מילוני (עמודת dictionary) - במצב "בוט ייבוא" (mw-import-tionary.js): פתיח, בלי תמונות, {{בוט <סוג>}}.
	// הסוג לפי תבניות הבוט במכלול (word-filter/analysis/dictionary-rules.md); כשאין התאמה ברורה - ייבוא רגיל.
	// הסיווג (חיים, 2026-09-29), לפי הסוג (dictionary) והסיבה (dictionary_why: "תבנית X" / "קטגוריה X"):
	//   ספורט - ספורט. מוזיקה - מוזיקה (שירים, אלבומים, אירוויזיון...); מוזיקאים וזמרים, וגם להקות - מוזיקאים.
	//   שחקנים - רק שחקנים; דוגמנים, מנחים, קומיקאים, במאים וכו' - תרבות ובידור. סרטים - סרטים;
	//   תוכניות וסדרות טלוויזיה - טלוויזיה; דמות בדיונית, טקס פרסים, רקדנים - תרבות ובידור.
	//   ספרות ומשחקי מחשב - כמו שהם.
	var MUSICIANS_CAT = /(מוזיקאים|מוזיקאיות|נגני|מנצחים|מלחינים|פסנתרנים|כנרים|צ'לנים|זמרי|זמרים|זמרות|להקות|ראפרים|תקליטנים|אמני |אמניות |משתתפי אירוויזיון)/;
	var DANCERS_CAT = /(רקדני|רקדנים|רקדניות|כוריאוגרפים|כוריאוגרפיות)/;
	function importBotClass(row) {
		if (!row.dictionary) return null;
		var m = /^(תבנית|קטגוריה) (.*)$/.exec(row.dictionary_why || '') || [];
		var byTemplate = m[1] === 'תבנית', name = m[2] || '';
		switch (row.dictionary) {
			case 'ספורט': return 'ספורט';
			case 'מוזיקאים': return 'מוזיקאים';
			case 'מוזיקה':
				if (byTemplate) return name === 'להקה' ? 'מוזיקאים' : 'מוזיקה';
				if (MUSICIANS_CAT.test(name)) return 'מוזיקאים';
				if (DANCERS_CAT.test(name)) return 'תרבות ובידור';
				return 'מוזיקה';
			case 'שחקנים':
				if (byTemplate) return name === 'אישיות משחק' ? 'שחקנים' : 'תרבות ובידור';
				return /(שחקני|שחקניות)/.test(name) ? 'שחקנים' : 'תרבות ובידור';
			case 'סרטים':
				return /^(דמות בדיונית|טקס פרסי קולנוע)$/.test(name) ? 'תרבות ובידור' : 'סרטים';
			case 'טלוויזיה': return 'טלוויזיה';
			case 'סרטים וטלוויזיה':
				if (/^דמויות ב|זיכיונות מדיה/.test(name)) return 'תרבות ובידור';
				if (/טלוויזיה|סדרות|תוכניות/.test(name)) return 'טלוויזיה';
				if (/^סרטי/.test(name)) return 'סרטים';
				return 'תרבות ובידור';
			case 'ספרות': return 'ספרות';
			case 'משחקי מחשב': return 'משחקי מחשב';
		}
		return null;
	}

	// mw.import יכול להיות דרוס: הקובץ הישן מדיה ויקי:Gadget-mw-import.js (לא רשום כגאדג'ט) מגדיר
	// mw.import = {openForm, getProperties}, ואם הוא נטען בדף אחרי הגאדג'ט - המחלקה אובדת ("mw.import is
	// not a constructor"). לכן הקוד של ext.gadget.mw-import נטען כאן לעותק פרטי, בלי לגעת ב-mw.import הגלובלי.
	function loadImportPackage() {
		return $.ajax({
			url: mw.util.wikiScript('load'), dataType: 'text', cache: true,
			data: { modules: 'ext.gadget.mw-import', only: 'scripts', lang: mw.config.get('wgUserLanguage'), skin: mw.config.get('skin') }
		}).then(function (code) {
			var pkg = null;
			var local = Object.create(mw);
			local.loader = Object.create(mw.loader);
			local.loader.impl = function (fn) { var a = fn(); pkg = a[1]; };
			local.loader.implement = function (name, script) { pkg = script; };
			local.loader.state = function () {};
			new Function('mw', code)(local);
			if (!pkg || !pkg.files || !pkg.main) throw new Error('הקוד של mw-import לא נמצא');
			return { pkg: pkg, local: local };
		});
	}
	// רשימת ההחלפות הקבועות של הייבוא ("גיורים"), מתוך חבילת הגאדג'ט. נטענת פעם אחת.
	var importReplacementsPromise = null;
	function getImportReplacements() {
		if (!importReplacementsPromise) {
			importReplacementsPromise = loadImportPackage().then(function (r) {
				var files = r.pkg.files;
				var list = files['mw-import-replacements.json'] || files['./mw-import-replacements.json'];
				if (typeof list === 'string') list = JSON.parse(list);
				if (!Array.isArray(list)) throw new Error('רשימת ההחלפות לא נמצאה בחבילה');
				return list;
			});
			importReplacementsPromise.catch(function () { importReplacementsPromise = null; });
		}
		return importReplacementsPromise;
	}
	function loadImportClass() {
		return loadImportPackage().then(function (r) {
			var pkg = r.pkg, local = r.local;
			var cache = {};
			var req = function (name) {
				var key = name.replace(/^\.\//, '');
				if (cache[key]) return cache[key].exports;
				var file = pkg.files[key];
				if (typeof file !== 'function') return file;
				var module = cache[key] = { exports: {} };
				file(req, module, module.exports);
				return module.exports;
			};
			req(pkg.main);
			if (typeof local.import !== 'function') throw new Error('mw.import לא נוצר');
			return local.import;
		});
	}

	// ערכים מ"חסר במכלול" שכבר נוצרו במכלול מאז העדכון הלילי (ייבוא שלי או של מישהו אחר) -
	// נבדק בזמן אמת מול המכלול לכל עמוד, ושוב כשחוזרים ללשונית. וי ירוק וכפתור ייבוא מנוטרל.
	var existsNow = new Set();
	function markExistingInMechalol() {
		if (activeTab !== 'missing' || !currentPageRows.length) return;
		var titles = currentPageRows.map(function (r) { return r.title; }).filter(Boolean);
		batches(titles, 50).forEach(function (b) {
			mwApiFetch({ action: 'query', titles: b.join('|'), prop: 'info' }).then(function (d) {
				var q = d.query || {}, back = {};
				(q.normalized || []).forEach(function (n) { back[n.to] = n.from; });
				(q.pages || []).forEach(function (pg) { if (!pg.missing) existsNow.add(back[pg.title] || pg.title); });
				paintExisting();
			}).catch(function () { /* לא נבדק - נשאר כמו שהוא */ });
		});
	}
	function paintExisting() {
		document.querySelectorAll('#mchl-table-target button.mchl-import-btn[data-title]').forEach(function (btn) {
			var t = btn.getAttribute('data-title');
			if (!existsNow.has(t) || btn.hasAttribute('data-exists')) return;
			btn.setAttribute('data-exists', '1');
			btn.disabled = true;
			btn.title = 'כבר קיים במכלול';
			var link = btn.closest('tr') && btn.closest('tr').querySelector('.mchl-title');
			if (link) link.insertAdjacentHTML('beforeend', ' <span class="mchl-exists-now" title="כבר קיים במכלול (נוצר מאז העדכון האחרון)">✓</span>');
		});
	}
	document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') markExistingInMechalol(); });

	var importerPromise = null;
	function getImporter() {
		if (!importerPromise) {
			importerPromise = mw.loader.using(['mediawiki.api', 'mediawiki.Title', 'mediawiki.ForeignApi', 'mediawiki.util']).then(function () {
				return typeof mw.import === 'function' ? mw.import : loadImportClass();
			}).then(function (Import) { return new Import(); });
			importerPromise.catch(function () { importerPromise = null; });
		}
		return importerPromise;
	}

	function importFromDashboard(btn) {
		var title = btn.getAttribute('data-title');
		var bot = btn.getAttribute('data-bot') || false;
		if (!title || btn.disabled) return;
		btn.disabled = true;
		var label = btn.textContent;
		btn.textContent = 'טוען...';
		var done = function () { btn.disabled = false; btn.textContent = label; };
		getImporter().then(function (importer) {
			// form: true - importWikitext פותח את טופס העריכה בעצמו ולא מחזיר תוצאה.
			var p = importer.importWikitext({ page: title, exist: false, currentPage: title, form: true, bot: bot });
			if (p && p.catch) p.catch(function (err) { mw.notify(String(err), { type: 'warn' }); done(); });
			setTimeout(done, 1500);
		}).catch(function (err) {
			console.error('ייבוא מהדשבורד:', err);
			mw.notify('לא ניתן לטעון את גאדג\'ט הייבוא: ' + (err && err.message ? err.message : err), { type: 'error' });
			done();
		});
	}

	// ===== קביעת גרסת מקור מתוך הדשבורד =====
	// הלוגיקה (איתור תבנית, חישוב השינוי, חיפוש הגרסה בוויקיפדיה) היא של הסקריפט "משתמש:גאון הירדן/הוספת תאריך למיון ויקיפדיה.js"
	// (עותק בריפו: gadget/gadget-sortTemplateFix.js). הדשבורד לא מעתיק אותה: הוא טוען את הסקריפט מהאתר כמו את מודול העדכון,
	// והסקריפט חושף אותה ב-mw.sortTemplateFix. כאן רק הממשק: היסטוריית הערך, בחירת שורת הייבוא, תצוגה מקדימה ושמירה באישור.
	var SORT_FIX_SCRIPT_PAGE = 'משתמש:גאון הירדן/הוספת תאריך למיון ויקיפדיה.js';
	var sortFixPromise = null;
	function loadSortTemplateFix() {
		if (!sortFixPromise) {
			sortFixPromise = Promise.resolve(mw.loader.using(['mediawiki.api', 'mediawiki.util'])).then(function () {
				if (mw.sortTemplateFix) return null;
				return Promise.resolve(mw.loader.getScript(mw.util.wikiScript('index') + '?title=' + encodeURIComponent(SORT_FIX_SCRIPT_PAGE) + '&action=raw&ctype=text/javascript'));
			}).then(function () {
				if (!mw.sortTemplateFix) throw new Error('הסקריפט "' + SORT_FIX_SCRIPT_PAGE + '" נטען אבל לא חושף את mw.sortTemplateFix: צריך להחליף אותו בגרסה העדכנית (gadget/gadget-sortTemplateFix.js).');
				return mw.sortTemplateFix;
			});
			sortFixPromise.catch(function () { sortFixPromise = null; });
		}
		return sortFixPromise;
	}

	var fixSrc = (function () {
		var PAGE_BATCH = 20;
		var BOX_STYLE = 'margin:6px 0;padding:8px 12px;border:1px solid var(--mchl-border, #c8ccd1);border-radius:8px;background:var(--mchl-ink-800, #f8f9fa);';

		function errText(e) { return e && e.message ? e.message : String(e); }
		function el(tag, props, children) {
			var node = document.createElement(tag);
			Object.keys(props || {}).forEach(function (k) {
				if (k === 'style') node.style.cssText = props[k]; else if (k === 'text') node.textContent = props[k]; else node.setAttribute(k, props[k]);
			});
			(children || []).forEach(function (c) { node.appendChild(c); });
			return node;
		}
		// mw.Api דוחה עם (code, data): עוטפים ושומרים גם את המידע.
		function mwCall(promise) {
			return new Promise(function (resolve, reject) {
				promise.then(resolve, function (code, data) {
					reject(new Error(code + (data && data.error && data.error.info ? ': ' + data.error.info : '')));
				});
			});
		}

		function setBody(state, nodes) {
			state.panel.textContent = '';
			nodes.forEach(function (n) { state.panel.appendChild(n); });
		}
		function setStatus(state, text, kind) {
			setBody(state, [el('div', { text: text, style: kind === 'error' ? 'color:var(--mchl-alert, #a94442);' : kind === 'ok' ? 'color:var(--mchl-wiki, #3c763d);' : 'opacity:.8;' })]);
		}

		// שדה לשם דף ויקיפדיה (כשאין תבנית או שאין בה דף=), עם השלמה אוטומטית. מחזיר Promise לשם, או null אם בוטל.
		function askTitle(state, defaultTitle) {
			var fix = state.fix;
			return new Promise(function (resolve) {
				var input = el('input', { type: 'text', list: 'mchl-fix-titles', style: 'width:22em;direction:rtl;' });
				input.value = defaultTitle;
				var list = el('datalist', { id: 'mchl-fix-titles' });
				var timer;
				input.addEventListener('input', function () {
					clearTimeout(timer);
					timer = setTimeout(function () {
						if (!input.value.trim()) return;
						fix.wikipediaApi({ action: 'opensearch', search: input.value, limit: '8', namespace: '0' }).then(function (d) {
							list.textContent = '';
							(d[1] || []).forEach(function (t) { list.appendChild(el('option', { value: t })); });
						}).catch(function () { /* ההשלמה אופציונלית */ });
					}, 250);
				});
				var ok = el('button', { text: 'המשך', type: 'button', 'class': 'mchl-import-btn' });
				var cancel = el('button', { text: 'ביטול', type: 'button', 'class': 'mchl-import-btn', style: 'margin-right:6px;' });
				setBody(state, [el('div', {}, [el('div', { text: 'אין תבנית מיון עם דף=. שם הערך בוויקיפדיה:' }), input, list, ok, cancel])]);
				ok.addEventListener('click', function () { var v = fix.normTitle(input.value); if (v) resolve(v); });
				cancel.addEventListener('click', function () { resolve(null); });
				input.focus();
			});
		}

		function describePlan(fix, plan, wp, tsHamichlol) {
			var box = el('div', {});
			box.appendChild(el('div', { text: 'גרסת ויקיפדיה שנמצאה: ' + wp.revid + ' (' + fix.formatJerusalemTime(wp.ts) + ') בערך "' + wp.title + '", לפי זמן השורה ' + fix.formatJerusalemTime(tsHamichlol) }));
			if (plan.created) {
				box.appendChild(el('div', { text: 'אין תבנית מיון בערך, תתווסף שורה חדשה:' }));
			} else {
				plan.changes.forEach(function (c) {
					box.appendChild(el('div', { text: c.name + ': ' + (c.from || '(חסר)') + ' ← ' + c.to }));
				});
			}
			if (plan.removedCategory) box.appendChild(el('div', { text: 'תוסר קטגוריית התחזוקה "ללא תבנית מיון ויקיפדיה".' }));
			var ctx = fix.previewContext(plan.text, 2);
			if (ctx) {
				var view = el('div', { dir: 'rtl', style: 'margin:4px 0;border:1px solid #c8ccd1;background:#fff;color:#202122;font-family:monospace;font-size:0.9em;text-align:right;' });
				var addLine = function (text, hit) {
					view.appendChild(el('div', { text: text === '' ? ' ' : text, dir: 'rtl', style: 'white-space:pre-wrap;padding:1px 6px;unicode-bidi:plaintext;' + (hit ? 'background:#d8f0d8;' : '') }));
				};
				if (ctx.before) addLine('…', false);
				ctx.lines.forEach(function (l) { addLine(l.text, l.hit); });
				if (ctx.after) addLine('…', false);
				box.appendChild(view);
			}
			return box;
		}

		function headerNodes(state) {
			var link = el('a', { href: mechalolFixSourceUrl(state.title), target: '_blank', rel: 'noopener', text: 'פתח את ההיסטוריה בדף' });
			return el('div', { style: 'margin-bottom:6px;' }, [
				el('strong', { text: 'קביעת גרסת מקור: ' }),
				document.createTextNode('בוחרים את שורת הייבוא (בדרך כלל הראשונה). שום דבר לא נשמר בלי אישור.  '),
				link
			]);
		}

		function loadRevisions(state, fresh) {
			if (fresh) { state.revs = []; state.cont = null; }
			setStatus(state, 'טוען את היסטוריית הערך…');
			var params = { action: 'query', prop: 'revisions', titles: state.title, rvlimit: String(PAGE_BATCH), rvdir: state.dir, rvprop: 'ids|timestamp|user|comment' };
			if (state.cont) params.rvcontinue = state.cont;
			return mwApiFetch(params).then(function (d) {
				var page = d.query && d.query.pages && d.query.pages[0];
				if (!page || page.missing) throw new Error('הערך לא נמצא במכלול.');
				state.revs = state.revs.concat(page.revisions || []);
				state.cont = (d['continue'] && d['continue'].rvcontinue) || null;
				renderList(state);
			}).catch(function (e) { setStatus(state, 'טעינת ההיסטוריה נכשלה: ' + errText(e), 'error'); });
		}

		function renderList(state) {
			var nodes = [headerNodes(state)];
			var dirBtn = el('button', { type: 'button', 'class': 'mchl-import-btn', text: state.dir === 'newer' ? 'להציג מהחדשה' : 'להציג מהישנה' });
			dirBtn.addEventListener('click', function () { state.dir = state.dir === 'newer' ? 'older' : 'newer'; loadRevisions(state, true); });
			nodes.push(el('div', { style: 'margin-bottom:6px;' }, [el('span', { text: state.dir === 'newer' ? 'מהישנה לחדשה  ' : 'מהחדשה לישנה  ', style: 'opacity:.8;' }), dirBtn]));
			var table = el('table', { style: 'width:100%;' });
			state.revs.forEach(function (rev) {
				var pick = el('button', { type: 'button', 'class': 'mchl-import-btn', text: 'זו שורת הייבוא' });
				pick.addEventListener('click', function () { choose(state, rev); });
				table.appendChild(el('tr', {}, [
					el('td', { text: state.fix.formatJerusalemTime(rev.timestamp), style: 'white-space:nowrap;' }),
					el('td', { text: rev.user || '(מוסתר)' }),
					el('td', { text: (rev.comment || '').slice(0, 120) }),
					el('td', {}, [pick])
				]));
			});
			nodes.push(table);
			if (state.cont) {
				var more = el('button', { type: 'button', 'class': 'mchl-import-btn', text: 'עוד', style: 'margin-top:6px;' });
				more.addEventListener('click', function () { loadRevisions(state, false); });
				nodes.push(more);
			}
			setBody(state, nodes);
		}

		// בחירת שורה: שולף את התוכן הנוכחי, מוצא את גרסת ויקיפדיה לפי זמן השורה, ומציג תכנית לאישור.
		function choose(state, rev) {
			var fix = state.fix;
			setStatus(state, 'מעבד…');
			var rv, content, tplPage, wp, values, date;
			return mwApiFetch({ action: 'query', prop: 'revisions', titles: state.title, rvprop: 'content|timestamp', rvslots: 'main' }).then(function (cur) {
				var page = cur.query.pages[0];
				if (page.missing) throw new Error('הערך חסר או שלא ניתן לקרוא אותו.');
				rv = page.revisions[0];
				var slot = rv.slots && rv.slots.main;
				if (!slot || typeof slot.content !== 'string') throw new Error('תוכן הערך חסר או מוסתר.');
				content = slot.content;
				tplPage = fix.sortTemplatePage(content);
				return tplPage ? tplPage : askTitle(state, fix.normTitle(state.hint));
			}).then(function (wpTitle) {
				if (!wpTitle) { renderList(state); return null; }
				setStatus(state, 'מחפש את גרסת ויקיפדיה…');
				return fix.lookupWikipediaRevision(wpTitle, rev.timestamp).then(function (found) {
					wp = found;
					date = fix.sortDateFromTimestamp(rev.timestamp);
					var titleDiffers = !!tplPage && fix.normTitle(wp.title) !== tplPage;
					values = { page: fix.normTitle(wp.title), rev: wp.revid, item: wp.item, date: date };
					var plan = fix.planSortTemplate(content, Object.assign({ updatePage: titleDiffers }, values));
					if (!plan.created && plan.changes.length === 0 && !plan.removedCategory) {
						setStatus(state, 'אין מה לתקן: הגרסה והתאריך כבר תואמים (גרסה ' + wp.revid + ').', 'ok');
						state.onDone();
						return;
					}
					var pageBox = null, nodes = [headerNodes(state), describePlan(fix, plan, wp, rev.timestamp)];
					if (titleDiffers) {
						pageBox = el('input', { type: 'checkbox', checked: 'checked' });
						nodes.push(el('label', {}, [pageBox, document.createTextNode(' הערך הועבר בוויקיפדיה ל"' + wp.title + '" - לעדכן גם דף=')]));
					}
					var confirmBtn = el('button', { text: 'שמור', type: 'button', 'class': 'mchl-import-btn', style: 'margin-top:4px;' });
					var cancelBtn = el('button', { text: 'חזרה לרשימה', type: 'button', 'class': 'mchl-import-btn', style: 'margin-right:6px;' });
					nodes.push(el('div', {}, [confirmBtn, cancelBtn]));
					setBody(state, nodes);
					cancelBtn.addEventListener('click', function () { renderList(state); });
					confirmBtn.addEventListener('click', function () {
						confirmBtn.disabled = true;
						cancelBtn.disabled = true;
						var final = fix.planSortTemplate(content, Object.assign({ updatePage: !!(pageBox && pageBox.checked) }, values));
						var summary = 'תיקון גרסת מקור: ויקיפדיה גרסה ' + wp.revid + (final.created ? ' (הוספת תבנית מיון)' : '');
						mw.loader.using('mediawiki.api').then(function () {
							return mwCall(new mw.Api().postWithToken('csrf', {
								action: 'edit', title: state.title, text: final.text, summary: summary, bot: true,
								basetimestamp: rv.timestamp, nocreate: true, formatversion: 2
							}));
						}).then(function (res) {
							if (!res.edit || res.edit.result !== 'Success') throw new Error('השמירה לא הצליחה: ' + JSON.stringify(res.edit || res));
							setStatus(state, (res.edit.nochange ? 'אין שינוי בדף.' : 'נשמר: גרסה ' + wp.revid + ', ' + date + '.') + ' הערך יצא מהטאב אחרי "רענן נתוני תחזוקה".', 'ok');
							state.onDone();
						}).catch(function (e) {
							console.error('שגיאה בשמירת גרסת מקור:', e);
							setStatus(state, 'שגיאה בשמירה: ' + errText(e), 'error');
						});
					});
				});
			}).catch(function (e) {
				console.error('שגיאה בקביעת גרסת מקור:', e);
				setStatus(state, errText(e), 'error');
			});
		}

		// פותח או סוגר פאנל מתחת לשורה של הכפתור.
		function toggle(btn) {
			var tr = btn.closest('tr');
			var next = tr.nextElementSibling;
			if (next && next.classList.contains('mchl-fix-row')) { next.parentNode.removeChild(next); return; }
			var title = btn.getAttribute('data-title');
			var row = currentPageRows.filter(function (r) { return r.title === title; })[0] || {};
			var panel = el('div', { style: BOX_STYLE });
			var panelRow = el('tr', { 'class': 'mchl-fix-row' }, [el('td', { colspan: String(tr.children.length) }, [panel])]);
			tr.parentNode.insertBefore(panelRow, tr.nextSibling);
			var state = {
				title: title, hint: row.linked_title || row.rev_page_title || title, dir: 'newer', cont: null, revs: [], panel: panel, fix: null,
				onDone: function () { btn.textContent = 'בוצע ✓'; btn.disabled = true; tr.style.opacity = '0.6'; }
			};
			setStatus(state, 'טוען את הסקריפט של קביעת הגרסה…');
			loadSortTemplateFix().then(function (fix) {
				state.fix = fix;
				return loadRevisions(state, true);
			}).catch(function (e) { setStatus(state, 'לא ניתן לטעון את הסקריפט: ' + errText(e), 'error'); });
		}

		return { toggle: toggle };
	})();

	function effectiveColumns(cfg) {
		// עמודת השיוך הידני מתווספת רק בטאב "חסר במכלול", ורק כש-
		// יש חיבור פעיל - לא כל מבקר בטאב הזה אמור לראות אותה בכלל.
		var cols = cfg.displayColumns || cfg.columns;
		if (VIEWS[activeTab] && VIEWS[activeTab].manualMatch && serviceKeyConnected) {
			var at = cols.indexOf('import_action');
			return at < 0 ? cols.concat(['manual_match_action']) : cols.slice(0, at).concat(['manual_match_action'], cols.slice(at));
		}
		return cols;
	}

	// ===== טאב "עדכון": הקוד ב-gadget-searchHelperDashboard-update.js, נטען כשנפתח הטאב =====
	// המודול קורא את מה שהדשבורד חושף ב-window.mchlDash, ורושם בו את mchlDash.update.
	var UPDATE_MODULE_PAGE = 'משתמש:בוט גאון הירדן/dashboard.js/update.js';
	var updateMod = null;
	var updateModPromise = null;
	function loadUpdateModule() {
		if (!updateModPromise) {
			window.mchlDash = {
				escapeHtml: escapeHtml, withRetry: withRetry, batches: batches, mwApiFetch: mwApiFetch, mechalolEditUrl: mechalolEditUrl,
				pgHeaders: pgHeaders, $id: $id, SUPABASE_URL: SUPABASE_URL, getImportReplacements: getImportReplacements,
				activeTab: function () { return activeTab; }, cfg: function () { return VIEWS[activeTab]; }, rows: function () { return currentPageRows; }
			};
			updateModPromise = Promise.resolve(mw.loader.getScript(mw.util.wikiScript('index') + '?title=' + encodeURIComponent(UPDATE_MODULE_PAGE) + '&action=raw&ctype=text/javascript')).then(function () {
				if (!window.mchlDash.update) throw new Error('המודול נטען אבל לא נרשם');
				return (updateMod = window.mchlDash.update);
			});
			updateModPromise.catch(function () { updateModPromise = null; });
		}
		return updateModPromise;
	}
	// בפתיחת טאב שזקוק למודול: טוענים, מציירים מחדש (כותרת ותאים מלאים) ומפעילים את המידע החי.
	function ensureUpdateForTab(cfg) {
		if (!cfg.liveChange && !cfg.freshness) return;
		var myTab = activeTab, wasLoaded = !!updateMod;
		loadUpdateModule().then(function (mod) {
			if (activeTab !== myTab) return;
			if (!wasLoaded) renderTable();
			if (cfg.freshness) mod.loadFreshness();
			mod.loadInfo();
		}, function (e) {
			var el = $id('mchl-update-fresh');
			if (el) el.innerHTML = '<span class="mchl-badge mchl-alert">מודול העדכון לא נטען: ' + escapeHtml(e && e.message ? e.message : e) + '</span>';
		});
	}
	function updateRowIsSame(row) { return updateMod ? updateMod.isSame(row) : false; }
	function renderUpdateChange(row) { return updateMod ? updateMod.renderChange(row) : '<span class="mchl-skeleton" style="display:inline-block;height:12px;width:70%;">&nbsp;</span>'; }
	function updateBannerHtml(cfg) {
		if (updateMod) return updateMod.bannerHtml(cfg);
		return cfg.freshness ? '<div class="mchl-update-note"><span id="mchl-update-fresh"><span class="mchl-muted">טוען את מודול העדכון…</span></span></div>' : '';
	}
	function toggleUpdatePanel(btn) { if (updateMod) updateMod.togglePanel(btn); }
	function openUpdateMerge(btn) { if (updateMod) updateMod.openMerge(btn); }
	function renderTable() {
		var cfg = VIEWS[activeTab];
		var columns = effectiveColumns(cfg);
		var banner = updateBannerHtml(cfg);
		if (currentPageRows.length === 0) {
			$id('mchl-table-target').innerHTML = banner + '<div class="mchl-state"><div class="mchl-big">אין תוצאות</div>אין שורות התואמות לסינון הנוכחי.</div>';
			return;
		}
		var allOnPageSelected = currentPageRows.every(function (r) { return selectedRows.has(rowKey(r)); });
		var thead = '<tr><th class="mchl-chk-col"><input type="checkbox" data-action="toggle-page-selection" ' + (allOnPageSelected ? 'checked' : '') + '></th>' +
			columns.map(function (c) { return '<th' + (c === 'import_action' || c === 'expand' || c === 'update_action' || c === 'fix_source_action' ? ' class="mchl-narrow-col"' : '') + '>' + escapeHtml(c in COLUMN_LABELS ? COLUMN_LABELS[c] : c) + '</th>'; }).join('') + '</tr>';
		var tbody = currentPageRows.map(function (r) {
			var selected = selectedRows.has(rowKey(r));
			var expandable = columns.indexOf('expand') >= 0 && wfHasDetails(r);
			return '<tr class="' + (selected ? 'mchl-selected' : '') + (expandable ? ' mchl-expandable' : '') + (updateRowIsSame(r) ? ' mchl-upd-same' : '') + '">' +
				'<td class="mchl-chk-col" data-label=""><input type="checkbox" data-action="toggle-row-selection" data-row-id="' + escapeHtml(rowIdOf(r)) + '" ' + (selected ? 'checked' : '') + '></td>' +
				columns.map(function (c) { return '<td data-label="' + escapeHtml(COLUMN_LABELS[c] || c) + '">' + renderCell(c, r) + '</td>'; }).join('') + '</tr>';
		}).join('');
		$id('mchl-table-target').innerHTML = banner + '<table><thead>' + thead + '</thead><tbody>' + tbody + '</tbody></table>';
		paintExisting();
	}

	function renderCell(col, row) {
		var val = row[col];
		if (col === 'title') {
			var linkMode = VIEWS[activeTab].titleLink;
			// בקריאה, לא בעריכה: לפי מזהה דף המכלול; בטאב "נעולים" לפי mechalol_id, ודף שעוד לא קיים (נעול ליצירה) לפי הכותרת
			var url = linkMode === 'edit' ? mechalolEditUrl(val)
				: linkMode === 'mechalol-read' ? (row.mechalol_id ? mechalolUrl(row.mechalol_id) : mechalolReadUrl(val))
				: mechalolUrl(row.id);
			var link = '<span class="mchl-title"><a href="' + url + '" target="_blank" rel="noopener">' + escapeHtml(val) + '</a></span>';
			// בטאבים עם displayColumns התיאור מוויקינתונים מוצג מתחת לכותרת, במקום עמודה משלו.
			if (VIEWS[activeTab].displayColumns && VIEWS[activeTab].wikidata) link += '<div class="mchl-row-desc">' + renderCell('wikidata_desc', row) + '</div>';
			return link;
		}
		if (col === 'topic') {
			if (row.dictionary) return '<span class="mchl-badge mchl-neutral" title="' + escapeHtml('מועמד לייבוא מילוני: ' + (row.dictionary_why || '')) + '">מילוני: ' + escapeHtml(row.dictionary) + '</span>';
			return row.topic && WF_TOPIC_LABELS[row.topic] ? '<span class="mchl-topic-cell">' + escapeHtml(WF_TOPIC_LABELS[row.topic]) + '</span>' : '<span class="mchl-muted">—</span>';
		}
		if (col === 'wf_matches') return renderWfMatches(row);
		if (col === 'import_action') {
			// "קיים במכלול כהפניה" - הפעולה היא לבדוק את יעד ההפניה, לא לייבא על ההפניה.
			if (activeTab === 'missing_redirect') return '<button type="button" class="mchl-import-btn" disabled title="קיים במכלול כהפניה - לבדוק את יעד ההפניה">ייבוא</button>';
			var bot = importBotClass(row);
			return '<button type="button" class="mchl-import-btn" data-action="import" data-title="' + escapeHtml(row.title) + '"' +
				(bot ? ' data-bot="' + escapeHtml(bot) + '"' : '') + ' title="' +
				escapeHtml(bot ? 'ייבוא מילוני (בוט ' + bot + '): פתיח, בלי תמונות - נפתח בלשונית חדשה לתצוגה מקדימה' : 'ייבוא - נפתח בלשונית חדשה לתצוגה מקדימה') + '">' +
				(bot ? 'ייבוא מילוני' : 'ייבוא') + '</button>';
		}
		if (col === 'expand') {
			return wfHasDetails(row) ? '<button type="button" class="mchl-expand-btn" data-action="wf-details" data-id="' + row.id + '" title="פרטים: המילים במשפט שלהן, הקוד המוסתר והתמונות" aria-expanded="false">▾</button>' : '';
		}
		if (col === 'update_date') {
			if (!row.sort_template_date) return '<span class="mchl-muted">ללא תאריך</span>';
			var updDate = new Date(row.sort_template_date + 'T00:00:00');
			return '<span class="mchl-num-cell" title="חודש העדכון המתועד בתבנית {{מיון ויקיפדיה}} (תאריך=)">' +
				escapeHtml(updDate.toLocaleDateString('he-IL', { month: 'long', year: 'numeric' })) + '</span>';
		}
		if (col === 'update_change') return renderUpdateChange(row);
		if (col === 'fix_source_action') return '<button type="button" class="mchl-import-btn" data-action="fix-source-open" data-title="' + escapeHtml(row.title) + '" title="פותח כאן את היסטוריית הערך: בוחרים את שורת הייבוא והכלי קובע גרסה ותאריך (נשמר רק באישור)">קבע גרסה</button>';
		if (col === 'update_action') return '<button type="button" class="mchl-import-btn" data-action="update-open" data-id="' + row.id + '" title="השוואה ומיזוג של מה שהתחדש בוויקיפדיה, ופתיחת טופס העריכה במכלול">עדכן</button>';
		if (col === 'wikipedia_title') return '<span class="mchl-title"><a href="' + wikipediaUrl(row.wikipedia_id) + '" target="_blank" rel="noopener">' + escapeHtml(val) + '</a></span>';
		if (col === 'mechalol_title') return '<a href="' + mechalolUrl(row.mechalol_id) + '" target="_blank" rel="noopener">' + escapeHtml(val) + '</a>';
		if (col === 'mechalol_status') return '<span class="mchl-badge mchl-neutral">' + escapeHtml(val) + '</span>';
		if (col === 'wikipedia_id') return val ? '<a href="' + wikipediaUrl(val) + '" target="_blank" rel="noopener" class="mchl-num-cell">' + val + '</a>' : '<span class="mchl-muted">—</span>';
		if (col === 'source_type') return '<span class="mchl-badge mchl-neutral">' + escapeHtml(SOURCE_TYPE_LABELS[val] || val) + '</span>';
		if (col === 'match_type') return '<span class="mchl-badge ' + (val === 'ללא התאמה' ? 'mchl-alert' : 'mchl-wiki') + '">' + escapeHtml(val) + '</span>';
		if (col === 'status') return '<span class="mchl-badge mchl-neutral">' + escapeHtml(val) + '</span>';
		if (col === 'lock_level') return '<span class="mchl-badge ' + (val === 'נעול לקריאה' ? 'mchl-alert' : 'mchl-neutral') + '">' + escapeHtml(val) + '</span>';
		if (col === 'lock_source') return '<span class="mchl-muted">' + escapeHtml(val) + '</span>';
		if (col === 'rev_page_title') {
			if (!val) return '<span class="mchl-muted">—</span>';
			return row.rev_page_id
				? '<a href="' + wikipediaUrl(row.rev_page_id) + '" target="_blank" rel="noopener">' + escapeHtml(val) + '</a>' : escapeHtml(val);
		}
		if (col === 'linked_title') return val ? '<a href="' + wikipediaUrl(row.wikipedia_id) + '" target="_blank" rel="noopener">' + escapeHtml(val) + '</a>' : '<span class="mchl-muted">—</span>';
		if (col === 'sort_template_rev') {
			return val ? '<a href="https://he.wikipedia.org/w/index.php?oldid=' + encodeURIComponent(val) + '" target="_blank" rel="noopener" class="mchl-num-cell" title="הגרסה בוויקיפדיה">' + val + '</a>' : '<span class="mchl-muted">חסרה</span>';
		}
		if (col === 'task_type') return '<span class="mchl-badge mchl-alert">' + escapeHtml(val) + '</span>';
		if (col === 'manual_match_action') {
			// כיוון הפוך מהעמודה הישנה (שהייתה ב"משימות לטיפול"): כאן row
			// היא שורת ויקיפדיה (מ-report_missing_from_mechalol) - ה-
			// wikipedia_id כבר ידוע (row.id), ומחפשים כותרת מכלולאית -
			// חיפוש חי (ilike התחלה, עד 5 תוצאות) במקום הקלדה עיוורת של
			// כותרת מדויקת. הכפתור מנוטרל עד שנבחרת הצעה בפועל (ראו
			// pickManualMatchSuggestion) - מונע ניסיון שיוך לפי טקסט חופשי
			// שלא נפתר לשורת מכלול אמיתית.
			//
			// כשיש הפניה קיימת במכלול (mechalol_redirect_exists) - ממלאים
			// מראש עם היעד האמיתי של ההפניה (מטמון mechalolRedirectTargetCache,
			// נבדק חי מול מדיה-ויקי) - המשתמש כבר לא צריך לדעת/להקליד את
			// הכותרת בעצמו ברוב המקרים, רק לאשר בלחיצה על "שייך". עדיין
			// אפשר לערוך את הטקסט ולחפש משהו אחר אם ההצעה לא נכונה.
			var redirectCached = row.mechalol_redirect_exists === true ? mechalolRedirectTargetCache.get(row.title) : undefined;
			var prefillTitle = (redirectCached && redirectCached.targetTitle) ? redirectCached.targetTitle : '';
			var prefillId = (redirectCached && redirectCached.mechalolId) ? redirectCached.mechalolId : '';
			var hintText = '';
			if (row.mechalol_redirect_exists === true) {
				hintText = redirectCached === undefined
					? 'בודק הפניה קיימת…'
					: (prefillTitle ? 'הצעה אוטומטית מהפניה קיימת - אפשר לשנות' : '');
			}
			return '<span class="mchl-manual-match-cell"' +
				(row.mechalol_redirect_exists === true ? ' data-redirect-check-title="' + escapeHtml(row.title) + '"' : '') +
				' data-wikipedia-id="' + row.id + '"' +
				(prefillId ? ' data-selected-mechalol-id="' + prefillId + '"' : '') + '>' +
				'<span class="mchl-manual-match-input-wrap">' +
				'<input type="text" class="mchl-search mchl-manual-match-input" placeholder="כותרת מכלולאית" autocomplete="off" value="' + escapeHtml(prefillTitle) + '">' +
				(hintText ? '<div class="mchl-manual-match-hint">' + escapeHtml(hintText) + '</div>' : '') +
				'</span>' +
				'<div class="mchl-manual-match-suggestions" style="display:none;"></div>' +
				'<button type="button" class="mchl-export-btn" data-action="assign-manual-match" data-wikipedia-id="' + row.id + '"' + (prefillId ? '' : ' disabled') + '>שייך</button>' +
				'</span>';
		}
		if (col === 'verdict') return renderContentLevel(row);
		if (col === 'has_images') {
			if (row.has_images === true) return '<span class="mchl-num-cell" title="תמונות של הערך">' + row.photo_count + '</span>';
			if (row.has_images === false) return '<span class="mchl-muted">אין</span>';
			return '<span class="mchl-muted">—</span>';
		}
		if (col === 'via') return '<span class="mchl-badge mchl-neutral" title="' + (val === 'template' ? 'שם התבנית (דף=) הוא שם ישן שכבר לא קיים בוויקיפדיה' : 'הכותרת שלנו זהה לשם הישן בוויקיפדיה') + '">' + (val === 'template' ? 'שם בתבנית' : 'כותרת') + '</span>';
		if (col === 'checked_at' || col === 'created_at' || col === 'detected_at' || col === 'renamed_at') return val ? '<span class="mchl-num-cell">' + new Date(val).toLocaleDateString('he-IL') + '</span>' : '<span class="mchl-muted">—</span>';
		if (col === 'mechalol_redirect_exists') {
			if (val === true) return '<span class="mchl-badge mchl-neutral">קיים כהפניה</span>';
			if (val === false) return '<span class="mchl-muted">אין בכלל</span>';
			return '<span class="mchl-muted">טרם נבדק</span>';
		}
		if (col === 'wikidata_desc') {
			var title = row.title;
			if (wikidataCache.has(title)) {
				var v = wikidataCache.get(title);
				if (v === null) return '<span class="mchl-muted" data-desc-title="' + escapeHtml(title) + '">שגיאה בשליפה</span>';
				if (v === '') return '<span class="mchl-muted" data-desc-title="' + escapeHtml(title) + '">—</span>';
				return '<span data-desc-title="' + escapeHtml(title) + '">' + escapeHtml(v) + '</span>';
			}
			return '<span class="mchl-skeleton" data-desc-title="' + escapeHtml(title) + '" style="display:inline-block;height:12px;width:70%;">&nbsp;</span>';
		}
		return escapeHtml(val == null ? '—' : val);
	}

	// רמת התוכן - התג בלבד. הספירות בעמודת "מילים", והפרטים בשורה הנפתחת.
	function renderContentLevel(row) {
		var level = wfRowLevel(row);
		if (!level) return '<span class="mchl-muted">טרם נסרק</span>';
		var info = WF_SUSPICION[level] || WF_LEVELS[level];
		return '<span class="mchl-badge ' + info.cls + '">' + escapeHtml(info.label) + '</span>';
	}

	function wfHasDetails(row) { return !!(row.matches_total || row.has_images || row[wfHiddenColumn()] || row[wfNamesColumn()]); }

	// ספירה קצרה של המילים שנמצאו, לפי השיטה והרשימות שנבחרו; ומילים בקוד המוסתר.
	function renderWfMatches(row) {
		var counts = row.counts && row.counts[(wfMethod === 'ctx' ? 'c' : '') + wfMode];
		var parts = [];
		if (counts) {
			if (counts.problem) parts.push(counts.problem + ' בעיה');
			if (wfMethod === 'ctx') {
				if (counts.high) parts.push(counts.high + ' גבוה');
				if (counts.medium) parts.push(counts.medium + ' בינוני');
				if (counts.low) parts.push(counts.low + ' נמוך');
			} else if (counts.review) parts.push(counts.review + ' לבדיקה');
			if (counts.wording) parts.push(counts.wording + ' ניסוח');
			if (counts.names) parts.push(counts.names + ' שמות הקודש');
		}
		var html = parts.length ? '<span class="mchl-num-cell mchl-nowrap">' + escapeHtml(parts.join(' · ')) + '</span>' : '<span class="mchl-muted">—</span>';
		var hidden = row[wfHiddenColumn()];
		if (hidden) html += ' <span class="mchl-tag" title="מילים בקוד שהקורא לא רואה - לא נספרות ברמה">' + hidden + ' בקוד</span>';
		return html;
	}

	// פרטי הסינון לערך אחד - שורה נפתחת מתחת לשורה בטבלה: כל מילה עם המשפט
	// שלה (העורך לא רואה כאן את הטקסט המלא), לפי הרשימות שנבחרו, ותמונות
	// הערך כתמונות ממוזערות - לחיצה פותחת מציג במסך מלא (openWfViewer).
	function toggleContentDetails(btn) {
		var id = btn.getAttribute('data-id');
		var tr = btn.closest('tr');
		var next = tr.nextElementSibling;
		if (next && next.classList.contains('mchl-wf-details-row')) {
			next.remove(); btn.textContent = '▾'; btn.setAttribute('aria-expanded', 'false'); tr.classList.remove('mchl-open'); return;
		}
		btn.textContent = '▴'; btn.setAttribute('aria-expanded', 'true'); tr.classList.add('mchl-open');
		var detailsTr = document.createElement('tr');
		detailsTr.className = 'mchl-wf-details-row';
		detailsTr.innerHTML = '<td colspan="' + tr.children.length + '"><div class="mchl-wf-box mchl-muted">טוען…</div></td>';
		tr.parentNode.insertBefore(detailsTr, tr.nextSibling);
		var box = detailsTr.querySelector('.mchl-wf-box');
		var row = currentPageRows.find(function (r) { return String(r.id) === id; });
		loadContentDetails(id).then(function (d) {
			// מנהל מחובר - גם הסימונים שלו (✗/✓), כדי להציג אותם ליד כל מילה.
			return (serviceKeyConnected ? loadWfFeedback(id).catch(function () { return null; }) : Promise.resolve(null))
				.then(function () { return d; });
		}).then(function (d) {
			box.classList.remove('mchl-muted');
			box.innerHTML = renderContentDetails(d, row);
		}).catch(function (e) {
			box.innerHTML = '<span class="mchl-alert">שגיאה בשליפת הפרטים: ' + escapeHtml(e.message || e) + '</span>';
		});
	}

	function loadContentDetails(id) {
		if (wfDetailsCache.has(id)) return Promise.resolve(wfDetailsCache.get(id));
		return withRetry(function () {
			var params = new URLSearchParams();
			params.set('select', 'matches,matches_total,images,photo_count,scanned_at,rev_id,lists_version');
			params.set('wikipedia_id', 'eq.' + id);
			return fetch(SUPABASE_URL + '/rest/v1/word_filter_results?' + params.toString(), { headers: pgHeaders() })
				.then(function (res) {
					if (!res.ok) return res.text().then(function (t) { throw makePgError(res.status, t); });
					return res.json();
				});
		}).then(function (rows) {
			var d = rows && rows[0];
			if (!d) throw new Error('אין תוצאות סריקה לערך הזה');
			wfDetailsCache.set(id, d);
			return d;
		});
	}

	// ===== סימון התראות: ✗ התראת שווא / ✓ בעייתי באמת (word_filter_feedback) =====
	// רק למנהל מחובר (אותה רשימה כמו שיוך ידני - is_manual_match_admin). הסימונים
	// מצטברים לכל רשומה ברשימות (word_filter_feedback_summary): תבנית שנצברו עליה
	// 10 סימוני ✗ ומעלה, או 20% מהמופעים, עולה לתיקון; מופע בודד נשאר בבדיקה.
	// ההתאמה מזוהה בערך לפי שורה + מילה + רשומות (wfMatchKey).
	var wfFeedbackCache = new Map(); // wikipedia_id -> { match_key: 'false' | 'true' }
	function wfMatchKey(m) { return m.line + ':' + m.x + ':' + (m.e || []).slice().sort().join(','); }
	function loadWfFeedback(id) {
		var params = new URLSearchParams();
		params.set('select', 'match_key,label');
		params.set('wikipedia_id', 'eq.' + id);
		return fetch(SUPABASE_URL + '/rest/v1/word_filter_feedback?' + params.toString(), { headers: authHeaders() })
			.then(function (res) {
				if (!res.ok) return res.text().then(function (t) { throw makePgError(res.status, t); });
				return res.json();
			}).then(function (rows) {
				var marks = {};
				rows.forEach(function (r) { marks[r.match_key] = r.label; });
				wfFeedbackCache.set(String(id), marks);
				return marks;
			});
	}
	function wfFeedbackButtons(id, d, m) {
		if (!serviceKeyConnected) return '';
		var mark = (wfFeedbackCache.get(String(id)) || {})[wfMatchKey(m)];
		var i = d.matches.indexOf(m);
		return ' <span class="mchl-wf-fb">' +
			'<button type="button" class="mchl-wf-fb-btn' + (mark === 'false' ? ' mchl-on-false' : '') + '" data-action="wf-feedback" data-label="false" data-mi="' + i +
			'" title="התראת שווא: זו לא המילה, או שימוש תמים">✗</button>' +
			'<button type="button" class="mchl-wf-fb-btn' + (mark === 'true' ? ' mchl-on-true' : '') + '" data-action="wf-feedback" data-label="true" data-mi="' + i +
			'" title="בעייתי באמת">✓</button></span>';
	}
	function wfFeedback(btn) {
		var detailsRow = btn.closest('tr.mchl-wf-details-row');
		var id = detailsRow && detailsRow.previousElementSibling.querySelector('[data-action="wf-details"]').getAttribute('data-id');
		var d = id && wfDetailsCache.get(id);
		var m = d && d.matches[parseInt(btn.getAttribute('data-mi'), 10)];
		if (!m) return;
		var label = btn.getAttribute('data-label');
		var key = wfMatchKey(m);
		var marks = wfFeedbackCache.get(String(id)) || {};
		var unmark = marks[key] === label; // לחיצה שנייה על אותו סימון מבטלת אותו
		var row = currentPageRows.find(function (r) { return String(r.id) === id; });
		var mode = wfMode;
		var level = m.h ? m[mode] : (wfMethod === 'ctx' && m['c' + mode] != null ? m['c' + mode] : m[mode]);
		var send = function () {
			if (PG_PROFILE) {
				// v2: פונקציות מנהלים בסכמת api (database_V2 מיגרציות 0005, 0019)
				return fetch(SUPABASE_URL + '/rest/v1/rpc/' + (unmark ? 'unmark_feedback' : 'mark_feedback'), {
					method: 'POST', headers: authHeaders({ 'Content-Type': 'application/json' }),
					body: JSON.stringify(unmark ? { p_wiki_id: Number(id), p_match_key: key } : {
						p_wiki_id: Number(id), p_match_key: key, p_word: m.x, p_entries: m.e || [], p_label: label, p_topic: m.t || null,
						p_hidden: m.h || null, p_level: level || null, p_lists_version: d.lists_version || null })
				});
			}
			if (unmark) {
				var q = new URLSearchParams();
				q.set('wikipedia_id', 'eq.' + id);
				q.set('match_key', 'eq.' + key);
				return fetch(SUPABASE_URL + '/rest/v1/word_filter_feedback?' + q.toString(), {
					method: 'DELETE', headers: authHeaders({ Prefer: 'return=minimal' })
				});
			}
			return fetch(SUPABASE_URL + '/rest/v1/word_filter_feedback?on_conflict=wikipedia_id,match_key,user_id', {
				method: 'POST',
				headers: authHeaders({ 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' }),
				body: JSON.stringify({
					wikipedia_id: Number(id), title: row ? row.title : null, match_key: key, word: m.x, entries: m.e || [],
					topic: m.t || null, hidden: m.h || null, label: label, level: level || null,
					before: m.b || null, after: m.f || null, lists_version: d.lists_version || null
				})
			});
		};
		var group = btn.parentNode;
		Array.prototype.forEach.call(group.querySelectorAll('button'), function (b) { b.disabled = true; });
		send().then(function (res) {
			if (res.status !== 401) return res;
			return refreshAuthSession().then(send);
		}).then(function (res) {
			if (res.status === 403) throw new Error('החשבון המחובר אינו ברשימת המורשים (manual_match_admins).');
			if (!res.ok) return res.text().then(function (t) { throw new Error('HTTP ' + res.status + ': ' + t); });
			if (unmark) delete marks[key]; else marks[key] = label;
			wfFeedbackCache.set(String(id), marks);
			Array.prototype.forEach.call(group.querySelectorAll('button'), function (b) {
				var l = b.getAttribute('data-label');
				b.classList.toggle('mchl-on-false', l === 'false' && marks[key] === 'false');
				b.classList.toggle('mchl-on-true', l === 'true' && marks[key] === 'true');
			});
		}).catch(function (e) {
			alert('הסימון נכשל: ' + (e.message || e));
		}).then(function () {
			Array.prototype.forEach.call(group.querySelectorAll('button'), function (b) { b.disabled = false; });
		});
	}

	function renderContentDetails(d, row) {
		var mode = wfMode;
		// בשיטת ההקשר - הרמה של כל התאמה לפי המילה והמשפט (ca/cs); סריקה ישנה בלי
		// השדות האלה נופלת חזרה לרמת הרשימה (a/s).
		var levelOf = function (m) {
			if (wfMethod === 'ctx' && m['c' + mode] != null) return m['c' + mode];
			return m[mode];
		};
		var all = (d.matches || []).filter(function (m) { return m[mode] != null; });
		var matches = all.filter(function (m) { return !m.h; });
		var hiddenMatches = all.filter(function (m) { return m.h; });
		var html = '';
		['problem', 'high', 'medium', 'low', 'review', 'wording', 'names'].forEach(function (level) {
			var items = matches.filter(function (m) { return levelOf(m) === level; });
			if (!items.length) return;
			var info = WF_SUSPICION[level] || WF_LEVELS[level];
			var markLevel = level === 'high' || level === 'medium' || level === 'low' ? 'review' : level;
			html += '<div class="mchl-wf-group"><span class="mchl-badge ' + info.cls + '">' +
				escapeHtml(info.label) + ' (' + items.length + ')</span><ul>';
			items.forEach(function (m) {
				var notes = [];
				if (mode === 's' && m.a == null) notes.push('רק לפי ההצעות');
				if (m.d && m.d.length && markLevel === 'review') notes.push('ירד לבדיקה - שימוש תמים אפשרי');
				if (wfMethod === 'ctx' && m['k' + mode] && m.kw) notes.push('מילת הקשר: ' + m.kw.join(', '));
				if (wfMethod === 'ctx' && m.g) notes.push({ anchor: 'עוגן', A: 'מילה בעייתית ברוב המקרים', B: 'מילה דו-משמעית', C: 'מילה תמימה ברוב המקרים', X: 'בעיה לפי הרשימה' }[m.g] || m.g);
				html += '<li><span class="mchl-num-cell">שורה ' + m.line + ' · ' + escapeHtml(WF_TOPICS[m.t] || m.t) + '</span> ' +
					escapeHtml(m.b) + '<mark class="mchl-wf-' + markLevel + '">' + escapeHtml(m.x) + '</mark>' + escapeHtml(m.f) +
					(notes.length ? ' <span class="mchl-muted">(' + escapeHtml(notes.join('; ')) + ')</span>' : '') +
					' <span class="mchl-muted mchl-wf-ids" title="רשומות ברשימת המילים">' + escapeHtml((m.e || []).join(',')) + '</span>' +
					wfFeedbackButtons(row ? row.id : '', d, m) + '</li>';
			});
			html += '</ul></div>';
		});
		if (!html) html = '<div class="mchl-muted">אין התאמות לפי הרשימות שנבחרו.</div>';
		var shown = (d.matches || []).filter(function (m) { return !m.h; }).length;
		if (d.matches_total > shown) {
			html += '<div class="mchl-muted">מוצגות ' + shown + ' התאמות מתוך ' + d.matches_total + '.</div>';
		}
		if (hiddenMatches.length) {
			html += '<div class="mchl-wf-group"><span class="mchl-badge mchl-neutral" title="הקוד כולו עובר למכלול, אבל הקורא לא רואה את החלקים האלה. לא נספר ברמת הערך - להחלטת העורך.">בקוד המוסתר בלבד (' +
				hiddenMatches.length + ')</span><ul>';
			hiddenMatches.forEach(function (m) {
				var level = m[mode];
				html += '<li><span class="mchl-num-cell">שורה ' + m.line + ' · ' + escapeHtml(WF_HIDDEN_KINDS[m.h] || m.h) + ' · ' +
					escapeHtml((WF_LEVELS[level] || {}).label || level) + '</span> <code class="mchl-wf-code">' +
					escapeHtml(m.b) + '<mark class="mchl-wf-hidden">' + escapeHtml(m.x) + '</mark>' + escapeHtml(m.f) + '</code>' +
					' <span class="mchl-muted mchl-wf-ids" title="רשומות ברשימת המילים">' + escapeHtml((m.e || []).join(',')) + '</span>' +
					wfFeedbackButtons(row ? row.id : '', d, m) + '</li>';
			});
			html += '</ul></div>';
		}
		if (d.images && d.images.length) {
			html += '<div class="mchl-wf-group"><span class="mchl-badge mchl-neutral">תמונות הערך (' + d.photo_count + ')</span>' +
				(d.photo_count > d.images.length ? ' <span class="mchl-muted">מוצגות ' + d.images.length + '</span>' : '') +
				'<div class="mchl-wf-thumbs">' +
				d.images.map(function (name, i) {
					return '<button type="button" class="mchl-wf-thumb" data-action="wf-image" data-index="' + i + '" title="' + escapeHtml(name) + '">' +
						'<img loading="lazy" alt="' + escapeHtml(name) + '" src="' + escapeHtml(wfImageUrl(name, 240)) + '"></button>';
				}).join('') + '</div></div>';
		}
		var when = d.scanned_at ? new Date(d.scanned_at).toLocaleDateString('he-IL') : '';
		html += '<div class="mchl-muted mchl-wf-foot">נסרק ' + escapeHtml(when) + ' · <a href="' + wikipediaUrl(row ? row.id : '') +
			'" target="_blank" rel="noopener">הערך בוויקיפדיה</a></div>';
		return html;
	}

	// ===== תמונות הערך: ממוזערות, ומציג במסך מלא =====
	// מציג משלנו ולא MultimediaViewer (מותקן במכלול): הוא נפתח רק מתמונות בתוך
	// תוכן הדף, ואין לו ממשק ציבורי יציב לפתיחת רשימת קבצים שרירותית.
	// דרך Special:FilePath של המכלול עצמו, כדי לראות בדיוק מה שיוצג בערך אחרי
	// הייבוא: המכלול מחפש קובץ בשם הזה קודם אצלו, אחר כך בוויקיפדיה, ואחר כך
	// בוויקישיתוף (דרך ויקיפדיה) - meta=filerepoinfo: local, hewiki. כך קובץ
	// שהוחלף במכלול בגרסה מתוקנת מוצג בגרסה של המכלול. width בפיקסלים.
	var MICHLOL_BASE = 'https://www.hamichlol.org.il';
	function wfImageUrl(name, width) {
		return MICHLOL_BASE + '/Special:FilePath/' + encodeURIComponent(name) + (width ? '?width=' + width : '');
	}
	function wfFilePageUrl(name) {
		return MICHLOL_BASE + '/' + encodeURIComponent('קובץ:' + name);
	}

	var wfViewer = { images: [], index: 0, el: null };
	function openWfViewer(images, index) {
		wfViewer.images = images;
		if (!wfViewer.el) {
			var el = document.createElement('div');
			el.className = 'mchl-viewer';
			el.setAttribute('role', 'dialog');
			el.setAttribute('aria-modal', 'true');
			el.innerHTML = '<button type="button" class="mchl-viewer-btn mchl-viewer-close" data-viewer="close" title="סגירה (Esc)">✕</button>' +
				'<button type="button" class="mchl-viewer-btn mchl-viewer-prev" data-viewer="prev" title="הקודמת">›</button>' +
				'<button type="button" class="mchl-viewer-btn mchl-viewer-next" data-viewer="next" title="הבאה">‹</button>' +
				'<div class="mchl-viewer-stage" data-viewer="close"><img class="mchl-viewer-img" alt=""><div class="mchl-viewer-loading">טוען…</div></div>' +
				'<div class="mchl-viewer-caption"></div>';
			el.addEventListener('click', function (e) {
				var t = e.target.closest('[data-viewer]');
				if (!t || e.target.classList.contains('mchl-viewer-img')) return;
				var what = t.getAttribute('data-viewer');
				if (what === 'close') closeWfViewer();
				else stepWfViewer(what === 'next' ? 1 : -1);
			});
			var img = el.querySelector('.mchl-viewer-img');
			img.addEventListener('load', function () { el.classList.remove('mchl-viewer-busy'); });
			img.addEventListener('error', function () {
				el.classList.remove('mchl-viewer-busy');
				el.querySelector('.mchl-viewer-caption').insertAdjacentHTML('beforeend', ' <span class="mchl-alert">לא ניתן לטעון את התמונה.</span>');
			});
			document.body.appendChild(el);
			wfViewer.el = el;
		}
		wfViewer.el.style.display = 'flex';
		document.addEventListener('keydown', onWfViewerKey);
		showWfViewerImage(index);
	}
	function showWfViewerImage(index) {
		var n = wfViewer.images.length;
		wfViewer.index = (index + n) % n;
		var name = wfViewer.images[wfViewer.index];
		var el = wfViewer.el;
		// ברזולוציה של המסך (כולל צפיפות פיקסלים), מעוגל למדרגות כדי שהמטמון של ויקיפדיה יעבוד.
		var want = Math.ceil(Math.min(window.innerWidth * (window.devicePixelRatio || 1), 2560) / 320) * 320;
		el.classList.add('mchl-viewer-busy');
		el.querySelector('.mchl-viewer-img').src = wfImageUrl(name, want);
		el.querySelector('.mchl-viewer-img').alt = name;
		el.querySelector('.mchl-viewer-caption').innerHTML = (n > 1 ? '<b>' + (wfViewer.index + 1) + ' / ' + n + '</b> · ' : '') +
			escapeHtml(name) + ' · <a href="' + wfFilePageUrl(name) + '" target="_blank" rel="noopener">דף הקובץ</a>' +
			' · <a href="' + wfImageUrl(name) + '" target="_blank" rel="noopener">גודל מקורי</a>';
		el.querySelector('.mchl-viewer-prev').style.visibility = n > 1 ? 'visible' : 'hidden';
		el.querySelector('.mchl-viewer-next').style.visibility = n > 1 ? 'visible' : 'hidden';
		// טעינה מוקדמת של השכנות, כדי שהמעבר יהיה מיידי.
		[1, -1].forEach(function (d) { if (n > 1) new Image().src = wfImageUrl(wfViewer.images[(wfViewer.index + d + n) % n], want); });
	}
	function stepWfViewer(delta) { if (wfViewer.images.length > 1) showWfViewerImage(wfViewer.index + delta); }
	function closeWfViewer() {
		if (!wfViewer.el) return;
		wfViewer.el.style.display = 'none';
		wfViewer.el.querySelector('.mchl-viewer-img').removeAttribute('src');
		document.removeEventListener('keydown', onWfViewerKey);
	}
	// מקשים: Esc סוגר; החיצים לפי כיוון הקריאה מימין לשמאל - שמאלה = הבאה.
	function onWfViewerKey(e) {
		if (e.key === 'Escape') closeWfViewer();
		else if (e.key === 'ArrowLeft') stepWfViewer(1);
		else if (e.key === 'ArrowRight') stepWfViewer(-1);
		else return;
		e.preventDefault();
	}

	function renderPager() {
		var pager = $id('mchl-pager');
		pager.style.display = 'flex';
		var from = totalRows === 0 ? 0 : currentPage * pageSize + 1;
		var to = Math.min(totalRows, (currentPage + 1) * pageSize);
		if (countUnknown) to = currentPage * pageSize + currentPageRows.length;
		$id('mchl-pager-summary').textContent = 'מציג ' + from.toLocaleString('he-IL') + '–' + to.toLocaleString('he-IL') + ' מתוך ' + (countUnknown ? '? (הספירה לא התקבלה)' : totalRows.toLocaleString('he-IL'));
		$id('mchl-pg-label').textContent = 'עמוד ' + (currentPage + 1).toLocaleString('he-IL') + (countUnknown ? '' : ' מתוך ' + totalPages.toLocaleString('he-IL'));
		$id('mchl-pg-first').disabled = currentPage === 0;
		$id('mchl-pg-prev').disabled = currentPage === 0;
		$id('mchl-pg-next').disabled = currentPage >= totalPages - 1;
		$id('mchl-pg-last').disabled = countUnknown || currentPage >= totalPages - 1;
	}

	function goPage(p) {
		if (p < 0 || p > totalPages - 1) return;
		currentPage = p;
		loadActiveView();
	}

	function toggleRowSelection(id, checked) {
		var row = currentPageRows.find(function (r) { return rowIdOf(r) === id; });
		if (!row) return;
		var key = rowKey(row);
		if (checked) selectedRows.set(key, row); else selectedRows.delete(key);
		updateSelectionBar();
		syncSelectionMarks();
	}
	function togglePageSelection(checked) {
		currentPageRows.forEach(function (r) {
			var key = rowKey(r);
			if (checked) selectedRows.set(key, r); else selectedRows.delete(key);
		});
		updateSelectionBar();
		syncSelectionMarks();
	}
	function clearSelection() { selectedRows.clear(); updateSelectionBar(); syncSelectionMarks(); }
	// מעדכן רק את תיבות הסימון וצבע השורות - בלי לצייר את הטבלה מחדש (שהייתה מוחקת טקסט
	// שהוקלד בשיוך הידני, שורות פרטים פתוחות והודעות).
	function syncSelectionMarks() {
		var byId = {};
		currentPageRows.forEach(function (r) { byId[rowIdOf(r)] = selectedRows.has(rowKey(r)); });
		document.querySelectorAll('#mchl-table-target input[data-action="toggle-row-selection"]').forEach(function (cb) {
			var on = !!byId[cb.getAttribute('data-row-id')];
			cb.checked = on;
			var tr = cb.closest('tr');
			if (tr) tr.classList.toggle('mchl-selected', on);
		});
		var all = $id('mchl-table-target').querySelector('input[data-action="toggle-page-selection"]');
		if (all) all.checked = currentPageRows.length > 0 && currentPageRows.every(function (r) { return selectedRows.has(rowKey(r)); });
	}

	function updateSelectionBar() {
		var bar = $id('mchl-selection-bar');
		var n = selectedRows.size;
		$id('mchl-selected-count').textContent = n.toLocaleString('he-IL');
		bar.style.display = n > 0 ? 'flex' : 'none';
		var linkBtn = $id('mchl-select-all-matching-btn');
		if (n > 0 && n < totalRows && currentPageRows.every(function (r) { return selectedRows.has(rowKey(r)); })) {
			linkBtn.style.display = 'inline';
			linkBtn.textContent = 'בחר את כל ' + totalRows.toLocaleString('he-IL') + ' התוצאות התואמות';
		} else {
			linkBtn.style.display = 'none';
		}
		// כפתור הנעילה רלוונטי רק בטאב "חסר במכלול", וגם רק כשיש "חיבור"
		// (ראו saveServiceKey - עדיין לא אימות אמיתי, רק שער נראות)
		// - בלי מפתח שמור, הכפתור לא מוצג בכלל, גם אם יש שורות נבחרות.
		var lockBtn = $id('mchl-lock-titles-btn');
		lockBtn.style.display = (n > 0 && VIEWS[activeTab] && VIEWS[activeTab].lockable && serviceKeyConnected) ? 'inline' : 'none';
	}

	function selectAllMatching() {
		var btn = $id('mchl-select-all-matching-btn');
		var originalText = btn.textContent;
		var cfg = VIEWS[activeTab];
		if (!countUnknown && totalRows > 20000 && !confirm('לבחור ' + totalRows.toLocaleString('he-IL') + ' ערכים? הטעינה תיקח כדקה.')) return Promise.resolve();
		btn.disabled = true;
		btn.textContent = 'טוען…';
		return pgSelectAll(cfg.view, { filterParams: buildFilterParams(), order: stableOrder(cfg) }, function (got, expected) {
			btn.textContent = 'טוען… ' + got.toLocaleString('he-IL') + (expected != null ? ' מתוך ' + expected.toLocaleString('he-IL') : '');
		}).then(function (res) {
			res.data.forEach(function (r) { selectedRows.set(rowKey(r), r); });
			btn.disabled = false;
			btn.textContent = originalText;
			updateSelectionBar();
			syncSelectionMarks();
			if (!res.complete) alert('נבחרו ' + res.data.length.toLocaleString('he-IL') + ' מתוך ' + res.expected.toLocaleString('he-IL') + ' - חלק מהתוצאות לא נטענו. אפשר לנסות שוב.');
		}).catch(function (e) {
			btn.disabled = false;
			btn.textContent = originalText;
			alert(isTransientMaintenanceError(e)
				? 'המסד באמצע עדכון תקופתי כרגע - נסה שוב בעוד רגע.'
				: 'שגיאה בטעינת כל התוצאות, גם אחרי כמה ניסיונות:\n' + (e.message || e) + '\n\nניתן לנסות שוב.');
		});
	}

	// ייצוא: "סינון תוכן" לפי הרשימות שנבחרו בסרגל, כתווית בעברית.
	function exportValue(col, row) {
		if (col === 'verdict') {
			var level = wfRowLevel(row);
			return level ? (WF_SUSPICION[level] || WF_LEVELS[level]).label : 'טרם נסרק';
		}
		if (col === 'topic') return row.dictionary ? 'מילוני: ' + row.dictionary : (WF_TOPIC_LABELS[row.topic] || row.topic || '');
		return row[col];
	}

	function download(filename, content, mime) {
		var blob = new Blob([content], { type: mime + ';charset=utf-8' });
		var url = URL.createObjectURL(blob);
		var a = document.createElement('a');
		a.href = url; a.download = filename;
		document.body.appendChild(a); a.click(); document.body.removeChild(a);
		URL.revokeObjectURL(url);
	}

	function getExportRows() {
		if (selectedRows.size > 0) return Promise.resolve(Array.from(selectedRows.values()));
		var cfg = VIEWS[activeTab];
		return pgSelectAll(cfg.view, { filterParams: buildFilterParams(), order: stableOrder(cfg) }).then(function (res) {
			if (!res.complete && !confirm('נטענו ' + res.data.length.toLocaleString('he-IL') + ' מתוך ' + res.expected.toLocaleString('he-IL') + ' ערכים. לייצא בכל זאת?')) return null;
			return res.data;
		}).catch(function (e) {
			alert(isTransientMaintenanceError(e)
				? 'המסד באמצע עדכון תקופתי כרגע - נסה שוב בעוד רגע.'
				: 'שגיאה בהבאת הנתונים לייצוא, גם אחרי כמה ניסיונות:\n' + (e.message || e));
			return null;
		});
	}

	function exportData(kind, btn) {
		var originalText;
		if (btn) { originalText = btn.textContent; btn.disabled = true; btn.textContent = 'מכין…'; }
		return getExportRows().then(function (rows) {
			if (btn) { btn.disabled = false; btn.textContent = originalText; }
			if (rows === null) return;
			if (rows.length === 0) { alert('אין שורות לייצוא.'); return; }
			var cfg = VIEWS[activeTab];
			if (cfg.wikidata) {
				// התיאור מהמסד הוא המקור; המטמון בדפדפן רק משלים שורות שאין
				// להן תיאור שמור. (קודם המטמון דרס את ערך המסד - ולכל שורה
				// שלא הוצגה על המסך הייצוא קיבל תיאור ריק.)
				rows.forEach(function (r) {
					if (r.wikidata_desc !== null && r.wikidata_desc !== undefined) return;
					var v = wikidataCache.get(r.title);
					r.wikidata_desc = (typeof v === 'string') ? v : '';
				});
			}
			var titleColumn = cfg.titleColumn || 'title';
			var idColumns = cfg.exportIdColumns || ['id'];
			var stamp = new Date().toISOString().slice(0, 10);
			var base = cfg.label + '_' + stamp;
			if (kind === 'txt') { download(base + '.txt', rows.map(function (r) { return r[titleColumn]; }).join('\n'), 'text/plain'); return; }
			if (kind === 'json') {
				var clean = rows.map(function (r) { var o = {}; idColumns.concat(cfg.columns).forEach(function (c) { o[c] = exportValue(c, r); }); return o; });
				download(base + '.json', JSON.stringify(clean, null, 2), 'application/json');
				return;
			}
			if (kind === 'csv') {
				var headers = idColumns.concat(cfg.columns);
				var escapeCsv = function (v) { return '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"'; };
				var lines = [headers.map(function (h) { return escapeCsv(COLUMN_LABELS[h] || h); }).join(',')];
				rows.forEach(function (r) { lines.push(headers.map(function (h) { return escapeCsv(exportValue(h, r)); }).join(',')); });
				download(base + '.csv', '\ufeff' + lines.join('\r\n'), 'text/csv');
			}
		});
	}

	// ===== נעילת כותרות (aspaklaryalockdown) - רק בטאב "חסר במכלול" =====
	// משתמש ב-mw.Api הרגיל של המשתמש המחובר עצמו (טוקן CSRF שכבר יש לו
	// דרך ה-session) - *לא* דורש שום מפתח/סוד נפרד, כי הגאדג'ט רץ בתוך
	// המכלול. השרת אוכף הרשאות בעצמו (בדיוק כמו כל עריכה/פעולה רגילה
	// במדיה-ויקי) - זה מה שהופך את הפעולה הזו לבטוחה לבנות ישירות,
	// בניגוד לעריכת manual_matches שדורשת מפתח סופרבייס נפרד.
	function lockSelectedTitles(btn) {
		var titles = Array.from(selectedRows.values()).map(function (r) { return r.title; });
		if (titles.length === 0) return;
		if (!confirm('לנעול ' + titles.length.toLocaleString('he-IL') + ' כותרות ליצירה במכלול?')) return;

		var api = new mw.Api();
		var originalText = btn.textContent;
		btn.disabled = true;
		var failed = [];

		function lockNext(i) {
			if (i >= titles.length) {
				btn.disabled = false;
				btn.textContent = originalText;
				if (failed.length) {
					alert('הסתיים עם ' + failed.length.toLocaleString('he-IL') + ' כשלונות מתוך ' +
						titles.length.toLocaleString('he-IL') + ':\n' + failed.join('\n'));
				} else {
					alert('כל ' + titles.length.toLocaleString('he-IL') + ' הכותרות ננעלו בהצלחה.');
				}
				return;
			}
			btn.textContent = 'נועל… (' + (i + 1) + '/' + titles.length + ')';
			// action=aspaklaryalockdown, level='create' - זהה בדיוק
			// לפעולה ב-create.py שהועלה, רק דרך mw.Api (טוקן אוטומטי)
			// במקום התחברות ידנית נפרדת.
			api.postWithToken('csrf', {
				action: 'aspaklaryalockdown',
				title: titles[i],
				level: 'create',
				formatversion: '2'
			}).done(function (data) {
				if (!(data && data.aspaklaryalockdown && data.aspaklaryalockdown.status === 'Succes')) {
					failed.push(titles[i]);
				}
			}).fail(function () {
				failed.push(titles[i]);
			}).always(function () {
				// אותה השהיה של שנייה כמו ב-create.py, בין נעילה לנעילה.
				sleep(1000).then(function () { lockNext(i + 1); });
			});
		}

		lockNext(0);
	}

	// ===== שיוך התאמה ידנית (manual_matches) - רק כש-serviceKeyConnected,
	// ורק בטאב "חסר במכלול" (ראו effectiveColumns). כיוון: משורת
	// ויקיפדיה (wikipedia_id כבר ידוע) לכותרת מכלולאית, נבחרת מתוך חיפוש
	// חי (לא הקלדה עיוורת של כותרת מדויקת) =====

	var manualMatchDebounce = new WeakMap(); // input element -> timer id
	var MANUAL_MATCH_SEARCH_DELAY_MS = 300;
	var MANUAL_MATCH_SUGGESTION_LIMIT = 5;

	// נקרא מ-wireEvents (event delegation, כמו כל שאר הפעולות) בכל
	// input בתוך תא שיוך ידני - מבטל את הטיימר הקודם לאותו input בלבד
	// (WeakMap, לא טיימר גלובלי יחיד) כדי ששורות שונות לא יפריעו זו לזו.
	function onManualMatchInput(input) {
		var cell = input.closest('.mchl-manual-match-cell');
		var btn = cell.querySelector('button[data-action="assign-manual-match"]');
		// עריכה אחרי שכבר נבחרה הצעה - מבטלים את הבחירה הקודמת, לא
		// משאירים כפתור פעיל שמצביע על טקסט שכבר לא תואם את מה שנבחר.
		delete cell.dataset.selectedMechalolId;
		btn.disabled = true;

		clearTimeout(manualMatchDebounce.get(input));
		var query = (input.value || '').trim();
		var suggestionsBox = cell.querySelector('.mchl-manual-match-suggestions');
		if (!query) {
			suggestionsBox.style.display = 'none';
			suggestionsBox.innerHTML = '';
			return;
		}
		manualMatchDebounce.set(input, setTimeout(function () {
			searchManualMatchSuggestions(query, cell, suggestionsBox);
		}, MANUAL_MATCH_SEARCH_DELAY_MS));
	}

	// ilike עם * בסוף בלבד (התחלת-כותרת) - לא *טקסט* - לפי מה שסוכם:
	// מהיר יותר ומשתמש באינדקס title הקיים, בניגוד לחיפוש-הכל-בכל-מקום.
	function searchManualMatchSuggestions(query, cell, suggestionsBox) {
		var mySeq = String((Number(cell.dataset.searchSeq) || 0) + 1);
		cell.dataset.searchSeq = mySeq;
		suggestionsBox.style.display = 'block';
		suggestionsBox.innerHTML = '<div class="mchl-manual-match-suggestion-loading">מחפש…</div>';
		var params = new URLSearchParams();
		params.set('select', 'id,title');
		params.set('title', 'ilike.' + query.replace(/[%*]/g, '') + '*');
		params.set('order', 'title.asc');
		params.set('limit', String(MANUAL_MATCH_SUGGESTION_LIMIT));
		fetch(SUPABASE_URL + '/rest/v1/mechalol_pages?' + params.toString(), {
			headers: pgHeaders()
		}).then(function (res) {
			if (!res.ok) throw new Error('HTTP ' + res.status);
			return res.json();
		}).then(function (rows) {
			// המשתמש כבר המשיך להקליד/ניקה בזמן שהבקשה הזו הייתה באוויר -
			// לא מציירים תוצאות מיושנות מעל מה שהוא רואה עכשיו.
			if (suggestionsBox.style.display === 'none' || cell.dataset.searchSeq !== mySeq) return;
			renderManualMatchSuggestions(rows, cell, suggestionsBox);
		}).catch(function () {
			if (cell.dataset.searchSeq !== mySeq) return;
			suggestionsBox.innerHTML = '<div class="mchl-manual-match-suggestion-loading">שגיאה בחיפוש</div>';
		});
	}

	function renderManualMatchSuggestions(rows, cell, suggestionsBox) {
		if (!rows || rows.length === 0) {
			suggestionsBox.innerHTML = '<div class="mchl-manual-match-suggestion-loading">אין תוצאות</div>';
			return;
		}
		suggestionsBox.innerHTML = rows.map(function (r) {
			return '<div class="mchl-manual-match-suggestion-item" data-action="pick-manual-match-suggestion" ' +
				'data-mechalol-id="' + r.id + '" data-mechalol-title="' + escapeHtml(r.title) + '">' +
				escapeHtml(r.title) + '</div>';
		}).join('');
	}

	function pickManualMatchSuggestion(el) {
		var cell = el.closest('.mchl-manual-match-cell');
		var input = cell.querySelector('.mchl-manual-match-input');
		var btn = cell.querySelector('button[data-action="assign-manual-match"]');
		var suggestionsBox = cell.querySelector('.mchl-manual-match-suggestions');

		input.value = el.getAttribute('data-mechalol-title');
		cell.dataset.selectedMechalolId = el.getAttribute('data-mechalol-id');
		suggestionsBox.style.display = 'none';
		suggestionsBox.innerHTML = '';
		btn.disabled = false;
	}

	function assignManualMatch(btn) {
		var wikipediaId = parseInt(btn.getAttribute('data-wikipedia-id'), 10);
		var cell = btn.closest('.mchl-manual-match-cell');
		var input = cell.querySelector('.mchl-manual-match-input');
		var mechalolId = parseInt(cell.dataset.selectedMechalolId, 10);
		var mechalolTitle = input.value;

		// לא אמור לקרות (הכפתור מנוטרל עד שנבחרת הצעה - ראו
		// onManualMatchInput/pickManualMatchSuggestion) - הגנה נוספת בלבד.
		if (!mechalolId) {
			alert('יש לבחור כותרת מתוך רשימת ההצעות לפני שיוך.');
			return;
		}

		btn.disabled = true;
		input.disabled = true;
		var originalText = btn.textContent;
		btn.textContent = 'משייך…';

		// הכתיבה ל-manual_matches - דורשת את הטוקן של המשתמש המחובר
		// (authHeaders), לא מפתח ה-anon. שני ה-id-ים כבר ידועים (מהשורה
		// עצמה + מההצעה שנבחרה) - בניגוד לגרסה הישנה, אין כאן שלב חיפוש
		// נפרד לפני הכתיבה.
		var postMatch = function () {
			if (PG_PROFILE) {
				return fetch(SUPABASE_URL + '/rest/v1/rpc/set_manual_link', {
					method: 'POST', headers: authHeaders({ 'Content-Type': 'application/json' }),
					body: JSON.stringify({ p_mech_id: mechalolId, p_wiki_id: wikipediaId, p_reason: null })
				});
			}
			return fetch(SUPABASE_URL + '/rest/v1/manual_matches', {
				method: 'POST',
				headers: authHeaders({ 'Content-Type': 'application/json', Prefer: 'return=minimal' }),
				body: JSON.stringify({ mechalol_page_id: mechalolId, wikipedia_page_id: wikipediaId })
			});
		};
		// טוקן הגישה של Supabase Auth פג אחרי שעה - על 401 מחדשים פעם
		// אחת עם ה-refresh_token השמור ומנסים שוב.
		postMatch().then(function (res) {
			if (res.status !== 401) return res;
			return refreshAuthSession().then(postMatch);
		}).then(function (res) {
			if (res.status === 403) {
				throw new Error('החשבון המחובר אינו ברשימת המורשים לשיוך ידני (manual_match_admins).');
			}
			if (!res.ok) return res.text().then(function (t) { throw new Error('HTTP ' + res.status + ': ' + t); });
			cell.innerHTML = '<span class="mchl-badge mchl-wiki">✓ שויך ל-"' + escapeHtml(mechalolTitle) + '"</span>' +
				'<span class="mchl-muted" style="font-size:11px;">(יתעדכן בדוח בריצה הבאה)</span>';
		}).catch(function (e) {
			btn.disabled = false;
			input.disabled = false;
			btn.textContent = originalText;
			alert('שיוך נכשל: ' + (e.message || e));
		});
	}


	function toggleAdminPanel() {
		var panel = $id('mchl-admin-panel');
		panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
		syncMaintRow();
	}

	// ===== רענון נתוני התחזוקה =====
	// הכפתור מפעיל דרך המסד (request_maintenance_refresh, pg_net) את ה-workflow maintenance_refresh.yml, שמביא את מצב
	// המכלול האמיתי (דלתא, התאמה ממוקדת, עדכון שעתי, בדיקת גרסאות מחדש, ניקוי), ומחכה לסיומו (maintenance_refresh_status).
	// כשהוא מסתיים הדשבורד נטען מחדש. הרשאה נאכפת במסד (manual_match_admins); הכפתור מוצג רק למחוברים.
	// migrations/migration_add_trigger_maintenance_refresh.sql
	var MAINT_POLL_MS = 10000, MAINT_START_TIMEOUT_MS = 4 * 60 * 1000, MAINT_RUN_TIMEOUT_MS = 40 * 60 * 1000;
	var maintPolling = false;
	function syncMaintRow() {
		var row = $id('mchl-maint-row');
		if (row) row.style.display = serviceKeyConnected && !PG_PROFILE ? '' : 'none';   // רענון תחזוקה: v1 בלבד (ב-v2 הסנכרון והבדיקות הן workflows)
	}
	function maintRpc(name) {
		assertWritable();
		var send = function () {
			return fetch(SUPABASE_URL + '/rest/v1/rpc/' + name, {
				method: 'POST', headers: authHeaders({ 'Content-Type': 'application/json' }), body: '{}'
			});
		};
		return send().then(function (res) {
			if (res.status !== 401) return res;
			return refreshAuthSession().then(send);
		}).then(function (res) {
			if (res.status === 403 || res.status === 401) throw new Error('החשבון המחובר אינו ברשימת המורשים (manual_match_admins).');
			if (!res.ok) return res.text().then(function (t) { throw makePgError(res.status, t); });
			return res.json();
		});
	}
	function maintRefresh(btn) {
		if (maintPolling) return;
		var statusEl = $id('mchl-admin-status');
		var original = btn.textContent;
		var show = function (msg, cls) { statusEl.textContent = msg; statusEl.className = 'mchl-muted ' + (cls || ''); };
		var finish = function (msg, cls) { maintPolling = false; btn.disabled = false; btn.textContent = original; show(msg, cls); };
		maintPolling = true;
		btn.disabled = true;
		btn.textContent = 'מרענן…';
		show('מפעיל רענון…');
		maintRpc('request_maintenance_refresh').then(function (res) {
			var requestedAt = new Date(res.requested_at).getTime();
			if (!res.started) show('רענון כבר רץ, ממתין לסיומו…');
			var poll = function () {
				return maintRpc('maintenance_refresh_status').then(function (st) {
					var elapsed = Date.now() - requestedAt;
					if (st.dispatch_error) return finish('ההפעלה נדחתה: ' + st.dispatch_error, 'mchl-alert');
					var finishedAt = st.finished_at ? new Date(st.finished_at).getTime() : 0;
					if (st.status === 'success' && finishedAt >= requestedAt) {
						show('הרענון הושלם, טוען מחדש…', 'mchl-success');
						return refreshAll().then(function () { finish('הנתונים עודכנו (' + new Date().toLocaleTimeString('he-IL', { hour: '2-digit', minute: '2-digit' }) + ').', 'mchl-success'); });
					}
					if (st.status === 'failed' && finishedAt >= requestedAt) return finish('הרענון נכשל. פרטים ב-GitHub Actions (נפתח Issue).', 'mchl-alert');
					if (st.status === 'requested' && elapsed > MAINT_START_TIMEOUT_MS) return finish('הריצה לא התחילה תוך כמה דקות. בדוק ב-GitHub Actions.', 'mchl-alert');
					if (elapsed > MAINT_RUN_TIMEOUT_MS) return finish('הרענון נמשך זמן רב מהצפוי. בדוק ב-GitHub Actions.', 'mchl-alert');
					show(st.status === 'running' ? 'הרענון רץ (' + Math.round(elapsed / 60000) + ' דק׳)…' : 'ממתין שהריצה תתחיל…');
					return sleep(MAINT_POLL_MS).then(poll);
				});
			};
			return sleep(MAINT_POLL_MS).then(poll);
		}).catch(function (e) {
			finish('הרענון נכשל: ' + (e.message || e), 'mchl-alert');
		});
	}


	// ===== התחברות אמיתית (Supabase Auth) - רק לפתיחת פאנל ניהול =====
	// לא ספריית supabase-js (הגאדג'ט לא משתמש בה בכלל, ראו pgHeaders
	// למעלה) - קריאה ישירה לנקודת הקצה של Auth, באותה שיטה שכל שאר
	// הגאדג'ט פונה ל-PostgREST.
	function authLogin() {
		var email = ($id('mchl-auth-email-input').value || '').trim();
		var password = $id('mchl-auth-password-input').value || '';
		var statusEl = $id('mchl-admin-status');
		var btn = $id('mchl-auth-login-btn');

		if (!email || !password) {
			statusEl.textContent = 'יש למלא אימייל וסיסמה.';
			statusEl.className = 'mchl-muted mchl-alert';
			return;
		}

		btn.disabled = true;
		statusEl.textContent = 'מתחבר…';
		statusEl.className = 'mchl-muted';

		fetch(SUPABASE_URL + '/auth/v1/token?grant_type=password', {
			method: 'POST',
			headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
			body: JSON.stringify({ email: email, password: password })
		}).then(function (res) {
			return res.json().then(function (data) { return { ok: res.ok, data: data }; });
		}).then(function (result) {
			btn.disabled = false;
			if (!result.ok || !result.data.access_token) {
				serviceKeyConnected = false;
				statusEl.textContent = 'התחברות נכשלה: ' + (result.data.error_description || result.data.msg || 'פרטים שגויים');
				statusEl.className = 'mchl-muted mchl-alert';
				updateSelectionBar();
				return;
			}
			sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({
				access_token: result.data.access_token,
				refresh_token: result.data.refresh_token,
				email: email
			}));
			serviceKeyConnected = true;
			statusEl.textContent = 'התחברות בוצעה בהצלחה.';
			syncMaintRow();
			statusEl.className = 'mchl-muted mchl-success';
			updateSelectionBar();
			syncAuthTabs();
			// אם כבר נמצאים בטאב עם עמודת שיוך ידני ("חסר במכלול"/"קיים כהפניה") - מרעננים
			// כדי שעמודת השיוך הידני תופיע בלי לחכות למעבר טאב.
			if (VIEWS[activeTab] && VIEWS[activeTab].manualMatch) renderTable();
			// נסגר לבד אחרי שהמחוון הראה הצלחה לרגע - לא נשאר פתוח סתם.
			sleep(1200).then(function () { $id('mchl-admin-panel').style.display = 'none'; });
		}).catch(function () {
			btn.disabled = false;
			serviceKeyConnected = false;
			statusEl.textContent = 'שגיאת רשת בהתחברות - נסה שוב.';
			statusEl.className = 'mchl-muted mchl-alert';
			updateSelectionBar();
			syncAuthTabs();
		});
	}

	// מחדש את הסשן עם ה-refresh_token השמור. נכשל -> מנתק (הכפתורים
	// נעלמים) וזורק שגיאה עם הסבר.
	function refreshAuthSession() {
		var stored = null;
		try { stored = JSON.parse(sessionStorage.getItem(SESSION_STORAGE_KEY) || 'null'); } catch (e) { stored = null; }
		if (!stored || !stored.refresh_token) {
			return Promise.reject(new Error('פג תוקף ההתחברות - יש להתחבר מחדש בפאנל הניהול.'));
		}
		return fetch(SUPABASE_URL + '/auth/v1/token?grant_type=refresh_token', {
			method: 'POST',
			headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
			body: JSON.stringify({ refresh_token: stored.refresh_token })
		}).then(function (res) {
			return res.json().then(function (data) { return { ok: res.ok, data: data }; });
		}).then(function (result) {
			if (!result.ok || !result.data.access_token) {
				try { sessionStorage.removeItem(SESSION_STORAGE_KEY); } catch (e) { /* מתעלמים */ }
				serviceKeyConnected = false;
				updateSelectionBar();
				syncAuthTabs();
				throw new Error('פג תוקף ההתחברות - יש להתחבר מחדש בפאנל הניהול.');
			}
			sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({
				access_token: result.data.access_token,
				refresh_token: result.data.refresh_token,
				email: stored.email
			}));
		});
	}

	// בדיקה בטעינת הדף אם כבר יש סשן שמור מקודם באותו טאב (sessionStorage
	// לא מאומת מחדש מול השרת כאן - רק "יש טוקן שמור"; אם פג תוקפו, הקריאה
	// הראשונה שתשתמש בו תחדש אותו דרך refreshAuthSession).
	function restoreAuthSession() {
		try {
			var raw = sessionStorage.getItem(SESSION_STORAGE_KEY);
			if (!raw) return;
			var parsed = JSON.parse(raw);
			if (parsed && parsed.access_token) serviceKeyConnected = true;
		} catch (e) {
			// שריד פגום ב-sessionStorage - מתעלמים, לא מחוברים.
		}
	}


	function wireEvents(root) {
		root.addEventListener('click', function (e) {
			var el = e.target.closest('[data-action]');
			if (!el) {
				// לחיצה על השורה עצמה (לא על קישור, כפתור או תיבת סימון) פותחת וסוגרת את הפרטים.
				var tr = e.target.closest('#mchl-table-target tr.mchl-expandable');
				if (tr && !e.target.closest('a, button, input, label, select, textarea')) {
					var b = tr.querySelector('[data-action="wf-details"]');
					if (b) toggleContentDetails(b);
				}
				return;
			}
			var action = el.getAttribute('data-action');
			if (action === 'refresh') refreshAll();
			else if (action === 'clear-filters') clearFilters();
			else if (action === 'select-all-matching') selectAllMatching();
			else if (action === 'clear-selection') clearSelection();
			else if (action === 'retry') loadCurrentTab();
			else if (action === 'export') exportData(el.getAttribute('data-kind'), el);
			else if (action === 'select-culture-subcat') selectCultureSubcat(el.getAttribute('data-subcat'));
			else if (action === 'culture-back') { cultureState.selected = null; renderCulturePicker(); }
			else if (action === 'culture-load-more') { if (!cultureState.loading) loadCultureMembers(); }
			else if (action === 'lock-titles') lockSelectedTitles(el);
			else if (action === 'assign-manual-match') assignManualMatch(el);
			else if (action === 'pick-manual-match-suggestion') pickManualMatchSuggestion(el);
			else if (action === 'toggle-admin-panel') toggleAdminPanel();
			else if (action === 'auth-login') authLogin();
			else if (action === 'maint-refresh') maintRefresh(el);
			else if (action === 'wf-details') toggleContentDetails(el);
			else if (action === 'update-open') toggleUpdatePanel(el);
			else if (action === 'fix-source-open') fixSrc.toggle(el);
			else if (action === 'update-merge-open') openUpdateMerge(el);
			else if (action === 'import') importFromDashboard(el);
			else if (action === 'req-filter') { requestsState.filter = el.getAttribute('data-v'); renderRequests(); }
			else if (action === 'req-reply') replyToRequest(el);
			else if (action === 'req-open') toggleRequestPanel(el.closest('tr'));
			else if (action === 'set-theme') setTheme(el.getAttribute('data-v'));
			else if (action === 'toggle-side') { uiPrefs.sideHidden = !uiPrefs.sideHidden; saveUiPrefs(); applySidePanel(); }
			else if (action === 'chip-remove') removeChip(el.getAttribute('data-chip'));
			else if (action === 'wf-feedback') wfFeedback(el);
			else if (action === 'wf-image') {
				var detailsRow = el.closest('tr.mchl-wf-details-row');
				var cached = detailsRow && wfDetailsCache.get(detailsRow.previousElementSibling.querySelector('[data-action="wf-details"]').getAttribute('data-id'));
				if (cached && cached.images) openWfViewer(cached.images, parseInt(el.getAttribute('data-index'), 10));
			}
			else if (action === 'wf-meter-filter') setWfLevel(wfLevelChoice === el.getAttribute('data-filter') ? '' : el.getAttribute('data-filter'));
			else if (action === 'goto') {
				var target = el.getAttribute('data-target');
				if (target === 'first') goPage(0);
				else if (target === 'prev') goPage(currentPage - 1);
				else if (target === 'next') goPage(currentPage + 1);
				else if (target === 'last') goPage(totalPages - 1);
			}
		});
		// חיפוש חי בתא שיוך ידני (ראו onManualMatchInput) - delegation
		// כמו כל שאר האירועים, לא listener נפרד לכל שורה בנפרד (השורות
		// מצוירות מחדש בכל renderTable, listener ישיר היה נדרש להתחבר
		// מחדש בכל פעם).
		root.addEventListener('input', function (e) {
			if (e.target.matches('.mchl-manual-match-input')) onManualMatchInput(e.target);
		});
		root.addEventListener('change', function (e) {
			var el = e.target;
			if (el.matches('[data-action="toggle-page-selection"]')) togglePageSelection(el.checked);
			else if (el.matches('[data-action="toggle-row-selection"]')) toggleRowSelection(el.getAttribute('data-row-id'), el.checked);
		});
	}
	
	   function getLevel(groups) {
        return Math.max(...groups.map(g => GROUP_LEVELS[g] || 0), 0);
      }

	// דרגת ההרשאה הנדרשת כדי לראות את פאנל הניהול בכלל (מפתח סרוויס +
	// עריכת התאמות ידניות בעתיד) - מעל sysop(20) ו-bot(18) בלבד. זו רק
	// בדיקת-נראות בצד הלקוח (UX, "מי בכלל אמור לראות את זה") - היא
	// *לא* שכבת אבטחה: כל מי שפותח כלי מפתחים יכול לעקוף אותה. ההגנה
	// האמיתית (אם/כשתיבנה) חייבת לבוא מהמסד עצמו, לא מכאן.
	var ADMIN_LEVEL_THRESHOLD = 17;
	// ===== העיצוב: gadget-searchHelperDashboard.css, נטען מדף באתר =====
	var CSS_PAGE = 'משתמש:בוט גאון הירדן/dashboard.css';
	// done נקרא כשהעיצוב נטען (או נכשל), כדי שהדשבורד לא יופיע רגע בלי עיצוב.
	function loadDashboardCss(done) {
		var link = document.createElement('link');
		var finish = function () { clearTimeout(timer); done(); };
		var timer = setTimeout(finish, 4000);
		link.rel = 'stylesheet';
		link.onload = finish;
		link.onerror = finish;
		link.href = mw.util.wikiScript('index') + '?title=' + encodeURIComponent(CSS_PAGE) + '&action=raw&ctype=text/css';
		document.head.appendChild(link);
	}

	var HTML = '' +
		'<header class="mchl-top">' +
		'<div class="mchl-top-title"><div class="mchl-h1">ויקיפדיה העברית <span class="mchl-arrow">↔</span> <span class="mchl-mch">המכלול</span></div>' +
		'<div class="mchl-sync-note" id="mchl-sync-note">נבדק לאחרונה —</div></div>' +
		'<div class="mchl-top-actions">' +
		'<button type="button" class="mchl-refresh" id="mchl-admin-toggle-btn" data-action="toggle-admin-panel" style="display:none;">⚙ ניהול</button>' +
		'<button type="button" class="mchl-refresh" id="mchl-refresh-btn" data-action="refresh"><span class="mchl-dot"></span> רענון</button></div>' +
		'</header>' +
		'<section class="mchl-admin-panel" id="mchl-admin-panel" style="display:none;">' +
		'<div class="mchl-eyebrow">פאנל ניהול - התחברות</div>' +
		'<div class="mchl-admin-row">' +
		'<input type="email" id="mchl-auth-email-input" class="mchl-search" placeholder="אימייל" autocomplete="off">' +
		'<input type="password" id="mchl-auth-password-input" class="mchl-search" placeholder="סיסמה" autocomplete="off">' +
		'<button type="button" class="mchl-export-btn" id="mchl-auth-login-btn" data-action="auth-login">התחברות</button>' +
		'</div>' +
		'<div class="mchl-muted" id="mchl-admin-status" style="font-size:12.5px;margin-top:8px;">טרם התחברת - כפתור נעילת הכותרות בטאב "חסר במכלול" יופיע רק אחרי התחברות מוצלחת.</div>' +
		'<div class="mchl-admin-row" style="margin-top:12px;">' +
		'<span class="mchl-muted">מסד נתונים:</span>' +
		'<select id="mchl-backend-select" class="mchl-search" style="max-width:220px;">' +
		Object.keys(BACKENDS).map(function (k) { return '<option value="' + k + '">' + BACKENDS[k].label + '</option>'; }).join('') +
		'</select>' +
		'<span class="mchl-muted" style="font-size:12.5px;">הבחירה נשמרת בדפדפן הזה ומרעננת את הדף. במסד החדש (ניסיוני): שיוך ידני ומשוב סינון נתמכים; רענון תחזוקה לא.</span>' +
		'</div>' +
		'<div class="mchl-admin-row" id="mchl-maint-row" style="display:none;margin-top:12px;">' +
		'<button type="button" class="mchl-export-btn" id="mchl-maint-btn" data-action="maint-refresh">רענן נתוני תחזוקה</button>' +
		'<span class="mchl-muted" style="font-size:12.5px;">מביא את מצב המכלול האמיתי ומנקה שורות שהתיישנו. לוקח כמה דקות.</span>' +
		'</div>' +
		'</section>' +
		'<nav class="mchl-tabs" id="mchl-tabs"></nav>' +
		'<div id="mchl-stats-area" style="display:none;">' +
		'<section class="mchl-ledger">' +
		'<div class="mchl-ledger-heads">' +
		'<div class="mchl-ledger-head mchl-wikih"><span class="mchl-label">ערכים בוויקיפדיה <span class="mchl-mini-spinner" id="mchl-spin-wiki"></span><span class="mchl-warn-inline" id="mchl-warn-wiki" style="display:none;">⚠</span></span><span class="mchl-num" id="mchl-stat-wiki-total">—</span></div>' +
		'<div class="mchl-ledger-head mchl-mechaloh" style="text-align:left;"><span class="mchl-label">ערכים במכלול <span class="mchl-mini-spinner" id="mchl-spin-mechalol"></span><span class="mchl-warn-inline" id="mchl-warn-mechalol" style="display:none;">⚠</span></span><span class="mchl-num" id="mchl-stat-mechalol-total">—</span></div>' +
		'</div>' +
		'<div class="mchl-bar" id="mchl-ledger-bar"><div class="mchl-seg mchl-matched" style="width:0%"></div><div class="mchl-seg mchl-tasks" style="width:0%"></div><div class="mchl-seg mchl-missing" style="width:0%"></div></div>' +
		'<div class="mchl-ledger-legend"><span class="mchl-item"><span class="mchl-swatch mchl-matched"></span> תואמים בין שני האתרים</span><span class="mchl-item"><span class="mchl-swatch mchl-tasks"></span> ממתינים לטיפול</span><span class="mchl-item"><span class="mchl-swatch mchl-missing"></span> חסרים במכלול לגמרי</span></div>' +
		'</section>' +
		'<section class="mchl-stat-cards">' +
		'<div class="mchl-stat-card"><div class="mchl-n" id="mchl-stat-tasks">—</div><div class="mchl-l"><span class="mchl-mini-spinner" id="mchl-spin-tasks"></span><span class="mchl-warn-inline" id="mchl-warn-tasks" style="display:none;">⚠</span>משימות גרסה</div></div>' +
		'<div class="mchl-stat-card"><div class="mchl-n" id="mchl-stat-undoc">—</div><div class="mchl-l"><span class="mchl-mini-spinner" id="mchl-spin-undoc"></span><span class="mchl-warn-inline" id="mchl-warn-undoc" style="display:none;">⚠</span>ללא תבנית מיון</div></div>' +
		'<div class="mchl-stat-card"><div class="mchl-n" id="mchl-stat-missing">—</div><div class="mchl-l"><span class="mchl-mini-spinner" id="mchl-spin-missing"></span><span class="mchl-warn-inline" id="mchl-warn-missing" style="display:none;">⚠</span>חסרים במכלול</div></div>' +
		'</section>' +
		'</div>' +
		'<div class="mchl-body" id="mchl-body">' +
		'<aside class="mchl-side" id="mchl-side" style="display:none;"></aside>' +
		'<button type="button" class="mchl-side-rail" id="mchl-side-rail" data-action="toggle-side" title="הצגת המסננים">☰ מסננים</button>' +
		'<div class="mchl-main">' +
		'<div class="mchl-filter-bar" id="mchl-filter-bar">' +
		'<div class="mchl-search-wrap"><input class="mchl-search" id="mchl-search-input" placeholder="חיפוש בכותרת…"></div>' +
		'<div id="mchl-dynamic-filters" style="display:flex;gap:10px;flex-wrap:wrap;"></div>' +
		'<button type="button" class="mchl-clear-filters" id="mchl-clear-filters-btn" data-action="clear-filters" style="display:none;">נקה סינון</button>' +
		'<span class="mchl-spacer"></span>' +
		'<select class="mchl-page-size" id="mchl-page-size"><option value="25">25 בעמוד</option><option value="50" selected>50 בעמוד</option><option value="100">100 בעמוד</option><option value="250">250 בעמוד</option></select>' +
		'</div>' +
		'<div class="mchl-chips" id="mchl-chips" style="display:none;"></div>' +
		'<div class="mchl-selection-bar" id="mchl-selection-bar" style="display:none;">' +
		'<span><b id="mchl-selected-count">0</b> נבחרו</span>' +
		'<button type="button" class="mchl-select-all-matching" id="mchl-select-all-matching-btn" style="display:none;" data-action="select-all-matching"></button>' +
		'<span class="mchl-grow"></span>' +
		'<button type="button" class="mchl-export-btn" id="mchl-lock-titles-btn" style="display:none;" data-action="lock-titles">🔒 נעילת כותרות נבחרות</button>' +
		'<button type="button" class="mchl-export-btn" data-action="export" data-kind="csv">ייצוא CSV</button>' +
		'<button type="button" class="mchl-export-btn" data-action="export" data-kind="json">ייצוא JSON</button>' +
		'<button type="button" class="mchl-export-btn" data-action="export" data-kind="txt">ייצוא כותרות (טקסט)</button>' +
		'<button type="button" data-action="clear-selection">נקה בחירה</button>' +
		'</div>' +
		'<div class="mchl-wf-meter" id="mchl-wf-meter" style="display:none;"></div>' +
		'<div class="mchl-table-wrap"><div id="mchl-table-target"></div>' +
		'<div class="mchl-pager" id="mchl-pager" style="display:none;">' +
		'<span id="mchl-pager-summary"></span>' +
		'<div class="mchl-controls">' +
		'<button type="button" id="mchl-pg-first" data-action="goto" data-target="first">«</button>' +
		'<button type="button" id="mchl-pg-prev" data-action="goto" data-target="prev">‹</button>' +
		'<span id="mchl-pg-label"></span>' +
		'<button type="button" id="mchl-pg-next" data-action="goto" data-target="next">›</button>' +
		'<button type="button" id="mchl-pg-last" data-action="goto" data-target="last">»</button>' +
		'</div></div></div>' +
		'</div></div>' +
		'<footer class="mchl-footer">הנתונים מתעדכנים אוטומטית כל לילה (עדכון מצטבר) ובכל מוצאי שבת (סנכרון מלא)</footer>';

	function init() {
    	var groups = mw.config.get('wgUserGroups') || [];
    	var level = getLevel(groups);
    	userLevel = level;

    	if (level < 8) {
        $('#bodyContent').html('<div style="color: red; font-size: 18px; text-align: center; margin-top: 50px;">אין לך הרשאות לגשת לכלי זה.</div>');
        return;
    }
		var container = document.createElement('div');
		container.id = 'mchl-dash';
		container.innerHTML = HTML;
		var contentEl = document.getElementById('mw-content-text') || document.getElementById('bodyContent');
		if (!contentEl) return;
		contentEl.innerHTML = '';
		contentEl.appendChild(container);
		applyTheme();
		container.style.visibility = 'hidden';
		loadDashboardCss(function () { container.style.visibility = ''; });

		// פאנל הניהול (מפתח סרוויס + בעתיד עריכת התאמות ידניות) - הכפתור
		// שפותח אותו קיים ב-HTML הסטטי עם display:none, ורק כאן, לפי
		// level בפועל, הופך גלוי. זו עדיין רק בדיקת-נראות בצד הלקוח
		// (מי שבודק את קוד המקור/ה-DOM עם כלי מפתחים יראה את זה בכל
		// מקרה) - לא שכבת הגנה.
		if (level > ADMIN_LEVEL_THRESHOLD) {
			$id('mchl-admin-toggle-btn').style.display = 'inline-flex';
			restoreAuthSession();
		}

		wireEvents(container);
		var backendSelect = $id('mchl-backend-select');
		if (backendSelect) {
			backendSelect.value = BACKEND_NAME;
			backendSelect.addEventListener('change', function () {
				try { localStorage.setItem(BACKEND_STORAGE_KEY, backendSelect.value); } catch (e) { /* בלי אחסון: נשארים במסד הנוכחי */ }
				location.reload();
			});
		}
		if (PG_PROFILE) {
			var banner = document.createElement('div');
			banner.className = 'mchl-muted mchl-alert';
			banner.style.margin = '8px 0';
			banner.textContent = 'מוצג מהמסד החדש (v2), גרסת ניסוי. החזרה למסד הישן: ⚙ ניהול ← מסד נתונים.';
			container.insertBefore(banner, container.firstChild);
			// שער בריאות: הסנכרון ישן או תקוע (api.v_sync_status.health)
			fetch(SUPABASE_URL + '/rest/v1/v_sync_status?select=kind,health,last_success_at&kind=eq.sync', { headers: pgHeaders() })
				.then(function (res) { return res.ok ? res.json() : []; })
				.then(function (rows) {
					var h = rows && rows[0];
					if (!h || h.health === 'ok') return;
					var warn = document.createElement('div');
					warn.className = 'mchl-alert';
					warn.style.margin = '8px 0';
					warn.textContent = h.health === 'never' ? 'הנתונים טרם סונכרנו.'
						: h.health === 'stuck' ? 'הסנכרון האחרון נראה תקוע; הנתונים עלולים להיות ישנים.'
						: 'הנתונים לא עודכנו מאז ' + new Date(h.last_success_at).toLocaleString('he-IL') + '.';
					container.insertBefore(warn, banner.nextSibling);
				}).catch(function () { /* אזהרה בלבד */ });
		}
		buildTabs();
		applySiteNav();
		applySidePanel();
		if (VIEWS[activeTab] && VIEWS[activeTab].columns.indexOf('wikidata_desc') !== -1) $id('mchl-search-input').placeholder = 'חיפוש בכותרת או בתיאור ויקינתונים…';
		buildDynamicFilters();
		$id('mchl-search-input').addEventListener('input', function () {
			clearTimeout(searchDebounce);
			searchDebounce = setTimeout(function () { currentPage = 0; loadActiveView(); renderChips(); }, 550);
		});
		$id('mchl-page-size').addEventListener('change', onPageSizeChange);
		refreshAll();
	}

	mw.hook('wikipage.content').add(function () { init(); });
}());
