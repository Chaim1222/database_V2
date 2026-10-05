begin;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2');
insert into work.admin (user_id) values ('00000000-0000-0000-0000-0000000000a1');
insert into mirror.wiki_page (page_id, title) values (1, 'ויקי');
insert into enrich.content_scan (wiki_id) values (1);
insert into enrich.content_scan_detail (wiki_id, counts) values (1, '{}');
insert into work.scan_feedback (wiki_id, match_key, word, entries, label, user_id)
    values (1, 'k', 'w', '{e}', 'false', '00000000-0000-0000-0000-0000000000a1');

-- anon: קורא views וטבלאות ציבוריות, אבל לא כותב ולא קורא טבלאות סגורות
set local role anon;
do $$
declare ok boolean;
begin
    perform count(*) from api.v_missing;
    perform count(*) from api.v_counts;
    perform count(*) from mirror.wiki_page;

    ok := false; begin insert into work.manual_link (mech_id, wiki_id) values (1, 1); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon could insert into work.manual_link'; end if;

    ok := false; begin insert into mirror.wiki_page (page_id, title) values (9, 'x'); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon could write mirror'; end if;

    ok := false; begin perform count(*) from enrich.content_scan_detail; exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon could read content_scan_detail'; end if;

    ok := false; begin perform count(*) from work.scan_feedback; exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon could read scan_feedback'; end if;

    ok := false; begin perform count(*) from work.admin; exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon could read work.admin'; end if;

    ok := false; begin perform api.set_manual_link(1, 1, 'x'); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'anon could execute set_manual_link'; end if;
end $$;
reset role;

-- authenticated שאינו מנהל: הפונקציה נדחית
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';
do $$
declare ok boolean := false;
begin
    if api.is_admin() then raise exception 'non-admin reported as admin'; end if;
    begin perform api.set_manual_link(11, 1, 'x'); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'non-admin could set manual link'; end if;
    ok := false;
    begin insert into work.manual_link (mech_id, wiki_id) values (11, 1); exception when insufficient_privilege then ok := true; end;
    if not ok then raise exception 'authenticated could insert directly'; end if;
end $$;
reset role;

-- מנהל: כותב דרך הפונקציות בלבד
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$
begin
    if not api.is_admin() then raise exception 'admin not recognised'; end if;
    perform api.set_manual_link(11, 1, 'בדיקה');
    perform api.add_exclusion('import_excluded', 1, null, 'לא לייבא');
    perform api.mark_feedback(1, 'k2', 'w2', array['e2'], 'true');
end $$;
reset role;

do $$
begin
    if (select count(*) from work.manual_link where mech_id = 11 and created_by = '00000000-0000-0000-0000-0000000000a1') <> 1 then
        raise exception 'manual link not recorded with creator';
    end if;
    if (select count(*) from work.exclusion where wiki_id = 1) <> 1 then raise exception 'exclusion not written'; end if;
end $$;

-- service_role עוקף RLS וכותב למראה
set local role service_role;
insert into mirror.wiki_page (page_id, title) values (99, 'נכתב על ידי service_role');
reset role;
rollback;
select 'ok t04_security' as test;
