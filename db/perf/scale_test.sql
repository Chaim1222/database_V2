-- בדיקת קנה מידה (לא ב-CI הרגיל): נתונים סינתטיים בגודל הייצור (406 אלף / 382 אלף), מדידת גודל וזמני שאילתות.
-- הרצה: v2/db/perf/run_scale.sh. המספרים תלויים במכונה ואינם מייצגים את סופרבייס (איטי ומשתנה יותר).
\timing on
-- ויקיפדיה: 406 אלף דפים. כותרות בעברית באורך ממוצע ~25 בתים (כמו בייצור: 25.3 בייצור, נמדד 5.10)
insert into mirror.wiki_page (page_id, title, latest_rev_id)
select g, 'ערך ' || g || ' ויקי', 40000000 + g
from generate_series(1, 406000) g;
-- מכלול: 382 אלף, 99% מהם מקושרים לוויקיפדיה לפי אותה כותרת
insert into mirror.mech_page (page_id, title, status, source_type)
select g, 'ערך ' || g || ' ויקי',
       case when g % 100 = 0 then 'imported_undocumented' else 'imported_documented' end,
       case when g % 100 = 0 then 'missing_sort' else 'wikipedia_documented' end
from generate_series(1, 379000) g;
insert into mirror.mech_page (page_id, title, status, source_type)
select 400000 + g, 'ערך מכלול בלבד ' || g, 'created_in_mech', 'created' from generate_series(1, 3000) g;
-- חריגים בלבד נשמרים (קישור רגיל = אותה כותרת, בלי שורה): 3 אלף התאמות סמנטיות, 6 אלף תבניות שאומתו
insert into derived.mech_key (mech_id, wiki_candidate_key, rules)
select g, mirror.title_key('ערך ' || g || ' ויקי'), '{כתיב_אלוהים}' from generate_series(1, 3000) g;
insert into derived.template_link (mech_id, wiki_id) select g, g from generate_series(10001, 16000) g;
-- העשרה וסינון ל-27 אלף "חסרים" (הדפים 379001..406000)
insert into enrich.wiki_enrichment (wiki_id, wikidata_desc, wiki_created_at, length, mech_redirect, desc_checked_at)
select g, 'תיאור קצר מוויקינתונים ' || g, now() - (g || ' hours')::interval, 3000 + g % 5000, false, now()
from generate_series(379001, 406000) g;
insert into enrich.content_scan (wiki_id, rev_id, verdict_list_a, verdict_ctx_a, topic, has_images, photo_count, matches_total)
select g, 40000000 + g, 'clean', 'clean', 'geo', g % 3 = 0, g % 4, 0 from generate_series(379001, 406000) g;
insert into enrich.content_scan_detail (wiki_id, counts, matches, images)
select g, jsonb_build_object('a', 1, 's', 2), '[]'::jsonb, '[]'::jsonb from generate_series(379001, 406000) g;
analyze;

\echo '--- refresh_wiki_gap (מלא; צפוי 27,000 שורות חדשות)'
select derived.refresh_wiki_gap();
\echo '--- refresh_wiki_gap (שוב: אמור לשנות 0)'
select derived.refresh_wiki_gap();
\echo '--- refresh_wiki_gap (ממוקד ל-1000 דפים)'
select derived.refresh_wiki_gap((select array_agg(g) from generate_series(379001, 380000) g)::bigint[]);
select ops.refresh_counts();
analyze;

\echo '--- api.v_missing: עמוד של 100 (הישנים קודם)'
explain (analyze, buffers, costs off, timing off, summary on)
select * from api.v_missing order by created_at asc nulls last, id asc limit 100;
\echo '--- ספירת "חסר" מהטבלה המחושבת'
select n from api.v_counts where key = 'missing' \gset
\echo :n

\echo '--- אורך כותרת ממוצע בבתים (יעד כ-25)'
select round(avg(octet_length(title)), 1) from mirror.wiki_page;

\echo '--- גדלים'
select n.nspname || '.' || c.relname as rel, c.relkind, pg_size_pretty(pg_total_relation_size(c.oid)) as total
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('mirror', 'derived', 'enrich', 'work', 'ops') and c.relkind = 'r'
  and pg_total_relation_size(c.oid) > 1000000
order by pg_total_relation_size(c.oid) desc;
select pg_size_pretty(sum(pg_total_relation_size(c.oid))) as total_all_schemas
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('mirror', 'derived', 'enrich', 'work', 'ops') and c.relkind = 'r';

