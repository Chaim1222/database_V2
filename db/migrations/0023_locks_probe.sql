-- 0023: זיהוי כותרות נעולות ליצירה (N6/N8; v1: check_missing_locked.py). קבוצת העשרה חדשה `locks`: לכל דף "חסר" נשאלת רמת הנעילה
-- (allevel) במכלול. create: החרגה מ"חסר" (work.exclusion locked_create); read: work.page_lock; כל רמה אחרת רק נרשמת כנבדקה.
-- רענון: 30 יום. api.enrich_pending ו-api.sync_apply_enrichment מוחלפות (כל הקבוצות הקיימות נשמרות).

alter table enrich.wiki_enrichment add column if not exists locks_checked_at timestamptz;

create or replace function api.enrich_pending(p_group text, p_after bigint default 0, p_limit integer default 500)
returns table (wiki_id bigint, title text)
language plpgsql
stable
set search_path = ''
as $$
begin
    if p_group not in ('created', 'length', 'desc', 'redirect', 'locks') then
        raise exception 'bad group %', p_group using errcode = '22023';
    end if;
    return query
    select g.wiki_id, w.title
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    where g.kind = 'missing' and g.wiki_id > p_after
      and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                      and (x.wiki_id = g.wiki_id or x.title = w.title))
      and case p_group
              when 'created'  then e.created_checked_at is null
              when 'length'   then e.length_checked_at is null or e.length_checked_at < now() - interval '7 days'
              when 'desc'     then e.desc_checked_at is null or e.desc_checked_at < now() - interval '30 days'
              when 'locks'    then e.locks_checked_at is null or e.locks_checked_at < now() - interval '30 days'
              else                 e.redirect_checked_at is null or e.redirect_checked_at < now() - interval '1 day'
          end
    order by g.wiki_id
    limit p_limit;
end;
$$;

-- p_rows: [{wiki_id, created_at?, length?, wikidata_desc?, mech_redirect?}] עבור קבוצה אחת. ערך ריק נשמר כ"נבדק".
create or replace function api.sync_apply_enrichment(p_group text, p_rows jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
    v_n integer;
begin
    if p_group = 'created' then
        insert into enrich.wiki_enrichment as e (wiki_id, wiki_created_at, created_checked_at)
        select r.wiki_id, r.created_at, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, created_at timestamptz)
        on conflict (wiki_id) do update set wiki_created_at = excluded.wiki_created_at, created_checked_at = now();
    elsif p_group = 'length' then
        insert into enrich.wiki_enrichment as e (wiki_id, length, length_checked_at)
        select r.wiki_id, r.length, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, length bigint)
        on conflict (wiki_id) do update set length = excluded.length, length_checked_at = now();
    elsif p_group = 'desc' then
        insert into enrich.wiki_enrichment as e (wiki_id, wikidata_desc, desc_checked_at)
        select r.wiki_id, r.wikidata_desc, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, wikidata_desc text)
        on conflict (wiki_id) do update set wikidata_desc = excluded.wikidata_desc, desc_checked_at = now();
    elsif p_group = 'locks' then
        -- p_rows: [{wiki_id, title, allevel, pageid}]. create: כותרת שאי אפשר ליצור במכלול (החרגה, לא ייבוא);
        -- read: דף קיים במכלול שנעול לקריאה (נעילה במקור אחד). none/אחר: רק נרשם שנבדק.
        insert into work.exclusion (kind, title, reason)
        select 'locked_create', r.title, 'allevel=create (זוהה אוטומטית)'
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, title text, allevel text, pageid bigint)
        where r.allevel = 'create' and r.title is not null
        on conflict do nothing;
        insert into work.page_lock (site, page_id, level, detected_by)
        select 'mechalol', r.pageid, 'read', 'missing_check'
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, title text, allevel text, pageid bigint)
        where r.allevel = 'read' and r.pageid is not null
        on conflict (site, page_id) do nothing;
        insert into enrich.wiki_enrichment as e (wiki_id, locks_checked_at)
        select r.wiki_id, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint)
        on conflict (wiki_id) do update set locks_checked_at = now();
    elsif p_group = 'redirect' then
        insert into enrich.wiki_enrichment as e (wiki_id, mech_redirect, redirect_checked_at)
        select r.wiki_id, r.mech_redirect, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, mech_redirect boolean)
        on conflict (wiki_id) do update set mech_redirect = excluded.mech_redirect, redirect_checked_at = now();
    else
        raise exception 'bad group %', p_group using errcode = '22023';
    end if;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

