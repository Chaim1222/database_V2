begin;
do $$
declare v uuid;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"א"},{"page_id":2,"title":"ב"}]');
    perform api.sync_apply_mech_pages('[{"page_id":5,"title":"ג","status":"created_in_mech","source_type":"created","is_dictionary":true}]');
    if (select count(*) from api.reconcile_pages('wikipedia', 0, 10)) <> 2 then raise exception 'wiki pages'; end if;
    if (select count(*) from api.reconcile_pages('wikipedia', 1, 10)) <> 1 then raise exception 'paging by id'; end if;
    if not (select is_dictionary from api.reconcile_pages('mechalol') where page_id = 5) then raise exception 'mech columns'; end if;
    v := api.reconcile_record('{"x":1}', '{"s":1}', '[{"site":"wikipedia","class":"only_db","page_id":2,"title":"ב","detail":{"a":1},"explained_by_window":true},{"site":"mechalol","class":"status","page_id":5}]');
    if (select count(*) from ops.reconcile_finding where run_id = v) <> 2 then raise exception 'findings'; end if;
    if not (select explained_by_window from ops.reconcile_finding where run_id = v and class = 'only_db') then raise exception 'flag'; end if;
end $$;
rollback;
select 'ok t15_reconcile_io' as test;
