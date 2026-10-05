-- 0009: תיקונים מסקירה חיצונית (קומיט 43c5e52). כל סעיף מכוסה ב-db/tests/t08_review_fixes.sql.
--  1. refresh_wiki_gap: תבנית ושיוך ידני נחשבים רק כשערך המכלול קיים (אחרת מחיקת ערך לא החזירה "חסר").
--  2. sync_apply_mech_pages: מנקה template_link של ערכים שנעלמו, ומרעננת דפי ויקיפדיה שהותאמו אליהם בתבנית,
--     בשיוך ידני או בכלל סמנטי, גם כשהמחיקה הייתה לפי כותרת.
--  3. שיוך ידני (דרך פונקציה, מחיקה ב-RLS או ישירות) מרענן את wiki_gap והספירות (טריגר).
--  4. ספירת "חסר" מתעלמת מהחרגות לפי כותרת כמו v_missing; sync_run_finish מרענן ספירות.
--  5. mirror.page_event קריא ל-anon/authenticated (api.v_moves היא security_invoker).
--  6. api.sync_load_begin: נקודת תחילת הטעינה נשמרת בין ניסיונות עד שהטעינה מושלמת.
-- הפונקציה sync_apply_mech_pages מכילה `delete from`: להחיל בעורך ה-SQL של סופרבייס, לא דרך ה-MCP.

create or replace function derived.refresh_wiki_gap(p_ids bigint[] default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
    changed integer;
begin
    with scope as (
        select w.page_id, w.title, mirror.title_key(w.title) as k
        from mirror.wiki_page w
        where p_ids is null or w.page_id = any (p_ids)
    ), matched as (
        select s.page_id, s.k,
               (exists (select 1 from mirror.mech_page m where mirror.title_key(m.title) = s.k)
                or exists (select 1 from derived.mech_key mk where mk.wiki_candidate_key = s.k)
                or exists (select 1 from derived.template_link t
                           join mirror.mech_page m on m.page_id = t.mech_id where t.wiki_id = s.page_id)
                or exists (select 1 from work.manual_link x
                           join mirror.mech_page m on m.page_id = x.mech_id where x.wiki_id = s.page_id)) as strict_match
        from scope s
    ), target as (
        select m.page_id as wiki_id,
               case
                   when m.strict_match then null
                   when exists (select 1 from mirror.mech_page mm
                                where mm.title ~ '^(הרב|רבי)\s'
                                  and mirror.rav_strip(mirror.title_key(mm.title)) = m.k)
                        or (m.k ~ '^(הרב|רבי) '
                            and exists (select 1 from mirror.mech_page mm
                                        where mirror.title_key(mm.title) = mirror.rav_strip(m.k)))
                        then 'rav_review'
                   else 'missing'
               end as kind
        from matched m
    ), upserted as (
        insert into derived.wiki_gap as g (wiki_id, kind)
        select wiki_id, kind from target where kind is not null
        on conflict (wiki_id) do update set kind = excluded.kind
            where g.kind is distinct from excluded.kind
        returning 1
    ), removed as (
        delete from derived.wiki_gap g
        where (p_ids is null or g.wiki_id = any (p_ids))
          and not exists (select 1 from target t where t.wiki_id = g.wiki_id and t.kind is not null)
        returning 1
    )
    select (select count(*) from upserted) + (select count(*) from removed) into changed;
    return changed;
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
    v_ck text[];
    v_aff bigint[];
    v_link_wiki bigint[];
begin
    if exists (select 1 from jsonb_to_recordset(p_live) as l(page_id bigint) group by page_id having count(*) > 1)
       or exists (select 1 from jsonb_to_recordset(p_live) as l(title text) group by title having count(*) > 1) then
        raise exception 'duplicate page_id or title in p_live' using errcode = '22023';
    end if;

    select coalesce(array_agg(page_id), '{}') into v_ids from jsonb_to_recordset(p_live) as l(page_id bigint);

    -- הדפים המושפעים (לפני כל שינוי): חיים בקלט, מזהים שנעלמו, כותרות שנעלמו, ובעלי כותרת שדף חי תופס.
    -- מהם: המפתחות הסמנטיים שלהם, ודפי ויקיפדיה שקושרו אליהם בתבנית או בשיוך ידני (לרענון "חסר").
    select coalesce(array_agg(m.page_id), '{}') into v_aff
    from mirror.mech_page m
    where m.page_id = any (v_ids) or m.page_id = any (p_gone_ids) or m.title = any (p_gone_titles)
       or m.title = any (select l.title from jsonb_to_recordset(p_live) as l(title text));
    v_aff := v_aff || v_ids || p_gone_ids;
    select coalesce(array_agg(k.wiki_candidate_key), '{}') into v_ck from derived.mech_key k where k.mech_id = any (v_aff);
    select coalesce(array_agg(x.w), '{}') into v_link_wiki from (
        select t.wiki_id as w from derived.template_link t where t.mech_id = any (v_aff) and t.wiki_id is not null
        union select m.wiki_id from work.manual_link m where m.mech_id = any (v_aff)) x;

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

    -- כללים סמנטיים: נשמרים רק כשהכותרת השתנתה (שורה לכל דף חי שיש לו wiki_candidate_key; אחרת נמחקת)
    delete from derived.mech_key k
    where k.mech_id = any (v_ids) or not exists (select 1 from mirror.mech_page m where m.page_id = k.mech_id);
    insert into derived.mech_key (mech_id, wiki_candidate_key, rules)
    select l.page_id, l.wiki_candidate_key, coalesce(l.rules, '{}')
    from jsonb_to_recordset(p_live) as l(page_id bigint, wiki_candidate_key text, rules text[])
    where l.wiki_candidate_key is not null;
    delete from derived.template_link t
    where t.mech_id = any (v_aff) and not exists (select 1 from mirror.mech_page m where m.page_id = t.mech_id);
    select v_ck || coalesce(array_agg(l.wiki_candidate_key), '{}') into v_ck
    from jsonb_to_recordset(p_live) as l(wiki_candidate_key text) where l.wiki_candidate_key is not null;

    -- מפתחות הכותרות שהושפעו (חדשות, ישנות ומחוקות) ווריאציות הרב/רבי שלהן
    select coalesce(array_agg(distinct k), '{}') into v_keys from (
        select mirror.title_key(t) as k from unnest(v_old || v_gone || v_ck) as t
        union select mirror.title_key(l.title) from jsonb_to_recordset(p_live) as l(title text)
    ) x;
    select coalesce(array_agg(w.page_id), '{}') into v_wiki_ids
    from mirror.wiki_page w
    where mirror.title_key(w.title) = any (v_keys)
       or mirror.rav_strip(mirror.title_key(w.title)) = any (v_keys)
       or mirror.title_key(w.title) = any (select 'הרב ' || k from unnest(v_keys) as k)
       or mirror.title_key(w.title) = any (select 'רבי ' || k from unnest(v_keys) as k);

    v_wiki_ids := v_wiki_ids || v_link_wiki;
    v_gap := derived.refresh_wiki_gap(v_wiki_ids);
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap, 'wiki_refreshed', cardinality(v_wiki_ids));
end;
$$;