create or replace function api.sync_apply_enrichment(p_group text, p_rows jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
    v_n integer;
begin
    if p_group = 'created' then
        insert into enrich.wiki_enrichment as e (wiki_id, wiki_created_at, created_checked_at)
        select r.wiki_id, r.created_at, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, created_at timestamptz)
        on conflict (wiki_id) do update set wiki_created_at = excluded.wiki_created_at, created_checked_at = now();
    elsif p_group = 'length' then
        insert into enrich.wiki_enrichment as e (wiki_id, length, length_checked_at)
        select r.wiki_id, r.length, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, length bigint)
        on conflict (wiki_id) do update set length = excluded.length, length_checked_at = now();
    elsif p_group = 'desc' then
        insert into enrich.wiki_enrichment as e (wiki_id, wikidata_desc, desc_checked_at)
        select r.wiki_id, r.wikidata_desc, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, wikidata_desc text)
        on conflict (wiki_id) do update set wikidata_desc = excluded.wikidata_desc, desc_checked_at = now();
    elsif p_group = 'locks' then
        -- p_rows: [{wiki_id, title, allevel, pageid}]. create: כותרת שאי אפשר ליצור במכלול (החרגה, לא ייבוא);
        -- read: דף קיים במכלול שנעול לקריאה (נעילה במקור אחד). none/אחר: רק נרשם שנבדק.
        insert into work.exclusion (kind, title, reason)
        select 'locked_create', r.title, 'allevel=create (זוהה אוטומטית)'
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, title text, allevel text, pageid bigint)
        where r.allevel = 'create' and r.title is not null
        on conflict do nothing;
        insert into work.page_lock (site, page_id, level, detected_by)
        select 'mechalol', r.pageid, 'read', 'missing_check'
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, title text, allevel text, pageid bigint)
        where r.allevel = 'read' and r.pageid is not null
        on conflict (site, page_id) do nothing;
        insert into enrich.wiki_enrichment as e (wiki_id, locks_checked_at)
        select r.wiki_id, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint)
        on conflict (wiki_id) do update set locks_checked_at = now();
    elsif p_group = 'redirect' then
        insert into enrich.wiki_enrichment as e (wiki_id, mech_redirect, redirect_checked_at)
        select r.wiki_id, r.mech_redirect, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, mech_redirect boolean)
        on conflict (wiki_id) do update set mech_redirect = excluded.mech_redirect, redirect_checked_at = now();
    else
        raise exception 'bad group %', p_group using errcode = '22023';
    end if;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

revoke all on function api.enrich_pending(text, bigint, integer), api.sync_apply_enrichment(text, jsonb) from public, anon, authenticated;
grant execute on function api.enrich_pending(text, bigint, integer), api.sync_apply_enrichment(text, jsonb) to service_role;
-- דפים שהוחרגו (נעולים ליצירה או הוחרגו ידנית) אינם מועשרים ואינם נסרקים: אותו תנאי כמו ב-v_missing
create or replace function api.scan_pending(p_after bigint default 0, p_limit integer default 1000)
returns table (wiki_id bigint, title text, wikidata_desc text, scan_rev_id bigint, scan_lists_version text, scan_topic text)
language sql
stable
set search_path = ''
as $$
    select g.wiki_id, w.title, e.wikidata_desc, s.rev_id, s.lists_version, s.topic
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    left join enrich.content_scan s on s.wiki_id = g.wiki_id
    where g.kind = 'missing' and g.wiki_id > p_after
      and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                      and (x.wiki_id = g.wiki_id or x.title = w.title))
    order by g.wiki_id
    limit p_limit;
$$;
revoke all on function api.scan_pending(bigint, integer) from public, anon, authenticated;
grant execute on function api.scan_pending(bigint, integer) to service_role;
insert into ops.schema_migration (version) values ('0023') on conflict do nothing;
