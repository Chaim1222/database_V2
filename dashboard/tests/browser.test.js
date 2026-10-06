// בדיקת דפדפן אמיתית (Playwright + Chromium): הגאדג'ט הבנוי רץ בדף עם mw מדומה ושרת PostgREST מדומה (route).
// הרצה: node dashboard/build.js && node dashboard/tests/browser.test.js  (דורש playwright; מדלג אם אינו זמין)
'use strict';
const path = require('path');
const fs = require('fs');
let chromium;
try { ({ chromium } = require('playwright')); } catch (e) { console.log('SKIP: playwright לא זמין'); process.exit(process.env.REQUIRE_BROWSER ? 1 : 0); }

const BUILT = path.join(__dirname, '..', 'dist', 'gadget-dashboard.js');
const MISSING = [
	{ id: 1, title: 'ערך א', topic: 'geo', has_images: true, created_at: '2020-01-01T00:00:00Z', wikidata_desc: 'תיאור', mech_redirect: false, scan_state: 'scanned', verdict_list_a: 'problem', verdict_list_s: 'problem', verdict_ctx_a: 'review', suspicion_a: 'high' },
	{ id: 2, title: 'ערך ב', topic: null, has_images: false, created_at: null, mech_redirect: false, scan_state: 'not_scanned' }
];

