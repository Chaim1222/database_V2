-- 0049: מגבלת זמן לתהליכי הרקע (service_role - רק ה-workflows מחזיקים את המפתח הזה) 60 שניות.
-- עד עכשיו חלה עליהם מגבלת authenticator, 8 שניות. 17.10: maintenance_refresh_gap ו-maintenance_refresh_counts חרגו ממנה.
-- הסיבה (גרפי סופבייס): מכונת Nano, 0.5GB זיכרון, ~500MB ב-swap כל הזמן - אותה שאילתה, כולה "מהזיכרון" לפי PostgreSQL,
-- לקחה 0.17 עד 7 שניות. בלי שדרוג (החלטת חיים) - מרווח לתהליכי הרקע.
-- הדשבורד (anon 5 שניות, authenticated 8) לא משתנה. PostgREST קורא את הגדרות התפקיד מחדש רק אחרי reload config.
alter role service_role set statement_timeout = '60s';
notify pgrst, 'reload config';

insert into ops.schema_migration (version) values ('0049');
