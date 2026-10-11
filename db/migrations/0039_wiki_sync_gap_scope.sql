-- 0039: Avoid rechecking gap membership for revision-only Wikipedia edits.
-- Same signature, permissions, atomic rename handling and deletion behavior.
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
    v_gap integer := 0;
    v_gap_ids bigint[];
begin
    if exists (select 1 from jsonb_to_recordset(p_live) as l(page_id bigint) group by page_id having count(*) > 1)
       or exists (select 1 from jsonb_to_recordset(p_live) as l(title text) group by title having count(*) > 1) then
        raise exception 'duplicate page_id or title in p_live' using errcode = '22023';
    end if;

    select coalesce(array_agg(page_id), '{}') into v_ids from jsonb_to_recordset(p_live) as l(page_id bigint);

    -- Revision-only edits cannot change title/link-based gap membership.
    -- Capture the affected identities before renames/upserts; the whole call stays atomic.
    select coalesce(array_agg(affected.page_id), '{}') into v_gap_ids
    from (
        select l.page_id
        from jsonb_to_recordset(p_live) as l(page_id bigint, title text)
        left join mirror.wiki_page w on w.page_id = l.page_id
        where w.page_id is null or w.title is distinct from l.title
        union
        -- Keep identities before title-based deletion/collision removes the mirror row.
        select w.page_id from mirror.wiki_page w
        where w.title = any(p_gone_titles) and not (w.page_id = any(v_ids))
        union
        select w.page_id from mirror.wiki_page w
        join jsonb_to_recordset(p_live) as l(page_id bigint, title text) on l.title = w.title
        where l.page_id <> w.page_id and not (w.page_id = any(v_ids))
    ) affected;

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

    if cardinality(v_gap_ids || p_gone_ids) > 0 then
        v_gap := derived.refresh_wiki_gap(v_gap_ids || p_gone_ids);
    end if;
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap);
end;
$$;

insert into ops.schema_migration(version) values ('0039');
