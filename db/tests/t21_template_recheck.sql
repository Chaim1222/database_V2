begin;
do $$
begin
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"א","status":"imported_documented"},{"page_id":11,"title":"ב","status":"imported_documented"},{"page_id":12,"title":"ג","status":"imported_documented"},{"page_id":13,"title":"ד","status":"imported_documented"}]');
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"unresolved","template_ref":"x"},{"mech_id":11,"outcome":"denied"},{"mech_id":12,"outcome":"same"}]');
    if (select array_agg(page_id order by page_id) from api.template_pending(0, 100)) <> array[13::bigint] then raise exception 'only unchecked pending now'; end if;
    update derived.template_check set checked_at = now() - interval '8 days';
    if (select array_agg(page_id order by page_id) from api.template_pending(0, 100)) <> array[10::bigint, 11, 13] then raise exception 'stale unresolved/denied must be rechecked, same must not: %', (select array_agg(page_id) from api.template_pending(0, 100)); end if;
end $$;
rollback;
select 'ok t21_template_recheck' as test;
