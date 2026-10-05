begin;
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"חסר","latest_rev_id":5}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"ערך","status":"imported_documented"},{"page_id":11,"title":"ערך ב","status":"imported_documented"}]');
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"unresolved","template_ref":"לא קיים"},{"mech_id":11,"outcome":"same"}]');
end $$;
set local role anon;
do $$ begin
    if (select scan_state from api.v_missing where id = 1) <> 'not_scanned' then raise exception 'not_scanned'; end if;
    if (select count(*) from api.v_template_issues) <> 1 then raise exception 'template issues'; end if;
    if (select template_ref from api.v_template_issues where id = 10) <> 'לא קיים' then raise exception 'ref'; end if;
end $$;
reset role;
rollback;
select 'ok t18_dashboard_views' as test;
