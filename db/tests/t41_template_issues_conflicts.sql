-- 0048: הטאב "בעיות תבנית" - בלי נעולים ונמחקים לפי גרסה, ועם התנגשויות מחושבות מראש.
begin;
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"יעד"},{"page_id":2,"title":"אותו שם"},{"page_id":3,"title":"פירוש"},
                                        {"page_id":4,"title":"נוצר רגיל"}]');
    perform api.sync_apply_mech_pages('[
      {"page_id":10,"title":"אותו שם","status":"imported_documented"},
      {"page_id":11,"title":"פירוש","status":"created_in_mech","source_type":"pirushon"},
      {"page_id":12,"title":"נוצר רגיל","status":"created_in_mech","source_type":"created"},
      {"page_id":20,"title":"שם לא קיים","status":"imported_documented"},
      {"page_id":21,"title":"נעול","status":"imported_documented"},
      {"page_id":22,"title":"נמחק","status":"imported_documented"},
      {"page_id":23,"title":"שויך","status":"imported_documented"}]');
    insert into derived.template_link (mech_id, wiki_id, template_ref) values (10, 1, 'יעד');
    -- דרך הפונקציה של הסנכרון: denied נרשם גם כנעילה (0022)
    perform api.sync_apply_template_checks('[
      {"mech_id":20,"outcome":"unresolved","template_ref":"לא קיים","template_rev":0},
      {"mech_id":21,"outcome":"denied"},
      {"mech_id":22,"outcome":"unresolved","template_ref":"נמחק","template_rev":500},
      {"mech_id":23,"outcome":"unresolved","template_ref":"שויך","template_rev":0}]');
    insert into derived.rev_check (mech_id, rev_task, rev_id) values (22, 'deleted_by_rev', 500);
    insert into work.manual_link (mech_id, wiki_id, reason) values (23, 4, 'בדיקה');
    -- לפני הרענון: רק unresolved שאינו נמחק ואינו משויך; לא denied
    if (select array_agg(id order by id) from api.v_template_issues) is distinct from array[20]::bigint[] then
        raise exception 'before refresh: %', (select array_agg(id order by id) from api.v_template_issues); end if;
    if (select ops.refresh_match_conflicts()) <> 2 then raise exception 'conflict count'; end if;
    perform api.maintenance_refresh_counts();   -- הרענון השגרתי כולל את ההתנגשויות
end $$;
set local role anon;
do $$ begin
    if (select array_agg(id || ':' || outcome order by id) from api.v_template_issues)
       is distinct from array['10:template_vs_title', '11:disambig_same_title', '20:unresolved'] then
        raise exception 'rows: %', (select array_agg(id || ':' || outcome order by id) from api.v_template_issues); end if;
    if (select wikipedia_id from api.v_template_issues where id = 10) <> 2 then raise exception 'same-title wiki page'; end if;
    if (select template_ref from api.v_template_issues where id = 10) <> 'יעד' then raise exception 'template ref'; end if;
    if (select wikipedia_title from api.v_template_issues where id = 11) <> 'פירוש' then raise exception 'disambig wiki title'; end if;
    if (select template_ref from api.v_template_issues where id = 20) <> 'לא קיים' then raise exception 'unresolved ref'; end if;
    if exists (select 1 from api.v_template_issues where id = 12) then raise exception 'ordinary created page is not a conflict'; end if;
end $$;
reset role;
-- הנעול נשאר בטאב הנעולים; שיוך ידני מוציא גם התנגשות
do $$ begin
    if not exists (select 1 from api.report_locked_pages where mechalol_id = 21) then raise exception 'locked tab'; end if;
    insert into work.manual_link (mech_id, wiki_id, reason) values (11, 3, 'בדיקה');
    perform ops.refresh_match_conflicts();
    if exists (select 1 from api.v_template_issues where id = 11) then raise exception 'manual link hides conflict'; end if;
end $$;
rollback;
select 'ok t41_template_issues_conflicts' as test;
