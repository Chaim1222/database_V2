-- 0007: החלת מצב על המראות, כקריאות RPC לקולקטור בלבד (service_role). מבוסס מצב ולא רצף אירועים:
-- הקולקטור שואל את המקור מה המצב עכשיו ושולח את התוצאה, והפונקציה מביאה את המסד לשם בטרנזקציה אחת.
-- לכן הרצה חוזרת של אותו קלט אינה משנה דבר, ועצירה באמצע מתגלגלת לאחור.
--
-- חוזה הקלט (לכל אתר):
--   p_live         - [{page_id, title, ...}] דפים שחיים עכשיו (ערך במרחב הראשי, לא הפניה), בכותרתם הנוכחית
--   p_gone_ids     - מזהים שאינם חיים עוד (נמחקו, הפכו להפניה, עברו מרחב שם)
--   p_gone_titles  - כותרות שנשאלו ואין להן ערך חי; שורה שמחזיקה בכותרת כזו ומזהה שלה אינו חי נמחקת
-- מחיקה לפי כותרת בלבד אינה קיימת: זה מה שמחק את "Morphine" (הפניה שנמחקה לפי כותרת, בזמן שהשורה של הדף שהועבר
-- עוד נשאה את הכותרת הישנה). כאן הדף שהועבר נמצא ב-p_live בכותרתו החדשה, ולכן אינו נפגע.
--
-- הערה תפעולית: בגופי הפונקציות כאן יש `delete from`. ה-MCP של סופרבייס (apply_migration) נתקע על זה; מחילים
-- בעורך ה-SQL של סופרבייס (או psql), לא דרך ה-MCP. הבדיקות המקומיות מריצות אותה כרגיל.

create or replace function api.sync_apply_wiki_pages(
    p_live jsonb, p_gone_ids bigint[] default '{}', p_gone_titles text[] default '{}')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_deleted integer := 0;
    v_rows integer;
    v_inserted integer;
    v_updated integer;
    v_ids bigint[];
    v_gap integer;
begin
    if exists (select 1 from jsonb_to_recordset(p_live) as l(page_id bigint) group by page_id having count(*) > 1)
       or exists (select 1 from jsonb_to_recordset(p_live) as l(title text) group by title having count(*) > 1) then
        raise exception 'duplicate page_id or title in p_live' using errcode = '22023';
    end if;

    select coalesce(array_agg(page_id), '{}') into v_ids from jsonb_to_recordset(p_live) as l(page_id bigint);

    -- מזהים שנעלמו (אלא אם הם גם חיים בקלט: אז המצב החי גובר)
    delete from mirror.wiki_page w
    where w.page_id = any (p_gone_ids) and not (w.page_id = any (v_ids));
    get diagnostics v_rows = row_count; v_deleted := v_deleted + v_rows;

    -- כותרות שנעלמו: רק שורה שהמזהה שלה אינו חי
    delete from mirror.wiki_page w
    where w.title = any (p_gone_titles) and not (w.page_id = any (v_ids));
    get diagnostics v_rows = row_count; v_deleted := v_deleted + v_rows;

    -- פינוי כותרות: דף חי שהכותרת שלו השתנתה עובר לכותרת זמנית ייחודית, כך שהחלפות והעברות שרשרת לא מתנגשות
    update mirror.wiki_page w set title = '#tmp-' || w.page_id
    from jsonb_to_recordset(p_live) as l(page_id bigint, title text)
    where w.page_id = l.page_id and w.title <> l.title;

    -- שורה מיושנת (מזהה שאינו בקלט) שמחזיקה כותרת של דף חי: נמחקת
    delete from mirror.wiki_page w
    using jsonb_to_recordset(p_live) as l(page_id bigint, title text)
    where w.title = l.title and w.page_id <> l.page_id and not (w.page_id = any (v_ids));
    get diagnostics v_rows = row_count; v_deleted := v_deleted + v_rows;

    with up as (
        insert into mirror.wiki_page as w (page_id, title, latest_rev_id)
        select l.page_id, l.title, l.latest_rev_id
        from jsonb_to_recordset(p_live) as l(page_id bigint, title text, latest_rev_id bigint)
        on conflict (page_id) do update
            set title = excluded.title,
                latest_rev_id = coalesce(excluded.latest_rev_id, w.latest_rev_id)
            where w.title is distinct from excluded.title
               or (excluded.latest_rev_id is not null and w.latest_rev_id is distinct from excluded.latest_rev_id)
        returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_inserted, v_updated from up;

    v_gap := derived.refresh_wiki_gap(v_ids || p_gone_ids);
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap);
end;
$$;

