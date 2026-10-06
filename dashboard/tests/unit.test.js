'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { levelParams, buildParams, escapeIlike, sparkline } = require('../src/filters.js');
const { toCsv } = require('../src/export.js');
const { createClient } = require('../src/api-client.js');
const { TABS, rowLevel } = require('../src/tabs.js');

test('levelParams: רשימה והקשר', () => {
	assert.deepStrictEqual(levelParams('list', 'a', 'problem'), [['scan_state', 'eq.scanned'], ['verdict_list_a', 'eq.problem']]);
	assert.deepStrictEqual(levelParams('ctx', 's', 'high'), [['scan_state', 'eq.scanned'], ['verdict_ctx_s', 'eq.review'], ['suspicion_s', 'eq.high']]);
	assert.deepStrictEqual(levelParams('ctx', 'a', 'clean'), [['scan_state', 'eq.scanned'], ['verdict_ctx_a', 'eq.clean']]);
	assert.deepStrictEqual(levelParams('list', 'a', 'not_scanned'), [['scan_state', 'eq.not_scanned']]);
	assert.deepStrictEqual(levelParams('list', 'a', ''), []);
});

test('buildParams: בסיס, סינון וחיפוש (הוצאת תווים מסוכנים)', () => {
	const p = buildParams(TABS.missing, { method: 'ctx', mode: 's', filters: { level: 'medium', has_images: 'true' }, search: 'a,b(c)*%' });
	assert.deepStrictEqual(p[0], ['mech_redirect', 'eq.false']);
	assert.ok(p.some((x) => x[0] === 'suspicion_s' && x[1] === 'eq.medium'));
	assert.ok(p.some((x) => x[0] === 'has_images' && x[1] === 'eq.true'));
	assert.deepStrictEqual(p[p.length - 1], ['title', 'ilike.*a b c*']);
	assert.strictEqual(escapeIlike('x%y'), 'x y');
	const rav = buildParams(TABS.rav, { filters: {}, search: 'משה' });
	assert.deepStrictEqual(rav, [['wiki_title', 'ilike.*משה*']]);
});

test('rowLevel לפי שיטה ומצב', () => {
	const r = { scan_state: 'scanned', verdict_list_a: 'review', verdict_ctx_a: 'review', suspicion_a: 'low', verdict_list_s: 'problem' };
	assert.strictEqual(rowLevel(r, 'list', 'a'), 'review');
	assert.strictEqual(rowLevel(r, 'ctx', 'a'), 'low');
	assert.strictEqual(rowLevel(r, 'list', 's'), 'problem');
	assert.strictEqual(rowLevel({ scan_state: 'not_scanned' }, 'list', 'a'), 'not_scanned');
	for (const method of ['list', 'ctx']) for (const mode of ['a', 's']) {
		assert.strictEqual(rowLevel({ ...r, scan_state: 'stale', ['verdict_' + method + '_' + mode]: 'clean' }, method, mode), 'stale');
		assert.deepStrictEqual(levelParams(method, mode, 'clean')[0], ['scan_state', 'eq.scanned']);
	}
});

test('toCsv: BOM, מירכאות ושורות חדשות', () => {
	const csv = toCsv([{ key: 'title', label: 'כותרת' }, { key: 'n', label: 'מספר' }], [{ title: 'א"ב, ג', n: 1 }, { title: 'שורה\nשנייה', n: null }]);
	assert.strictEqual(csv.charCodeAt(0), 0xfeff);
	assert.ok(csv.includes('"א""ב, ג",1'));
	assert.ok(csv.includes('"שורה\nשנייה",'));
});

function fakeFetch(handlers) {
	const calls = [];
	const fn = async (url, init) => {
		calls.push({ url, init });
		const h = handlers.shift();
		return { ok: h.status < 400, status: h.status, headers: { get: (k) => (k === 'Content-Range' ? h.range || null : null) }, json: async () => h.body, text: async () => (typeof h.body === 'string' ? h.body : JSON.stringify(h.body)) };
	};
	fn.calls = calls;
	return fn;
}
const cfg = { url: 'https://x.supabase.co', anonKey: 'ANON', schema: 'api', pageSize: 50, sessionKey: 's' };

test('select: Range, ספירה, פרופיל api', async () => {
	const f = fakeFetch([{ status: 206, range: '0-49/123', body: [{ id: 1 }] }]);
	const c = createClient({ fetch: f, config: cfg });
	const res = await c.select('v_missing', { params: [['mech_redirect', 'eq.false']], order: 'id.asc', from: 0 });
	assert.deepStrictEqual(res, { data: [{ id: 1 }], count: 123 });
	const { url, init } = f.calls[0];
	assert.ok(url.startsWith('https://x.supabase.co/rest/v1/v_missing?'));
	assert.strictEqual(init.headers.Range, '0-49');
	assert.strictEqual(init.headers['Accept-Profile'], 'api');
	assert.strictEqual(init.headers.Prefer, 'count=exact');
});

