-- 0040: זהות דרך העברה בוויקיפדיה, ותוקף תוצאת הסינון.
--
-- 1. ערך מכלול שתבנית המיון שלו מצביעה על אותה כותרת (outcome = same) כוסה רק לפי כותרת. כשוויקיפדיה
--    מעבירה את הדף, הכותרת נשברת והדף הופיע ב"חסר במכלול" למרות שהערך קיים בשם הקודם (ממצא 13.10: כל
--    17 ההעברות במרחב הערכים). התבנית מצביעה על הכותרת הישנה, שבעת ההעברה הייתה של אותו מזהה; לכן נשמר
--    קישור תבנית לפי מזהה, באותו מסלול של "תבנית שאומתה". אין קישור כשדף חי אחר מחזיק עכשיו בשם הישן
--    (אז אין הוכחה לאיזה דף התבנית התכוונה). v_moves כבר מציג משימה גם כשיש קישור לאותו מזהה.
--    (א) sync_apply_wiki_pages: קישור בזמן החלת ההעברה, באותה טרנזקציה, לפני חישוב החסרים.
--    (ב) sync_apply_template_checks: בדיקה חוזרת שמחזירה same לאותו שם בתבנית משמרת את הקישור.
--    (ג) תיקון חד-פעמי מהיסטוריית האירועים (mirror.page_event) להעברות שכבר הוחלו.
-- 2. scan_state: "stale" רק כשהגרסה שנסרקה קודמת לגרסה שבמראה. גרסה שנסרקה חדשה מהמראה (הסורק קרא אחרי
--    הסנכרון) אינה תוצאה ישנה. גרסה אחרונה לא ידועה נשארת stale: אין הוכחה לטריות.

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
    v_moved_ids bigint[];
    v_moved_old text[];
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

    -- העברות: המזהה והכותרת הקודמת, לפני שהכותרת מוחלפת
    select coalesce(array_agg(w.page_id), '{}'), coalesce(array_agg(w.title), '{}') into v_moved_ids, v_moved_old
    from mirror.wiki_page w
    join jsonb_to_recordset(p_live) as l(page_id bigint, title text) on l.page_id = w.page_id
    where w.title <> l.title;

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

    -- זהות דרך העברה (ראו כותרת המיגרציה); המזהים כבר ב-v_gap_ids כי הכותרת שלהם השתנתה
    perform derived.link_moved_templates(v_moved_ids, v_moved_old);

    if cardinality(v_gap_ids || p_gone_ids) > 0 then
        v_gap := derived.refresh_wiki_gap(v_gap_ids || p_gone_ids);
    end if;
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap);
end;
$$;

