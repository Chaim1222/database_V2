begin;
do $$
declare r jsonb;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"יעד א"},{"page_id":2,"title":"יעד ב"}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"ערך שונה","status":"imported_documented"},{"page_id":11,"title":"ערך דומה","status":"imported_documented"},{"page_id":12,"title":"נעול","status":"imported_documented"}]');
    if not exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'precondition: wiki 1 missing'; end if;

    -- pending: שלושה ערכים לא נבדקו
    if (select count(*) from api.template_pending(0, 100)) <> 3 then raise exception 'pending should be 3'; end if;

    -- ok: ערך 10 מצביע לדף 1 -> דף 1 כבר לא חסר. unresolved: ערך 11 מצביע לכותרת לא קיימת. same: 12
    r := api.sync_apply_template_checks('[
        {"mech_id":10,"outcome":"ok","rev_id":5,"wiki_id":1,"template_ref":"יעד א"},
        {"mech_id":11,"outcome":"ok","rev_id":6,"wiki_id":999,"template_ref":"לא קיים"},
        {"mech_id":12,"outcome":"same","rev_id":7}]');
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'ok link should hide wiki 1'; end if;
    if (select outcome from derived.template_check where mech_id = 11) <> 'unresolved' then raise exception 'unknown wiki id must become unresolved'; end if;
    if (select wiki_id from derived.template_link where mech_id = 11) is not null then raise exception 'unresolved must have null wiki_id'; end if;
    if exists (select 1 from derived.template_link where mech_id = 12) then raise exception 'same must not store a link'; end if;
    if (select count(*) from api.template_pending(0, 100)) <> 0 then raise exception 'nothing pending after checks'; end if;

    -- הרצה חוזרת: אותו תוצאה
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"ok","rev_id":5,"wiki_id":1,"template_ref":"יעד א"}]');
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'replay changed the state'; end if;

    -- denied: הקישור הקודם נשמר
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"denied","rev_id":5}]');
    if not exists (select 1 from derived.template_link where mech_id = 10 and wiki_id = 1) then raise exception 'denied must keep the previous link'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 1) then raise exception 'denied must not reopen the gap'; end if;

    -- הדף הועבר ליעד אחר: דף 1 חוזר לחסר, דף 2 מכוסה
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"ok","rev_id":8,"wiki_id":2,"template_ref":"יעד ב"}]');
    if not exists (select 1 from derived.wiki_gap where wiki_id = 1 and kind = 'missing') then raise exception 'old target should be missing again'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 2) then raise exception 'new target should be covered'; end if;

    -- התבנית הוסרה: none מוחק את הקישור
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"none","rev_id":9}]');
    if exists (select 1 from derived.template_link where mech_id = 10) then raise exception 'none must remove the link'; end if;
    if not exists (select 1 from derived.wiki_gap where wiki_id = 2) then raise exception 'wiki 2 should be missing after link removal'; end if;
end $$;
rollback;
select 'ok t09_template_check' as test;
