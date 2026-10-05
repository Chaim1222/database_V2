-- 0027: api.import_human_data בודקת ש-p_admin קיים ב-auth.users, אך ל-service_role אין select על הטבלה ב-Supabase
-- (HTTP 403, 42501). הפונקציה מוגבלת ל-service_role בלבד (revoke מכולם), ולכן security definer בטוחה: היא רצה כבעלים.
alter function api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb) security definer;
insert into ops.schema_migration (version) values ('0027') on conflict do nothing;
