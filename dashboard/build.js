#!/usr/bin/env node
// בונה את הגאדג'ט לקובץ אחד: dist/gadget-dashboard.js (מודולים בסדר קבוע, בתוך IIFE). שימוש: node dashboard/build.js
'use strict';
const fs = require('fs');
const path = require('path');
const ORDER = ['config', 'filters', 'export', 'api-client', 'live', 'tabs', 'ui', 'style', 'main'];
const src = (n) => fs.readFileSync(path.join(__dirname, 'src', n + '.js'), 'utf8');
const body = ORDER.map((n) => `/* ===== ${n} ===== */\n${src(n)}`).join('\n');
const out = `/* נבנה אוטומטית מ-dashboard/src (node dashboard/build.js). אין לערוך ידנית. */\n(function () {\n'use strict';\n${body}\n})();\n`;
fs.mkdirSync(path.join(__dirname, 'dist'), { recursive: true });
fs.writeFileSync(path.join(__dirname, 'dist', 'gadget-dashboard.js'), out);
console.log('dist/gadget-dashboard.js', out.length, 'bytes');
// עמוד תצוגה מקדימה עצמאי (בלי הוויקי): mw מדומה ששם את הגאדג'ט בעמוד "ניהול_ייבוא". קורא נתונים חיים ממסד v2 (מפתח anon ציבורי).
const shim = `<!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>דשבורד המכלול (תצוגה מקדימה)</title></head><body><div id="mw-content-text"></div><script>
window.mw = { config: { get: function (k) { return { wgCanonicalSpecialPageName: 'Blankpage', wgPageName: 'מכלול/ניהול_ייבוא', wgScriptPath: 'https://www.hamichlol.org.il/w', wgScript: 'https://www.hamichlol.org.il/w/index.php' }[k]; } } };
</script><script>
${out}
</script></body></html>`;
fs.writeFileSync(path.join(__dirname, 'dist', 'preview.html'), shim);
console.log('dist/preview.html', shim.length, 'bytes');
