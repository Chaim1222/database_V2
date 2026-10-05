-- 0014: שכבת תאימות לגאדג'ט הקיים. views בסכמת api בשמות ובעמודות של v1 (report_*, wikipedia_pages, mechalol_pages), כך שהגאדג'ט
-- קורא את v2 בהוספת הכותרת Accept-Profile: api בלבד, בלי לשכתב את הטאבים. הלוגיקה נשארת ב-views הקיימים של v2 (v_missing וכו').
-- מחוץ להיקף v2 (ריקים כאן): עדכון (N10), משימות הגרסה. העמודה counts/images אינה נחשפת (content_scan_detail סגורה ל-anon).

create or replace view api.wikipedia_pages with (security_invoker = true) as
select w.page_id as id, w.title from mirror.wiki_page w;

create or replace view api.mechalol_pages with (security_invoker = true) as
select m.page_id as id, m.title, ms.label_he as status, null::bigint as wikipedia_id, ''::text as match_type
from mirror.mech_page m join ref.mech_status ms on ms.code = m.status;

create or replace view api.report_missing_from_mechalol with (security_invoker = true) as
select g.wiki_id as id, w.title, e.desc_checked_at as checked_at, e.wikidata_desc,
       e.length as easy_import_length, s.has_images as easy_import_has_images,
       null::boolean as problematic_words_clean, e.wiki_created_at as created_at,
       coalesce(e.mech_redirect, false) as mechalol_redirect_exists,
       (e.length_checked_at is not null) as easy_import_checked, (e.created_checked_at is not null) as created_at_checked
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
left join enrich.content_scan s on s.wiki_id = g.wiki_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind = 'import_excluded' and (x.wiki_id = w.page_id or x.title = w.title));

create or replace view api.report_missing_word_filter with (security_invoker = true) as
select m.id, m.title, m.checked_at, m.wikidata_desc, m.easy_import_length, m.created_at, m.mechalol_redirect_exists,
       s.verdict_list_a as verdict, s.verdict_list_s as verdict_suggested, s.has_images, s.photo_count,
       null::jsonb as counts, s.matches_total, null::jsonb as images, s.scanned_at,
       s.verdict_ctx_a as ctx_verdict, s.suspicion_a as ctx_suspicion,
       s.verdict_ctx_s as ctx_verdict_suggested, s.suspicion_s as ctx_suspicion_suggested,
       s.hidden_count_a as hidden_count, s.hidden_count_s as hidden_count_suggested,
       s.dictionary, s.dictionary_why, s.topic,
       s.names_count_a as names_count, s.names_count_s as names_count_suggested
from api.report_missing_from_mechalol m
left join enrich.content_scan s on s.wiki_id = m.id;

create or replace view api.report_undocumented_import with (security_invoker = true) as
select u.id, u.title, u.source_type, u.wiki_id as wikipedia_id, ''::text as match_type from api.v_undocumented u;

create or replace view api.report_wikipedia_moves with (security_invoker = true) as
select v.id, v.title, v.old_title, v.wikipedia_title, v.moved_at as renamed_at, 'title'::text as via,
       ms.label_he as status
from api.v_moves v
join mirror.mech_page m on m.page_id = v.id
join ref.mech_status ms on ms.code = m.status;

create or replace view api.report_locked_pages with (security_invoker = true) as
select l.page_id as id, l.title,
       case when l.level = 'create' then 'נעול ליצירה' else 'נעול לקריאה' end as lock_level,
       l.detected_by as lock_source, null::bigint as wikipedia_id, l.page_id as mechalol_id, l.detected_at
from api.v_locks l;

create or replace view api.report_rav_prefix_normalization with (security_invoker = true) as
select r.wiki_id as wikipedia_id, r.wiki_title as wikipedia_title, mirror.title_key(r.wiki_title) as normalized_title,
       r.mech_id as mechalol_id, r.mech_title as mechalol_title, ms.label_he as mechalol_status,
       null::text as mechalol_source_type, ''::text as mechalol_match_type,
       count(*) over (partition by r.wiki_id) as candidate_count
from api.v_rav_review r
join ref.mech_status ms on ms.code = r.mech_status;

create or replace view api.report_rev_tasks with (security_invoker = true) as
select v.id, v.title, v.status_label as status, v.rev_task, v.rev_id as sort_template_rev, null::date as sort_template_date,
       null::bigint as wikipedia_id, v.linked_title, v.rev_page_id, v.rev_page_title, v.checked_at
from api.v_rev_tasks v;

-- עדכון (N10) מחוץ להיקף: view ריק באותן עמודות, כדי שהטאב לא ייכשל
create or replace view api.report_source_update with (security_invoker = true) as
select null::bigint as id, null::text as title, null::date as sort_template_date, null::text as update_bucket,
       null::bigint as sort_template_rev, null::bigint as wikipedia_id
where false;

-- זמן הסנכרון האחרון (הגאדג'ט מציג "עודכן לאחרונה")
grant select on ops.watermark to anon, authenticated;
create policy public_read on ops.watermark for select to anon, authenticated using (true);
create or replace view api.sync_watermarks with (security_invoker = true) as
select w.ts as last_synced_ts from ops.watermark w where w.stream = 'delta';

grant select on all tables in schema api to anon, authenticated;
