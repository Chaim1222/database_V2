-- 0012: אימות תבניות. derived.template_check שומרת את תוצאת הבדיקה לכל ערך מכלול (none/same/ok/unresolved/denied),
-- ו-derived.template_link נשארת דלילה: רק ok (wiki_id) ו-unresolved (בעיה בשם). ראו PLAN_STAGE4.md סעיף 4.1.
-- sync_apply_template_checks מכילה `delete from`: להחיל בעורך ה-SQL של סופרבייס, לא דרך ה-MCP.

create table derived.template_check (
    mech_id    bigint primary key,
    outcome    text not null check (outcome in ('none', 'same', 'ok', 'unresolved', 'denied')),
    rev_id     bigint,
    checked_at timestamptz not null default now()
);
create index template_check_outcome_idx on derived.template_check (outcome) where outcome in ('unresolved', 'denied');
alter table derived.template_check enable row level security;
create policy public_read on derived.template_check for select to anon, authenticated using (true);
grant select on derived.template_check to anon, authenticated;

-- ערכי מכלול מיובאים שטרם נבדקו (לפי מזהה, להמשך מהמקום שנפסק)
create or replace function api.template_pending(p_after bigint default 0, p_limit integer default 1000)
returns table (page_id bigint, title text)
language sql
stable
set search_path = ''
as $$
    select m.page_id, m.title
    from mirror.mech_page m
    where m.page_id > p_after
      and m.status in ('imported_documented', 'imported_undocumented')
      and not exists (select 1 from derived.template_check c where c.mech_id = m.page_id)
    order by m.page_id
    limit p_limit;
$$;

-- p_rows: [{mech_id, outcome, rev_id, wiki_id, template_ref}]. ok עם wiki_id שאינו דף חי הופך ל-unresolved.
-- denied משאיר את הקישור הקודם; none/same מסירים קישור קודם.
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
    select r.mech_id, r.rev_id, r.template_ref,
           case when r.outcome = 'ok' and not exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then 'unresolved' else r.outcome end as outcome,
           case when r.outcome = 'ok' and exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then r.wiki_id end as wiki_id
    from jsonb_to_recordset(p_rows) as r(mech_id bigint, outcome text, rev_id bigint, wiki_id bigint, template_ref text);

    select coalesce(array_agg(t.wiki_id), '{}') into v_old
    from derived.template_link t join _tc c on c.mech_id = t.mech_id
    where t.wiki_id is not null and c.outcome <> 'denied';

    insert into derived.template_check as k (mech_id, outcome, rev_id, checked_at)
    select mech_id, outcome, rev_id, now() from _tc
    on conflict (mech_id) do update set outcome = excluded.outcome, rev_id = excluded.rev_id, checked_at = now();
    get diagnostics v_n = row_count;

    delete from derived.template_link t
    using _tc c
    where t.mech_id = c.mech_id and c.outcome in ('none', 'same');

    insert into derived.template_link as t (mech_id, wiki_id, template_ref, verified_at)
    select mech_id, wiki_id, template_ref, now() from _tc where outcome in ('ok', 'unresolved')
    on conflict (mech_id) do update
        set wiki_id = excluded.wiki_id, template_ref = excluded.template_ref, verified_at = now();

    select coalesce(array_agg(wiki_id), '{}') into v_new from _tc where wiki_id is not null;
    v_gap := derived.refresh_wiki_gap(v_old || v_new);
    drop table _tc;
    return jsonb_build_object('checked', v_n, 'gap_changed', v_gap);
end;
$$;

revoke all on function api.template_pending(bigint, integer), api.sync_apply_template_checks(jsonb)
    from public, anon, authenticated;
grant execute on function api.template_pending(bigint, integer), api.sync_apply_template_checks(jsonb) to service_role;
