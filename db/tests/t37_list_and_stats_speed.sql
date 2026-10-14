-- 0044: counts כתת-שאילתה - אותן שורות ואותם counts כמו בחיבור; ו-anon רואה אותם. ספירת ללא תבנית מיון בלי שינוי.
begin;
do $$ begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"רגיל","latest_rev_id":11},{"page_id":5,"title":"נסרק","latest_rev_id":15},{"page_id":6,"title":"נסרק 2","latest_rev_id":16}]');
    perform api.sync_apply_scan('[{"wikipedia_id":5,"rev_id":15,"lists_version":"v","verdict":"problem","ctx_verdict":"problem","counts":{"a":{"problem":2}},"matches":[]},
        {"wikipedia_id":6,"rev_id":16,"lists_version":"v","verdict":"clean","ctx_verdict":"clean","counts":{"a":{"problem":0}},"matches":[]}]');
end $$;
create temp table expect as
select r.id, d.counts from api.report_missing_word_filter r left join api.word_filter_results d on d.wikipedia_id = r.id;
grant select on expect to anon;
set local role anon;
do $$ begin
    if (select count(*) from api.report_missing_word_filter) <> 3 then raise exception 'rows'; end if;
    if exists (select r.id, r.counts from api.report_missing_word_filter r except select * from expect)
       or exists (select * from expect except select r.id, r.counts from api.report_missing_word_filter r) then raise exception 'counts differ'; end if;
    if (select counts from api.report_missing_word_filter where id = 5) is distinct from '{"a":{"problem":2}}'::jsonb then raise exception 'anon counts'; end if;
    if (select counts from api.report_missing_word_filter where id = 1) is not null then raise exception 'unscanned counts'; end if;
    -- דף אחרי מיון ו-LIMIT: אותם counts
    if (select counts from api.report_missing_word_filter order by id desc limit 1) is distinct from '{"a":{"problem":0}}'::jsonb then raise exception 'limit counts'; end if;
end $$;
reset role;
do $$ begin
    if not exists (select 1 from pg_indexes where indexname = 'mech_page_undocumented_idx') then raise exception 'index'; end if;
    if not exists (select 1 from ops.schema_migration where version = '0044') then raise exception '0044 not recorded'; end if;
end $$;
rollback;
select 'ok t37_list_and_stats_speed';
