# database_v2: מערכת ההשוואה ויקיפדיה ↔ המכלול, מבוססת צרכים

כתיבה מחדש של המסד, הצינורות והדשבורד, אחרי הלמידה על המערכת הקודמת (`Chaim1222/database`).

- **תכנון:** [`DESIGN.md`](DESIGN.md) (צרכים, עקרונות, מודל נתונים, סנכרון והוכחה, חוזים פתוחים בסעיף 12) ו-[`PLAN_STAGE4.md`](PLAN_STAGE4.md).
- **מעבר מהמערכת הישנה:** [`CUTOVER.md`](CUTOVER.md): סדר ההחלות וההרצות, ומה עדיין לא קיים.
- **כללי עבודה:** [`CLAUDE.md`](CLAUDE.md).
- **פרויקט סופרבייס:** `ukzijtrpchvmoxlslxpz` (`ap-southeast-2`).

## מבנה

| תיקייה | תוכן |
|---|---|
| `db/migrations/` | מיגרציות קדימה בלבד, ממוספרות. `db/schema.sql` נוצר מהן (`db/gen_schema.sh`) |
| `db/tests/` | בדיקות SQL (הרצה חוזרת, אטומיות, הרשאות, views, שחזור) |
| `db/perf/` | מדידות קנה מידה (`run_scale.sh`, `SCALE_SCRIPT=apply_scale.sql`, `sizes.sql`) |
| `collector/` | Python: `sync`, `load` (דמפ), `rebuild`, `templates`, `enrich`, `revcheck`, `reconcile`, `health`, `maintenance`, `import_v1` |
| `dashboard/` | דשבורד חדש: `src/` (מודולים), `build.js`, `dist/gadget-dashboard.js` (הקובץ להעתקה לוויקי), `tests/` |
| `ops/` | נוהל גיבוי ושחזור והדמיה מקומית שלו |
| `.github/workflows/` | `sync`, `enrich`, `reconcile`, `revcheck`, `maintenance`, `health`, `load`, `rebuild`, `templates`, `import_v1`, `ci` |

המנוע של סינון התוכן (`word-filter/`) נשאר בריפו הישן; `scan-missing.js --backend v2` כותב משם למסד הזה.

## בדיקות

```
db/run_tests.sh                       # מיגרציות + בדיקות SQL על Postgres 16 מקומי (מסד זמני)
python3 -m unittest discover -s tests # הקולקטור
node --test dashboard/tests/unit.test.js
node dashboard/build.js && node dashboard/tests/browser.test.js   # דורש playwright + Chromium
```

בסביבת הענן: `pg_ctlcluster 16 main start` לפני בדיקות ה-SQL.

## מיגרציות בסופרבייס

הקבצים ב-`db/migrations/` הם המקור. מיגרציה עם `delete from` או `drop` בגוף פונקציה נתקעת ב-`apply_migration` של ה-MCP: מחילים בעורך ה-SQL של סופרבייס. אחרי כל החלה: בדיקת עשן, ו-`get_advisors`.

## תזמון

כל ה-workflows המתוזמנים פעילים רק כשמשתנה הריפו `ENABLE_SCHEDULE=true` (Settings, Secrets and variables, Variables). בלעדיו הם ידניים בלבד.
