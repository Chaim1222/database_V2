-- 0043: סיכום "חסר במכלול" (api.report_missing_word_filter_summary) מחושב מראש.
-- נמצא (14.10): במכונת Nano המסד בזיכרון מוחלף (swap כ-550MB), ובטעינה ראשונה אחרי שקט הסיכום החי לקח 2-3.3 שניות
-- (מול 259ms חם) - מעבר ל-3 שניות של anon יחד עם שאר הבקשות, ומכאן 500 בדשבורד.
-- התיקון: התוצאה (589 קבוצות) נשמרת כ-jsonb בשורה אחת, ומחושבת מחדש ב-ops.refresh_counts (סוף סנכרון, תחזוקה,
-- שינוי החרגה/קישור ידני) ובסוף העשרה וסריקה. מונה דורות (gen) עולה בכל כתיבה לחמש טבלאות הקלט; כשהשמור לא
-- מהדור הנוכחי, ה-view מחזיר את החישוב החי (כמו עד היום) - כך התוצאה לעולם אינה ישנה, רק לפעמים איטית.
-- שורה אחת עם jsonb ולא טבלה: בלי delete בתוך פונקציה (נתקע ב-MCP, ראו CLAUDE.md).
-- ספירת "missing" ב-dashboard_counts נלקחת מהסיכום (אותו היקף בדיוק) - החישוב הכבד רץ פעם אחת ולא פעמיים.

create table ops.missing_summary (
    id boolean primary key default true check (id),
    gen bigint not null default 1,          -- עולה בכל שינוי בקלט
    built_gen bigint not null default 0,    -- הדור שעליו חושב rows
    built_at timestamptz,
    rows jsonb not null default '[]'
);
insert into ops.missing_summary default values;
alter table ops.missing_summary enable row level security;
create policy public_read on ops.missing_summary for select to anon, authenticated using (true);
grant select on ops.missing_summary to anon, authenticated;
grant select, update on ops.missing_summary to service_role;

-- החישוב החי (ההגדרה של 0038, ישירות מהטבלאות כמו report_missing_word_filter ב-0042)
create view ops.missing_summary_live with (security_invoker = true) as
select coalesce(mech_redirect, false) as redirect, has_images,
       case when scan_state = 'scanned' then verdict_list_a end as verdict,
       case when scan_state = 'scanned' then verdict_list_s end as verdict_suggested,
       case when scan_state = 'scanned' then verdict_ctx_a end as ctx_verdict,
       case when scan_state = 'scanned' then suspicion_a end as ctx_suspicion,
       case when scan_state = 'scanned' then verdict_ctx_s end as ctx_verdict_suggested,
       case when scan_state = 'scanned' then suspicion_s end as ctx_suspicion_suggested,
       dictionary is not null as dictionary, topic, count(*)::int as n, scan_state
from (
    select e.mech_redirect, s.has_images, s.verdict_list_a, s.verdict_list_s, s.verdict_ctx_a, s.suspicion_a,
           s.verdict_ctx_s, s.suspicion_s, s.dictionary, s.topic,
           case when s.wiki_id is null then 'not_scanned'
                when w.latest_rev_id is null or s.rev_id < w.latest_rev_id then 'stale'
                else 'scanned' end as scan_state
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    left join enrich.content_scan s on s.wiki_id = g.wiki_id
    where g.kind = 'missing'
      and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.wiki_id = g.wiki_id)
      and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and x.title = w.title)
) q
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12;
grant select on ops.missing_summary_live to anon, authenticated, service_role;

-- השמור כשהוא מהדור הנוכחי, אחרת החי. התנאים לא תלויים בשורה (One-Time Filter): הענף שלא נדרש לא רץ.
create or replace view api.report_missing_word_filter_summary with (security_invoker = true) as
select r.redirect, r.has_images, r.verdict, r.verdict_suggested, r.ctx_verdict, r.ctx_suspicion,
       r.ctx_verdict_suggested, r.ctx_suspicion_suggested, r.dictionary, r.topic, r.n, r.scan_state
from ops.missing_summary m
cross join jsonb_to_recordset(m.rows) as r(redirect boolean, has_images boolean, verdict text, verdict_suggested text,
    ctx_verdict text, ctx_suspicion text, ctx_verdict_suggested text, ctx_suspicion_suggested text,
    dictionary boolean, topic text, n int, scan_state text)
where m.built_gen = m.gen
union all
select l.redirect, l.has_images, l.verdict, l.verdict_suggested, l.ctx_verdict, l.ctx_suspicion,
       l.ctx_verdict_suggested, l.ctx_suspicion_suggested, l.dictionary, l.topic, l.n, l.scan_state
from ops.missing_summary_live l
where not exists (select 1 from ops.missing_summary m where m.built_gen = m.gen);

-- מונה הדורות. ברמת משפט (כתיבה גדולה = עדכון אחד); בהחרגות ברמת שורה ובשם שקודם ל-exclusion_refresh,
-- כדי שהרענון שבטריגר שלה יראה את הדור החדש (טריגרי שורה רצים לפני טריגרי משפט).
create or replace function ops.bump_missing_summary()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update ops.missing_summary set gen = gen + 1;
    return null;
end;
$$;
revoke all on function ops.bump_missing_summary() from public, anon, authenticated;

create trigger missing_summary_gen after insert or update or delete or truncate on derived.wiki_gap
for each statement execute function ops.bump_missing_summary();
create trigger missing_summary_gen after insert or update or delete or truncate on mirror.wiki_page
for each statement execute function ops.bump_missing_summary();
create trigger missing_summary_gen after insert or update or delete or truncate on enrich.wiki_enrichment
for each statement execute function ops.bump_missing_summary();
create trigger missing_summary_gen after insert or update or delete or truncate on enrich.content_scan
for each statement execute function ops.bump_missing_summary();
create trigger exclusion_gen after insert or update or delete on work.exclusion
for each row execute function ops.bump_missing_summary();
create trigger exclusion_gen_truncate after truncate on work.exclusion
for each statement execute function ops.bump_missing_summary();

-- הדור נקרא לפני החישוב: כתיבה שנכנסת באמצע משאירה את השמור "לא עדכני" (נופל לחי) עד הרענון הבא - אף פעם לא להפך.
create or replace function ops.refresh_missing_summary()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
    g bigint;
    r jsonb;
begin
    select gen into g from ops.missing_summary;
    select coalesce(jsonb_agg(to_jsonb(l)), '[]') into r from ops.missing_summary_live l;
    update ops.missing_summary set rows = r, built_gen = g, built_at = now();
    return (select coalesce(sum((x ->> 'n')::bigint), 0) from jsonb_array_elements(r) x);
end;
$$;
revoke all on function ops.refresh_missing_summary() from public, anon, authenticated;

create or replace function ops.refresh_counts()
returns void
language plpgsql
set search_path = ''
as $$
declare v_missing bigint := ops.refresh_missing_summary();
begin
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages', (select n from ops.mirror_count where key = 'wiki_pages'), now()),
        ('mech_pages', (select n from ops.mirror_count where key = 'mech_pages'), now()),
        ('missing', v_missing, now()),
        ('rav_review', (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks', (select count(*) from work.page_lock), now()),
        ('rev_tasks', (select count(*) from api.v_rev_tasks), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
end;
$$;

select ops.refresh_counts();
insert into ops.schema_migration (version) values ('0043');
