begin;
-- עוזר: מצב הכותרות כמחרוזת, לבדיקות
create function pg_temp.titles() returns text language sql as
$$ select coalesce(string_agg(page_id || ':' || title, ',' order by page_id), '') from mirror.wiki_page $$;
create function pg_temp.mtitles() returns text language sql as
$$ select coalesce(string_agg(page_id || ':' || title, ',' order by page_id), '') from mirror.mech_page $$;

do $$
declare r jsonb;
begin
    -- 1. מילוי ראשוני והרצה חוזרת: אותה תוצאה, ובהרצה השנייה 0 שינויים
    r := api.sync_apply_wiki_pages('[{"page_id":1,"title":"א","latest_rev_id":10},{"page_id":2,"title":"ב"}]');
    if (r ->> 'inserted')::int <> 2 then raise exception 'first apply should insert 2: %', r; end if;
    r := api.sync_apply_wiki_pages('[{"page_id":1,"title":"א","latest_rev_id":10},{"page_id":2,"title":"ב"}]');
    if (r ->> 'inserted')::int <> 0 or (r ->> 'updated')::int <> 0 or (r ->> 'deleted')::int <> 0 then
        raise exception 'replay must change nothing: %', r;
    end if;
    if pg_temp.titles() <> '1:א,2:ב' then raise exception 'state after replay: %', pg_temp.titles(); end if;
end $$;

do $$
declare r jsonb;
begin
    -- 2. Morphine: הדף הועבר (הפניה נשארה), והפניה נמחקה לפי כותרת. הדף החי נשמר בכותרתו החדשה.
    insert into mirror.wiki_page (page_id, title, latest_rev_id) values (2579988, 'Morphine (band)', 123);
    for i in 1..3 loop   -- וגם בהרצה חוזרת
        r := api.sync_apply_wiki_pages('[{"page_id":2579988,"title":"Morphine"}]', '{}', array['Morphine (band)']);
        if not exists (select 1 from mirror.wiki_page where page_id = 2579988 and title = 'Morphine') then
            raise exception 'Morphine row lost or wrong title (iteration %): %', i, pg_temp.titles();
        end if;
        -- השורה עצמה נשמרה (לא נמחקה ונכתבה מחדש): הגרסה שנשמרה עליה נשארת
        if (select latest_rev_id from mirror.wiki_page where page_id = 2579988) is distinct from 123 then
            raise exception 'Morphine row was deleted and recreated (rev lost), iteration %', i;
        end if;
    end loop;
end $$;

do $$
begin
    -- 3. החלפת כותרות באותה קריאה (מעגל): 1<->2
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"ב"},{"page_id":2,"title":"א"}]');
    if (select title from mirror.wiki_page where page_id = 1) <> 'ב' or (select title from mirror.wiki_page where page_id = 2) <> 'א' then
        raise exception 'swap failed: %', pg_temp.titles();
    end if;
    -- 4. העברה ודף חדש בכותרת הישנה, בקריאה אחת
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"ג"},{"page_id":7,"title":"ב"}]');
    if not (select title from mirror.wiki_page where page_id = 1) = 'ג' or (select title from mirror.wiki_page where page_id = 7) <> 'ב' then
        raise exception 'move + new page at old title failed: %', pg_temp.titles();
    end if;
end $$;

do $$
declare r jsonb;
begin
    -- 5. שורה מיושנת שמחזיקה כותרת של דף חי (המזהה שלה לא בקלט): נמחקת
    insert into mirror.wiki_page (page_id, title) values (900, 'תפוס');
    r := api.sync_apply_wiki_pages('[{"page_id":901,"title":"תפוס"}]');
    if exists (select 1 from mirror.wiki_page where page_id = 900) then raise exception 'stale holder not removed'; end if;
    if (r ->> 'deleted')::int <> 1 then raise exception 'deleted count: %', r; end if;
    -- 6. מזהה שנעלם נמחק; מזהה שגם חי בקלט לא נמחק
    insert into mirror.wiki_page (page_id, title) values (910, 'ייעלם'), (911, 'יישאר');
    perform api.sync_apply_wiki_pages('[{"page_id":911,"title":"יישאר"}]', array[910, 911]::bigint[], '{}');
    if exists (select 1 from mirror.wiki_page where page_id = 910) then raise exception 'gone id kept'; end if;
    if not exists (select 1 from mirror.wiki_page where page_id = 911) then raise exception 'live id deleted'; end if;
    -- 7. כותרת שנעלמה: שורה שהמזהה שלה לא חי נמחקת
    insert into mirror.wiki_page (page_id, title) values (920, 'כותרת שנעלמה');
    perform api.sync_apply_wiki_pages('[]', '{}', array['כותרת שנעלמה']);
    if exists (select 1 from mirror.wiki_page where page_id = 920) then raise exception 'gone title row kept'; end if;
end $$;

do $$
declare ok boolean := false;
begin
    -- 8. קלט כפול נדחה
    begin
        perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"x"},{"page_id":2,"title":"x"}]');
    exception when sqlstate '22023' then ok := true; end;
    if not ok then raise exception 'duplicate title in payload accepted'; end if;
