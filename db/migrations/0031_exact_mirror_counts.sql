-- 0031: ספירה מדויקת נשמרת באותה טרנזקציה של שינוי במראה.
-- count(*) מלא נמדד בייצור בכ-1.9 שניות לטבלת המכלול, ולכן אינו חוזר בכל refresh_counts.
-- Transition tables סופרות רק את השורות שנוספו/נמחקו בפועל, גם ב-ON CONFLICT ובהרצה חוזרת.
lock table mirror.wiki_page, mirror.mech_page in share row exclusive mode;
create table ops.mirror_count (
    key text primary key check (key in ('wiki_pages', 'mech_pages')),
    n bigint not null check (n >= 0)
);
alter table ops.mirror_count enable row level security;
grant select, insert, update on ops.mirror_count to service_role;
insert into ops.mirror_count (key, n) values
    ('wiki_pages', (select count(*) from mirror.wiki_page)),
    ('mech_pages', (select count(*) from mirror.mech_page));

create or replace function ops.track_mirror_count()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_delta bigint;
begin
    select count(*) into v_delta from changed_rows;
    if TG_OP = 'DELETE' then v_delta := -v_delta; end if;
    update ops.mirror_count set n = n + v_delta where key = TG_TABLE_NAME || 's';
    if not found then raise exception 'missing exact mirror counter'; end if;
    return null;
end;
$$;
revoke all on function ops.track_mirror_count() from public, anon, authenticated;
grant execute on function ops.track_mirror_count() to service_role;
create trigger wiki_count_insert after insert on mirror.wiki_page
referencing new table as changed_rows for each statement execute function ops.track_mirror_count();
create trigger wiki_count_delete after delete on mirror.wiki_page
referencing old table as changed_rows for each statement execute function ops.track_mirror_count();
create trigger mech_count_insert after insert on mirror.mech_page
referencing new table as changed_rows for each statement execute function ops.track_mirror_count();
create trigger mech_count_delete after delete on mirror.mech_page
referencing old table as changed_rows for each statement execute function ops.track_mirror_count();

create or replace function ops.refresh_counts()
returns void
language sql
set search_path = ''
as $$
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages', (select n from ops.mirror_count where key = 'wiki_pages'), now()),
        ('mech_pages', (select n from ops.mirror_count where key = 'mech_pages'), now()),
        ('missing', (select count(*) from derived.wiki_gap g
                     join mirror.wiki_page w on w.page_id = g.wiki_id
                     where g.kind = 'missing'
                       and not exists (select 1 from work.exclusion e where e.kind in ('import_excluded', 'locked_create') and e.wiki_id = g.wiki_id)
                       and not exists (select 1 from work.exclusion e where e.kind in ('import_excluded', 'locked_create') and e.title = w.title)), now()),
        ('rav_review', (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks', (select count(*) from work.page_lock), now()),
        ('rev_tasks', (select count(*) from api.v_rev_tasks), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
$$;
select ops.refresh_counts();
insert into ops.schema_migration (version) values ('0031') on conflict do nothing;
