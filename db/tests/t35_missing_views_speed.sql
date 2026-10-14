-- 0042: ההחרגה כשני NOT EXISTS (מזהה / כותרת) ו-report_missing_word_filter ישירות מהטבלאות - אותן שורות בשלושת ה-views.
begin;
do $$ begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"רגיל","latest_rev_id":11},{"page_id":2,"title":"מוחרג לפי מזהה","latest_rev_id":12},
        {"page_id":3,"title":"מוחרג לפי כותרת","latest_rev_id":13},{"page_id":4,"title":"נעול ליצירה","latest_rev_id":14},{"page_id":5,"title":"נסרק","latest_rev_id":15}]');
    insert into work.exclusion (kind, wiki_id, reason) values ('import_excluded', 2, 'x');
    insert into work.exclusion (kind, title, reason) values ('import_excluded', 'מוחרג לפי כותרת', 'x'), ('locked_create', 'נעול ליצירה', 'x');
    perform api.sync_apply_scan('[{"wikipedia_id":5,"rev_id":15,"lists_version":"v","verdict":"clean","ctx_verdict":"clean","counts":{"a":{"problem":0}},"matches":[]}]');
end $$;
set local role anon;
do $$ begin
    if array(select id from api.report_missing_word_filter order by id) <> array[1,5]::bigint[] then raise exception 'word_filter scope: %', array(select id from api.report_missing_word_filter order by id); end if;
    if array(select id from api.report_missing_from_mechalol order by id) <> array[1,5]::bigint[] then raise exception 'missing scope'; end if;
    if array(select id from api.v_missing order by id) <> array[1,5]::bigint[] then raise exception 'v_missing scope'; end if;
    if (select counts from api.report_missing_word_filter where id = 5) is distinct from '{"a":{"problem":0}}'::jsonb then raise exception 'anon counts'; end if;
    if (select scan_state from api.report_missing_word_filter where id = 5) <> 'scanned' or (select scan_state from api.report_missing_word_filter where id = 1) <> 'not_scanned' then raise exception 'scan_state'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary) <> 2 then raise exception 'summary'; end if;
end $$;
reset role;
do $$ begin
    if not exists (select 1 from ops.schema_migration where version = '0042') then raise exception '0042 not recorded'; end if;
end $$;
rollback;
select 'ok t35_missing_views_speed';
