begin;
do $$
begin
    if not exists (select 1 from ops.health_threshold where kind='sync'
                   and max_age=interval '15 hours' and max_running=interval '90 minutes') then
        raise exception 'sync thresholds do not match twelve-hour cadence';
    end if;
end $$;
-- Roll back these fixtures; test both sides of the actual configured threshold.
delete from ops.sync_run where kind='sync';
insert into ops.sync_run(kind,status,started_at,finished_at)
values ('sync','succeeded',now()-interval '14 hours',now()-interval '14 hours');
do $$ begin
    if (select state from ops.health() where kind='sync') is distinct from 'ok' then
        raise exception 'healthy twelve-hour cadence reported stale';
    end if;
end $$;
update ops.sync_run set finished_at=now()-interval '16 hours' where kind='sync';
do $$ begin
    if (select state from ops.health() where kind='sync') is distinct from 'stale' then
        raise exception 'missed sync not reported stale';
    end if;
end $$;
insert into ops.sync_run(kind,status,started_at) values ('sync','running',now()-interval '2 hours');
do $$ begin
    if (select state from ops.health() where kind='sync') is distinct from 'stuck' then
        raise exception 'stuck-run protection changed';
    end if;
end $$;
rollback;
select 'ok t28_sync_cadence' as test;
