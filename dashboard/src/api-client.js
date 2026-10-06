// לקוח PostgREST ל-v2: קריאות לסכמת api, התחברות Supabase Auth ורענון טוקן. fetch והאחסון מוזרקים (נבדק ב-tests/).
function createClient(opts) {
	var fetchFn = opts.fetch;
	var storage = opts.storage;
	var memorySession;
	var refreshing = null;
	var cfg = opts.config;

	function readSession() {
		if (memorySession !== undefined) return memorySession;
		try { return storage ? JSON.parse(storage.getItem(cfg.sessionKey) || 'null') : null; } catch (e) { return null; }
	}
	function writeSession(s) {
		memorySession = s;
		try { if (storage) { if (s) storage.setItem(cfg.sessionKey, JSON.stringify(s)); else storage.removeItem(cfg.sessionKey); } } catch (e) { /* נשמר בזיכרון עד סגירת הדף */ }
	}
	function headers(extra, authed) {
		var s = authed ? readSession() : null;
		var h = { apikey: cfg.anonKey, Authorization: 'Bearer ' + (s && s.access_token ? s.access_token : cfg.anonKey),
			'Accept-Profile': cfg.schema, 'Content-Profile': cfg.schema };
		for (var k in (extra || {})) h[k] = extra[k];
		return h;
	}
	function fail(res, text) {
		var err = new Error('HTTP ' + res.status + ': ' + String(text).slice(0, 300));
		err.status = res.status;
		return err;
	}
	function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

	// שליפה עם עימוד (Range) וספירה מדויקת. ניסיון חוזר אחד על 5xx/429, ללא ניסיון חוזר על timeout (57014): עדיף שגיאה ברורה.
	function select(view, o) {
		o = o || {};
		var params = new URLSearchParams();
		params.set('select', o.select || '*');
		(o.params || []).forEach(function (p) { params.append(p[0], p[1]); });
		if (o.order) params.set('order', o.order);
		var extra = { Range: (o.from || 0) + '-' + (o.to === undefined ? (o.from || 0) + cfg.pageSize - 1 : o.to), 'Range-Unit': 'items' };
		if (o.count !== false) extra.Prefer = 'count=exact';
		var attempt = function (n, renewed) {
			return fetchFn(cfg.url + '/rest/v1/' + view + '?' + params.toString(), { headers: headers(extra, o.authed) }).then(function (res) {
				if (o.authed && res.status === 401 && !renewed) return refresh().then(function () { return attempt(n, true); });
				if ((res.status >= 500 || res.status === 429) && n < 1) {
					return res.text().then(function (t) {
						if (/57014/.test(t)) throw fail(res, t);
						return wait(1500).then(function () { return attempt(n + 1, renewed); });
					});
				}
				if (!res.ok) return res.text().then(function (t) { throw fail(res, t); });
				var total = parseInt((res.headers.get('Content-Range') || '').split('/')[1], 10);
				return res.json().then(function (data) { return { data: data, count: isNaN(total) ? null : total }; });
			});
		};
		return attempt(0);
	}

	function rpc(name, body) {
		var send = function () {
			return fetchFn(cfg.url + '/rest/v1/rpc/' + name, { method: 'POST', headers: headers({ 'Content-Type': 'application/json' }, true), body: JSON.stringify(body || {}) });
		};
		return send().then(function (res) {
			if (res.status !== 401) return res;
			return refresh().then(send);
		}).then(function (res) {
			if (!res.ok) return res.text().then(function (t) { throw fail(res, t); });
			return res.text().then(function (t) { return t ? JSON.parse(t) : null; });
		});
	}

	function authCall(grant, body) {
		return fetchFn(cfg.url + '/auth/v1/token?grant_type=' + grant, {
			method: 'POST', headers: { apikey: cfg.anonKey, 'Content-Type': 'application/json' }, body: JSON.stringify(body)
		}).then(function (res) {
			return res.json().then(function (d) {
				if (!res.ok || !d.access_token) throw new Error(d.error_description || d.msg || 'ההתחברות נכשלה');
				writeSession({ access_token: d.access_token, refresh_token: d.refresh_token, email: d.user && d.user.email });
				return d;
			});
		});
	}
	function login(email, password) { return authCall('password', { email: email, password: password }); }
	function refresh() {
		if (refreshing) return refreshing;
		var s = readSession();
		if (!s || !s.refresh_token) return Promise.reject(new Error('פג תוקף ההתחברות, יש להתחבר מחדש'));
		refreshing = authCall('refresh_token', { refresh_token: s.refresh_token });
		return refreshing.then(function (d) { refreshing = null; return d; }, function (e) { refreshing = null; throw e; });
	}
	function logout() { writeSession(null); }
	function isLoggedIn() { var s = readSession(); return !!(s && s.access_token); }
	function email() { var s = readSession(); return s && s.email; }

	return { select: select, rpc: rpc, login: login, logout: logout, isLoggedIn: isLoggedIn, email: email };
}

if (typeof module !== 'undefined') module.exports = { createClient: createClient };
