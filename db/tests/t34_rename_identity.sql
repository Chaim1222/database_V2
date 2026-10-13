-- 0040: העברה בוויקיפדיה שומרת כיסוי של ערך שהתבנית שלו אומתה לאותה כותרת; תוקף תוצאת הסינון.
begin;
do $$
declare r jsonb;
begin
    -- מצב פתיחה: דף 1 "שם ישן" מכוסה בערך 10 (תבנית same), דף 4 "ג" מכוסה בכותרת בלבד (ערך 12, בלי תבנית)
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"שם ישן","latest_rev_id":100},
        {"page_id":2,"title":"ב","latest_rev_id":200},{"page_id":4,"title":"ג","latest_rev_id":400}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"שם ישן","status":"imported_documented"},
        {"page_id":11,"title":"ב","status":"imported_documented"},{"page_id":12,"title":"ג","status":"imported_undocumented"}]');
    perform api.sync_apply_template_checks('[
        {"mech_id":10,"outcome":"same","rev_id":5,"template_rev":90,"template_title":"שם ישן"},
        {"mech_id":11,"outcome":"same","rev_id":6,"template_rev":190,"template_title":"ב"},
        {"mech_id":12,"outcome":"none","rev_id":7,"template_rev":0}]');
    if exists (select 1 from derived.wiki_gap where wiki_id in (1, 2, 4)) then raise exception 'precondition: all covered'; end if;

    -- 1. העברה: הקישור נשמר לפי מזהה, הדף לא חסר, והתוצאה ok
    r := api.sync_apply_wiki_pages('[{"page_id":1,"title":"שם חדש","latest_rev_id":101}]');
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'renamed page became missing'; end if;
    if not exists (select 1 from derived.template_link where mech_id = 10 and wiki_id = 1 and template_ref = 'שם ישן') then
        raise exception 'rename link not stored'; end if;
    if (select outcome from derived.template_check where mech_id = 10) <> 'ok' then raise exception 'outcome should be ok'; end if;
    if (select template_title from derived.template_check where mech_id = 10) <> 'שם ישן' then raise exception 'template title changed'; end if;

    -- משימת ההעברה נשארת גלויה
    perform api.sync_record_events('[{"site":"wikipedia","kind":"move","page_id":1,"title":"שם ישן","new_title":"שם חדש","ts":"2026-10-13T04:46:02Z"}]');
    if not exists (select 1 from api.v_moves where id = 10 and wiki_id = 1) then raise exception 'move task hidden by the link'; end if;

    -- 2. הרצה חוזרת של אותה העברה: אין שינוי
    r := api.sync_apply_wiki_pages('[{"page_id":1,"title":"שם חדש","latest_rev_id":101}]');
    if (r->>'gap_changed')::int <> 0 or (select count(*) from derived.template_link where mech_id = 10) <> 1 then
        raise exception 'replay changed state: %', r; end if;

    -- 3. בדיקה חוזרת של הערך (נערך במכלול, התבנית עדיין "שם ישן"): הקישור נשמר
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"same","rev_id":8,"template_rev":90,"template_title":"שם ישן"}]');
    if not exists (select 1 from derived.template_link where mech_id = 10 and wiki_id = 1) then raise exception 'recheck dropped the link'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'recheck reopened the gap'; end if;
    if (select outcome from derived.template_check where mech_id = 10) <> 'ok' then raise exception 'recheck outcome should be ok'; end if;

    -- 4. דף אחר תפס את השם הישן באותה החלה: אין קישור (אין הוכחה לאיזה דף התבנית התכוונה)
    perform api.sync_apply_wiki_pages('[{"page_id":2,"title":"ב חדש","latest_rev_id":201},{"page_id":3,"title":"ב","latest_rev_id":300}]');
    if exists (select 1 from derived.template_link where mech_id = 11) then raise exception 'linked although another page holds the old title'; end if;
    if not exists (select 1 from derived.wiki_gap where wiki_id = 2 and kind = 'missing') then raise exception 'ambiguous move should stay missing'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 3) then raise exception 'new page with the old title is covered by title'; end if;

    -- 5. בלי תבנית (כותרת בלבד): הכלל לא השתנה, הדף שהועבר חסר
    perform api.sync_apply_wiki_pages('[{"page_id":4,"title":"ג חדש","latest_rev_id":401}]');
    if not exists (select 1 from derived.wiki_gap where wiki_id = 4 and kind = 'missing') then raise exception 'title-only rule changed'; end if;
    if exists (select 1 from derived.template_link where mech_id = 12) then raise exception 'title-only page linked'; end if;

    -- 6. הערך הועבר במכלול והתבנית עודכנה לשם החדש: הקישור הישן מוסר, הכיסוי לפי כותרת
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"שם חדש","status":"imported_documented"}]');
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"same","rev_id":9,"template_rev":101,"template_title":"שם חדש"}]');
    if exists (select 1 from derived.template_link where mech_id = 10) then raise exception 'updated template kept the rename link'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'title match lost'; end if;

    -- 7. תיקון מהיסטוריה (מסלול המיגרציה): העברה שהוחלה בלי קישור מקבלת אותו מהאירועים
    perform api.sync_apply_wiki_pages('[{"page_id":5,"title":"ד","latest_rev_id":500}]');
    perform api.sync_apply_mech_pages('[{"page_id":13,"title":"ד","status":"imported_documented"}]');
    perform api.sync_apply_template_checks('[{"mech_id":13,"outcome":"same","rev_id":10,"template_rev":490,"template_title":"ד"}]');
    -- העברה ישירה במראה, כפי שהוחלה לפני 0040 (בלי קישור)
    update mirror.wiki_page set title = 'ד חדש' where page_id = 5;
    perform derived.refresh_wiki_gap(array[5]::bigint[]);
    if not exists (select 1 from derived.wiki_gap where wiki_id = 5) then raise exception 'precondition: pre-0040 state is missing'; end if;
    if derived.link_moved_templates(array[5, 5]::bigint[], array['ד', 'ד']) <> 1 then raise exception 'backfill did not link once'; end if;
    perform derived.refresh_wiki_gap(array[5]::bigint[]);
    if exists (select 1 from derived.wiki_gap where wiki_id = 5) then raise exception 'backfill did not restore coverage'; end if;
    if derived.link_moved_templates(array[5]::bigint[], array['ד']) <> 0 then raise exception 'backfill replay changed state'; end if;

    -- שם ישן שהיה של שני מזהים: מדולג
    perform api.sync_apply_wiki_pages('[{"page_id":6,"title":"ה","latest_rev_id":600}]');
    perform api.sync_apply_mech_pages('[{"page_id":14,"title":"ה","status":"imported_documented"}]');
    perform api.sync_apply_template_checks('[{"mech_id":14,"outcome":"same","rev_id":11,"template_rev":590,"template_title":"ה"}]');
    update mirror.wiki_page set title = 'ה חדש' where page_id = 6;
    if derived.link_moved_templates(array[6, 1]::bigint[], array['ה', 'ה']) <> 0 then raise exception 'ambiguous history linked'; end if;
