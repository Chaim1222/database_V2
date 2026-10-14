-- 0044: רשימת "חסר במכלול" וספירת "ללא תבנית מיון" מהירות (14.10). בלי שינוי בתוצאות.
-- (1) report_missing_word_filter חיברה את api.word_filter_results (counts) לכל השורות שעברו את הסינון, לפני המיון וה-LIMIT:
--     נמדד בייצור (מטמון חם) 1.4 שניות לדף של 50 מתוך 11,591 - מזה כ-1.1 שניות בחיבור. כתת-שאילתה ברשימת העמודות
--     המתכנן מחשב אותה אחרי ה-LIMIT, רק לשורות שמוחזרות (נמדד: 0.27 שניות). word_filter_results - שורה אחת לכל ערך.
-- (2) הספירה של report_undocumented_import עברה על כל 382 אלף דפי המכלול כדי למצוא כ-100 (2.6 שניות, קרוב ל-3 של anon).
--     אינדקס חלקי לסטטוס הזה.

create or replace view api.report_missing_word_filter with (security_invoker = true) as
select g.wiki_id as id, w.title, e.desc_checked_at as checked_at, e.wikidata_desc, e.length as easy_import_length,
       e.wiki_created_at as created_at, e.mech_redirect as mechalol_redirect_exists,
       s.verdict_list_a as verdict, s.verdict_list_s as verdict_suggested, s.has_images, s.photo_count,
       (select d.counts from api.word_filter_results d where d.wikipedia_id = g.wiki_id) as counts,   -- content_scan_detail סגורה ל-anon
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
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.wiki_id = g.wiki_id)
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.title = w.title);

create index mech_page_undocumented_idx on mirror.mech_page (page_id) where status = 'imported_undocumented';

insert into ops.schema_migration (version) values ('0044');