test('select: ניסיון חוזר אחד על 5xx, ובלי ניסיון חוזר על timeout', async () => {
	const ok = createClient({ fetch: fakeFetch([{ status: 503, body: 'down' }, { status: 200, range: '0-0/1', body: [] }]), config: cfg });
	assert.strictEqual((await ok.select('v')).count, 1);
	const f = fakeFetch([{ status: 500, body: '{"code":"57014"}' }, { status: 200, body: [] }]);
	await assert.rejects(createClient({ fetch: f, config: cfg }).select('v'), /57014/);
	assert.strictEqual(f.calls.length, 1);
});

test('התחברות, טוקן ב-rpc, ורענון על 401', async () => {
	const store = {};
	const storage = { getItem: (k) => store[k] || null, setItem: (k, v) => { store[k] = v; }, removeItem: (k) => { delete store[k]; } };
	const f = fakeFetch([
		{ status: 200, body: { access_token: 'T1', refresh_token: 'R1', user: { email: 'a@b' } } },
		{ status: 401, body: 'expired' },
		{ status: 200, body: { access_token: 'T2', refresh_token: 'R2', user: { email: 'a@b' } } },
		{ status: 200, body: 'true' }
	]);
	const c = createClient({ fetch: f, storage, config: cfg });
	await c.login('a@b', 'pw');
	assert.ok(c.isLoggedIn());
	assert.strictEqual(await c.rpc('is_admin', {}), true);
	assert.strictEqual(f.calls[1].init.headers.Authorization, 'Bearer T1');
	assert.strictEqual(f.calls[3].init.headers.Authorization, 'Bearer T2');
	c.logout();
	assert.ok(!c.isLoggedIn());
});

const { parseRequests, lookupTitles } = require('../src/live.js');
test('התחברות ללא אחסון או עם אחסון חסום נשמרת עד יציאה', async () => {
	for (const storage of [undefined, { getItem() { throw Error('blocked'); }, setItem() { throw Error('blocked'); }, removeItem() { throw Error('blocked'); } }]) {
		const f = fakeFetch([{ status: 200, body: { access_token: 'T', refresh_token: 'R', user: { email: 'a@b' } } }, { status: 200, body: true }]);
		const c = createClient({ fetch: f, config: cfg, storage });
		await c.login('a@b', 'pw');
		assert.ok(c.isLoggedIn());
		assert.strictEqual(c.email(), 'a@b');
		await c.rpc('is_admin');
		assert.strictEqual(f.calls[1].init.headers.Authorization, 'Bearer T');
		c.logout();
		assert.ok(!c.isLoggedIn());
	}
});

test('שליפת משוב מזוהה מרעננת טוקן פעם אחת', async () => {
	const f = fakeFetch([{ status: 200, body: { access_token: 'T1', refresh_token: 'R' } }, { status: 401, body: 'expired' },
		{ status: 200, body: { access_token: 'T2', refresh_token: 'R2' } }, { status: 200, body: [] }]);
	const c = createClient({ fetch: f, config: cfg });
	await c.login('a@b', 'pw');
	assert.deepStrictEqual((await c.select('word_filter_feedback', { authed: true })).data, []);
	assert.strictEqual(f.calls[3].init.headers.Authorization, 'Bearer T2');
});

test('parseRequests: סטטוס, מבקש ותאריך; מרחבי שם אחרים מסוננים', () => {
	const text = ['== [[ערך א]] ==', 'תודה. [[משתמש:דני]] 10:30, 5 באוקטובר 2026 (IDT)', ': {{בוצע}} [[משתמש:ג]] 12:00, 6 באוקטובר 2026',
		'== [[קטגוריה:x]] ==', '== [[ערך ב]] ==', 'בבקשה --[[משתמש:רינה]] 11:00, 1 בספטמבר 2026', '=== תת-כותרת ===', ': ראינו'].join('\n');
	const r = parseRequests(text);
	assert.deepStrictEqual(r.map((x) => [x.title, x.status, x.requester]), [['ערך א', 'done', 'דני'], ['ערך ב', 'replied', 'רינה']]);
	assert.strictEqual(r[1].date.getMonth(), 8);
});

test('lookupTitles: קיום במכלול ובוויקיפדיה (נרמול והפניות)', async () => {
	const mw = async () => ({ query: { pages: [{ title: 'א', missing: true }, { title: 'ב', redirect: true }, { title: 'ג' }] } });
	const wiki = async () => ({ query: { normalized: [{ from: 'א_', to: 'א' }], redirects: [{ from: 'ב', to: 'ב יעד' }], pages: [{ title: 'א', pageid: 1 }, { title: 'ב יעד', pageid: 2 }, { title: 'ג', missing: true }] } });
	const res = await lookupTitles(['א', 'ב', 'ג'], mw, wiki);
	assert.deepStrictEqual(res.mech, { א: 'missing', ב: 'redirect', ג: 'exists' });
	assert.deepStrictEqual(res.wiki.ב, { id: 2, title: 'ב יעד' });
	assert.strictEqual(res.wiki.ג, null);
});

test('sparkline: מגמה טקסטואלית', () => {
	assert.strictEqual(sparkline([1]), '');
	assert.strictEqual(sparkline([5, 5, 5]), '▁▁▁');
	assert.strictEqual(sparkline([0, 10]), '▁█');
	assert.strictEqual(sparkline([0, 5, 10]).length, 3);
});
