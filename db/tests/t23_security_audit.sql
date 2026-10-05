begin;
do $$
declare r record;
begin
    -- כל טבלה בסכמות הפנימיות: RLS פעיל
    for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where c.relkind in ('r', 'p') and n.nspname in ('ref', 'mirror', 'derived', 'enrich', 'work', 'ops', 'api') and not c.relrowsecurity loop
        raise exception 'RLS disabled on %.%', r.nspname, r.relname;
    end loop;
    -- anon ו-authenticated לעולם לא כותבים ישירות לטבלה
    for r in select table_schema, table_name, privilege_type from information_schema.role_table_grants
             where grantee in ('anon', 'authenticated') and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
               and table_schema in ('ref', 'mirror', 'derived', 'enrich', 'work', 'ops', 'api')
               and not (grantee = 'authenticated' and privilege_type = 'DELETE' and table_schema = 'work' and table_name = 'manual_link') loop   -- חריג מכוון (מדיניות admin_delete)
        raise exception 'direct % grant to anon/authenticated on %.%', r.privilege_type, r.table_schema, r.table_name;
    end loop;
    if not exists (select 1 from pg_policies where schemaname = 'work' and tablename = 'manual_link' and cmd = 'DELETE' and qual like '%is_admin%') then
        raise exception 'manual_link delete must be admin-only';
    end if;
    -- פונקציות כתיבה/תחזוקה לא פתוחות ל-anon
    for r in select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'api' and (p.proname like 'sync\_%' or p.proname like 'maintenance\_%' or p.proname like 'reconcile\_%' or p.proname like 'enrich\_%' or p.proname like 'scan\_%' or p.proname like 'import\_%')
               and has_function_privilege('anon', p.oid, 'execute') loop
        raise exception 'api.% executable by anon', r.proname;
    end loop;
end $$;
rollback;
select 'ok t23_security_audit' as test;