revoke all on function api.sync_apply_mech_pages(jsonb, bigint[], text[]) from public, anon, authenticated;
grant execute on function api.sync_apply_mech_pages(jsonb, bigint[], text[]) to service_role;

-- ===== ספירות =====
create or replace function ops.refresh_counts()
returns void
language sql
set search_path = ''
as $$
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages',   (select count(*) from mirror.wiki_page), now()),
        ('mech_pages',   (select count(*) from mirror.mech_page), now()),
        ('missing',      (select count(*) from derived.wiki_gap g
                           join mirror.wiki_page w on w.page_id = g.wiki_id
                           where g.kind = 'missing'
                             and not exists (select 1 from work.exclusion e
                                             where e.kind = 'import_excluded'
                                               and (e.wiki_id = g.wiki_id or e.title = w.title))), now()),
        ('rav_review',   (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks',        (select count(*) from work.page_lock), now()),
        ('rev_tasks',    (select count(*) from derived.rev_check c
                           where not exists (select 1 from work.manual_link m where m.mech_id = c.mech_id)), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
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
    if p_status = 'succeeded' then
        perform ops.refresh_counts();
    end if;
end;
$$;

-- ===== שיוך ידני והחרגות: רענון אוטומטי (גם מחיקה ישירה דרך מדיניות RLS) =====
create or replace function work.after_link_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform derived.refresh_wiki_gap(array_remove(array[
        case when tg_op <> 'INSERT' then old.wiki_id end,
        case when tg_op <> 'DELETE' then new.wiki_id end], null));
    perform ops.refresh_counts();
    return null;
end;
$$;
create trigger manual_link_refresh after insert or update or delete on work.manual_link
    for each row execute function work.after_link_change();

create or replace function work.after_exclusion_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform ops.refresh_counts();
    return null;
end;
$$;
create trigger exclusion_refresh after insert or update or delete on work.exclusion
    for each row execute function work.after_exclusion_change();
revoke all on function work.after_link_change(), work.after_exclusion_change() from public;

-- ===== דוח ההעברות =====
grant select on mirror.page_event to anon, authenticated;
create policy public_read on mirror.page_event for select to anon, authenticated using (true);

-- ===== טעינה ראשונית: נקודת תחילה נשמרת עד שהטעינה מושלמת =====
-- ניסיון שנכשל והופעל מחדש חייב להמשיך מאותה נקודה: מחיקה שקרתה בין הניסיונות אחרת הייתה נופלת מחוץ לחלון הדלתא.
-- נקודה חדשה נקבעת רק כשאין נקודה, או כשהטעינה הקודמת הושלמה (נקודת הדלתא התקדמה אליה או אחריה).
create or replace function api.sync_load_begin(p_site text)
returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
    v_start timestamptz;
    v_delta timestamptz;
begin
    select ts into v_start from ops.watermark where site = p_site and stream = 'load_start';
    select ts into v_delta from ops.watermark where site = p_site and stream = 'delta';
    if v_start is null or (v_delta is not null and v_delta >= v_start) then
        v_start := clock_timestamp();
        insert into ops.watermark (site, stream, ts) values (p_site, 'load_start', v_start)
        on conflict (site, stream) do update set ts = excluded.ts;
    end if;
    return v_start;
end;
$$;
revoke all on function api.sync_load_begin(text) from public, anon, authenticated;
grant execute on function api.sync_load_begin(text) to service_role;
