begin;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2');
insert into work.admin (user_id) values ('00000000-0000-0000-0000-0000000000a1');
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"יעד"},{"page_id":2,"title":"אותו שם"},{"page_id":3,"title":"חסר"},{"page_id":4,"title":"נוצר"}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"אותו שם","status":"imported_documented"},{"page_id":11,"title":"נוצר","status":"created_in_mech"}]');
    insert into derived.template_link (mech_id, wiki_id) values (10, 1);
    -- סתירות
    if (select count(*) from api.match_conflicts() where kind = 'template_vs_title' and mech_id = 10 and wiki_id = 1 and other_wiki_id = 2) <> 1 then raise exception 'template_vs_title'; end if;
    if (select count(*) from api.match_conflicts() where kind = 'unrelated_same_title' and mech_id = 11) <> 1 then raise exception 'unrelated_same_title'; end if;
    -- פירוט הסינון רק לדפי חסר
    perform api.sync_apply_scan('[{"wikipedia_id":3,"rev_id":1,"lists_version":"v","verdict":"clean","matches":[{"w":"x"}]},{"wikipedia_id":4,"rev_id":1,"lists_version":"v","verdict":"clean","matches":[]}]');
end $$;
set local role anon;
do $$ begin
    if (select count(*) from api.word_filter_results) <> 1 then raise exception 'details only for missing pages'; end if;
    if (select matches from api.word_filter_results where wikipedia_id = 3) <> '[{"w":"x"}]' then raise exception 'details content'; end if;
end $$;
reset role;

-- משוב: סימון, קריאה (רק של המשתמש עצמו), וביטול
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ begin
    perform api.mark_feedback(3, 'k', 'w', array['e'], 'false');
    if (select count(*) from api.word_filter_feedback where wikipedia_id = 3) <> 1 then raise exception 'own feedback visible'; end if;
    perform api.unmark_feedback(3, 'k');
    if (select count(*) from api.word_filter_feedback) <> 0 then raise exception 'unmark'; end if;
end $$;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';
do $$ declare ok boolean := false; begin
    begin perform api.unmark_feedback(3, 'k'); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'non-admin unmark'; end if;
end $$;
reset role;

-- שמירה: דף שאינו חסר והעשרתו ישנה נמחקים; דף חסר נשאר
do $$
declare r jsonb;
begin
    insert into enrich.wiki_enrichment (wiki_id, desc_checked_at) values (2, now() - interval '100 days'), (3, now() - interval '100 days');
    update enrich.content_scan set scanned_at = now() - interval '100 days';
    r := api.maintenance_prune();
    if (r ->> 'enrichment')::int <> 1 or exists (select 1 from enrich.wiki_enrichment where wiki_id = 2) then raise exception 'prune enrichment %', r; end if;
    if not exists (select 1 from enrich.wiki_enrichment where wiki_id = 3) then raise exception 'missing page must keep enrichment'; end if;
    if (r ->> 'scan')::int <> 1 or exists (select 1 from enrich.content_scan where wiki_id = 4) or not exists (select 1 from enrich.content_scan where wiki_id = 3) then raise exception 'prune scan %', r; end if;
end $$;
rollback;
select 'ok t16_ops_and_conflicts' as test;
