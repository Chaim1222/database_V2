begin;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1');
insert into work.admin (user_id) values ('00000000-0000-0000-0000-0000000000a1');

-- 3א. template_link: מחיקת ערך המכלול מחזירה את דף ויקיפדיה ל"חסר" (גם אחרי מחיקה לפי מזהה וגם לפי כותרת)
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":10,"title":"ויקי א"},{"page_id":11,"title":"ויקי ב"}]');
    perform api.sync_apply_mech_pages('[{"page_id":60,"title":"מכלול א","status":"created_in_mech"},{"page_id":61,"title":"מכלול ב","status":"created_in_mech"}]');
    insert into derived.template_link (mech_id, wiki_id) values (60, 10), (61, 11);
    perform derived.refresh_wiki_gap(array[10, 11]);
    if exists (select 1 from derived.wiki_gap where wiki_id in (10, 11)) then raise exception 'template links should hide both pages'; end if;

    perform api.sync_apply_mech_pages('[]', array[60]::bigint[]);                       -- לפי מזהה
    perform api.sync_apply_mech_pages('[]', '{}', array['מכלול ב']);                    -- לפי כותרת
    if (select count(*) from derived.wiki_gap where wiki_id in (10, 11) and kind = 'missing') <> 2 then
        raise exception 'wiki pages should be missing again: %', (select string_agg(wiki_id || kind, ',') from derived.wiki_gap);
    end if;
    if exists (select 1 from derived.template_link where mech_id in (60, 61)) then raise exception 'stale template_link kept'; end if;
end $$;

-- 3ב. מחיקה לפי כותרת מסירה mech_key ומרעננת את דף ויקיפדיה שהותאם אליו
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":20,"title":"קורבן"}]');
    perform api.sync_apply_mech_pages('[{"page_id":70,"title":"קרבן","status":"created_in_mech","wiki_candidate_key":"קורבן"}]');
    if exists (select 1 from derived.wiki_gap where wiki_id = 20) then raise exception 'precondition: linked'; end if;
    perform api.sync_apply_mech_pages('[]', '{}', array['קרבן']);
    if not exists (select 1 from derived.wiki_gap where wiki_id = 20 and kind = 'missing') then
        raise exception 'wiki page should return to missing after delete by title';
    end if;
    if exists (select 1 from derived.mech_key where mech_id = 70) then raise exception 'stale mech_key'; end if;
end $$;

-- 4. שיוך ידני (דרך הפונקציה) ומחיקתו מרעננים את הדוח
select api.sync_apply_mech_pages('[{"page_id":900,"title":"ערך לשיוך","status":"created_in_mech"}]') is not null;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$
begin
    perform api.set_manual_link(900, 20, 'בדיקה');
end $$;
reset role;
do $$
begin
    if exists (select 1 from derived.wiki_gap where wiki_id = 20) then raise exception 'manual link should hide wiki 20 from the gap table'; end if;
end $$;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$
begin
    delete from work.manual_link where mech_id = 900;
end $$;
reset role;
do $$
begin
    if not exists (select 1 from derived.wiki_gap where wiki_id = 20 and kind = 'missing') then
        raise exception 'removing the manual link should bring wiki 20 back to missing';
    end if;
end $$;

-- 5. ספירות: החרגה לפי כותרת נספרת, ו-sync_run_finish מרענן ספירות
do $$
declare r jsonb; v_n bigint;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":30,"title":"מוחרג לפי כותרת"}]');
    insert into work.exclusion (kind, title) values ('import_excluded', 'מוחרג לפי כותרת');
    perform ops.refresh_counts();
    if (select d.n from ops.dashboard_counts d where d.key = 'missing') <> (select count(*) from api.v_missing) then
        raise exception 'missing count % differs from v_missing %', (select d.n from ops.dashboard_counts d where d.key = 'missing'), (select count(*) from api.v_missing);
    end if;
    update ops.dashboard_counts set n = -1 where key = 'missing';
    r := api.sync_run_start('sync');
    perform api.sync_run_finish((r ->> 'run_id')::uuid, 'succeeded', '{}', null, '{}');
    select d.n into v_n from ops.dashboard_counts d where d.key = 'missing';
    if v_n < 0 then raise exception 'counts not refreshed by sync_run_finish'; end if;
end $$;

-- 6. דוח ההעברות נגיש ל-anon
insert into mirror.page_event (site, kind, page_id, title, new_title, ts) values ('wikipedia', 'move', 1, 'א', 'ב', now());
set local role anon;
select count(*) from api.v_moves;
reset role;

-- 2. טעינה: נקודת התחלה נשמרת בין ניסיונות, ומתחדשת רק אחרי טעינה שהושלמה
do $$
declare s1 timestamptz; s2 timestamptz; s3 timestamptz;
begin
    s1 := api.sync_load_begin('wikipedia', null);
    perform pg_sleep(0.05);
    s2 := api.sync_load_begin('wikipedia', null);
    if s1 <> s2 then raise exception 'failed attempt must keep the original start'; end if;
    perform api.sync_run_finish((api.sync_run_start('rebuild') ->> 'run_id')::uuid, 'succeeded', '{}', null,
                                jsonb_build_object('wikipedia/delta', s1));
    perform pg_sleep(0.05);
    s3 := api.sync_load_begin('wikipedia', null);
    if s3 <= s1 then raise exception 'a completed load must start a new window'; end if;
end $$;
-- 2ב. נקודת התחלה מוצעת (דמפ): מוקדמת מנצחת בניסיון פתוח, ובטעינה חדשה היא נקודת ההתחלה
do $$
declare s1 timestamptz; s2 timestamptz; s3 timestamptz;
begin
    s1 := api.sync_load_begin('mechalol', '2026-10-01 00:00+00');
    s2 := api.sync_load_begin('mechalol', '2026-10-03 00:00+00');     -- דמפ חדש יותר באותו ניסיון פתוח
    if s1 <> s2 or s2 <> '2026-10-01 00:00+00' then raise exception 'open attempt must keep the earlier start: % %', s1, s2; end if;
    s3 := api.sync_load_begin('mechalol', '2026-09-20 00:00+00');     -- דמפ ישן יותר: מוקדם יותר מכסה יותר
    if s3 <> '2026-09-20 00:00+00' then raise exception 'earlier proposed start should win: %', s3; end if;
    perform api.sync_run_finish((api.sync_run_start('rebuild') ->> 'run_id')::uuid, 'succeeded', '{}', null,
                                jsonb_build_object('mechalol/delta', s3));
    if api.sync_load_begin('mechalol', '2026-10-05 00:00+00') <> '2026-10-05 00:00+00' then
        raise exception 'after a completed load the proposed start is used';
    end if;
end $$;
rollback;
select 'ok t08_review_fixes' as test;
