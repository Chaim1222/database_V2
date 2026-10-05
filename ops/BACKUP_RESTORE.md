# גיבוי ובדיקת שחזור

גיבוי נחשב שימושי רק אחרי בדיקת שחזור (DESIGN.md 12.7). מה שחשוב לשחזר: **החלטות אדם והרשאות** (`work.*`, `auth.users`), כי שאר הנתונים נבנים מחדש מהמקורות (טעינה ראשונית ועוד).

## מה נשמר איפה
- בתוכנית החינמית של Supabase אין גיבויים אוטומטיים לשחזור עצמאי. לכן: גיבוי ידני של `work` ו-`auth.users` לפני כל שינוי גדול, ולפחות פעם בשבוע.
- הנתונים שנבנים מחדש: `mirror`, `derived`, `enrich` (שחזור: `load.yml`, אחריו `templates.yml` ו-`enrich.yml`, והסינון).

## גיבוי (מהמחשב, עם מחרוזת החיבור של הפרויקט, Settings, Database)
```
pg_dump "$DB_URL" --schema=work --data-only --no-owner -f work_backup.sql
pg_dump "$DB_URL" --table=auth.users --data-only --no-owner -f auth_users_backup.sql
```

## בדיקת שחזור (חובה לפני המעבר, ואחר כך אחת לרבעון)
1. מסד זמני מקומי: `createdb restore_test`.
2. להחיל את המיגרציות 0001 עד האחרונה (`db/run_tests.sh` עושה זאת על מסד זמני; או ידנית `psql -f db/migrations/…` לפי הסדר) ואת `db/tests/00_supabase_stub.sql` קודם.
3. לשחזר: `psql restore_test -f auth_users_backup.sql -f work_backup.sql`.
4. לבדוק: `select count(*) from work.admin; select count(*) from work.manual_link; select count(*) from work.exclusion; select count(*) from work.scan_feedback;` מול הספירות בייצור.
5. לוודא שהרשאות עובדות: `select api.is_admin()` עם `request.jwt.claim.sub` של המנהל מחזיר true.
6. לרשום את תאריך הבדיקה ותוצאתה בראש הקובץ הזה.

סטטוס: **טרם בוצעה בדיקת שחזור**.
