begin;
do $$
declare r record;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"חסר"},{"page_id":2,"title":"קיים"},{"page_id":3,"title":"הרב אברהם"}]');
    perform api.sync_apply_mech_pages('[{"page_id":20,"title":"קיים","status":"imported_undocumented","source_type":"missing_sort"},{"page_id":30,"title":"אברהם","status":"created_in_mech"}]');
    insert into enrich.wiki_enrichment (wiki_id, wikidata_desc, wiki_created_at, length, mech_redirect, desc_checked_at) values (1, 'תיאור', now(), 1234, false, now());
    insert into enrich.content_scan (wiki_id, verdict_list_a, verdict_ctx_a, topic, has_images) values (1, 'clean', 'clean', 'geo', true);
    insert into work.page_lock (site, page_id, level, detected_by) values ('mechalol', 20, 'create', 'test');
end $$;
set local role anon;
do $$
declare r record; n int;
begin
    select * into r from api.report_missing_word_filter where id = 1;
    if r.title <> 'חסר' or r.verdict <> 'clean' or r.topic <> 'geo' or r.easy_import_length <> 1234 or r.mechalol_redirect_exists then
        raise exception 'report_missing_word_filter wrong: %', r;
    end if;
    if (select count(*) from api.report_missing_from_mechalol) <> 1 then raise exception 'missing count'; end if;
    if (select count(*) from api.report_undocumented_import where id = 20) <> 1 then raise exception 'undocumented'; end if;
    if (select lock_level from api.report_locked_pages where id = 20) <> 'נעול ליצירה' then raise exception 'locked'; end if;
    if (select count(*) from api.report_rav_prefix_normalization where wikipedia_id = 3 and candidate_count = 1) <> 1 then raise exception 'rav'; end if;
    perform count(*) from api.sync_watermarks; perform count(*) from api.wikipedia_pages; perform count(*) from api.mechalol_pages;
    perform count(*) from api.report_wikipedia_moves; perform count(*) from api.report_rev_tasks; perform count(*) from api.report_source_update;
end $$;
reset role;
rollback;
select 'ok t11_compat_views' as test;
