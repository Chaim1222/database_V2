// ייצוא CSV (עם BOM כדי שאקסל יקרא עברית). פונקציות טהורות.
function csvCell(value) {
	if (value === null || value === undefined) return '';
	var text = typeof value === 'object' ? JSON.stringify(value) : String(value);
	return /[",\n\r]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
}

function toCsv(columns, rows) {
	var lines = [columns.map(function (c) { return csvCell(c.label); }).join(',')];
	rows.forEach(function (row) {
		lines.push(columns.map(function (c) { return csvCell(row[c.key]); }).join(','));
	});
	return '﻿' + lines.join('\r\n') + '\r\n';
}

if (typeof module !== 'undefined') module.exports = { csvCell: csvCell, toCsv: toCsv };
