// עיצוב: משתני צבע (בהיר/כהה לפי העדפת המערכת), פריסה של סרגל צד + תוכן, כרטיסים, טבלה עם כותרת דביקה, תגיות מצב.
// כל הכללים תחת .mchl2 כדי לא להשפיע על שאר דף הוויקי.
var STYLE = [
	'.mchl2{--bg:#f4f6fa;--surface:#fff;--surface-2:#f8fafc;--line:#e3e8ef;--text:#1b2433;--muted:#6b778c;--primary:#2563eb;--primary-soft:#e8f0fe;--primary-text:#fff;--ok:#16a34a;--ok-soft:#dcfce7;--warn:#b45309;--warn-soft:#fef3c7;--bad:#b91c1c;--bad-soft:#fee2e2;--orange-soft:#ffedd5;--orange:#c2410c;--purple-soft:#ede9fe;--purple:#6d28d9;--shadow:0 1px 2px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.08)}',
	'@media (prefers-color-scheme:dark){.mchl2{--bg:#0f1420;--surface:#171e2e;--surface-2:#1c2538;--line:#2a3550;--text:#e6ebf5;--muted:#93a0b8;--primary:#6ea0ff;--primary-soft:#1d2d52;--primary-text:#0b1220;--ok:#4ade80;--ok-soft:#12361f;--warn:#fbbf24;--warn-soft:#3b2f0b;--bad:#f87171;--bad-soft:#3f1717;--orange-soft:#3b2412;--orange:#fb923c;--purple-soft:#2a2150;--purple:#c4b5fd;--shadow:none}}',
	'.mchl2,.mchl2 *{box-sizing:border-box}',
	'.mchl2{direction:rtl;font-family:system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;font-size:14px;line-height:1.5;color:var(--text);background:var(--bg);max-width:1400px;margin:0 auto;padding:16px;border-radius:14px}',
	'.mchl2 a{color:var(--primary);text-decoration:none}.mchl2 a:hover{text-decoration:underline}',
	/* סרגל עליון */
	'.mchl2-top{display:flex;flex-wrap:wrap;align-items:center;gap:12px 20px;background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:12px 16px;box-shadow:var(--shadow);margin-bottom:16px}',
	'.mchl2-brand{display:flex;align-items:center;gap:10px;font-size:18px;font-weight:700;margin-inline-end:auto}',
	'.mchl2-logo{display:inline-grid;place-items:center;width:34px;height:34px;border-radius:10px;background:var(--primary);color:var(--primary-text);font-size:18px}',
	'.mchl2-top label{display:flex;align-items:center;gap:6px;color:var(--muted);font-size:13px}',
	'.mchl2-user{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13px}',
	'.mchl2-chip{display:inline-block;padding:2px 10px;border-radius:999px;background:var(--primary-soft);color:var(--primary);font-size:12px;font-weight:600}',
	/* פריסה */
	'.mchl2-body{display:grid;grid-template-columns:230px minmax(0,1fr);gap:16px;align-items:start}',
	'.mchl2-nav{position:sticky;top:12px;background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:10px;box-shadow:var(--shadow)}',
	'.mchl2-nav-group{margin-bottom:10px}.mchl2-nav-group:last-child{margin-bottom:0}',
	'.mchl2-nav-title{padding:6px 10px;font-size:11px;font-weight:700;letter-spacing:.04em;color:var(--muted)}',
	'.mchl2-tab{display:block;width:100%;text-align:right;padding:7px 10px;margin:1px 0;border:0;border-radius:8px;background:transparent;color:var(--text);font:inherit;cursor:pointer}',
	'.mchl2-tab:hover{background:var(--surface-2)}',
	'.mchl2-tab.mchl2-on{background:var(--primary-soft);color:var(--primary);font-weight:600}',
	'.mchl2-main{min-width:0}',
	/* כרטיס וסרגל כלים */
	'.mchl2-card{background:var(--surface);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);overflow:hidden}',
	'.mchl2-cardhead{padding:14px 16px 4px}.mchl2-cardhead h2{margin:0;font-size:17px;font-weight:700}.mchl2-cardhead p{margin:2px 0 0;color:var(--muted);font-size:13px}',
	'.mchl2-controls{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:12px 16px}',
	'.mchl2-input{height:34px;padding:0 10px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--text);font:inherit}',
	'.mchl2-input:focus{outline:2px solid var(--primary);outline-offset:-1px}',
	'input.mchl2-input[type=search]{min-width:220px;flex:1 1 220px}',
	'.mchl2-btn{display:inline-flex;align-items:center;justify-content:center;gap:4px;height:32px;padding:0 12px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--text);font:inherit;font-size:13px;cursor:pointer;text-decoration:none}',
	'.mchl2-btn:hover:not([disabled]){background:var(--surface-2);border-color:var(--muted);text-decoration:none}',
	'.mchl2-btn[disabled]{opacity:.45;cursor:default}',
	'.mchl2-btn.mchl2-on{background:var(--primary);border-color:var(--primary);color:var(--primary-text)}',
	'.mchl2-spacer{margin-inline-start:auto}',
	/* טבלה */
	'.mchl2-tablewrap{overflow:auto;max-height:70vh;border-top:1px solid var(--line)}',
	'.mchl2-table{width:100%;border-collapse:separate;border-spacing:0}',
	'.mchl2-table th{position:sticky;top:0;z-index:1;background:var(--surface-2);color:var(--muted);font-size:12px;font-weight:600;text-align:right;padding:9px 14px;border-bottom:1px solid var(--line);white-space:nowrap}',
	'.mchl2-table td{padding:9px 14px;border-bottom:1px solid var(--line);text-align:right;vertical-align:middle}',
	'.mchl2-table tbody tr:hover td{background:var(--surface-2)}',
	'.mchl2-table tbody tr:last-child td{border-bottom:0}',
	'.mchl2-actions{display:flex;gap:6px;justify-content:flex-end;white-space:nowrap}',
	'.mchl2-details{background:var(--surface-2)!important;padding:14px 18px!important}',
	'.mchl2-match{margin:6px 0;display:flex;flex-wrap:wrap;gap:6px;align-items:center}',
	'.mchl2-match mark{background:var(--warn-soft);color:var(--warn);border-radius:4px;padding:0 3px}',
	/* תגיות */
	'.mchl2-level,.mchl2-pill{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap;background:var(--surface-2);color:var(--muted)}',
	'.mchl2-problem{background:var(--bad-soft);color:var(--bad)}.mchl2-high{background:var(--orange-soft);color:var(--orange)}',
	'.mchl2-review{background:var(--warn-soft);color:var(--warn)}.mchl2-medium{background:var(--warn-soft);color:var(--warn)}',
	'.mchl2-low{background:var(--primary-soft);color:var(--primary)}.mchl2-wording{background:var(--purple-soft);color:var(--purple)}',
	'.mchl2-clean,.mchl2-names{background:var(--ok-soft);color:var(--ok)}.mchl2-not_scanned,.mchl2-stale{background:var(--surface-2);color:var(--muted)}',
	'.mchl2-ok{background:var(--ok-soft);color:var(--ok)}.mchl2-bad{background:var(--bad-soft);color:var(--bad)}.mchl2-warn{background:var(--warn-soft);color:var(--warn)}',
	'.mchl2-check{color:var(--ok);font-weight:700}',
	/* מצבים */
	'.mchl2-muted{color:var(--muted)}.mchl2-error{color:var(--bad);background:var(--bad-soft);border-radius:8px;padding:8px 12px;margin:0 0 12px}',
	'.mchl2-notice{background:var(--primary-soft);color:var(--primary);border-radius:8px;padding:8px 12px;margin:0 0 12px}',
	'.mchl2-empty{padding:48px 16px;text-align:center;color:var(--muted)}.mchl2-empty b{display:block;font-size:16px;color:var(--text);margin-bottom:4px}',
	'.mchl2-skel{height:12px;border-radius:6px;background:linear-gradient(90deg,var(--line),var(--surface-2),var(--line));background-size:200% 100%;animation:mchl2-shimmer 1.2s linear infinite}',
	'@keyframes mchl2-shimmer{0%{background-position:200% 0}100%{background-position:-200% 0}}',
	'@media (prefers-reduced-motion:reduce){.mchl2-skel{animation:none}}',
	/* עימוד */
	'.mchl2-pager{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 16px;border-top:1px solid var(--line);color:var(--muted);font-size:13px}',
	/* כרטיסי סטטיסטיקה */
	'.mchl2-stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px}',
	'.mchl2-stat{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px;box-shadow:var(--shadow)}',
	'.mchl2-stat-label{color:var(--muted);font-size:13px}.mchl2-stat-n{font-size:28px;font-weight:700;line-height:1.2;margin:2px 0}',
	'.mchl2-spark{font-size:18px;letter-spacing:1px;color:var(--primary);direction:ltr;text-align:right;min-height:26px}',
	/* מובייל: הניווט הופך לשורת צ׳יפים נגללת */
	'@media (max-width:820px){.mchl2{padding:10px}.mchl2-body{grid-template-columns:1fr}.mchl2-nav{position:static;display:flex;overflow-x:auto;gap:14px;padding:8px}.mchl2-nav-group{display:flex;align-items:center;gap:4px;margin:0;flex:0 0 auto}.mchl2-nav-title{padding:0 6px}.mchl2-tab{width:auto;white-space:nowrap;border:1px solid var(--line)}.mchl2-table th,.mchl2-table td{padding:8px 10px}}'
].join('\n');
