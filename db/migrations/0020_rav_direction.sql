-- 0020: תיקון: ערך מכלול עם תואר ("הרב כהן") מול דף ויקיפדיה בלי תואר ("כהן") לא נבדק בהחלה המצטברת, ולכן rav_review לא נוצר
-- (0 מול 191 ב-v1, התגלה בהשוואת הנתונים החיים). נוסף ענף שלישי בחיפוש דפי ויקיפדיה מושפעים. כל בדיקת t17 מכסה את שני הכיוונים.
-- אחרי החלה: לרענן את כל "חסר" פעם אחת (api.maintenance_refresh_gap בלולאה, או python -m collector.cli maintenance).
-- הפונקציה מכילה `delete from`: להחיל בעורך ה-SQL של סופרבייס.

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
    -- דפי ויקיפדיה שהמפתחות האלה משפיעים עליהם: אותה כותרת, או אותה כותרת עם הרב/רבי. שני ענפים עם `= any (מערך)`,
    -- כדי שהאינדקס על title_key ישמש (בגרסה הקודמת תנאי OR עם rav_strip וביטויי select גרמו לסריקה מלאה של 406 אלף שורות).
    select coalesce(array_agg(distinct w.page_id), '{}') into v_wiki_ids from (
        select w1.page_id from mirror.wiki_page w1 where mirror.title_key(w1.title) = any (v_keys)
        union all
        select w2.page_id from mirror.wiki_page w2
        where mirror.title_key(w2.title) = any (select p || k from unnest(v_keys) as k, unnest(array['הרב ', 'רבי ']) as p)
        union all
        -- הכיוון ההפוך: ערך מכלול עם תואר ("הרב כהן") מול דף ויקיפדיה בלי תואר ("כהן")
        select w3.page_id from mirror.wiki_page w3
        where mirror.title_key(w3.title) = any (select mirror.rav_strip(k) from unnest(v_keys) as k)
    ) w;
    v_wiki_ids := v_wiki_ids || v_link_wiki;
    v_gap := derived.refresh_wiki_gap(v_wiki_ids);
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap, 'wiki_refreshed', cardinality(v_wiki_ids));
end;
$$;

revoke all on function api.sync_apply_mech_pages(jsonb, bigint[], text[]) from public, anon, authenticated;
grant execute on function api.sync_apply_mech_pages(jsonb, bigint[], text[]) to service_role;

-- רענון מלא של wiki_gap במנות לפי מזהה ויקיפדיה (מנה אחת קצרה מספיק כדי לא לחרוג מ-statement timeout של ה-API).
-- מחזירה את המזהה האחרון שנבדק (להמשך) ואת מספר השורות שהשתנו; null כשנגמר.
create or replace function api.maintenance_refresh_gap(p_after bigint default 0, p_limit integer default 20000)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_ids bigint[];
    v_changed integer;
begin
    select array_agg(x.page_id) into v_ids from (
        select w.page_id from mirror.wiki_page w where w.page_id > p_after order by w.page_id limit p_limit) x;
    if v_ids is null then
        return jsonb_build_object('last_id', null, 'changed', 0);
    end if;
    v_changed := derived.refresh_wiki_gap(v_ids);
    perform ops.refresh_counts();
    return jsonb_build_object('last_id', v_ids[cardinality(v_ids)], 'changed', v_changed);
end;
$$;
revoke all on function api.maintenance_refresh_gap(bigint, integer) from public, anon, authenticated;
grant execute on function api.maintenance_refresh_gap(bigint, integer) to service_role;