(async () => {
	const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || chromium.executablePath(), args: ['--no-sandbox'] });
	const page = await browser.newPage();
	const requests = [];
	const errors = [];
	page.on('pageerror', (e) => errors.push(e.message));
	if (process.env.DEBUG_BROWSER) { page.on('console', (m) => console.log('console:', m.text())); page.on('requestfailed', (r) => console.log('failed:', r.url(), r.failure() && r.failure().errorText)); }
	await page.route('https://ukzijtrpchvmoxlslxpz.supabase.co/**', async (route) => {
		const url = new URL(route.request().url());
		const headers = route.request().headers();
		requests.push({ path: url.pathname, query: url.search, profile: headers['accept-profile'], range: headers['range'] });
		const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-expose-headers': 'Content-Range', 'access-control-allow-methods': '*' };
		if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
		if (url.pathname.endsWith('/v_missing')) return route.fulfill({ status: 200, headers: { ...cors, 'content-range': '0-1/2', 'content-type': 'application/json' }, body: JSON.stringify(MISSING) });
		if (url.pathname.endsWith('/v_counts')) return route.fulfill({ status: 200, headers: { ...cors, 'content-range': '0-0/1', 'content-type': 'application/json' }, body: JSON.stringify([{ key: 'missing', n: 34019, updated_at: '2026-10-05T20:00:00Z' }]) });
		route.fulfill({ status: 200, headers: { ...cors, 'content-range': '*/0', 'content-type': 'application/json' }, body: '[]' });
	});
	// ה-API של המכלול והוויקיפדיה (טאבי בקשות ותרבות)
	const REQUESTS_TEXT = '== [[ערך א]] ==\nבבקשה [[משתמש:דני]] 10:30, 5 באוקטובר 2026 (IDT)\n== [[ערך ב]] ==\nתודה [[משתמש:רינה]] 11:00, 1 בספטמבר 2026\n: {{בוצע}}';
	const cors = { 'access-control-allow-origin': '*', 'content-type': 'application/json' };
	await page.route('https://mechalol.test/w/api.php**', (route) => {
		const q = new URL(route.request().url()).searchParams;
		if (q.get('prop') === 'revisions') return route.fulfill({ status: 200, headers: cors, body: JSON.stringify({ query: { pages: [{ revisions: [{ slots: { main: { content: REQUESTS_TEXT } } }] }] } }) });
		if (q.get('prop') === 'info') return route.fulfill({ status: 200, headers: cors, body: JSON.stringify({ query: { pages: [{ title: 'ערך א', missing: true }, { title: 'ערך ב', missing: true }] } }) });
		return route.fulfill({ status: 200, headers: cors, body: JSON.stringify({ query: { pages: [{ title: 'קטגוריה:דפים לטיפול תרבות/ספורט', categoryinfo: { pages: 7 } }] } }) });
	});
	await page.route('https://he.wikipedia.org/w/api.php**', (route) => route.fulfill({ status: 200, headers: cors, body: JSON.stringify({ query: { pages: [{ title: 'ערך א', pageid: 1 }, { title: 'ערך ב', missing: true }] } }) }));
	await page.route('https://mechalol.test/', (route) => route.fulfill({ status: 200, contentType: 'text/html', body: '<html><body><div id="mw-content-text">old</div></body></html>' }));
	await page.goto('https://mechalol.test/');
	await page.addInitScript(() => {});
	await page.evaluate(() => { window.mw = { config: { get: (k) => ({ wgCanonicalSpecialPageName: 'Blankpage', wgPageName: 'מיוחד:דף_ריק/ניהול_ייבוא', wgScript: '/w/index.php', wgScriptPath: '/w' })[k] } }; });
	await page.addScriptTag({ content: fs.readFileSync(BUILT, 'utf8') });
	await page.waitForSelector('table.mchl2-table tbody tr', { timeout: 8000 }).catch(async (e) => { console.log('HTML:', (await page.content()).slice(0, 600), 'errors:', errors, 'requests:', requests.length); throw e; });

	const rows = await page.$$eval('table.mchl2-table tbody tr', (r) => r.length);
	const firstLevel = await page.$$eval('table.mchl2-table tbody tr:first-child td', (t) => t.map((c) => c.textContent));
	const footer = await page.textContent('.mchl2-pager');
	const api = requests.find((r) => r.path.endsWith('/v_missing'));
	const checks = [
		['שתי שורות', rows === 2],
		['רמה לפי רשימה מאושרות = בעיה ודאית', firstLevel.includes('בעיה ודאית')],
		['ספירה בעימוד', /2 שורות/.test(footer)],
		['סכמת api בכותרת', api && api.profile === 'api'],
		['סינון בסיס mech_redirect=false', api && /mech_redirect=eq\.false/.test(api.query)],
		['סדר לפי תאריך יצירה', api && /order=created_at\.asc\.nullslast%2Cid\.asc/.test(api.query)],
		['Range ראשון', api && api.range === '0-49']
	];

	// שיטת הקשר: הרמה הופכת לחשד גבוה
	await page.selectOption('.mchl2-top select >> nth=0', 'ctx');
	const ctxLevel = await page.$$eval('table.mchl2-table tbody tr:first-child td', (t) => t.map((c) => c.textContent));
	checks.push(['שיטת הקשר: חשד גבוה', ctxLevel.includes('חשד גבוה')]);

	// סינון לפי רמה (הקשר, חשד גבוה) נשלח כפרמטרים
	await page.selectOption('.mchl2-controls select >> nth=0', 'high');
	await page.waitForTimeout(200);
	const filtered = requests.filter((r) => r.path.endsWith('/v_missing')).pop();
	checks.push(['סינון הקשר ושדה חשד', /verdict_ctx_a=eq\.review/.test(filtered.query) && /suspicion_a=eq\.high/.test(filtered.query)]);
	checks.push(['רמה מחייבת סריקה עדכנית', /scan_state=eq\.scanned/.test(filtered.query)]);
	await page.selectOption('.mchl2-top select >> nth=0', 'list');
	await page.waitForTimeout(200);
	const cleared = requests.filter((r) => r.path.endsWith('/v_missing')).at(-1);
	checks.push(['דרגת חשד שאינה קיימת ברשימה מתאפסת', await page.inputValue('.mchl2-controls select >> nth=0') === '' && !/verdict_list_a=eq\.high/.test(cleared.query)]);
	await page.selectOption('.mchl2-top select >> nth=0', 'ctx');

	// החלפת שיטה/רשימה בזמן שסינון הרמה פעיל: סט השורות חייב להגיע משאילתה חדשה.
	await page.selectOption('.mchl2-controls select >> nth=0', 'clean');
	await page.waitForTimeout(200);
	let before = requests.filter((r) => r.path.endsWith('/v_missing')).length;
	await page.selectOption('.mchl2-top select >> nth=0', 'list');
	await page.waitForTimeout(200);
	let latest = requests.filter((r) => r.path.endsWith('/v_missing'));
	checks.push(['החלפת שיטה טוענת סינון חדש', latest.length > before && /verdict_list_a=eq\.clean/.test(latest.at(-1).query) && !/verdict_ctx_a/.test(latest.at(-1).query)]);
	before = latest.length;
	await page.selectOption('.mchl2-top select >> nth=1', 's');
	await page.waitForTimeout(200);
	latest = requests.filter((r) => r.path.endsWith('/v_missing'));
	checks.push(['החלפת רשימות טוענת סינון חדש', latest.length > before && /verdict_list_s=eq\.clean/.test(latest.at(-1).query) && !/verdict_list_a/.test(latest.at(-1).query)]);
	await page.selectOption('.mchl2-controls select >> nth=0', '');
	await page.waitForTimeout(200);
	before = requests.filter((r) => r.path.endsWith('/v_missing')).length;
	await page.selectOption('.mchl2-top select >> nth=0', 'ctx');
	await page.waitForTimeout(100);
	checks.push(['ללא סינון רמה אין שליפה מיותרת', requests.filter((r) => r.path.endsWith('/v_missing')).length === before]);

	// טאב סטטיסטיקה
	await page.click('text=סטטיסטיקה');
	await page.waitForSelector('text=34,019');
	checks.push(['טאב סטטיסטיקה', true]);

	// בקשות ייבוא: שתי בקשות; ערך א עם נתוני מסד (v_missing), ערך ב בוצע (יש תגובת בוצע)
	await page.click('text=בקשות ייבוא');
	await page.waitForSelector('table.mchl2-table tbody tr', { timeout: 8000 }).catch(() => {});
	const reqTexts = await page.$$eval('table.mchl2-table tbody tr', (r) => r.map((x) => x.textContent));
	checks.push(['בקשות: ממתינות מוצגות כברירת מחדל (ערך א)', reqTexts.length === 1 && /ערך א/.test(reqTexts[0]) && /דני/.test(reqTexts[0])]);
	if (process.env.DEBUG_BROWSER) console.log('REQ TAB:', (await page.textContent('.mchl2')).slice(0, 400), errors);
	await page.click('text=הכול (2)');
	checks.push(['בקשות: הכול = 2', (await page.$$eval('table.mchl2-table tbody tr', (r) => r.length)) === 2]);
	await page.click('text=דפים לטיפול - תרבות');
	await page.waitForSelector('text=ספורט', { timeout: 8000 }).catch(() => {});
	checks.push(['תרבות: תת-קטגוריה עם ספירה', /ספורט \(7\)/.test(await page.textContent('.mchl2'))]);

	let failed = 0;
	checks.forEach(([name, ok]) => { console.log((ok ? 'ok   ' : 'FAIL ') + name); if (!ok) failed++; });
	if (errors.length) { console.log('שגיאות דף:', errors); failed++; }
	await browser.close();
	process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
