// בניית פרמטרי PostgREST מתוך הגדרת טאב ומצב הסינון. פונקציות טהורות (נבדקות ב-tests/).
// הסינון לפי רמה תומך בשתי השיטות (רשימה/הקשר) ובשני המצבים (מאושרות a / הצעות s) של מנוע הסינון.

function levelParams(method, mode, value) {
	if (!value) return [];
	if (value === 'not_scanned' || value === 'stale') return [['scan_state', 'eq.' + value]];
	if (method === 'ctx') {
		if (value === 'high' || value === 'medium' || value === 'low') {
			return [['verdict_ctx_' + mode, 'eq.review'], ['suspicion_' + mode, 'eq.' + value]];
		}
		return [['verdict_ctx_' + mode, 'eq.' + value]];
	}
	return [['verdict_list_' + mode, 'eq.' + value]];
}

function escapeIlike(text) {
	return String(text).replace(/[%*,()]/g, ' ').trim();
}

function buildParams(tab, state) {
	var out = (tab.baseFilters || []).slice();
	var active = state.filters || {};
	(tab.filters || []).forEach(function (f) {
		var value = active[f.key];
		if (value === undefined || value === '') return;
		var pairs = f.toParams ? f.toParams(value, state) : [[f.key, 'eq.' + value]];
		pairs.forEach(function (p) { out.push(p); });
	});
	var search = escapeIlike(state.search || '');
	if (search && tab.searchColumn !== null) out.push([tab.searchColumn || 'title', 'ilike.*' + search + '*']);
	return out;
}

if (typeof module !== 'undefined') module.exports = { levelParams: levelParams, buildParams: buildParams, escapeIlike: escapeIlike };