create or replace function api.sync_apply_mech_pages(
    p_live jsonb, p_gone_ids bigint[] default '{}', p_gone_titles text[] default '{}')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_deleted integer := 0;
    v_rows integer;
    v_inserted integer;
    v_updated integer;
    v_ids bigint[];
    v_keys text[] := '{}';
    v_old text[];
    v_gone text[];
    v_wiki_ids bigint[];
    v_gap integer;
begin
    if exists (select 1 from jsonb_to_recordset(p_live) as l(page_id bigint) group by page_id having count(*) > 1)
       or exists (select 1 from jsonb_to_recordset(p_live) as l(title text) group by title having count(*) > 1) then
        raise exception 'duplicate page_id or title in p_live' using errcode = '22023';
    end if;

    select coalesce(array_agg(page_id), '{}') into v_ids from jsonb_to_recordset(p_live) as l(page_id bigint);

    -- הכותרות שמשתנות או נמחקות (לחישוב מחדש של "חסר" בצד ויקיפדיה)
    select coalesce(array_agg(w.title), '{}') into v_old
    from mirror.mech_page w
    join jsonb_to_recordset(p_live) as l(page_id bigint, title text) on l.page_id = w.page_id
    where w.title <> l.title;

    with d as (
        delete from mirror.mech_page w
        where w.page_id = any (p_gone_ids) and not (w.page_id = any (v_ids))
        returning w.title
    ), d2 as (
        delete from mirror.mech_page w
        where w.title = any (p_gone_titles) and not (w.page_id = any (v_ids))
          and not (w.page_id = any (p_gone_ids))
        returning w.title
    )
    select coalesce((select array_agg(title) from d), '{}') || coalesce((select array_agg(title) from d2), '{}'),
           (select count(*) from d) + (select count(*) from d2)
    into v_gone, v_rows;
    v_deleted := v_deleted + v_rows;

    update mirror.mech_page w set title = '#tmp-' || w.page_id
    from jsonb_to_recordset(p_live) as l(page_id bigint, title text)
    where w.page_id = l.page_id and w.title <> l.title;

    with s as (
        delete from mirror.mech_page w
        using jsonb_to_recordset(p_live) as l(page_id bigint, title text)
        where w.title = l.title and w.page_id <> l.page_id and not (w.page_id = any (v_ids))
        returning w.title
    )
    select v_gone || coalesce(array_agg(title), '{}'), v_deleted + count(*) into v_gone, v_deleted from s;

    with up as (
        insert into mirror.mech_page as m (page_id, title, status, source_type, needs_attention, is_dictionary)
        select l.page_id, l.title, l.status, coalesce(l.source_type, 'unknown'),
               coalesce(l.needs_attention, false), coalesce(l.is_dictionary, false)
        from jsonb_to_recordset(p_live) as l(page_id bigint, title text, status text, source_type text,
                                             needs_attention boolean, is_dictionary boolean)
        on conflict (page_id) do update
            set title = excluded.title, status = excluded.status, source_type = excluded.source_type,
                needs_attention = excluded.needs_attention, is_dictionary = excluded.is_dictionary
            where (m.title, m.status, m.source_type, m.needs_attention, m.is_dictionary)
                  is distinct from (excluded.title, excluded.status, excluded.source_type,
                                    excluded.needs_attention, excluded.is_dictionary)
        returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_inserted, v_updated from up;

    -- מפתחות הכותרות שהושפעו (חדשות, ישנות ומחוקות) ווריאציות הרב/רבי שלהן
    select coalesce(array_agg(distinct k), '{}') into v_keys from (
        select mirror.title_key(t) as k from unnest(v_old || v_gone) as t
        union select mirror.title_key(l.title) from jsonb_to_recordset(p_live) as l(title text)
    ) x;
    select coalesce(array_agg(w.page_id), '{}') into v_wiki_ids
    from mirror.wiki_page w
    where mirror.title_key(w.title) = any (v_keys)
       or mirror.rav_strip(mirror.title_key(w.title)) = any (v_keys)
       or mirror.title_key(w.title) = any (select 'הרב ' || k from unnest(v_keys) as k)
       or mirror.title_key(w.title) = any (select 'רבי ' || k from unnest(v_keys) as k);

    v_gap := derived.refresh_wiki_gap(v_wiki_ids);
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap, 'wiki_refreshed', cardinality(v_wiki_ids));
end;
$$;