end $$;

-- 8. תוקף הסינון: ישן רק כשהגרסה שנסרקה קודמת לגרסה שבמראה
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":20,"title":"סרוק ישן","latest_rev_id":1000},
        {"page_id":21,"title":"סרוק חדש","latest_rev_id":1000},{"page_id":22,"title":"סרוק זהה","latest_rev_id":1000},
        {"page_id":23,"title":"לא נסרק","latest_rev_id":1000}]');
    insert into enrich.content_scan (wiki_id, rev_id, verdict_list_a) values (20, 999, 'clean'), (21, 1001, 'clean'), (22, 1000, 'clean');
    if (select scan_state from api.v_missing where id = 20) <> 'stale' then raise exception 'older scan must be stale'; end if;
    if (select scan_state from api.v_missing where id = 21) <> 'scanned' then raise exception 'newer scan is not stale'; end if;
    if (select scan_state from api.v_missing where id = 22) <> 'scanned' then raise exception 'same scan must be scanned'; end if;
    if (select scan_state from api.v_missing where id = 23) <> 'not_scanned' then raise exception 'missing scan state'; end if;
    if (select scan_state from api.report_missing_word_filter where id = 20) <> 'stale'
       or (select scan_state from api.report_missing_word_filter where id = 21) <> 'scanned' then
        raise exception 'compat view disagrees'; end if;
    update mirror.wiki_page set latest_rev_id = null where page_id = 22;
    if (select scan_state from api.v_missing where id = 22) <> 'stale' then raise exception 'unknown latest revision is not proof of freshness'; end if;
end $$;

-- 9. הרשאות: הפונקציה הפנימית אינה נגישה ל-anon/authenticated
do $$
begin
    if has_function_privilege('anon', 'derived.link_moved_templates(bigint[], text[])', 'execute')
       or has_function_privilege('authenticated', 'derived.link_moved_templates(bigint[], text[])', 'execute') then
        raise exception 'internal function exposed'; end if;
    if not exists (select 1 from ops.schema_migration where version = '0040') then raise exception '0040 not recorded'; end if;
end $$;
rollback;
select 'ok t34_rename_identity';
