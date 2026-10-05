// ממשק: מצב, רינדור, אירועים. הנתונים נשלפים רק דרך api-client; אין חישוב בצד הלקוח מעבר לתצוגה.
function h(tag, attrs, children) {
	var el = document.createElement(tag);
	Object.keys(attrs || {}).forEach(function (k) {
		if (k === 'text') el.textContent = attrs[k];
		else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), attrs[k]);
		else if (attrs[k] !== null && attrs[k] !== undefined && attrs[k] !== false) el.setAttribute(k, attrs[k]);
	});
	[].concat(children || []).forEach(function (c) { if (c !== null && c !== undefined) el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
	return el;
}

function createApp(root, client, env) {
	var state = { tab: 'missing', page: 0, search: '', filters: {}, method: 'list', mode: 'a', rows: [], count: null, error: null, loading: false,
		admin: false, expanded: {}, details: {}, marks: {}, notice: '', req: { rows: null, filter: 'open' }, culture: { subcats: null, selected: null, members: [], cont: null, loading: false } };
	var wikiBase = 'https://he.wikipedia.org/wiki/';
	var editBase = (env.scriptUrl || '/w/index.php');
	var token = 0;

	function tab() { return TABS[state.tab]; }
	function wikiUrl(title) { return wikiBase + encodeURIComponent(String(title).replace(/ /g, '_')); }
	function mechUrl(title, action) { return editBase + '?title=' + encodeURIComponent(String(title).replace(/ /g, '_')) + (action ? '&action=' + action : ''); }

	function load() {
		var t = tab();
		if (t.special) { render(); return renderSpecial(); }
		var my = ++token;
		state.loading = true; state.error = null; render();
		return client.select(t.view, { params: buildParams(t, state), order: t.order, from: state.page * CONFIG.pageSize, to: (state.page + 1) * CONFIG.pageSize - 1 })
			.then(function (res) { if (my !== token) return; state.rows = res.data; state.count = res.count; state.loading = false; render(); })
			.catch(function (e) { if (my !== token) return; state.loading = false; state.rows = []; state.error = e.message; render(); });
	}

	function loadRequests() {
		var my = ++token;
		state.error = null; state.req.rows = null; render();
		var reqs;
		return env.mwApi({ action: 'query', prop: 'revisions', rvprop: 'content', rvslots: 'main', titles: REQUESTS_PAGE }).then(function (d) {
			var pg = d.query && d.query.pages && d.query.pages[0];
			if (!pg || !pg.revisions) throw new Error('הדף "' + REQUESTS_PAGE + '" לא נמצא');
			reqs = parseRequests(pg.revisions[0].slots.main.content);
			return lookupTitles(reqs.map(function (r) { return r.title; }), env.mwApi, env.wikiApi);
		}).then(function (found) {
			reqs.forEach(function (r) {
				r.mech = found.mech[r.title] || 'missing';
				r.wiki = found.wiki[r.title] || null;
				if (r.mech === 'exists' && r.status !== 'done') { r.status = 'done'; r.doneBy = 'exists'; }   // ערך שכבר קיים במכלול: הבקשה בוצעה (הכרעת חיים, 2026-09-29)
			});
			var ids = reqs.filter(function (r) { return r.wiki; }).map(function (r) { return r.wiki.id; });
			if (!ids.length) return [];
			var chunksOf = [];
			for (var i = 0; i < ids.length; i += 150) chunksOf.push(ids.slice(i, i + 150));
			return Promise.all(chunksOf.map(function (b) {
				return client.select('v_missing', { params: [['id', 'in.(' + b.join(',') + ')']], count: false, from: 0, to: b.length - 1 }).then(function (res) { return res.data; });
			})).then(function (parts) { return [].concat.apply([], parts); });
		}).then(function (dbRows) {
			if (my !== token) return;
			var byId = {};
			dbRows.forEach(function (r) { byId[r.id] = r; });
			state.req.rows = reqs.map(function (r) { return { req: r, db: r.wiki ? byId[r.wiki.id] || null : null }; })
				.sort(function (a, b) { return (b.req.date || 0) - (a.req.date || 0); });
			render();
		}).catch(function (e) { if (my === token) { state.error = e.message; render(); } });
	}

	function loadCulture(subcat) {
		var my = ++token, c = state.culture;
		state.error = null;
		if (!subcat) {
			c.selected = null;
			if (c.subcats) { render(); return Promise.resolve(); }
			return env.mwApi({ action: 'query', generator: 'categorymembers', gcmtitle: CULTURE_CATEGORY, gcmtype: 'subcat', gcmlimit: '50', prop: 'categoryinfo' }).then(function (d) {
				if (my !== token) return;
				c.subcats = ((d.query && d.query.pages) || []).map(function (p) { return { title: p.title, count: (p.categoryinfo && p.categoryinfo.pages) || 0 }; })
					.sort(function (a, b) { return a.title.localeCompare(b.title, 'he'); });
				render();
			}).catch(function (e) { if (my === token) { state.error = e.message; render(); } });
		}
		if (c.selected !== subcat) { c.selected = subcat; c.members = []; c.cont = null; }
		c.loading = true; render();
		var params = { action: 'query', list: 'categorymembers', cmtitle: subcat, cmtype: 'page', cmnamespace: '0', cmlimit: '50' };
		if (c.cont) params.cmcontinue = c.cont;
		return env.mwApi(params).then(function (d) {
			if (my !== token || c.selected !== subcat) return;
			c.members = c.members.concat((d.query && d.query.categorymembers) || []);
			c.cont = (d.continue && d.continue.cmcontinue) || null;
			c.loading = false; render();
		}).catch(function (e) { c.loading = false; if (my === token) { state.error = e.message; render(); } });
	}

	function renderSpecial() {
		var t = tab();
		if (t.special === 'requests') return loadRequests();
		if (t.special === 'culture') return loadCulture(null);
		var my = ++token;
		var req = t.special === 'stats' ? client.select('v_counts', { count: false, to: 50 }) : client.select('v_sync_status', { count: false, to: 50 });
		return req.then(function (res) { if (my === token) { state.rows = res.data; state.error = null; render(); } })
			.catch(function (e) { if (my === token) { state.error = e.message; render(); } });
	}

	function cellText(col, row) {
		if (col.computed) return LEVEL_LABELS[rowLevel(row, state.method, state.mode)] || '';
		var v = row[col.key];
		if (v === null || v === undefined) return '';
		if (typeof v === 'boolean') return v ? '✓' : '';
		if (/_at$/.test(col.key)) return String(v).slice(0, 10);
		return String(v);
	}

	function controls() {
		var t = tab();
		var box = h('div', { 'class': 'mchl2-controls' });
		box.appendChild(h('input', { type: 'search', placeholder: 'חיפוש בכותרת…', value: state.search, 'class': 'mchl2-input',
			onchange: function (e) { state.search = e.target.value; state.page = 0; load(); } }));
		(t.filters || []).forEach(function (f) {
			if (f.text) {
				box.appendChild(h('input', { type: 'text', placeholder: f.label, value: state.filters[f.key] || '', 'class': 'mchl2-input',
					onchange: function (e) { state.filters[f.key] = e.target.value.trim(); state.page = 0; load(); } }));
				return;
			}
			var sel = h('select', { 'class': 'mchl2-input', onchange: function (e) { state.filters[f.key] = e.target.value; state.page = 0; load(); } },
				[h('option', { value: '', text: f.label + ': הכול' })].concat(f.options.map(function (o) {
					return h('option', { value: o.value, text: o.label, selected: state.filters[f.key] === o.value ? 'selected' : null });
				})));
			box.appendChild(sel);
		});
		box.appendChild(h('button', { 'class': 'mchl2-btn', text: 'ייצוא CSV', onclick: exportCsv }));
		return box;
	}

	function exportCsv() {
		var t = tab();
		var all = [], from = 0;
		state.notice = 'מייצא…'; render();
		(function next() {
			return client.select(t.view, { params: buildParams(t, state), order: t.order, from: from, to: from + 999, count: false }).then(function (res) {
				all = all.concat(res.data);
				if (res.data.length === 1000) { from += 1000; return next(); }
			});
		})().then(function () {
			var cols = t.columns.map(function (c) { return { key: c.key, label: c.label }; });
			if (t.columns.some(function (c) { return c.computed; })) {
				all = all.map(function (r) { var o = Object.assign({}, r); o.level = LEVEL_LABELS[rowLevel(r, state.method, state.mode)] || ''; return o; });
			}
			var blob = new Blob([toCsv(cols, all)], { type: 'text/csv;charset=utf-8' });
			var a = h('a', { href: URL.createObjectURL(blob), download: state.tab + '.csv' });
			document.body.appendChild(a); a.click(); a.remove();
			state.notice = 'יוצאו ' + all.length + ' שורות.'; render();
		}).catch(function (e) { state.notice = 'הייצוא נכשל: ' + e.message; render(); });
	}

	function titleCell(row, t) {
		var title = row[t.columns[0].key];
		var url = t.wiki ? wikiUrl(title) : mechUrl(title);
		return h('a', { href: url, target: '_blank', rel: 'noopener', text: title });
	}

	function actionsCell(row, t) {
		var box = h('span', { 'class': 'mchl2-actions' });
		(t.actions || []).forEach(function (a) {
			if (a === 'import') box.appendChild(h('a', { 'class': 'mchl2-btn', href: mechUrl(row.title, 'edit'), target: '_blank', rel: 'noopener', text: 'ייבוא' }));
			if (!state.admin) return;
			var wikiId = row[t.idKey || 'id'];
			if (a === 'manual') box.appendChild(h('button', { 'class': 'mchl2-btn', text: 'שיוך ידני', onclick: function () { manualLink(row, wikiId); } }));
			if (a === 'exclude') box.appendChild(h('button', { 'class': 'mchl2-btn', text: 'החרגה', onclick: function () { exclude(row, wikiId); } }));
		});
		if (t.details) box.appendChild(h('button', { 'class': 'mchl2-btn', text: state.expanded[row.id] ? 'סגור' : 'פירוט', onclick: function () { toggleDetails(row); } }));
		return box;
	}

	function manualLink(row, wikiId) {
		var q = window.prompt('חיפוש ערך במכלול (תחילת הכותרת) לשיוך אל "' + (row.title || row.wiki_title) + '":');
		if (!q) return;
		client.select('mechalol_pages', { params: [['title', 'ilike.' + escapeIlike(q) + '*']], order: 'title.asc', to: 9, count: false }).then(function (res) {
			if (!res.data.length) { window.alert('לא נמצאו ערכים.'); return; }
			var pick = window.prompt(res.data.map(function (r, i) { return (i + 1) + '. ' + r.title; }).join('\n') + '\n\nמספר לשיוך:');
			var chosen = res.data[parseInt(pick, 10) - 1];
			if (!chosen) return;
			return client.rpc('set_manual_link', { p_mech_id: chosen.id, p_wiki_id: wikiId, p_reason: null }).then(function () {
				state.notice = 'שויך ל-"' + chosen.title + '" (יתעדכן ברענון הבא).'; load();
			});
		}).catch(function (e) { window.alert('השיוך נכשל: ' + e.message); });
	}

	function exclude(row, wikiId) {
		if (!window.confirm('להחריג את "' + row.title + '" מהרשימה?')) return;
		client.rpc('add_exclusion', { p_kind: 'import_excluded', p_wiki_id: wikiId, p_title: row.title, p_reason: null })
			.then(function () { state.notice = 'הוחרג.'; load(); }).catch(function (e) { window.alert('ההחרגה נכשלה: ' + e.message); });
	}

	function toggleDetails(row) {
		state.expanded[row.id] = !state.expanded[row.id];
		if (!state.expanded[row.id] || state.details[row.id]) return render();
		render();
		Promise.all([
			client.select('word_filter_results', { params: [['wikipedia_id', 'eq.' + row.id]], count: false, to: 0 }),
			state.admin ? client.select('word_filter_feedback', { params: [['wikipedia_id', 'eq.' + row.id]], count: false, to: 999, authed: true }) : Promise.resolve({ data: [] })
		]).then(function (res) {
			state.details[row.id] = res[0].data[0] || { matches: [] };
			state.marks[row.id] = {};
			res[1].data.forEach(function (m) { state.marks[row.id][m.match_key] = m.label; });
			render();
		}).catch(function (e) { state.details[row.id] = { error: e.message, matches: [] }; render(); });
	}

	function matchKey(m) { return m.line + ':' + m.x + ':' + (m.e || []).slice().sort().join(','); }

	function mark(row, m, label) {
		var key = matchKey(m), marks = state.marks[row.id], unmark = marks[key] === label;
		var d = state.details[row.id];
		var level = m[state.mode];
		var body = unmark ? { p_wiki_id: row.id, p_match_key: key }
			: { p_wiki_id: row.id, p_match_key: key, p_word: m.x, p_entries: m.e || [], p_label: label, p_topic: m.t || null, p_hidden: m.h || null, p_level: level || null, p_lists_version: d.lists_version || null };
		client.rpc(unmark ? 'unmark_feedback' : 'mark_feedback', body).then(function () {
			if (unmark) delete marks[key]; else marks[key] = label;
			render();
		}).catch(function (e) { window.alert('הסימון נכשל: ' + e.message); });
	}

	function detailsRow(row, colspan) {
		var d = state.details[row.id];
		var td = h('td', { colspan: colspan, 'class': 'mchl2-details' });
		if (!d) { td.appendChild(h('span', { text: 'טוען…' })); return h('tr', {}, [td]); }
		if (d.error) { td.appendChild(h('span', { 'class': 'mchl2-error', text: 'שגיאה: ' + d.error })); return h('tr', {}, [td]); }
		var matches = (d.matches || []).filter(function (m) { return m[state.mode] != null; });
		if (!matches.length) td.appendChild(h('span', { text: 'אין התאמות (או שהערך טרם נסרק).' }));
		matches.slice(0, 60).forEach(function (m) {
			var key = matchKey(m), cur = (state.marks[row.id] || {})[key];
			var level = state.method === 'ctx' && m['c' + state.mode] ? m['c' + state.mode] : m[state.mode];
			var line = h('div', { 'class': 'mchl2-match' }, [
				h('b', { text: m.x }), ' ', h('span', { 'class': 'mchl2-level mchl2-' + level, text: LEVEL_LABELS[level] || level }), ' ',
				h('span', { 'class': 'mchl2-muted', text: (m.b || '') + ' ' }), h('mark', { text: m.x }), h('span', { 'class': 'mchl2-muted', text: ' ' + (m.f || '') })
			]);
			if (state.admin) {
				line.appendChild(h('button', { 'class': 'mchl2-btn' + (cur === 'false' ? ' mchl2-on' : ''), title: 'התראת שווא', text: '✗', onclick: function () { mark(row, m, 'false'); } }));
				line.appendChild(h('button', { 'class': 'mchl2-btn' + (cur === 'true' ? ' mchl2-on' : ''), title: 'בעייתי באמת', text: '✓', onclick: function () { mark(row, m, 'true'); } }));
			}
			td.appendChild(line);
		});
		return h('tr', {}, [td]);
	}

	function table() {
		var t = tab();
		var head = h('tr', {}, t.columns.map(function (c) { return h('th', { text: c.label }); }).concat([h('th', { text: '' })]));
		var body = h('tbody');
		state.rows.forEach(function (row) {
			var key = t.rowKey ? t.rowKey(row) : row.id;
			var cells = t.columns.map(function (c, i) {
				if (i === 0 && (t.wiki || t.mech || c.key === 'title')) return h('td', {}, [titleCell(row, t)]);
				return h('td', { text: cellText(c, row) });
			});
			body.appendChild(h('tr', { 'data-key': key }, cells.concat([h('td', {}, [actionsCell(row, t)])])));
			if (t.details && state.expanded[row.id]) body.appendChild(detailsRow(row, t.columns.length + 1));
		});
		return h('table', { 'class': 'mchl2-table' }, [h('thead', {}, [head]), body]);
	}

	function pager() {
		var pages = state.count === null ? null : Math.max(1, Math.ceil(state.count / CONFIG.pageSize));
		return h('div', { 'class': 'mchl2-pager' }, [
			h('button', { 'class': 'mchl2-btn', text: 'הקודם', disabled: state.page === 0 ? 'disabled' : null, onclick: function () { state.page--; load(); } }),
			h('span', { text: ' עמוד ' + (state.page + 1) + (pages ? ' מתוך ' + pages : '') + (state.count !== null ? ' | ' + state.count.toLocaleString('he-IL') + ' שורות' : '') + ' ' }),
			h('button', { 'class': 'mchl2-btn', text: 'הבא', disabled: (pages !== null ? state.page + 1 >= pages : state.rows.length < CONFIG.pageSize) ? 'disabled' : null, onclick: function () { state.page++; load(); } })
		]);
	}

	var REQ_STATUS = { open: 'ממתינה', replied: 'יש תגובה', done: 'בוצע' };
	var MECH_STATE = { exists: 'קיים במכלול', redirect: 'הפניה במכלול', missing: 'לא קיים' };

	function requestsView() {
		var rows = state.req.rows;
		if (!rows) return h('div', { 'class': 'mchl2-muted', text: 'טוען בקשות…' });
		var count = function (f) { return rows.filter(function (r) { return r.req.status === f; }).length; };
		var filters = h('div', { 'class': 'mchl2-controls' }, [['open', 'ממתינות'], ['replied', 'יש תגובה'], ['done', 'בוצעו'], ['all', 'הכול']].map(function (o) {
			var n = o[0] === 'all' ? rows.length : count(o[0]);
			return h('button', { 'class': 'mchl2-btn' + (state.req.filter === o[0] ? ' mchl2-on' : ''), text: o[1] + ' (' + n + ')', onclick: function () { state.req.filter = o[0]; render(); } });
		}));
		var visible = rows.filter(function (r) { return state.req.filter === 'all' || r.req.status === state.req.filter; });
		var head = h('tr', {}, ['כותרת', 'מבקש', 'תאריך', 'סטטוס', 'במכלול', 'רמה', 'נושא'].map(function (x) { return h('th', { text: x }); }));
		var body = h('tbody', {}, visible.map(function (r) {
			var q = r.req, d = r.db;
			var title = q.wiki ? h('a', { href: wikiUrl(q.wiki.title), target: '_blank', rel: 'noopener', text: q.title }) : h('span', { text: q.title + ' (אין בוויקיפדיה)' });
			return h('tr', {}, [h('td', {}, [title, ' ', h('a', { 'class': 'mchl2-muted', href: mechUrl(q.title, 'edit'), target: '_blank', rel: 'noopener', text: '[ייבוא]' })]),
				h('td', { text: q.requester }), h('td', { text: q.date ? q.date.toLocaleDateString('he-IL') : '' }),
				h('td', { text: REQ_STATUS[q.status] + (q.doneBy === 'exists' ? ' (קיים)' : '') }), h('td', { text: MECH_STATE[q.mech] || '' }),
				h('td', { text: d ? (LEVEL_LABELS[rowLevel(d, state.method, state.mode)] || '') : (q.wiki ? 'לא בחסר' : '') }), h('td', { text: d && d.topic ? d.topic : '' })]);
		}));
		return h('div', {}, [filters, h('table', { 'class': 'mchl2-table' }, [h('thead', {}, [head]), body])]);
	}

	function cultureView() {
		var c = state.culture;
		if (!c.selected) {
			if (!c.subcats) return h('div', { 'class': 'mchl2-muted', text: 'טוען…' });
			if (!c.subcats.length) return h('div', { 'class': 'mchl2-muted', text: 'לא נמצאו תתי-קטגוריות (ייתכן ששם קטגוריית האם השתנה).' });
			return h('div', { 'class': 'mchl2-controls' }, c.subcats.map(function (sc) {
				return h('button', { 'class': 'mchl2-btn', text: sc.title.replace(CULTURE_CATEGORY + '/', '') + ' (' + sc.count.toLocaleString('he-IL') + ')', onclick: function () { loadCulture(sc.title); } });
			}));
		}
		var rows = c.members.map(function (m) { return h('tr', {}, [h('td', {}, [h('a', { href: mechUrl(m.title), target: '_blank', rel: 'noopener', text: m.title })])]); });
		return h('div', {}, [
			h('button', { 'class': 'mchl2-btn', text: '‹ חזרה לתתי-הקטגוריות', onclick: function () { c.selected = null; render(); } }),
			h('div', { 'class': 'mchl2-muted', text: c.selected.replace(CULTURE_CATEGORY + '/', '') }),
			h('table', { 'class': 'mchl2-table' }, [h('tbody', {}, rows)]),
			c.cont ? h('button', { 'class': 'mchl2-btn', text: c.loading ? 'טוען…' : 'טען עוד', disabled: c.loading ? 'disabled' : null, onclick: function () { loadCulture(c.selected); } }) : null
		]);
	}

	function specialView() {
		var t = tab();
		if (t.special === 'requests') return requestsView();
		if (t.special === 'culture') return cultureView();
		if (t.special === 'stats') {
			return h('table', { 'class': 'mchl2-table' }, state.rows.map(function (r) {
				return h('tr', {}, [h('td', { text: STAT_LABELS[r.key] || r.key }), h('td', { text: Number(r.n).toLocaleString('he-IL') }), h('td', { 'class': 'mchl2-muted', text: String(r.updated_at || '').slice(0, 16).replace('T', ' ') })]);
			}));
		}
		var names = { sync: 'סנכרון', reconcile: 'reconcile', enrich: 'העשרה', scan: 'סינון', maintenance: 'תחזוקה', rebuild: 'טעינה' };
		var hl = { ok: 'תקין', stale: 'ישן', stuck: 'תקוע', never: 'טרם רץ' };
		return h('table', { 'class': 'mchl2-table' }, [h('tr', {}, ['סוג', 'מצב', 'סטטוס אחרון', 'הצלחה אחרונה', 'שגיאה'].map(function (x) { return h('th', { text: x }); }))].concat(state.rows.map(function (r) {
			return h('tr', {}, [h('td', { text: names[r.kind] || r.kind }), h('td', { 'class': r.health !== 'ok' ? 'mchl2-error' : '', text: hl[r.health] || r.health }),
				h('td', { text: r.status }), h('td', { text: String(r.last_success_at || '').slice(0, 16).replace('T', ' ') }), h('td', { 'class': 'mchl2-muted', text: String(r.error || '').slice(0, 80) })]);
		})));
	}

	function authBox() {
		if (client.isLoggedIn()) {
			return h('span', {}, [h('span', { 'class': 'mchl2-muted', text: (client.email() || '') + (state.admin ? ' (מנהל) ' : ' (לא מנהל) ') }),
				h('button', { 'class': 'mchl2-btn', text: 'התנתקות', onclick: function () { client.logout(); state.admin = false; render(); } })]);
		}
		return h('button', { 'class': 'mchl2-btn', text: 'התחברות מנהל', onclick: function () {
			var email = window.prompt('אימייל:'); if (!email) return;
			var password = window.prompt('סיסמה:'); if (!password) return;
			client.login(email, password).then(checkAdmin).catch(function (e) { window.alert(e.message); });
		} });
	}

	function checkAdmin() {
		return client.rpc('is_admin', {}).then(function (ok) { state.admin = ok === true; render(); }).catch(function () { state.admin = false; render(); });
	}

	function render() {
		var t = tab();
		var top = h('div', { 'class': 'mchl2-top' }, [
			h('b', { text: 'ניהול ייבוא' }), ' ',
			h('label', {}, ['שיטה: ', h('select', { 'class': 'mchl2-input', onchange: function (e) { state.method = e.target.value; render(); } },
				[['list', 'לפי רשימה'], ['ctx', 'לפי הקשר']].map(function (o) { return h('option', { value: o[0], text: o[1], selected: state.method === o[0] ? 'selected' : null }); }))]), ' ',
			h('label', {}, ['רשימות: ', h('select', { 'class': 'mchl2-input', onchange: function (e) { state.mode = e.target.value; render(); } },
				[['a', 'מאושרות'], ['s', 'כולל הצעות']].map(function (o) { return h('option', { value: o[0], text: o[1], selected: state.mode === o[0] ? 'selected' : null }); }))]), ' ',
			authBox()
		]);
		var groups = h('div', { 'class': 'mchl2-groups' }, TAB_GROUPS.map(function (g) {
			return h('div', {}, [h('span', { 'class': 'mchl2-muted', text: g.label + ': ' })].concat(g.tabs.map(function (k) {
				return h('button', { 'class': 'mchl2-tab' + (state.tab === k ? ' mchl2-on' : ''), text: TABS[k].label, onclick: function () { state.tab = k; state.page = 0; state.filters = {}; state.search = ''; state.rows = []; state.count = null; state.notice = ''; load(); } });
			})));
		}));
		var main = [];
		if (state.notice) main.push(h('div', { 'class': 'mchl2-notice', text: state.notice }));
		if (state.error) main.push(h('div', { 'class': 'mchl2-error', text: 'שגיאה: ' + state.error }));
		if (t.special) main.push(specialView());
		else { main.push(controls()); if (state.loading) main.push(h('div', { 'class': 'mchl2-muted', text: 'טוען…' })); main.push(table()); main.push(pager()); }
		while (root.firstChild) root.removeChild(root.firstChild);
		[top, groups].concat(main).forEach(function (n) { root.appendChild(n); });
	}

	return { start: function () { render(); return Promise.all([load(), client.isLoggedIn() ? checkAdmin() : null]); }, state: state };
}

var LEVEL_LABELS = { problem: 'בעיה ודאית', review: 'לבדיקה', high: 'חשד גבוה', medium: 'חשד בינוני', low: 'חשד נמוך', wording: 'דורש ניסוח', clean: 'נקי', names: 'שמות קודש', not_scanned: 'לא נסרק', stale: 'תוצאה ישנה' };

if (typeof module !== 'undefined') module.exports = { h: h, createApp: createApp, LEVEL_LABELS: LEVEL_LABELS };
