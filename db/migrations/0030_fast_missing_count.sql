-- 0030: ספירת "חסר" ב-ops.refresh_counts קראה ל-not exists עם OR בין שני אינדקסים (bitmap לכל שורה): 2.2 שניות, ואחרי ייבוא 2,233 החרגות
-- הגיעה לפסק זמן (57014) תחת עומס, וכך נכשלו api.maintenance_refresh_counts וגם sync_run_finish. שני not exists נפרדים נותנים
-- hash anti join: 70 מילישניות. אותה תוצאה בדיוק.
create or replace function ops.refresh_counts()
returns void
language sql
set search_path = ''
as $$
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages',   (select case when c.reltuples >= 0 then c.reltuples::bigint
                                      else (select count(*) from mirror.wiki_page) end
                           from pg_class c where c.oid = 'mirror.wiki_page'::regclass), now()),
        ('mech_pages',   (select case when c.reltuples >= 0 then c.reltuples::bigint
                                      else (select count(*) from mirror.mech_page) end
                           from pg_class c where c.oid = 'mirror.mech_page'::regclass), now()),
        ('missing',      (select count(*) from derived.wiki_gap g
                           join mirror.wiki_page w on w.page_id = g.wiki_id
                           where g.kind = 'missing'
                             and not exists (select 1 from work.exclusion e
                                             where e.kind in ('import_excluded', 'locked_create') and e.wiki_id = g.wiki_id)
                             and not exists (select 1 from work.exclusion e
                                             where e.kind in ('import_excluded', 'locked_create') and e.title = w.title)), now()),
        ('rav_review',   (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks',        (select count(*) from work.page_lock), now()),
        ('rev_tasks',    (select count(*) from derived.rev_check c
                           where not exists (select 1 from work.manual_link m where m.mech_id = c.mech_id)), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
$$;
insert into ops.schema_migration (version) values ('0030') on conflict do nothing;