end $$;

-- 9. אטומיות: סטטוס לא חוקי מתגלגל לאחור את כל הקריאה (כולל מחיקות ושינויי כותרת באותה קריאה)
insert into mirror.mech_page (page_id, title, status) values (50, 'ישן', 'imported_documented'), (51, 'נשאר', 'imported_documented');
do $$
declare ok boolean := false;
begin
    begin
        perform api.sync_apply_mech_pages(
            '[{"page_id":50,"title":"חדש","status":"imported_documented"},{"page_id":52,"title":"שגוי","status":"no_such"}]',
            array[51]::bigint[], '{}');
    exception when foreign_key_violation then ok := true; end;
    if not ok then raise exception 'invalid status accepted'; end if;
    if pg_temp.mtitles() <> '50:ישן,51:נשאר' then raise exception 'failed call was not atomic: %', pg_temp.mtitles(); end if;
end $$;

-- 10. מכלול + נגזר באותה טרנזקציה: ערך מכלול חדש בכותרת של דף ויקיפדיה מסיר אותו מ"חסר"
do $$
declare r jsonb;
begin
    delete from mirror.wiki_page;
    delete from mirror.mech_page;
    delete from derived.wiki_gap;   -- איפוס ישיר של הבדיקה (בפועל הפונקציות מתחזקות אותה)
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"ויקי א"},{"page_id":2,"title":"הרב ויקי ב"}]');
    if (select count(*) from derived.wiki_gap where kind = 'missing') <> 2 then
        raise exception 'both pages should be missing: %', (select string_agg(wiki_id || kind, ',') from derived.wiki_gap);
    end if;
    r := api.sync_apply_mech_pages('[{"page_id":11,"title":"ויקי א","status":"imported_documented","source_type":"wikipedia_documented"},
                                      {"page_id":12,"title":"ויקי ב","status":"imported_documented"}]');
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'page 1 should be linked after mech apply'; end if;
    if (select kind from derived.wiki_gap where wiki_id = 2) is distinct from 'rav_review' then raise exception 'page 2 should be rav_review'; end if;
    -- ערך המכלול נמחק: הדף חוזר ל"חסר"
    perform api.sync_apply_mech_pages('[]', array[11]::bigint[], '{}');
    if (select kind from derived.wiki_gap where wiki_id = 1) is distinct from 'missing' then raise exception 'page 1 should be missing again'; end if;
    -- הרצה חוזרת על מצב זהה: אפס שינויים
    r := api.sync_apply_mech_pages('[{"page_id":12,"title":"ויקי ב","status":"imported_documented"}]');
    if (r ->> 'inserted')::int <> 0 or (r ->> 'updated')::int <> 0 or (r ->> 'deleted')::int <> 0 then raise exception 'mech replay changed rows: %', r; end if;
end $$;

-- 11. אירועים אידמפוטנטיים; ריצה: נקודת ההתקדמות מתקדמת רק בהצלחה
do $$
declare n int; run jsonb; rid uuid;
begin
    n := api.sync_record_events('[{"site":"wikipedia","kind":"move","page_id":5,"title":"A","new_title":"B","ts":"2026-10-05T11:27:20Z"}]');
    if n <> 1 then raise exception 'event not recorded'; end if;
    n := api.sync_record_events('[{"site":"wikipedia","kind":"move","page_id":5,"title":"A","new_title":"B","ts":"2026-10-05T11:27:20Z"}]');
    if n <> 0 then raise exception 'duplicate event recorded'; end if;

    run := api.sync_run_start('sync');
    rid := (run ->> 'run_id')::uuid;
    perform api.sync_run_finish(rid, 'failed', '{}', 'boom', '{"wikipedia/delta":"2026-10-05T10:00:00Z"}');
    if exists (select 1 from ops.watermark) then raise exception 'failed run advanced the watermark'; end if;
    run := api.sync_run_start('sync');
    rid := (run ->> 'run_id')::uuid;
    perform api.sync_run_finish(rid, 'succeeded', '{"x":1}', null, '{"wikipedia/delta":"2026-10-05T10:00:00Z","mechalol/delta":"2026-10-05T10:01:00Z"}');
    if (select count(*) from ops.watermark) <> 2 then raise exception 'successful run did not advance the watermarks'; end if;
    if (api.sync_run_start('sync') -> 'watermarks' ->> 'wikipedia/delta') is null then raise exception 'start does not report watermarks'; end if;
    if (select status from ops.sync_run where run_id = rid) <> 'succeeded' then raise exception 'run status'; end if;
end $$;

-- 12. הרשאות: הקולקטור בלבד
do $$
declare ok boolean;
begin
    set local role anon;
    ok := false; begin perform api.sync_apply_wiki_pages('[]'); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon can execute sync function'; end if;
    set local role authenticated;
    ok := false; begin perform api.sync_run_start('sync'); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'authenticated can execute sync function'; end if;
    reset role;
    set local role service_role;
    perform api.sync_apply_wiki_pages('[]');
    reset role;
end $$;
rollback;
select 'ok t06_sync_apply' as test;
