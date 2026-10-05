begin;
insert into mirror.wiki_page (page_id, title) values (1, E'בית האזרח  (רמת גן)');
do $$
declare k text; dup_ok boolean := false; fk_ok boolean := false; ev_ok boolean := false;
begin
    -- המפתח מחושב בפונקציה אחת (ובאינדקס ביטוי), לא נשמר בעמודה
    select mirror.title_key(title) into k from mirror.wiki_page where page_id = 1;
    if k is distinct from 'בית האזרח (רמת גן)' then raise exception 'title_key wrong: %', k; end if;
    if exists (select 1 from information_schema.columns
               where table_schema = 'mirror' and table_name in ('wiki_page', 'mech_page') and column_name = 'title_key') then
        raise exception 'title_key must not be a stored column';
    end if;

    -- כותרת ייחודית
    begin
        insert into mirror.wiki_page (page_id, title) values (2, E'בית האזרח  (רמת גן)');
    exception when unique_violation then dup_ok := true; end;
    if not dup_ok then raise exception 'duplicate title was accepted'; end if;

    -- סטטוס חייב להיות קוד קיים
    begin
        insert into mirror.mech_page (page_id, title, status) values (10, 'א', 'no_such_status');
    exception when foreign_key_violation then fk_ok := true; end;
    if not fk_ok then raise exception 'unknown status was accepted'; end if;

    insert into mirror.mech_page (page_id, title, status) values (10, 'א', 'imported_documented');
    if (select source_type from mirror.mech_page where page_id = 10) <> 'unknown' then
        raise exception 'default source_type should be unknown';
    end if;

    -- אירוע כפול נדחה
    insert into mirror.page_event (site, kind, page_id, title, new_title, ts)
        values ('wikipedia', 'move', 5, 'A', 'B', '2026-10-05 11:27:20+00');
    begin
        insert into mirror.page_event (site, kind, page_id, title, new_title, ts)
            values ('wikipedia', 'move', 5, 'A', 'B', '2026-10-05 11:27:20+00');
    exception when unique_violation then ev_ok := true; end;
    if not ev_ok then raise exception 'duplicate event was accepted'; end if;
end $$;
rollback;
select 'ok t02_mirror' as test;
