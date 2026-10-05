begin;
do $$
declare n int;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"חסר א"},{"page_id":2,"title":"חסר ב"},{"page_id":3,"title":"קיים"}]');
    perform api.sync_apply_mech_pages('[{"page_id":30,"title":"קיים","status":"created_in_mech"}]');
    -- רק דפים "חסרים" ממתינים
    if (select count(*) from api.enrich_pending('desc')) <> 2 then raise exception 'pending should cover the 2 missing pages'; end if;

    perform api.sync_apply_enrichment('desc', '[{"wiki_id":1,"wikidata_desc":"תיאור"},{"wiki_id":2,"wikidata_desc":""}]');
    if (select count(*) from api.enrich_pending('desc')) <> 0 then raise exception 'desc should be fresh for both'; end if;
    if (select wikidata_desc from enrich.wiki_enrichment where wiki_id = 2) <> '' then raise exception 'empty desc must be kept as checked'; end if;
    if (select count(*) from api.enrich_pending('length')) <> 2 then raise exception 'other groups untouched'; end if;

    -- קבוצות לא דורסות זו את זו
    perform api.sync_apply_enrichment('length', '[{"wiki_id":1,"length":4321}]');
    if (select wikidata_desc from enrich.wiki_enrichment where wiki_id = 1) <> 'תיאור' then raise exception 'length write overwrote desc'; end if;
    if (select length from enrich.wiki_enrichment where wiki_id = 1) <> 4321 then raise exception 'length not stored'; end if;

    -- התיישנות: desc אחרי 31 יום חוזר להמתין; created לא
    update enrich.wiki_enrichment set desc_checked_at = now() - interval '31 days', created_checked_at = now() - interval '400 days' where wiki_id = 1;
    perform api.sync_apply_enrichment('created', '[{"wiki_id":2,"created_at":null}]');
    if not exists (select 1 from api.enrich_pending('desc') where wiki_id = 1) then raise exception 'stale desc should be pending'; end if;
    if exists (select 1 from api.enrich_pending('created') where wiki_id = 2) then raise exception 'created null is a checked result'; end if;

    -- הדף יצא מ"חסר": מפסיק להתרענן
    perform api.sync_apply_mech_pages('[{"page_id":31,"title":"חסר א","status":"created_in_mech"}]');
    if exists (select 1 from api.enrich_pending('desc') where wiki_id = 1) then raise exception 'covered page must leave the queue'; end if;

    begin perform api.enrich_pending('bogus'); raise exception 'bad group accepted';
    exception when invalid_parameter_value then null; end;
end $$;
rollback;
select 'ok t12_enrichment' as test;
