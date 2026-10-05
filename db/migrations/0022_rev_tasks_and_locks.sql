-- 0022: (א) ops.schema_migration, כמו בתכנון (סעיף 4.5); (ב) תבנית: גרסה (`גרסה=`) וכותרת (`דף=`) נשמרות ב-template_check,
-- ונעילות קריאה שזוהו בבדיקה נרשמות ב-work.page_lock (מקור אחד, סעיף 4.4); (ג) משימות גרסה (N7): api.rev_scope ו-api.sync_apply_rev_checks.
-- sync_apply_template_checks ו-sync_apply_rev_checks מכילות `delete from`: להחיל בעורך ה-SQL של סופרבייס.

create table if not exists ops.schema_migration (
    version    text primary key,
    applied_at timestamptz not null default now()
);
alter table ops.schema_migration enable row level security;
insert into ops.schema_migration (version)
select v from unnest(array['0001','0002','0003','0004','0005','0006','0007','0008','0009','0010','0011','0012','0013','0014','0015','0016','0017','0018','0019','0020','0021','0022']) as v
on conflict do nothing;

alter table derived.template_check add column if not exists template_rev bigint, add column if not exists template_title text;

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

    create temp table _tc as
    select r.mech_id, r.rev_id, r.template_ref, r.template_rev, r.template_title,
           case when r.outcome = 'ok' and not exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then 'unresolved' else r.outcome end as outcome,
           case when r.outcome = 'ok' and exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then r.wiki_id end as wiki_id
    from jsonb_to_recordset(p_rows) as r(mech_id bigint, outcome text, rev_id bigint, wiki_id bigint, template_ref text, template_rev bigint, template_title text);

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

revoke all on function api.sync_apply_template_checks(jsonb) from public, anon, authenticated;
grant execute on function api.sync_apply_template_checks(jsonb) to service_role;

-- היקף בדיקת הגרסאות (כמו v1: מתועד, לא מילוני, לא דף טיפול, לא נעול לקריאה). linked_wiki_id: דף ויקיפדיה שהערך מקושר אליו
-- (תבנית שאומתה, שיוך ידני, או אותה כותרת). שיוך ידני = טופל, ולכן מחוץ להיקף.
create or replace function api.rev_scope(p_after bigint default 0, p_limit integer default 2000)
returns table (mech_id bigint, title text, template_rev bigint, template_title text, linked_wiki_id bigint)
language sql
stable
set search_path = ''
as $$
    select m.page_id, m.title, c.template_rev, c.template_title,
           coalesce(l.wiki_id, (select w.page_id from mirror.wiki_page w where mirror.title_key(w.title) = mirror.title_key(m.title) limit 1))
    from mirror.mech_page m
    join derived.template_check c on c.mech_id = m.page_id
    left join derived.template_link l on l.mech_id = m.page_id
    where m.page_id > p_after
      and m.status = 'imported_documented' and not m.is_dictionary and not m.needs_attention
      and c.outcome <> 'denied'
      and not exists (select 1 from work.manual_link x where x.mech_id = m.page_id)
    order by m.page_id
    limit p_limit;
$$;

-- p_rows: ממצאים [{mech_id, rev_task, rev_id, linked_wiki_id, rev_page_id, rev_page_title}]; p_scope_ids: כל המזהים שנבדקו
-- (שורה קיימת של מזהה שנבדק ואינה בממצאים נמחקת: תוקן). אידמפוטנטית.
create or replace function api.sync_apply_rev_checks(p_rows jsonb, p_scope_ids bigint[])
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_up integer;
    v_del integer;
begin
    insert into derived.rev_check as r (mech_id, rev_task, rev_id, linked_wiki_id, rev_page_id, rev_page_title, checked_at)
    select f.mech_id, f.rev_task, f.rev_id, f.linked_wiki_id, f.rev_page_id, f.rev_page_title, now()
    from jsonb_to_recordset(p_rows) as f(mech_id bigint, rev_task text, rev_id bigint, linked_wiki_id bigint, rev_page_id bigint, rev_page_title text)
    on conflict (mech_id) do update set rev_task = excluded.rev_task, rev_id = excluded.rev_id, linked_wiki_id = excluded.linked_wiki_id,
        rev_page_id = excluded.rev_page_id, rev_page_title = excluded.rev_page_title, checked_at = now();
    get diagnostics v_up = row_count;
    delete from derived.rev_check r
    where r.mech_id = any (p_scope_ids)
      and not exists (select 1 from jsonb_to_recordset(p_rows) as f(mech_id bigint) where f.mech_id = r.mech_id);
    get diagnostics v_del = row_count;
    perform ops.refresh_counts();
    return jsonb_build_object('written', v_up, 'removed', v_del);
end;
$$;
revoke all on function api.rev_scope(bigint, integer), api.sync_apply_rev_checks(jsonb, bigint[]) from public, anon, authenticated;
grant execute on function api.rev_scope(bigint, integer), api.sync_apply_rev_checks(jsonb, bigint[]) to service_role;
