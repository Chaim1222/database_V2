// אתחול: רק בעמוד הניהול (CONFIG.pagePattern), בתוך המכלול (mw זמין).
function boot() {
	if (typeof mw === 'undefined' || mw.config.get('wgCanonicalSpecialPageName') !== 'Blankpage') return;
	if (!CONFIG.pagePattern.test(mw.config.get('wgPageName') || '')) return;
	var style = document.createElement('style');
	style.textContent = STYLE;
	document.head.appendChild(style);
	var content = document.getElementById('mw-content-text') || document.body;
	while (content.firstChild) content.removeChild(content.firstChild);
	var root = document.createElement('div');
	root.className = 'mchl2';
	content.appendChild(root);
	var storage = null;
	try { storage = window.sessionStorage; } catch (e) { /* אחסון חסום: ההתחברות תחזיק עד סגירת הדף */ }
	var client = createClient({ fetch: window.fetch.bind(window), storage: storage || undefined, config: CONFIG });
	var apiUrl = mw.config.get('wgScriptPath') + '/api.php';
	var call = function (url, extra) {
		return function (params) {
			var q = new URLSearchParams(Object.assign({ format: 'json', formatversion: '2' }, extra || {}, params));
			return window.fetch(url + '?' + q.toString()).then(function (res) { if (!res.ok) throw new Error('HTTP ' + res.status); return res.json(); });
		};
	};
	createApp(root, client, { scriptUrl: mw.config.get('wgScript'), mwApi: call(apiUrl), wikiApi: call('https://he.wikipedia.org/w/api.php', { origin: '*' }) }).start();
}
if (typeof module === 'undefined') boot();
