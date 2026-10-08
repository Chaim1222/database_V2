begin;
insert into mirror.wiki_page(page_id,title) values
    (101,'שם נוכחי'),(102,'תבנית יעד'),(103,'חזר לשם הישן'),(104,'יעד של שם שנתפס'),(105,'שם שנתפס'),(106,'מקור קודם'),(107,'יעד מקור קודם');
insert into mirror.mech_page(page_id,title,status) values
    (201,'שם ישן','imported_documented'),(202,'כותרת מקומית','imported_documented'),
    (203,'חזר לשם הישן','created_in_mech'),(204,'שם שנתפס','created_in_mech'),
    (205,'ערך שמקורו נמחק','kept_after_wiki_delete'),(206,'תבנית יעד','imported_documented'),
    (207,'שם של דף שנמחק','imported_documented'),(208,'שם מקומי תקין','imported_documented'),
    (209,'כותרת שטופלה ידנית','imported_documented'),
    (210,'מקור קודם','imported_documented'),(211,'ידני קודם','imported_documented'),
    (212,'שם לפני טיוטה','imported_documented'),(213,'מקומי עם טיוטה','imported_documented'),
    (214,'טיוטה שכבר נמחקה','imported_documented'),(215,'טיוטה שהוחזרה','imported_documented'),
    (216,'טיוטה עם אירוע בלי מזהה','imported_documented'),(217,'טיוטה שעברה לשם חדש','imported_documented');
insert into derived.template_link(mech_id,wiki_id,template_ref) values
    (201,null,'שם ישן'),(202,null,'תבנית ישנה'),(205,null,'תבנית ישנה'),
    (206,null,'תבנית ישנה'),(208,102,'תבנית ישנה'),(209,null,'תבנית ישנה'),(210,106,'מקור קודם'),(213,null,'שם תבנית לפני טיוטה');
insert into work.manual_link(mech_id,wiki_id) values (209,102),(211,103);
insert into mirror.page_event(site,kind,page_id,title,new_title,ts) values
    ('wikipedia','move',101,'שם ישן','שם ביניים','2026-10-01'),
    ('wikipedia','move',101,'שם ישן','שם אחר ביומן','2026-10-02'),
    ('wikipedia','move',102,'תבנית ישנה','יעד ישן ביומן','2026-10-03'),
    ('wikipedia','move',103,'חזר לשם הישן','שם שבוטל','2026-10-03'),
    ('wikipedia','move',104,'שם שנתפס','יעד של שם שנתפס','2026-10-03'),
    ('wikipedia','move',999,'שם של דף שנמחק','יעד שנמחק','2026-10-03'),
    ('mechalol','move',101,'שם ישן','לא ויקיפדיה','2026-10-04'),
    ('wikipedia','move',107,'מקור קודם','יעד מקור קודם','2026-10-05'),
    ('wikipedia','move',102,'ידני קודם','תבנית יעד','2026-10-05'),
    ('wikipedia','move',301,'שם לפני טיוטה','טיוטה:שם לפני טיוטה','2026-10-05'),
    ('wikipedia','move',302,'שם תבנית לפני טיוטה','טיוטה:שם תבנית לפני טיוטה','2026-10-05'),
    ('wikipedia','move',303,'טיוטה שכבר נמחקה','טיוטה:למחיקה','2026-10-05'),
    ('wikipedia','delete',303,'טיוטה:למחיקה',null,'2026-10-06'),
    ('wikipedia','move',304,'טיוטה שהוחזרה','טיוטה:חזרה','2026-10-05'),
    ('wikipedia','move',304,'טיוטה:חזרה','טיוטה שהוחזרה','2026-10-06'),
    ('wikipedia','move',0,'טיוטה עם אירוע בלי מזהה','טיוטה:ללא מזהה','2026-10-05'),
    ('wikipedia','move',305,'טיוטה שעברה לשם חדש','טיוטה:ישן','2026-10-05'),
    ('wikipedia','move',305,'טיוטה:ישן','טיוטה:חדש','2026-10-06');
do $$
begin
    if (select array_agg(id order by id) from api.v_moves) is distinct from array[201,202,212,213,217]::bigint[] then
        raise exception 'moves scope changed: %', (select jsonb_agg(v) from api.v_moves v);
    end if;
    if (select wikipedia_title from api.v_moves where id=201) is distinct from 'שם נוכחי'
       or (select moved_at from api.v_moves where id=201) is distinct from '2026-10-02'::timestamptz
       or (select via from api.v_moves where id=201) is distinct from 'title' then raise exception 'latest move or title precedence'; end if;
    if (select via from api.report_wikipedia_moves where id=202) is distinct from 'template'
       or (select wikipedia_id from api.report_wikipedia_moves where id=202) is distinct from 102::bigint then raise exception 'compat template branch'; end if;
    if (select wikipedia_title from api.v_moves where id=212) is distinct from 'טיוטה:שם לפני טיוטה'
       or (select via from api.v_moves where id=213) is distinct from 'template'
       or (select wikipedia_title from api.v_moves where id=217) is distinct from 'טיוטה:חדש' then
        raise exception 'draft move disappeared or stale target used';
    end if;
    if exists (select 1 from api.v_moves where id in (204,210,211,214,215,216)) then
        raise exception 'resolved identity or superseded/unknown draft event became a task';
    end if;
    -- חזרה למרחב הראשי: מצב המראה גובר על יעד הטיוטה ההיסטורי.
    insert into mirror.wiki_page(page_id,title) values (301,'שם אחרי חזרה');
    if (select wikipedia_title from api.v_moves where id=212) is distinct from 'שם אחרי חזרה' then
        raise exception 'draft target overrode live mirror';
    end if;
    delete from mirror.wiki_page where page_id=301;
    -- אירוע חדש באותו זמן: מזהה האירוע שובר שוויון; מחיקה מאוחרת מבטלת טיוטה.
    insert into mirror.page_event(site,kind,page_id,title,new_title,ts) values
        ('wikipedia','delete',305,'טיוטה:חדש',null,'2026-10-06');
    if exists(select 1 from api.v_moves where id=217) then raise exception 'deleted draft remains'; end if;
    -- הדוח חי: שינוי שם היעד אינו מחייב אירוע חדש, ותיקון הכותרת אצלנו מסיר את המשימה.
    update mirror.wiki_page set title='השם החדש ביותר' where page_id=101;
    if (select wikipedia_title from api.v_moves where id=201) is distinct from 'השם החדש ביותר' then raise exception 'historical target leaked'; end if;
    update mirror.mech_page set title='השם החדש ביותר' where page_id=201;
    if exists(select 1 from api.v_moves where id=201) then raise exception 'fixed title remains a task'; end if;
    set local role anon;
    if (select count(*) from api.report_wikipedia_moves) <> 3 then raise exception 'anon report'; end if;
    reset role;
    set local role authenticated;
    perform count(*) from api.v_moves;
    reset role;
end $$;
rollback;
select 'ok t27_moves_current_identity' as test;
