begin;
insert into mirror.wiki_page (page_id, title) values (1, 'חסר רגיל'), (2, 'חסר מוחרג'), (3, 'מקושר'), (4, 'הרב ישראל חיים וייס'), (5, 'בית האזרח (רמת גן)');
insert into mirror.mech_page (page_id, title, status, source_type) values
    (20, 'מקושר', 'imported_documented', 'wikipedia_documented'),
    (21, 'בלי תבנית', 'imported_undocumented', 'missing_sort'),
    (22, 'בלי תבנית ושויך', 'imported_undocumented', 'unknown'),
    (23, 'מילוני', 'imported_undocumented', 'unknown'),
    (24, 'ישראל חיים וייס', 'imported_documented', 'wikipedia_documented'),
    (25, 'הועבר', 'imported_documented', 'wikipedia_documented');
update mirror.mech_page set is_dictionary = true where page_id = 23;
insert into enrich.wiki_enrichment (wiki_id, wikidata_desc, wiki_created_at, length, mech_redirect)
    values (1, 'תיאור', '2020-01-01', 5000, null);
insert into enrich.content_scan (wiki_id, verdict_list_a, topic, has_images) values (1, 'clean', 'geo', true);
insert into work.exclusion (kind, wiki_id, reason) values ('import_excluded', 2, 'בכוונה');
insert into work.manual_link (mech_id, wiki_id) values (22, 3);
insert into work.page_lock (site, page_id, level, detected_by) values ('mechalol', 21, 'read', 'access_denied');
insert into work.exclusion (kind, title, reason) values ('locked_create', 'נעול ליצירה', 'x');
insert into mirror.page_event (site, kind, page_id, title, new_title, ts)
    values ('wikipedia', 'move', 0, 'הועבר', 'הועבר (ויקיפדיה)', '2026-10-05 11:00:00+00');
insert into derived.rev_check (mech_id, rev_task, linked_wiki_id) values (20, 'bad_rev', 3), (22, 'redirect', null);
insert into ops.sync_run (kind, status, started_at) values ('sync', 'failed', '2026-10-05 08:00:00+00'), ('sync', 'succeeded', '2026-10-05 09:00:00+00');
select derived.refresh_wiki_gap();

do $$
begin
    -- v_missing: 1 (חסר, עם העשרה וסינון), 5; לא 2 (מוחרג), לא 3 (מקושר), לא 4 (רק הרב/רבי)
    if (select array_agg(id order by id) from api.v_missing) is distinct from array[1, 5]::bigint[] then
        raise exception 'v_missing wrong: %', (select array_agg(id order by id) from api.v_missing);
    end if;
    if (select verdict_list_a || '/' || topic || '/' || wikidata_desc from api.v_missing where id = 1) <> 'clean/geo/תיאור' then
        raise exception 'v_missing enrichment join wrong';
    end if;
    if (select mech_redirect from api.v_missing where id = 5) then raise exception 'mech_redirect should default to false'; end if;

    -- הרב/רבי לבדיקה
    if (select count(*) from api.v_rav_review) <> 1 then raise exception 'v_rav_review'; end if;

    -- ללא תבנית מיון: 21 בלבד (22 שויך ידנית, 23 מילוני)
    if (select array_agg(id) from api.v_undocumented) is distinct from array[21]::bigint[] then
        raise exception 'v_undocumented wrong: %', (select array_agg(id) from api.v_undocumented);
    end if;

    -- משימות גרסה: 20 בלבד (22 שויך ידנית)
    if (select array_agg(id) from api.v_rev_tasks) is distinct from array[20]::bigint[] then raise exception 'v_rev_tasks'; end if;
    if (select status_label from api.v_rev_tasks where id = 20) <> 'מיובא ומתועד' then raise exception 'status label join'; end if;

    -- הועברו בוויקיפדיה: "הועבר" אצלנו, ואין עוד דף בוויקיפדיה בכותרת הזו
    if (select array_agg(id) from api.v_moves) is distinct from array[25]::bigint[] then raise exception 'v_moves: %', (select array_agg(id) from api.v_moves); end if;

    -- נעילות: נעילת קריאה + כותרת נעולה ליצירה
    if (select count(*) from api.v_locks) <> 2 then raise exception 'v_locks'; end if;
    if (select title from api.v_locks where site = 'mechalol' and page_id = 21) <> 'בלי תבנית' then raise exception 'v_locks title'; end if;

    -- מצב סנכרון: הריצה האחרונה של כל סוג
    if (select status from api.v_sync_status where kind = 'sync') <> 'succeeded' then raise exception 'v_sync_status'; end if;
end $$;
rollback;
select 'ok t05_api_views' as test;
