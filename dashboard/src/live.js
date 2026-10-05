// טאבים חיים מה-API של המכלול (בלי מסד): "בקשות ייבוא" (הדף המכלול:בקשת ייבוא ערך) ו"דפים לטיפול - תרבות" (חברי קטגוריה).
// פענוח הבקשות הועתק מהגאדג'ט הישן (gadget-searchHelperDashboard.js) ללא שינוי בכללים; כאן הוא טהור ונבדק ב-tests/.
// בשונה מהישן: תצוגה בלבד (התגובה לבקשה נעשית בדף עצמו, דרך קישור).
var REQUESTS_PAGE = 'המכלול:בקשת ייבוא ערך';
var CULTURE_CATEGORY = 'קטגוריה:דפים לטיפול תרבות';
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

// קיום במכלול (missing / exists / redirect) וקיום בוויקיפדיה (מזהה וכותרת אחרי הפניה), לכותרות הבקשות. mwApi(params) -> Promise<json>;
// wikiApi(params) -> Promise<json> (CORS). שניהם מוזרקים.
function lookupTitles(titles, mwApi, wikiApi) {
	var mech = {}, wiki = {};
	var parts = [];
	for (var i = 0; i < titles.length; i += 50) parts.push(titles.slice(i, i + 50));
	var jobs = [];
	parts.forEach(function (b) {
		jobs.push(mwApi({ action: 'query', titles: b.join('|'), prop: 'info' }).then(function (d) {
			var q = d.query || {}, norm = {};
			(q.normalized || []).forEach(function (n) { norm[n.to] = n.from; });
			(q.pages || []).forEach(function (pg) { mech[norm[pg.title] || pg.title] = pg.missing ? 'missing' : pg.redirect ? 'redirect' : 'exists'; });
		}));
		jobs.push(wikiApi({ action: 'query', titles: b.join('|'), redirects: '1' }).then(function (d) {
			var q = d.query || {}, back = {};
			(q.normalized || []).forEach(function (n) { back[n.to] = n.from; });
			(q.redirects || []).forEach(function (r) { back[r.to] = back[r.from] || r.from; });
			(q.pages || []).forEach(function (pg) { wiki[back[pg.title] || pg.title] = pg.missing ? null : { id: pg.pageid, title: pg.title }; });
		}));
	});
	return Promise.all(jobs).then(function () { return { mech: mech, wiki: wiki }; });
}

if (typeof module !== 'undefined') module.exports = { parseRequests: parseRequests, sigDate: sigDate, wikiPlain: wikiPlain, lookupTitles: lookupTitles, REQUESTS_PAGE: REQUESTS_PAGE, CULTURE_CATEGORY: CULTURE_CATEGORY };
