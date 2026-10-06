begin;
do $$
declare r jsonb; before_gap bigint[];
begin
    -- מחיקה רק לפי כותרת: הנגזר נמחק יחד עם המראה, כולל בהרצה חוזרת.
    perform api.sync_apply_wiki_pages('[{"page_id":801,"title":"מחיקה בכותרת"},{"page_id":802,"title":"לא נגעו"}]');
    r := api.sync_apply_wiki_pages('[]', '{}', array['מחיקה בכותרת']);
    if (r->>'deleted')::int is distinct from 1 or exists (select 1 from derived.wiki_gap where wiki_id = 801) then
        raise exception 'delete by title left a gap: %', r;
    end if;
    r := api.sync_apply_wiki_pages('[]', '{}', array['מחיקה בכותרת']);
    if (r->>'deleted')::int is distinct from 0 or (r->>'gap_changed')::int is distinct from 0 then
        raise exception 'replay changed state: %', r;
    end if;
    if (select kind from derived.wiki_gap where wiki_id = 802) is distinct from 'missing' then
        raise exception 'unrelated gap changed';
    end if;

    -- מחזיק כותרת מיושן: גם המזהה שהוסר מפונה מהנגזר; החדש נשאר חסר.
    perform api.sync_apply_wiki_pages('[{"page_id":803,"title":"כותרת תפוסה"}]');
    r := api.sync_apply_wiki_pages('[{"page_id":804,"title":"כותרת תפוסה"}]');
    if exists (select 1 from derived.wiki_gap where wiki_id = 803)
       or (select kind from derived.wiki_gap where wiki_id = 804) is distinct from 'missing'
       or (r->>'deleted')::int is distinct from 1 then
        raise exception 'stale holder cleanup: %', r;
    end if;

    -- גם rav_review מפונה; מזהה חי גובר על כותרת/מזהה שנעלמו ושומר על גרסה קיימת.
    perform api.sync_apply_mech_pages('[{"page_id":900,"title":"כותרת רב","status":"created_in_mech"}]');
    perform api.sync_apply_wiki_pages('[{"page_id":805,"title":"הרב כותרת רב"},{"page_id":806,"title":"שם ישן","latest_rev_id":123}]');
    if (select kind from derived.wiki_gap where wiki_id = 805) is distinct from 'rav_review' then raise exception 'rav precondition'; end if;
    perform api.sync_apply_wiki_pages('[]', '{}', array['הרב כותרת רב']);
    if exists (select 1 from derived.wiki_gap where wiki_id = 805) then raise exception 'rav orphan'; end if;
    perform api.sync_apply_wiki_pages('[{"page_id":806,"title":"שם חדש"}]', array[806]::bigint[], array['שם ישן']);
    if (select latest_rev_id from mirror.wiki_page where page_id = 806) is distinct from 123
       or (select title from mirror.wiki_page where page_id = 806) is distinct from 'שם חדש' then raise exception 'live row lost'; end if;

    -- כשל אחרי מחיקה ופינוי כותרת: הקריאה כולה מתגלגלת לאחור, כולל הנגזר.
    select array_agg(wiki_id order by wiki_id) into before_gap from derived.wiki_gap;
    begin
        perform api.sync_apply_wiki_pages('[{"page_id":806,"title":"עוד שם"},{"page_id":807,"title":null}]', '{}', array['לא נגעו']);
        raise exception 'bad input accepted';
    exception when not_null_violation then null; end;
    if (select title from mirror.wiki_page where page_id = 802) is distinct from 'לא נגעו'
       or (select title from mirror.wiki_page where page_id = 806) is distinct from 'שם חדש'
       or (select array_agg(wiki_id order by wiki_id) from derived.wiki_gap) is distinct from before_gap then
        raise exception 'failed apply was not atomic';
    end if;
    if has_function_privilege('anon', 'api.sync_apply_wiki_pages(jsonb,bigint[],text[])', 'execute')
       or has_function_privilege('authenticated', 'api.sync_apply_wiki_pages(jsonb,bigint[],text[])', 'execute')
       or not has_function_privilege('service_role', 'api.sync_apply_wiki_pages(jsonb,bigint[],text[])', 'execute') then
        raise exception 'RPC permissions changed';
    end if;
end $$;
rollback;
select 'ok t26_sync_gap_cleanup' as test;
