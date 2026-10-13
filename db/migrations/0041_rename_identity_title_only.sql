-- 0041: גם ערך בלי תבנית מיון לא יוצא "חסר" בגלל העברה בוויקיפדיה (החלטת חיים, 13.10).
-- 0040 שמרה כיסוי דרך העברה רק לתבנית שאומתה לאותה כותרת. ערך שכוסה לפי כותרת בלבד (אין תבנית, או אין דף=)
-- יצא "חסר" כשוויקיפדיה העבירה את הדף (למשל "פיליפ לרקין"), ומופיע ממילא בטאב ההעברות. עכשיו גם הוא מקושר לפי
-- מזהה הדף שהועבר, באותם תנאים: הדף חי בשם אחר, אף דף חי אחר לא מחזיק בשם הקודם, והשם הקודם של מזהה אחד בלבד.
-- לא נכלל ערך שהתבנית שלו מצביעה על כותרת אחרת (ok/unresolved) או שלא נקרא (denied).
-- הקישור נשמר ב-derived.template_link (template_ref = השם הקודם); outcome של ערך בלי תבנית נשאר none.
-- בדיקה חוזרת שמחזירה none לערך שעדיין נושא את השם הקודם משמרת את הקישור.

create or replace function derived.link_moved_templates(p_page_ids bigint[], p_old_titles text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
    v_n integer;
begin
    with moved as (
        select distinct u.page_id, mirror.title_key(u.old_title) as k, u.old_title
        from unnest(p_page_ids, p_old_titles) as u(page_id, old_title)
    ), target as (
        select mv.page_id, mv.k, min(mv.old_title) as old_title
        from moved mv
        join mirror.wiki_page w on w.page_id = mv.page_id and mirror.title_key(w.title) <> mv.k
        where not exists (select 1 from mirror.wiki_page o where mirror.title_key(o.title) = mv.k)
          and (select count(distinct m2.page_id) from moved m2 where m2.k = mv.k) = 1
        group by mv.page_id, mv.k
    ), cand as (
        select m.page_id as mech_id, t.page_id, coalesce(c.template_title, t.old_title) as ref
        from target t
        join mirror.mech_page m on mirror.title_key(m.title) = t.k
        left join derived.template_check c on c.mech_id = m.page_id
        where (c.mech_id is null or c.outcome = 'none'
               or (c.outcome = 'same' and mirror.title_key(c.template_title) = t.k))
          and not exists (select 1 from derived.template_link l where l.mech_id = m.page_id)
    ), linked as (
        insert into derived.template_link (mech_id, wiki_id, template_ref, verified_at)
        select mech_id, page_id, ref, now() from cand
        on conflict (mech_id) do nothing
        returning mech_id
    ), promoted as (
        update derived.template_check c set outcome = 'ok'
        from linked l where c.mech_id = l.mech_id and c.outcome = 'same'
    )
    select count(*) into v_n from linked;
    return v_n;
end;
$$;
revoke all on function derived.link_moved_templates(bigint[], text[]) from public, anon, authenticated;

create or replace function api.sync_apply_template_checks(p_rows jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_old bigint[];
    v_new bigint[];
    v_gap integer;
    v_n integer;
begin
    if exists (select 1 from jsonb_to_recordset(p_rows) as r(mech_id bigint) group by mech_id having count(*) > 1) then
        raise exception 'duplicate mech_id in p_rows' using errcode = '22023';
    end if;

    -- קישור דרך העברה (derived.link_moved_templates) נשמר כשהבדיקה החוזרת קוראת את אותו שם:
    -- same לאותו שם בתבנית (הופך ל-ok), או none לערך שעדיין נושא את השם הקודם (נשאר none, הקישור נשמר)
    create temp table _tc as
    select r.mech_id, r.rev_id, coalesce(r.template_ref, keep.template_ref) as template_ref, r.template_rev, r.template_title,
           case when keep.wiki_id is not null and r.outcome = 'same' then 'ok'
                when r.outcome = 'ok' and not exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then 'unresolved' else r.outcome end as outcome,
           case when keep.wiki_id is not null then keep.wiki_id
                when r.outcome = 'ok' and exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then r.wiki_id end as wiki_id,
           keep.wiki_id is not null as keep_link
    from jsonb_to_recordset(p_rows) as r(mech_id bigint, outcome text, rev_id bigint, wiki_id bigint, template_ref text, template_rev bigint, template_title text)
    left join lateral (
        select t.wiki_id, t.template_ref
        from derived.template_link t
        join mirror.wiki_page w on w.page_id = t.wiki_id
        join mirror.mech_page m on m.page_id = r.mech_id
        where t.mech_id = r.mech_id
          and ((r.outcome = 'same' and mirror.title_key(t.template_ref) = mirror.title_key(r.template_title))
               or (r.outcome = 'none' and mirror.title_key(t.template_ref) = mirror.title_key(m.title)))
    ) keep on true;

    select coalesce(array_agg(t.wiki_id), '{}') into v_old
    from derived.template_link t join _tc c on c.mech_id = t.mech_id
    where t.wiki_id is not null and c.outcome <> 'denied';

    -- denied משאיר את גרסת התבנית והכותרת הקודמות (לא נקראו)
    insert into derived.template_check as k (mech_id, outcome, rev_id, template_rev, template_title, checked_at)
    select mech_id, outcome, rev_id, template_rev, template_title, now() from _tc
    on conflict (mech_id) do update set outcome = excluded.outcome, rev_id = excluded.rev_id, checked_at = now(),
        template_rev = case when excluded.outcome = 'denied' then k.template_rev else excluded.template_rev end,
        template_title = case when excluded.outcome = 'denied' then k.template_title else excluded.template_title end;
    get diagnostics v_n = row_count;

    delete from derived.template_link t
    using _tc c
    where t.mech_id = c.mech_id and c.outcome in ('none', 'same');   -- קישור שנשמר מוכנס מחדש מיד אחרי (keep_link)

    insert into derived.template_link as t (mech_id, wiki_id, template_ref, verified_at)
    select mech_id, wiki_id, template_ref, now() from _tc where outcome in ('ok', 'unresolved') or keep_link
    on conflict (mech_id) do update
        set wiki_id = excluded.wiki_id, template_ref = excluded.template_ref, verified_at = now();

    -- נעילות קריאה שזוהו בבדיקה: מקור אחד (work.page_lock); בדיקה מוצלחת מסירה נעילה שזוהתה כך
    insert into work.page_lock (site, page_id, level, detected_by, detected_at)
    select 'mechalol', mech_id, 'read', 'template_check', now() from _tc where outcome = 'denied'
    on conflict (site, page_id) do nothing;
    delete from work.page_lock l using _tc c
    where l.site = 'mechalol' and l.page_id = c.mech_id and l.detected_by = 'template_check' and c.outcome <> 'denied';

    select coalesce(array_agg(wiki_id), '{}') into v_new from _tc where wiki_id is not null;
    v_gap := derived.refresh_wiki_gap(v_old || v_new);
    drop table _tc;
    return jsonb_build_object('checked', v_n, 'gap_changed', v_gap);
end;
$$;

-- תיקון מהיסטוריית ההעברות לערכים בלי תבנית (כמו ב-0040)
do $$
declare
    v_ids bigint[];
    v_titles text[];
    v_linked integer;
begin
    select coalesce(array_agg(e.page_id), '{}'), coalesce(array_agg(e.title), '{}') into v_ids, v_titles
    from (select distinct page_id, title from mirror.page_event
          where site = 'wikipedia' and kind = 'move' and page_id > 0 and title is not null) e;
    v_linked := derived.link_moved_templates(v_ids, v_titles);
    perform derived.refresh_wiki_gap(array(select distinct unnest(v_ids)));
    raise notice '0041: % links restored from move history', v_linked;
end $$;

select ops.refresh_counts();

insert into ops.schema_migration (version) values ('0041');
