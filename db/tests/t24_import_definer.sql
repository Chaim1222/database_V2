begin;
do $$
begin
    if not (select prosecdef from pg_proc where oid = 'api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb)'::regprocedure) then
        raise exception 'import_human_data must be security definer';
    end if;
    if has_function_privilege('anon', 'api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb)', 'execute')
       or has_function_privilege('authenticated', 'api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb)', 'execute') then
        raise exception 'import_human_data must stay service_role only';
    end if;
end $$;
rollback;
select 'ok t24_import_definer' as test;
