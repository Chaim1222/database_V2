-- זמן החלה של מנה על מסד בגודל ייצור (נוסף אחרי שהטעינה הראשונית נתקלה ב-statement timeout ב-sync_apply_mech_pages).
\timing on
insert into mirror.wiki_page (page_id, title, latest_rev_id)
select g, 'ערך ' || g || ' ויקי', 40000000 + g from generate_series(1, 406000) g;
analyze mirror.wiki_page;
\echo '--- apply_mech_pages: מנה ראשונה של 1000 (כל הכותרות קיימות בוויקיפדיה, המכלול ריק)'
select api.sync_apply_mech_pages((select jsonb_agg(jsonb_build_object('page_id', g, 'title', 'ערך ' || g || ' ויקי', 'status', 'imported_documented', 'source_type', 'wikipedia_documented')) from generate_series(1, 1000) g));
\echo '--- אותה מנה שוב (אמורה לשנות 0)'
select api.sync_apply_mech_pages((select jsonb_agg(jsonb_build_object('page_id', g, 'title', 'ערך ' || g || ' ויקי', 'status', 'imported_documented', 'source_type', 'wikipedia_documented')) from generate_series(1, 1000) g));
\echo '--- מנה עם כללים סמנטיים (200 מתוך 1000)'
select api.sync_apply_mech_pages((select jsonb_agg(jsonb_build_object('page_id', g, 'title', 'ערך ' || g || ' ויקי', 'status', 'imported_documented', 'source_type', 'wikipedia_documented') || case when g % 5 = 0 then jsonb_build_object('wiki_candidate_key', 'ערך ' || (g + 1) || ' ויקי', 'rules', array['x']) else '{}' end) from generate_series(1001, 2000) g));
\echo '--- apply_wiki_pages: מנה של 1000 שינויי כותרת'
select api.sync_apply_wiki_pages((select jsonb_agg(jsonb_build_object('page_id', g, 'title', 'ערך ' || g || ' ויקי חדש', 'latest_rev_id', 50000000 + g)) from generate_series(1, 1000) g));
\echo '--- maintenance_refresh_gap: מנה של 20000 דפי ויקיפדיה (מכלול בגודל חלקי, מטרת המדידה: זמן מנה)'
select api.maintenance_refresh_gap(0, 20000);
