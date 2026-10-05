-- 0026: (א) היסטוריית מדדים יומית (ops.metric_snapshot) לגרף מגמה בדשבורד; (ב) התראת גודל מסד ב-api.health_check
-- (סף 400MB מתוך 500MB של התוכנית החינמית). אין delete בקובץ, ולכן ניתן להחלה דרך ה-MCP.

create table if not exists ops.metric_snapshot (
    day date not null,
    key text not null,
    n bigint not null,
    primary key (day, key)
);
alter table ops.metric_snapshot enable row level security;
drop policy if exists public_read on ops.metric_snapshot;
create policy public_read on ops.metric_snapshot for select to anon, authenticated using (true);
grant select on ops.metric_snapshot to anon, authenticated;

-- צילום יומי: הספירות הקיימות + גודל המסד. החלפה באותו יום (הצילום האחרון ביום גובר).
create or replace function ops.snapshot_metrics()
returns void
language sql
set search_path = ''
as $$
    insert into ops.metric_snapshot (day, key, n)
    select (now() at time zone 'utc')::date, c.key, c.n from ops.dashboard_counts c
    union all
    select (now() at time zone 'utc')::date, 'db_bytes', pg_database_size(current_database())
    on conflict (day, key) do update set n = excluded.n;
$$;

create or replace function api.maintenance_refresh_counts()
returns void
language sql
set search_path = ''
as $$ select ops.refresh_counts(); select ops.snapshot_metrics(); $$;

create or replace view api.v_metric_history with (security_invoker = true) as
select day, key, n from ops.metric_snapshot order by day, key;
grant select on api.v_metric_history to anon, authenticated;

-- health_check: בעיות הריצות + גודל מסד. מחזיר אובייקטים באותה צורה (kind, state, ...).
create or replace function api.health_check()
returns jsonb
language sql
stable
set search_path = ''
as $$
    select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select to_jsonb(h) as x from ops.health() h where h.state <> 'ok'
        union all
        select jsonb_build_object('kind', 'db_size', 'state', 'big', 'bytes', pg_database_size(current_database()))
        where pg_database_size(current_database()) > 400 * 1024 * 1024
    ) q;
$$;
revoke all on function api.health_check() from public, anon, authenticated;
grant execute on function api.health_check() to service_role;

insert into ops.schema_migration (version) values ('0026') on conflict do nothing;
