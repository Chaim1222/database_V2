-- 0042: מהירות טאבי "חסר במכלול" בדשבורד (14.10). בלי שינוי בתוצאות.
-- נמצא: בטעינה ראשונה הדשבורד מקבל 500 (statement timeout של anon, 3 שניות) מ-report_missing_word_filter,
-- report_missing_word_filter_summary ו-report_missing_from_mechalol. נמדד בייצור (מטמון חם): report_missing_word_filter
-- 1.3-1.5 שניות, הסיכום עד 2.9; במטמון קר ועם כמה שאילתות במקביל - מעבר ל-3.
-- הסיבות: (1) ההחרגה נבדקה בתנאי OR (wiki_id או כותרת) - בדיקת אינדקס כפולה לכל אחד מ-28 אלף החסרים;
-- (2) report_missing_word_filter חיברה שוב את mirror.wiki_page (400 אלף שורות) רק בשביל latest_rev_id.
-- התיקון: ההחרגה כשני תנאי NOT EXISTS נפרדים (אותה משמעות: לא מוחרג לפי מזהה וגם לא לפי כותרת), ו-report_missing_word_filter
-- נבנית ישירות מהטבלאות עם חיבור יחיד ל-wiki_page. נמדד על אותם נתונים: 1,271ms -> 200ms, אותן 26,010 שורות.

create or replace view api.report_missing_from_mechalol with (security_invoker = true) as
select g.wiki_id as id, w.title, e.desc_checked_at as checked_at, e.wikidata_desc,
       e.length as easy_import_length, s.has_images as easy_import_has_images,
       null::boolean as problematic_words_clean, e.wiki_created_at as created_at,
       e.mech_redirect as mechalol_redirect_exists,
       (e.length_checked_at is not null) as easy_import_checked, (e.created_checked_at is not null) as created_at_checked
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
left join enrich.content_scan s on s.wiki_id = g.wiki_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.wiki_id = g.wiki_id)
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.title = w.title);

create or replace view api.report_missing_word_filter with (security_invoker = true) as
select g.wiki_id as id, w.title, e.desc_checked_at as checked_at, e.wikidata_desc, e.length as easy_import_length,
       e.wiki_created_at as created_at, e.mech_redirect as mechalol_redirect_exists,
       s.verdict_list_a as verdict, s.verdict_list_s as verdict_suggested, s.has_images, s.photo_count, d.counts,
       s.matches_total, null::jsonb as images, s.scanned_at, s.verdict_ctx_a as ctx_verdict, s.suspicion_a as ctx_suspicion,
       s.verdict_ctx_s as ctx_verdict_suggested, s.suspicion_s as ctx_suspicion_suggested, s.hidden_count_a as hidden_count,
       s.hidden_count_s as hidden_count_suggested, s.dictionary, s.dictionary_why, s.topic, s.names_count_a as names_count,
       s.names_count_s as names_count_suggested,
       case when s.wiki_id is null then 'not_scanned'
            when w.latest_rev_id is null or s.rev_id < w.latest_rev_id then 'stale'
            else 'scanned' end as scan_state
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
left join enrich.content_scan s on s.wiki_id = g.wiki_id
left join api.word_filter_results d on d.wikipedia_id = g.wiki_id   -- content_scan_detail סגורה ל-anon; counts דרך ה-view הקיים
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.wiki_id = g.wiki_id)
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.title = w.title);

create or replace view api.v_missing with (security_invoker = true) as
select w.page_id as id, w.title, e.wiki_created_at as created_at, e.wikidata_desc, e.length,
       coalesce(e.mech_redirect, false) as mech_redirect, s.has_images, s.photo_count,
       s.verdict_list_a, s.verdict_list_s, s.verdict_ctx_a, s.verdict_ctx_s, s.suspicion_a, s.suspicion_s,
       s.hidden_count_a, s.hidden_count_s, s.names_count_a, s.names_count_s, s.matches_total,
       s.dictionary, s.dictionary_why, s.topic, s.scanned_at,
       case when s.wiki_id is null then 'not_scanned'
            when w.latest_rev_id is null or s.rev_id < w.latest_rev_id then 'stale'
            else 'scanned' end as scan_state
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = w.page_id
left join enrich.content_scan s on s.wiki_id = w.page_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind = any (array['import_excluded', 'locked_create']) and x.wiki_id = w.page_id)
  and not exists (select 1 from work.exclusion x where x.kind = any (array['import_excluded', 'locked_create']) and x.title = w.title);

insert into ops.schema_migration (version) values ('0042');
