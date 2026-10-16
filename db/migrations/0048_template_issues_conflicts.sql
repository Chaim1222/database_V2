-- 0048: הטאב "בעיות תבנית" (api.v_template_issues) - בלי נעולים ונמחקים, ועם התנגשויות התאמה (בקשת חיים, 16.10).
-- (1) denied (דף נעול לקריאה) יוצא: כל דף כזה כבר נרשם ב-work.page_lock (0022) ומופיע בטאב "נעולים".
-- (2) unresolved שהדף שלו נמחק בוויקיפדיה לפי הגרסה (rev_task = deleted_by_rev) יוצא: מופיע בטאב "נמחקו לפי גרסה".
-- (3) נכנסות ההתנגשויות של api.match_conflicts (0019), שעד היום נרשמו רק בדוח השבועי:
--     template_vs_title - התבנית מצביעה לדף אחד, והכותרת זהה לדף אחר (שניהם נחשבים מכוסים);
--     disambig_same_title - פירושון שנוצר במכלול, וכותרתו זהה לדף בוויקיפדיה (הדף בוויקיפדיה נחשב מכוסה).
--     unrelated_same_title של ערך רגיל לא נכנס: במדגם של 30 כמעט כולם אותו נושא (סקירה 16.10).
-- ההתנגשויות לוקחות כ-5.5 שניות (נמדד 16.10, מכונת Nano) - מעבר ל-5 שניות של anon. לכן הן מחושבות מראש לשורה אחת
-- (כמו 0043, בלי delete בפונקציה) ב-api.maintenance_refresh_counts: אחרי העשרה (פעמיים ביום), תבניות, revcheck ותחזוקה.
-- לא ב-ops.refresh_counts: היא רצה גם בטריגרים של שיוך והחרגה (פעולת משתמש, 8 שניות).
-- רק תצוגה: החישוב של "חסר" (derived.refresh_wiki_gap) לא משתנה.

create table ops.match_conflict_snapshot (
    id boolean primary key default true check (id),
    built_at timestamptz,
    rows jsonb not null default '[]'
);
insert into ops.match_conflict_snapshot default values;
alter table ops.match_conflict_snapshot enable row level security;
create policy public_read on ops.match_conflict_snapshot for select to anon, authenticated using (true);
grant select on ops.match_conflict_snapshot to anon, authenticated;
grant select, update on ops.match_conflict_snapshot to service_role;

create or replace function ops.refresh_match_conflicts()
returns integer
language plpgsql
set search_path = ''
as $$
declare r jsonb;
begin
    select coalesce(jsonb_agg(to_jsonb(x) order by x.title, x.id), '[]') into r from (
        -- התבנית מצביעה לדף אחד; wikipedia_id/title - הדף בוויקיפדיה עם הכותרת הזהה
        select m.page_id as id, m.title, 'template_vs_title' as outcome, t.template_ref,
               w.page_id as wikipedia_id, w.title as wikipedia_title
        from derived.template_link t
        join mirror.mech_page m on m.page_id = t.mech_id
        join mirror.wiki_page w on mirror.title_key(w.title) = mirror.title_key(m.title) and w.page_id <> t.wiki_id
        where t.wiki_id is not null
        union all
        select m.page_id, m.title, 'disambig_same_title', null, w.page_id, w.title
        from mirror.mech_page m
        join mirror.wiki_page w on mirror.title_key(w.title) = mirror.title_key(m.title)
        where m.status = 'created_in_mech' and m.source_type = 'pirushon'
    ) x
    where not exists (select 1 from work.manual_link l where l.mech_id = x.id);
    update ops.match_conflict_snapshot set rows = r, built_at = now() where id;   -- WHERE: pg-safeupdate בסופבייס (0045)
    return jsonb_array_length(r);
end;
$$;
revoke all on function ops.refresh_match_conflicts() from public, anon, authenticated;

create or replace function api.maintenance_refresh_counts()
returns void
language sql
set search_path = ''
as $$ select ops.refresh_counts(); select ops.snapshot_metrics(); select ops.refresh_match_conflicts(); $$;
revoke all on function api.maintenance_refresh_counts() from public, anon, authenticated;
grant execute on function api.maintenance_refresh_counts() to service_role;

-- עמודות חדשות בסוף (create or replace view מוסיף עמודות רק בסוף). checked_at של התנגשות = זמן החישוב.
create or replace view api.v_template_issues with (security_invoker = true) as
select m.page_id as id, m.title, c.outcome, l.template_ref, c.checked_at,
       null::bigint as wikipedia_id, null::text as wikipedia_title
from derived.template_check c
join mirror.mech_page m on m.page_id = c.mech_id
left join derived.template_link l on l.mech_id = c.mech_id
where c.outcome = 'unresolved'
  and not exists (select 1 from work.manual_link x where x.mech_id = c.mech_id)
  and not exists (select 1 from api.v_rev_tasks r where r.id = c.mech_id and r.rev_task = 'deleted_by_rev')
union all
select r.id, r.title, r.outcome, r.template_ref, s.built_at, r.wikipedia_id, r.wikipedia_title
from ops.match_conflict_snapshot s
cross join jsonb_to_recordset(s.rows) as r(id bigint, title text, outcome text, template_ref text,
                                         wikipedia_id bigint, wikipedia_title text);
grant select on api.v_template_issues to anon, authenticated;

select ops.refresh_match_conflicts();

insert into ops.schema_migration (version) values ('0048');
