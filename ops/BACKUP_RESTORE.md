# גיבוי ובדיקת שחזור

גיבוי נחשב שימושי רק אחרי בדיקת שחזור (DESIGN.md 12.7). מה שחשוב לשחזר: **החלטות אדם והרשאות** (`work.*`, `auth.users`), כי שאר הנתונים נבנים מחדש מהמקורות (טעינה ראשונית ועוד).

## מה נשמר איפה
- בתוכנית החינמית של Supabase אין גיבויים אוטומטיים לשחזור עצמאי. לכן: גיבוי ידני של `work` ו-`auth.users` לפני כל שינוי גדול, ולפחות פעם בשבוע.
- הנתונים שנבנים מחדש: `mirror`, `derived`, `enrich` (שחזור: `load.yml`, אחריו `templates.yml` ו-`enrich.yml`, והסינון).

## גיבוי (מהמחשב, עם מחרוזת החיבור של הפרויקט, Settings, Database)
```
pg_dump "$DB_URL" --table=auth.users --data-only --no-owner -f auth_users_backup.sql
pg_dump "$DB_URL" --schema=work --data-only --no-owner -f work_backup.sql
# שני קבצים נפרדים: pg_dump עם --table ו---schema יחד מוציא רק את הטבלה (נמצא בחזרת ההדמיה)
```

## בדיקת שחזור (חובה לפני המעבר, ואחר כך אחת לרבעון)
1. מסד זמני מקומי: `createdb restore_test`.
2. להחיל את המיגרציות 0001 עד האחרונה (`db/run_tests.sh` עושה זאת על מסד זמני; או ידנית `psql -f db/migrations/…` לפי הסדר) ואת `db/tests/00_supabase_stub.sql` קודם.
3. לשחזר, בסדר הזה (מפתחות זרים): `psql restore_test -f auth_users_backup.sql -f work_backup.sql`.
4. לבדוק: `select count(*) from work.admin; select count(*) from work.manual_link; select count(*) from work.exclusion; select count(*) from work.scan_feedback;` מול הספירות בייצור.
5. לוודא שהרשאות עובדות: `select api.is_admin()` עם `request.jwt.claim.sub` של המנהל מחזיר true.
6. לרשום את תאריך הבדיקה ותוצאתה בראש הקובץ הזה.

סטטוס: **הנוהל נבדק בהדמיה מקומית** (`ops/restore_rehearsal.sh`: מסד עם נתוני דוגמה, גיבוי, שחזור למסד חדש, השוואת ספירות ו-`api.is_admin`; ההדמיה תפסה שגיאה בנוהל הראשון). **בדיקת שחזור מגיבוי הייצור האמיתי: טרם בוצעה.**

## גיבוי אוטומטי (backup.yml)
workflow שבועי ("גיבוי החלטות אדם") שומר כ-artifact (30 יום): `work_data.sql` (סכמת work, נתונים בלבד), `admins.csv` (מנהלים: מזהה, אימייל, תאריך) ו-`counts.txt` (ספירות לבדיקה).
**בלי סיסמאות:** `auth.users` לא נשמר. בשחזור מקימים את חשבונות המנהלים מחדש ב-Authentication ורושמים את המזהים החדשים ב-`work.admin` לפי `admins.csv`; שורות `work.manual_link.created_by` ו-`work.scan_feedback.user_id` של מנהל שהוקם מחדש צריכות מיפוי (UPDATE) למזהה החדש.
דורש secret `V2_DB_URL` (מחרוזת החיבור של סופרבייס, Session pooler). הדמיית השחזור (`ops/restore_rehearsal.sh`) עדיין מדמה גם את `auth.users`; בדיקת שחזור מ-artifact אמיתי: טרם בוצעה.
