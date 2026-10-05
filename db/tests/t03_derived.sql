begin;
-- דפי ויקיפדיה: 1 אותה כותרת במכלול, 2 הרב/רבי בלבד, 3 חסר, 4 תבנית שאומתה, 5 התאמה סמנטית, 6 שיוך ידני,
-- 7 הרב/רבי בכיוון ההפוך (במכלול עם קידומת)
insert into mirror.wiki_page (page_id, title) values
    (1, 'ויקי א'), (2, 'הרב ויקי ב'), (3, 'ויקי ג'), (4, 'ויקי ד'), (5, 'אלוה'), (6, 'ויקי ו'), (7, 'ויקי ז');
insert into mirror.mech_page (page_id, title, status) values
    (11, E'ויקי\u00a0א', 'imported_documented'),     -- אותה כותרת אחרי נרמול
    (12, 'ויקי ב', 'imported_documented'),           -- בוויקיפדיה "הרב ויקי ב"
    (14, 'מכלול ד', 'imported_documented'),          -- התבנית מצביעה על דף 4
    (15, 'אלוק', 'imported_documented'),             -- הכללים הסמנטיים: אלוק -> אלוה
    (16, 'מכלול ו', 'imported_documented'),          -- שויך ידנית לדף 6
    (17, 'הרב ויקי ז', 'imported_documented');       -- בוויקיפדיה "ויקי ז"
insert into derived.template_link (mech_id, wiki_id) values (14, 4);
insert into derived.mech_key (mech_id, wiki_candidate_key, rules) values (15, 'אלוה', '{כתיב_אלוהים}');
insert into work.manual_link (mech_id, wiki_id) values (16, 6);
do $$
declare cnt int; r record;
begin
    cnt := derived.refresh_wiki_gap();
    if cnt <> 3 then raise exception 'first refresh should change 3 rows (2,3,7), changed %', cnt; end if;
    if (select kind from derived.wiki_gap where wiki_id = 2) is distinct from 'rav_review' then raise exception 'page 2 should be rav_review'; end if;
    if (select kind from derived.wiki_gap where wiki_id = 7) is distinct from 'rav_review' then raise exception 'page 7 should be rav_review (reverse)'; end if;
    if (select kind from derived.wiki_gap where wiki_id = 3) is distinct from 'missing' then raise exception 'page 3 should be missing'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id in (1, 4, 5, 6)) then raise exception 'linked pages must not appear in wiki_gap'; end if;

    -- אידמפוטנטי: הרצה חוזרת לא משנה כלום
    if derived.refresh_wiki_gap() <> 0 then raise exception 'second refresh should change 0 rows'; end if;

    -- ממוקד: ערך מכלול חדש בכותרת של דף 3
    insert into mirror.mech_page (page_id, title, status) values (13, 'ויקי ג', 'imported_documented');
    if derived.refresh_wiki_gap(array[3]::bigint[]) <> 1 then raise exception 'scoped refresh should change 1'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 3) then raise exception 'page 3 should be linked now'; end if;
    -- ממוקד לא נוגע בדפים אחרים
    if (select count(*) from derived.wiki_gap) <> 2 then raise exception 'scoped refresh touched other pages'; end if;

    -- ערך מכלול שנמחק: הדף חוזר ל"חסר"
    delete from mirror.mech_page where page_id = 13;
    perform derived.refresh_wiki_gap(array[3]::bigint[]);
    if (select kind from derived.wiki_gap where wiki_id = 3) is distinct from 'missing' then raise exception 'page 3 should be missing again'; end if;

    -- דף שנעלם מהמראה: השורה שלו מוסרת
    delete from mirror.wiki_page where page_id = 3;
    perform derived.refresh_wiki_gap(array[3]::bigint[]);
    if exists (select 1 from derived.wiki_gap where wiki_id = 3) then raise exception 'gap of removed page not deleted'; end if;

    -- ספירות לדשבורד
    perform ops.refresh_counts();
    if (select c.n from ops.dashboard_counts c where c.key = 'wiki_pages') <> 6 then raise exception 'wiki_pages count'; end if;
    if (select c.n from ops.dashboard_counts c where c.key = 'missing') <> 0 then raise exception 'missing count'; end if;
    if (select c.n from ops.dashboard_counts c where c.key = 'rav_review') <> 2 then raise exception 'rav_review count'; end if;
end $$;
rollback;
select 'ok t03_derived' as test;