-- אירועים (מקור המידע של דוחות; לא משפיעים על המצב). אידמפוטנטי.
create or replace function api.sync_record_events(p_events jsonb, p_run uuid default null)
returns integer
language sql
set search_path = ''
as $$
    with ins as (
        insert into mirror.page_event (site, kind, page_id, title, new_title, ts, run_id)
        select e.site, e.kind, e.page_id, e.title, e.new_title, e.ts, p_run
        from jsonb_to_recordset(p_events) as e(site text, kind text, page_id bigint, title text, new_title text, ts timestamptz)
        on conflict (site, kind, page_id, ts, title) do nothing
        returning 1
    )
    select count(*)::integer from ins;
$$;

-- ריצה: התחלה וסיום. נקודת ההתקדמות מתקדמת רק בסיום מוצלח, באותה טרנזקציה עם רישום הריצה.
create or replace function api.sync_run_start(p_kind text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_run uuid;
begin
    insert into ops.sync_run (kind, watermark_before)
    values (p_kind, (select coalesce(jsonb_object_agg(site || '/' || stream, ts), '{}') from ops.watermark))
    returning run_id into v_run;
    return jsonb_build_object('run_id', v_run,
        'watermarks', (select coalesce(jsonb_object_agg(site || '/' || stream, ts), '{}') from ops.watermark));
end;
$$;

create or replace function api.sync_run_finish(
    p_run uuid, p_status text, p_stats jsonb default '{}', p_error text default null, p_watermarks jsonb default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
    k text;
begin
    if p_status not in ('succeeded', 'failed', 'cancelled') then
        raise exception 'bad status %', p_status using errcode = '22023';
    end if;
    if p_status = 'succeeded' and p_watermarks is not null then
        for k in select jsonb_object_keys(p_watermarks) loop
            insert into ops.watermark (site, stream, ts)
            values (split_part(k, '/', 1), split_part(k, '/', 2), (p_watermarks ->> k)::timestamptz)
            on conflict (site, stream) do update set ts = excluded.ts;
        end loop;
    end if;
    update ops.sync_run
       set status = p_status, finished_at = now(), stats = p_stats, error = p_error,
           watermark_after = case when p_status = 'succeeded' then p_watermarks end
     where run_id = p_run;
end;
$$;

-- RPC של הקולקטור פתוחים ל-service_role בלבד (ברירת המחדל של הסכמה כבר שוללת מ-anon/authenticated; מפורש גם כאן)
revoke all on function
    api.sync_apply_wiki_pages(jsonb, bigint[], text[]), api.sync_apply_mech_pages(jsonb, bigint[], text[]),
    api.sync_record_events(jsonb, uuid), api.sync_run_start(text),
    api.sync_run_finish(uuid, text, jsonb, text, jsonb)
    from public, anon, authenticated;
grant execute on function
    api.sync_apply_wiki_pages(jsonb, bigint[], text[]), api.sync_apply_mech_pages(jsonb, bigint[], text[]),
    api.sync_record_events(jsonb, uuid), api.sync_run_start(text),
    api.sync_run_finish(uuid, text, jsonb, text, jsonb)
    to service_role;
