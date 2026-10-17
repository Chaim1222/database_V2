-- 0049: מגבלת זמן לתהליכי הרקע (service_role - רק ה-workflows מחזיקים את המפתח הזה) 60 שניות.
-- עד עכשיו חלה עליהם מגבלת authenticator, 8 שניות. על מכונת Nano, אחרי כמה שעות בלי פעילות הטבלאות לא בזיכרון:
-- 17.10, "ניקיון וחישוב מחדש" ידני (21:44, כ-3.5 שעות אחרי הסנכרון) נכשל ב-maintenance_refresh_gap (מנה > 8 שניות).
-- נמדד אותו יום: התנגשויות ההתאמה (ב-maintenance_refresh_counts) - 6 שניות קר, 0.17 חם.
-- הדשבורד (anon 5 שניות, authenticated 8) לא משתנה. PostgREST קורא את הגדרות התפקיד מחדש רק אחרי reload config.
alter role service_role set statement_timeout = '60s';
notify pgrst, 'reload config';

insert into ops.schema_migration (version) values ('0049');
