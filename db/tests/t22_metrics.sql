begin;
do $$
begin
    perform ops.refresh_counts();
    perform api.maintenance_refresh_counts();
    perform api.maintenance_refresh_counts();   -- idempotent באותו יום
    if (select count(*) from api.v_metric_history where key = 'db_bytes') <> 1 then raise exception 'one db_bytes row per day'; end if;
    if (select count(*) from api.v_metric_history where key = 'missing') <> 1 then raise exception 'counts snapshotted'; end if;
    if jsonb_typeof(api.health_check()) <> 'array' then raise exception 'health_check must stay an array'; end if;
end $$;
rollback;
select 'ok t22_metrics' as test;
