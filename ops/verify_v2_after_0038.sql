-- אימות ל-V2 אחרי החלת 0037 ו-0038. שאילתת select אחת, קריאה בלבד: לא כותבת ולא יוצרת כלום.
-- שימוש: להריץ על פרויקט V2 (ukzijtrpchvmoxlslxpz). כל שורה עם ok = false דורשת בדיקה לפני החלפת הדף בוויקי.
-- עקרון: ok לעולם אינו NULL (NULL נספר ככישלון), ובדיקה לא עוברת על ריק או על אובייקט חסר.
-- בדיקות שתלויות ב-0038 מוגנות, כך שלפני הפריסה הן יחזירו false ולא שגיאה.
select check_name, coalesce(ok, false) as ok, detail
from (
  select 1 as n, 'מיגרציות 0037 ו-0038 רשומות' as check_name,
         (select count(*) from ops.schema_migration where version in ('0037','0038')) = 2 as ok,
         (select string_agg(version, ',' order by version) from (select version from ops.schema_migration order by version desc limit 4) s) as detail
  union all
  select 2, 'rev_scope נשאר עם force_custom_plan',
         exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'api' and p.proname = 'rev_scope' and p.proconfig::text like '%force_custom_plan%'),
         null
  union all
  select 3, 'התצוגה report_missing_word_filter_summary קיימת וקריאה ל-anon',
         coalesce(has_table_privilege('anon', to_regclass('api.report_missing_word_filter_summary'), 'select'), false),
         coalesce(to_regclass('api.report_missing_word_filter_summary')::text, 'חסרה')
  union all
  select 4, 'mark_feedback: הגדרה אחת, 11 ארגומנטים, authenticated כן ו-anon לא',
         coalesce((select count(*) = 1 and bool_and(p.pronargs = 11)
                          and bool_and(has_function_privilege('authenticated', p.oid, 'execute'))
                          and not bool_or(has_function_privilege('anon', p.oid, 'execute'))
                   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'api' and p.proname = 'mark_feedback'), false),
         'ארגומנטים: ' || coalesce((select string_agg(p.pronargs::text, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'api' and p.proname = 'mark_feedback'), 'אין פונקציה')
  union all
  select 5, 'העמודה האחרונה: report_locked_pages=site, word_filter_results=counts',
         coalesce((select attname from pg_attribute where attrelid = 'api.report_locked_pages'::regclass and attnum > 0 and not attisdropped order by attnum desc limit 1) = 'site'
         and (select attname from pg_attribute where attrelid = 'api.word_filter_results'::regclass and attnum > 0 and not attisdropped order by attnum desc limit 1) = 'counts', false),
         (select attname from pg_attribute where attrelid = 'api.report_locked_pages'::regclass and attnum > 0 and not attisdropped order by attnum desc limit 1)
           || ' / ' || (select attname from pg_attribute where attrelid = 'api.word_filter_results'::regclass and attnum > 0 and not attisdropped order by attnum desc limit 1)
  union all
  -- 6: השוואה לכל שורה (לא כמויות): כל העמודות ש-report_rev_tasks גוזרת מ-v_rev_tasks, ובנוסף נדרש שיהיו שורות עם מזהה ויקיפדיה (אחרת זו עבירה ריקה).
  select 6, 'report_rev_tasks זהה לכל שורה ל-v_rev_tasks, כולל wikipedia_id = linked_wiki_id',
         (select count(*) from api.report_rev_tasks r full join api.v_rev_tasks v on v.id = r.id
          where r.id is null or v.id is null
             or r.title is distinct from v.title or r.status is distinct from v.status_label or r.rev_task is distinct from v.rev_task
             or r.sort_template_rev is distinct from v.rev_id or r.wikipedia_id is distinct from v.linked_wiki_id
             or r.linked_title is distinct from v.linked_title or r.rev_page_id is distinct from v.rev_page_id
             or r.rev_page_title is distinct from v.rev_page_title or r.checked_at is distinct from v.checked_at) = 0
         and (select count(*) from api.v_rev_tasks where linked_wiki_id is not null) > 0,
         'שורות שונות: ' || (select count(*) from api.report_rev_tasks r full join api.v_rev_tasks v on v.id = r.id
          where r.id is null or v.id is null
             or r.title is distinct from v.title or r.status is distinct from v.status_label or r.rev_task is distinct from v.rev_task
             or r.sort_template_rev is distinct from v.rev_id or r.wikipedia_id is distinct from v.linked_wiki_id
             or r.linked_title is distinct from v.linked_title or r.rev_page_id is distinct from v.rev_page_id
             or r.rev_page_title is distinct from v.rev_page_title or r.checked_at is distinct from v.checked_at)::text
         || ' | שורות עם מזהה ויקיפדיה ב-v_rev_tasks: ' || (select count(*) from api.v_rev_tasks where linked_wiki_id is not null)::text
  union all
  -- 7: report_locked_pages מול v_locks, שורה מול שורה בשני הכיוונים (except all), כולל nullif(page_id, 0) לפי האתר.
  select 7, 'report_locked_pages זהה לכל שורה לגזירה מ-v_locks (מזהה 0 וההפרדה לפי אתר)',
         case when exists (select 1 from information_schema.columns where table_schema = 'api' and table_name = 'report_locked_pages' and column_name = 'site')
              then (xpath('/row/c/text()', query_to_xml($q$
                select count(*) c from (
                  (select id, title, lock_level, lock_source, wikipedia_id, mechalol_id, detected_at, site from api.report_locked_pages
                   except all
                   select l.page_id, l.title, case when l.level = 'create' then 'נעול ליצירה' else 'נעול לקריאה' end, l.detected_by,
                          case when l.site = 'wikipedia' then nullif(l.page_id, 0) end, case when l.site = 'mechalol' then nullif(l.page_id, 0) end,
                          l.detected_at, l.site from api.v_locks l)
                  union all
                  (select l.page_id, l.title, case when l.level = 'create' then 'נעול ליצירה' else 'נעול לקריאה' end, l.detected_by,
                          case when l.site = 'wikipedia' then nullif(l.page_id, 0) end, case when l.site = 'mechalol' then nullif(l.page_id, 0) end,
                          l.detected_at, l.site from api.v_locks l
                   except all
                   select id, title, lock_level, lock_source, wikipedia_id, mechalol_id, detected_at, site from api.report_locked_pages)
                ) d $q$, false, true, '')))[1]::text::bigint = 0
              else false end,
         case when exists (select 1 from information_schema.columns where table_schema = 'api' and table_name = 'report_locked_pages' and column_name = 'site')
              then 'שורות שונות: ' || (xpath('/row/c/text()', query_to_xml($q$
                select count(*) c from (
                  (select id, title, lock_level, lock_source, wikipedia_id, mechalol_id, detected_at, site from api.report_locked_pages
                   except all
                   select l.page_id, l.title, case when l.level = 'create' then 'נעול ליצירה' else 'נעול לקריאה' end, l.detected_by,
                          case when l.site = 'wikipedia' then nullif(l.page_id, 0) end, case when l.site = 'mechalol' then nullif(l.page_id, 0) end,
                          l.detected_at, l.site from api.v_locks l)
                  union all
                  (select l.page_id, l.title, case when l.level = 'create' then 'נעול ליצירה' else 'נעול לקריאה' end, l.detected_by,
                          case when l.site = 'wikipedia' then nullif(l.page_id, 0) end, case when l.site = 'mechalol' then nullif(l.page_id, 0) end,
                          l.detected_at, l.site from api.v_locks l
                   except all
                   select id, title, lock_level, lock_source, wikipedia_id, mechalol_id, detected_at, site from api.report_locked_pages)
                ) d $q$, false, true, '')))[1]::text
              else 'אין עמודת site' end
  union all
  -- 8: מידע בלבד, לא תנאי להצלחת הפריסה. אם בנתונים אין נעילות מוויקיפדיה, בדיקה 7 לא מפעילה את ענף ההפרדה בין האתרים בנתונים החיים;
  -- היעדר נעילות כאלה אינו תקלה. t32 בודקת את שני האתרים וגם שתי חסימות יצירה לפי כותרת עם מזהה 0. בדיקה 7 מאמתת את הנתונים החיים אחרי הפריסה.
  select 8, 'מידע בלבד: אילו אתרים ומזהי 0 מופיעים בנעילות החיות (כיסוי של בדיקה 7)',
         true,
         'מידע בלבד, לא תנאי לפריסה: ' || coalesce((select string_agg(site || ': ' || c || ' (מזהה 0: ' || z || ')', ' | ' order by site)
          from (select site, count(*)::text c, count(*) filter (where page_id = 0)::text z from api.v_locks group by site) s), 'אין נעילות')
  union all
  select 9, 'סכום הסיכום שווה למספר השורות בדוח הסינון',
         case when to_regclass('api.report_missing_word_filter_summary') is not null
              then (xpath('/row/c/text()', query_to_xml('select coalesce(sum(n), 0) c from api.report_missing_word_filter_summary', false, true, '')))[1]::text::bigint = (select count(*) from api.report_missing_word_filter)
              else false end,
         'דוח: ' || (select count(*) from api.report_missing_word_filter)::text || ' | סיכום: ' ||
         case when to_regclass('api.report_missing_word_filter_summary') is not null
              then (xpath('/row/c/text()', query_to_xml('select coalesce(sum(n), 0) c from api.report_missing_word_filter_summary', false, true, '')))[1]::text
              else 'אין תצוגה' end
  union all
  select 10, 'דוח "חסר במכלול" ודוח הסינון מכילים אותה כמות',
         (select count(*) from api.report_missing_from_mechalol) = (select count(*) from api.report_missing_word_filter),
         (select count(*) from api.report_missing_from_mechalol)::text || ' מול ' || (select count(*) from api.report_missing_word_filter)::text
  union all
  select 11, 'ערכים עם redirect שלא נבדק (NULL): לידיעה, לא כשל',
         true,
         (select count(*) from api.report_missing_from_mechalol where mechalol_redirect_exists is null)::text
  union all
  -- 12: רשימה צפויה קבועה. אובייקט חסר נספר ככישלון (to_regclass מחזיר NULL, ו-coalesce הופך ל-false), ובפירוט מופיעים השמות שנכשלו.
  select 12, 'הרשאות קריאה על כל האובייקטים שהדשבורד קורא (anon), ו-word_filter_feedback: למחובר יש ולאורח אין',
         (select bool_and(g) from (select coalesce(has_table_privilege(e.role::name, to_regclass('api.' || e.name), 'select'), false) g
                                   from (values ('report_locked_pages','anon'),('report_missing_from_mechalol','anon'),('report_missing_word_filter','anon'),
                                                ('report_missing_word_filter_summary','anon'),('report_rav_prefix_normalization','anon'),('report_rev_tasks','anon'),
                                                ('report_undocumented_import','anon'),('report_wikipedia_moves','anon'),('word_filter_results','anon'),
                                                ('mechalol_pages','anon'),('sync_watermarks','anon'),('v_counts','anon'),('v_sync_status','anon'),
                                                ('v_template_issues','anon'),('word_filter_feedback','authenticated')) e(name, role)) x)
         and not coalesce(has_table_privilege('anon', to_regclass('api.word_filter_feedback'), 'select'), true),
         coalesce((select string_agg(e.name || ' (' || e.role || ')', ', ')
                   from (values ('report_locked_pages','anon'),('report_missing_from_mechalol','anon'),('report_missing_word_filter','anon'),
                                ('report_missing_word_filter_summary','anon'),('report_rav_prefix_normalization','anon'),('report_rev_tasks','anon'),
                                ('report_undocumented_import','anon'),('report_wikipedia_moves','anon'),('word_filter_results','anon'),
                                ('mechalol_pages','anon'),('sync_watermarks','anon'),('v_counts','anon'),('v_sync_status','anon'),
                                ('v_template_issues','anon'),('word_filter_feedback','authenticated')) e(name, role)
                   where not coalesce(has_table_privilege(e.role::name, to_regclass('api.' || e.name), 'select'), false)), 'הכול תקין')
         || case when coalesce(has_table_privilege('anon', to_regclass('api.word_filter_feedback'), 'select'), true)
                 then ' | אורח (anon) יכול לקרוא word_filter_feedback או שהתצוגה חסרה' else '' end
  union all
  select 13, 'הסנכרון האחרון הצליח לפני פחות מ-15 שעות (אין סנכרון מוצלח = כישלון)',
         coalesce((select now() - max(finished_at) from ops.sync_run where kind = 'sync' and status = 'succeeded') < interval '15 hours', false),
         coalesce((select max(finished_at) from ops.sync_run where kind = 'sync' and status = 'succeeded')::text, 'אין סנכרון מוצלח')
  union all
  select 14, 'כיסוי הסריקה (לידיעה; מצב scanned תלוי בהחלטה נפרדת על הסריקה)',
         true,
         (select string_agg(scan_state || '=' || c, ', ' order by scan_state)
          from (select scan_state, count(*)::text c from api.report_missing_word_filter group by 1) s)
) t
order by n;
