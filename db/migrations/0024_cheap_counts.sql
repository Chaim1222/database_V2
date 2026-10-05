-- 0024: ספירות זולות. ב-Supabase ספירה מדויקת של mirror.wiki_page ו-mirror.mech_page לקחה כ-7 שניות (סריקת אינדקס בלבד על 790 אלף שורות
-- בלי מפת נראות), וזה חרג מ-statement timeout של ה-API במנות התחזוקה (HTTP 500 / 57014) והעמיד את sync_run_finish קרוב לסף.
-- עכשיו: שני הספירות הגדולות הן הערכה מ-pg_class.reltuples (מתעדכנת ב-autovacuum/analyze; ללא מידע: ספירה מדויקת, כמו בטבלאות חדשות),
-- ושאר הספירות (חסר, נעולים וכו') נשארות מדויקות. maintenance_refresh_gap כבר אינה מרעננת ספירות במנה: api.maintenance_refresh_counts בסוף.

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
                                             where e.kind in ('import_excluded', 'locked_create')
                                               and (e.wiki_id = g.wiki_id or e.title = w.title))), now()),
        ('rav_review',   (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks',        (select count(*) from work.page_lock), now()),
        ('rev_tasks',    (select count(*) from derived.rev_check c
                           where not exists (select 1 from work.manual_link m where m.mech_id = c.mech_id)), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
$$;

create or replace function api.maintenance_refresh_gap(p_after bigint default 0, p_limit integer default 5000)
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
    return jsonb_build_object('last_id', v_ids[cardinality(v_ids)], 'changed', v_changed);
end;
$$;
revoke all on function api.maintenance_refresh_gap(bigint, integer) from public, anon, authenticated;
grant execute on function api.maintenance_refresh_gap(bigint, integer) to service_role;

create or replace function api.maintenance_refresh_counts()
returns void
language sql
set search_path = ''
as $$ select ops.refresh_counts(); $$;
revoke all on function api.maintenance_refresh_counts() from public, anon, authenticated;
grant execute on function api.maintenance_refresh_counts() to service_role;

insert into ops.schema_migration (version) values ('0024') on conflict do nothing;