-- קישור תבנית לדף שהועבר: ערכי מכלול שהתבנית שלהם אומתה כאותה כותרת כמו השם הקודם של הדף.
-- נדרש: הדף עדיין חי במראה בשם אחר, ואף דף חי אחר אינו מחזיק בשם הקודם. קישור קיים אינו נדרס.
-- מחזיר את מספר הקישורים שנוספו. לא מחשב חסרים: הקורא אחראי לרענון wiki_gap של המזהים.
create function derived.link_moved_templates(p_page_ids bigint[], p_old_titles text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
    v_n integer;
begin
    with moved as (
        select distinct u.page_id, mirror.title_key(u.old_title) as k
        from unnest(p_page_ids, p_old_titles) as u(page_id, old_title)
    ), target as (
        select mv.page_id, mv.k
        from moved mv
        join mirror.wiki_page w on w.page_id = mv.page_id and mirror.title_key(w.title) <> mv.k
        where not exists (select 1 from mirror.wiki_page o where mirror.title_key(o.title) = mv.k)
          and (select count(distinct m2.page_id) from moved m2 where m2.k = mv.k) = 1
    ), cand as (
        select c.mech_id, t.page_id, c.template_title
        from target t
        join mirror.mech_page m on mirror.title_key(m.title) = t.k
        join derived.template_check c on c.mech_id = m.page_id
        where c.outcome = 'same' and mirror.title_key(c.template_title) = t.k
          and not exists (select 1 from derived.template_link l where l.mech_id = c.mech_id)
    ), linked as (
        insert into derived.template_link (mech_id, wiki_id, template_ref, verified_at)
        select mech_id, page_id, template_title, now() from cand
        on conflict (mech_id) do nothing
        returning mech_id
    )
    update derived.template_check c set outcome = 'ok'
    from linked l where c.mech_id = l.mech_id;
    get diagnostics v_n = row_count;
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

    -- same לאותו שם בתבנית שכבר קושר דרך העברה (derived.link_moved_templates): הקישור לפי מזהה נשמר
    create temp table _tc as
    select r.mech_id, r.rev_id, coalesce(r.template_ref, keep.template_ref) as template_ref, r.template_rev, r.template_title,
           case when keep.wiki_id is not null then 'ok'
                when r.outcome = 'ok' and not exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then 'unresolved' else r.outcome end as outcome,
           case when keep.wiki_id is not null then keep.wiki_id
                when r.outcome = 'ok' and exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then r.wiki_id end as wiki_id
    from jsonb_to_recordset(p_rows) as r(mech_id bigint, outcome text, rev_id bigint, wiki_id bigint, template_ref text, template_rev bigint, template_title text)
    left join lateral (
        select t.wiki_id, t.template_ref
        from derived.template_link t
        join mirror.wiki_page w on w.page_id = t.wiki_id
        where r.outcome = 'same' and t.mech_id = r.mech_id
          and mirror.title_key(t.template_ref) = mirror.title_key(r.template_title)
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
    where t.mech_id = c.mech_id and c.outcome in ('none', 'same');

    insert into derived.template_link as t (mech_id, wiki_id, template_ref, verified_at)
    select mech_id, wiki_id, template_ref, now() from _tc where outcome in ('ok', 'unresolved')
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

-- תיקון חד-פעמי: העברות שכבר הוחלו לפני המיגרציה. כל העברה במרחב הערכים מהיסטוריית האירועים
-- (מזהה ושם קודם); הכללים זהים לסנכרון (אותה פונקציה). שם קודם שהיה של יותר ממזהה אחד מדולג.
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
    raise notice '0040: % template links restored from move history', v_linked;
end $$;

create or replace view api.report_missing_word_filter with (security_invoker = true) as
select m.id, m.title, m.checked_at, m.wikidata_desc, m.easy_import_length, m.created_at, m.mechalol_redirect_exists,
       s.verdict_list_a as verdict, s.verdict_list_s as verdict_suggested, s.has_images, s.photo_count, d.counts,
       s.matches_total, null::jsonb as images, s.scanned_at, s.verdict_ctx_a as ctx_verdict, s.suspicion_a as ctx_suspicion,
       s.verdict_ctx_s as ctx_verdict_suggested, s.suspicion_s as ctx_suspicion_suggested, s.hidden_count_a as hidden_count,
       s.hidden_count_s as hidden_count_suggested, s.dictionary, s.dictionary_why, s.topic, s.names_count_a as names_count,
       s.names_count_s as names_count_suggested,
       case when s.wiki_id is null then 'not_scanned'
            when w.latest_rev_id is null or s.rev_id < w.latest_rev_id then 'stale'
            else 'scanned' end as scan_state
from api.report_missing_from_mechalol m
join mirror.wiki_page w on w.page_id = m.id
left join enrich.content_scan s on s.wiki_id = m.id
left join api.word_filter_results d on d.wikipedia_id = m.id;

create or replace view api.v_missing with (security_invoker = true) as
select w.page_id as id, w.title, e.wiki_created_at as created_at, e.wikidata_desc, e.length,
       coalesce(e.mech_redirect, false) as mech_redirect, s.has_images, s.photo_count,
       s.verdict_list_a, s.verdict_list_s, s.verdict_ctx_a, s.verdict_ctx_s, s.suspicion_a, s.suspicion_s,
       s.hidden_count_a, s.hidden_count_s, s.names_count_a, s.names_count_s, s.matches_total,
       s.dictionary, s.dictionary_why, s.topic, s.scanned_at,
       case when s.wiki_id is null then 'not_scanned'
            when w.latest_rev_id is null or s.rev_id < w.latest_rev_id then 'stale'
            else 'scanned' end as scan_state
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = w.page_id
left join enrich.content_scan s on s.wiki_id = w.page_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x
                  where x.kind = any (array['import_excluded', 'locked_create'])
                    and (x.wiki_id = w.page_id or x.title = w.title));

select ops.refresh_counts();

insert into ops.schema_migration (version) values ('0040');
