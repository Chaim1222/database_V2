begin;
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"נעול ליצירה"},{"page_id":2,"title":"נעול לקריאה"},{"page_id":3,"title":"פתוח"}]');
    if (select count(*) from api.enrich_pending('locks')) <> 3 then raise exception 'pending'; end if;
    perform api.sync_apply_enrichment('locks', '[
        {"wiki_id":1,"title":"נעול ליצירה","allevel":"create"},
        {"wiki_id":2,"title":"נעול לקריאה","allevel":"read","pageid":777},
        {"wiki_id":3,"title":"פתוח","allevel":"none"}]');
    if (select count(*) from api.enrich_pending('locks')) <> 0 then raise exception 'all checked'; end if;
    if not exists (select 1 from work.exclusion where kind = 'locked_create' and title = 'נעול ליצירה') then raise exception 'create lock -> exclusion'; end if;
    if not exists (select 1 from work.page_lock where page_id = 777 and level = 'read' and detected_by = 'missing_check') then raise exception 'read lock -> page_lock'; end if;
    -- נעול ליצירה יצא מ"חסר", שאר הדפים נשארו
    if (select array_agg(id order by id) from api.v_missing) <> array[2::bigint, 3] then raise exception 'missing list %', (select array_agg(id) from api.v_missing); end if;
    -- הרצה חוזרת
    perform api.sync_apply_enrichment('locks', '[{"wiki_id":1,"title":"נעול ליצירה","allevel":"create"}]');
    if (select count(*) from work.exclusion where title = 'נעול ליצירה') <> 1 then raise exception 'replay duplicated exclusion'; end if;
    -- קבוצות אחרות לא נפגעו
    if (select count(*) from api.enrich_pending('desc')) <> 2 then raise exception 'other groups: excluded page must not be enriched'; end if;
end $$;
rollback;
select 'ok t20_locks_probe' as test;
