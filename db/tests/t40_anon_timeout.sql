-- 0047: מגבלת הזמן של anon היא 5 שניות.
do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'anon' and 'statement_timeout=5s' = any (rolconfig)) then
        raise exception 'anon statement_timeout is not 5s: %', (select rolconfig from pg_roles where rolname = 'anon');
    end if;
end $$;
select 'ok t40_anon_timeout';
