begin;
do $$
declare r jsonb;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"אחד"}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"אחד","status":"imported_documented"},{"page_id":11,"title":"נעול","status":"imported_documented"},{"page_id":12,"title":"מילוני","status":"imported_documented","is_dictionary":true}]');
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"same","rev_id":1,"template_rev":123,"template_title":"אחד"},{"mech_id":11,"outcome":"denied"},{"mech_id":12,"outcome":"none"}]');
    -- נעילה נרשמה מהבדיקה; denied לא נכנס להיקף גרסאות; מילוני לא בהיקף
    if not exists (select 1 from work.page_lock where site = 'mechalol' and page_id = 11 and level = 'read' and detected_by = 'template_check') then raise exception 'lock not recorded'; end if;
    if (select array_agg(mech_id) from api.rev_scope(0, 100)) <> array[10::bigint] then raise exception 'scope %', (select array_agg(mech_id) from api.rev_scope(0, 100)); end if;
    if (select linked_wiki_id from api.rev_scope(0, 100)) <> 1 or (select template_rev from api.rev_scope(0, 100)) <> 123 then raise exception 'scope columns'; end if;

    -- ממצא ואחר כך תיקון: השורה נמחקת, והרצה חוזרת לא משנה
    r := api.sync_apply_rev_checks('[{"mech_id":10,"rev_task":"bad_rev","rev_id":123,"linked_wiki_id":1}]', array[10]::bigint[]);
    if (r ->> 'written')::int <> 1 or (select count(*) from api.v_rev_tasks) <> 1 then raise exception 'finding'; end if;
    perform api.sync_apply_rev_checks('[{"mech_id":10,"rev_task":"bad_rev","rev_id":123,"linked_wiki_id":1}]', array[10]::bigint[]);
    if (select count(*) from derived.rev_check) <> 1 then raise exception 'replay'; end if;
    r := api.sync_apply_rev_checks('[]', array[10]::bigint[]);
    if (r ->> 'removed')::int <> 1 or exists (select 1 from derived.rev_check) then raise exception 'fixed finding must be removed'; end if;
    -- מזהה מחוץ להיקף הבדיקה לא נמחק
    perform api.sync_apply_rev_checks('[{"mech_id":10,"rev_task":"redirect"}]', array[10]::bigint[]);
    perform api.sync_apply_rev_checks('[]', array[99]::bigint[]);
    if not exists (select 1 from derived.rev_check where mech_id = 10) then raise exception 'out-of-scope row deleted'; end if;

    -- הנעילה הוסרה כשהדף נקרא בהצלחה
    perform api.sync_apply_template_checks('[{"mech_id":11,"outcome":"none","rev_id":2}]');
    if exists (select 1 from work.page_lock where page_id = 11) then raise exception 'lock should be cleared'; end if;
    if (select count(*) from ops.schema_migration) < 22 then raise exception 'schema_migration'; end if;
end $$;
rollback;
select 'ok t19_rev_and_locks' as test;
