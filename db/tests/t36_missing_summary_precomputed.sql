-- 0043: הסיכום השמור זהה לחי; כל כתיבה לקלט מסמנת אותו כלא עדכני וה-view נופל לחי; הרענון מחזיר אותו לשמור.
begin;
do $$ begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"רגיל","latest_rev_id":11},{"page_id":2,"title":"מוחרג","latest_rev_id":12},
        {"page_id":5,"title":"נסרק","latest_rev_id":15},{"page_id":6,"title":"ישן","latest_rev_id":17}]');
    perform api.sync_apply_scan('[{"wikipedia_id":5,"rev_id":15,"lists_version":"v","verdict":"problem","ctx_verdict":"review","counts":{},"matches":[]},
        {"wikipedia_id":6,"rev_id":16,"lists_version":"v","verdict":"clean","ctx_verdict":"clean","counts":{},"matches":[]}]');
    perform ops.refresh_counts();
end $$;
create temp table expect as select * from ops.missing_summary_live;
grant select on expect to anon;
do $$ begin
    if (select built_gen <> gen from ops.missing_summary) then raise exception 'not fresh after refresh'; end if;
    if (select n from ops.dashboard_counts where key = 'missing') <> 4 then raise exception 'missing count %', (select n from ops.dashboard_counts where key = 'missing'); end if;
end $$;
set local role anon;
do $$ begin
    if exists (select * from api.report_missing_word_filter_summary except all select * from expect)
       or exists (select * from expect except all select * from api.report_missing_word_filter_summary) then raise exception 'stored <> live'; end if;
    if (select verdict from api.report_missing_word_filter_summary where scan_state = 'scanned') <> 'problem' then raise exception 'scanned verdict'; end if;
    if (select verdict from api.report_missing_word_filter_summary where scan_state = 'stale') is not null then raise exception 'stale verdict hidden'; end if;
end $$;
reset role;
-- החרגה (טריגר שורה לפני exclusion_refresh): הרענון שבטריגר רואה את הדור החדש - טרי ומעודכן מיד
insert into work.exclusion (kind, wiki_id, reason) values ('import_excluded', 2, 'x');
do $$ begin
    if (select built_gen <> gen from ops.missing_summary) then raise exception 'exclusion left it stale'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary) <> 3 then raise exception 'exclusion not counted'; end if;
end $$;
-- כתיבה בלי רענון: לא עדכני, וה-view מחזיר את החי (כולל השינוי)
do $$ begin perform api.sync_apply_scan('[{"wikipedia_id":1,"rev_id":11,"lists_version":"v","verdict":"clean","ctx_verdict":"clean","counts":{},"matches":[]}]'); end $$;
set local role anon;
do $$ begin
    if (select built_gen = gen from ops.missing_summary) then raise exception 'scan did not bump gen'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary where scan_state = 'not_scanned') is not null then raise exception 'stale cache served'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary) <> 3 then raise exception 'live total'; end if;
end $$;
reset role;
update enrich.wiki_enrichment set mech_redirect = true where false;   -- גם משפט שלא שינה שורות מקדם (שמרני)
update mirror.wiki_page set latest_rev_id = 18 where page_id = 5;
do $$ begin
    perform api.maintenance_refresh_counts();
    if (select built_gen <> gen from ops.missing_summary) then raise exception 'maintenance refresh'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary where scan_state = 'stale') <> 2 then raise exception 'rev bump not in cache'; end if;
    if not exists (select 1 from ops.schema_migration where version = '0043') then raise exception '0043 not recorded'; end if;
end $$;
-- anon: לא מרענן ולא כותב
set local role anon;
do $$ begin
    begin perform ops.refresh_missing_summary(); raise exception 'anon refreshed'; exception when insufficient_privilege then null; end;
    begin update ops.missing_summary set built_gen = gen; raise exception 'anon wrote'; exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select 'ok t36_missing_summary_precomputed';
