begin;
do $$
declare s text;
begin
    -- אין ריצות: never
    if (select state from ops.health() where kind = 'sync') <> 'never' then raise exception 'expected never'; end if;
    if jsonb_array_length(api.health_check()) <> 1 then raise exception 'never must be reported'; end if;

    insert into ops.sync_run (kind, started_at, finished_at, status) values ('sync', now() - interval '20 minutes', now() - interval '15 minutes', 'succeeded');
    if (select state from ops.health() where kind = 'sync') <> 'ok' then raise exception 'recent success is ok'; end if;
    if api.health_check() <> '[]'::jsonb then raise exception 'ok must report nothing'; end if;

    -- הצלחה ישנה: stale
    update ops.sync_run set finished_at = now() - (select max_age from ops.health_threshold where kind='sync') - interval '1 hour' where kind = 'sync';
    if (select state from ops.health() where kind = 'sync') <> 'stale' then raise exception 'expected stale'; end if;

    -- ריצה תקועה גוברת: running מעל 90 דקות
    insert into ops.sync_run (kind, started_at, status) values ('sync', now() - interval '2 hours', 'running');
    if (select state from ops.health() where kind = 'sync') <> 'stuck' then raise exception 'expected stuck'; end if;

    -- ריצה פעילה רגילה (5 דקות) אינה תקועה
    delete from ops.sync_run where status = 'running';
    insert into ops.sync_run (kind, started_at, status) values ('sync', now() - interval '5 minutes', 'running');
    if (select state from ops.health() where kind = 'sync') <> 'stale' then raise exception 'short running must not be stuck'; end if;

    -- הדשבורד רואה את המצב; סוגי ריצה בלי סף נשארים ok
    insert into ops.sync_run (kind, status, finished_at) values ('enrich', 'failed', now());
    select health into s from api.v_sync_status where kind = 'enrich';
    if s <> 'ok' then raise exception 'kinds without a threshold stay ok'; end if;
    select health into s from api.v_sync_status where kind = 'sync';
    if s <> 'stale' then raise exception 'v_sync_status should show stale, got %', s; end if;
end $$;
set local role anon;
select count(*) from api.v_sync_status;
reset role;
rollback;
select 'ok t10_health' as test;
