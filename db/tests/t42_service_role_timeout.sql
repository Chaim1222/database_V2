-- 0049: תהליכי הרקע (service_role) - 60 שניות; הדשבורד לא משתנה.
do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'service_role' and 'statement_timeout=60s' = any (rolconfig)) then
        raise exception 'service_role statement_timeout is not 60s: %', (select rolconfig from pg_roles where rolname = 'service_role'); end if;
    if not exists (select 1 from pg_roles where rolname = 'anon' and 'statement_timeout=5s' = any (rolconfig)) then
        raise exception 'anon changed'; end if;
end $$;
select 'ok t42_service_role_timeout' as test;
