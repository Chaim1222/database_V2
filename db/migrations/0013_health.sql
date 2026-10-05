-- 0013: שער בריאות. ops.health_threshold קובעת לכל סוג ריצה כמה זמן מותר בלי הצלחה וכמה זמן ריצה יכולה להיות
-- ב-running. ops.health() מחשבת מצב (ok / stale / stuck / never); api.v_sync_status מציגה אותו לדשבורד;
-- api.health_check() מחזירה את הבעיות ל-workflow (health.yml) שנכשל כשיש בעיה, כדי ש-GitHub ישלח מייל.
-- ברירת המחדל: סנכרון 3 שעות ללא הצלחה או 90 דקות ב-running. הערכים ניתנים לעדכון בטבלה (ראו PLAN_STAGE4.md 4.4).

create table ops.health_threshold (
    kind        text primary key check (kind in ('sync', 'reconcile', 'enrich', 'scan', 'maintenance', 'rebuild')),
    max_age     interval not null,
    max_running interval not null
);
alter table ops.health_threshold enable row level security;
create policy public_read on ops.health_threshold for select to anon, authenticated using (true);
grant select on ops.health_threshold to anon, authenticated;
insert into ops.health_threshold (kind, max_age, max_running) values ('sync', interval '3 hours', interval '90 minutes');

create or replace function ops.health()
returns table (kind text, state text, last_success_at timestamptz, running_since timestamptz)
language sql
stable
set search_path = ''
as $$
    select t.kind,
           case
               when r.running_since is not null and r.running_since < now() - t.max_running then 'stuck'
               when s.last_success_at is null then 'never'
               when s.last_success_at < now() - t.max_age then 'stale'
               else 'ok'
           end,
           s.last_success_at,
           r.running_since
    from ops.health_threshold t
    left join lateral (select max(x.finished_at) as last_success_at
                       from ops.sync_run x where x.kind = t.kind and x.status = 'succeeded') s on true
    left join lateral (select min(x.started_at) as running_since
                       from ops.sync_run x where x.kind = t.kind and x.status = 'running') r on true;
$$;
grant execute on function ops.health() to anon, authenticated, service_role;

-- סטטוס הריצות לדשבורד: העמודות הקיימות כמות שהן, ובסוף המצב ונקודות הזמן
create or replace view api.v_sync_status with (security_invoker = true) as
select distinct on (r.kind) r.kind, r.status, r.started_at, r.finished_at, r.step, r.stats, r.error,
       coalesce(h.state, 'ok') as health, h.last_success_at
from ops.sync_run r
left join ops.health() h on h.kind = r.kind
order by r.kind, r.started_at desc;

create or replace function api.health_check()
returns jsonb
language sql
stable
set search_path = ''
as $$
    select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from ops.health() h where h.state <> 'ok';
$$;
revoke all on function api.health_check() from public, anon, authenticated;
grant execute on function api.health_check() to service_role;
