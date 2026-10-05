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
