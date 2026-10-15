-- 0047: מגבלת זמן לבקשה של משתמש לא מחובר (anon, הדשבורד) 3 -> 5 שניות (החלטת חיים, 15.10).
-- בטעינה ראשונה הדשבורד שולח כ-10 ספירות במקביל, ועל מכונת Nano שאילתה של 52ms נמדדה חורגת מ-3 שניות (500, ואז ניסיון חוזר מצליח).
-- המגבלה למחוברים (authenticated) ול-authenticator נשארת 8 שניות. PostgREST קורא את הגדרות התפקיד מחדש רק אחרי reload config.
alter role anon set statement_timeout = '5s';
notify pgrst, 'reload config';

insert into ops.schema_migration (version) values ('0047');
