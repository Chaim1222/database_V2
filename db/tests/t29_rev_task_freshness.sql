begin;
do $$
declare before_findings bigint;
begin
    perform api.sync_apply_mech_pages('[
      {"page_id":301,"title":"same baseline","status":"imported_documented"},
      {"page_id":302,"title":"null versus zero","status":"imported_documented"},
      {"page_id":303,"title":"null versus null","status":"imported_documented"},
      {"page_id":304,"title":"fixed missing baseline","status":"imported_documented"},
      {"page_id":305,"title":"changed positive baseline","status":"imported_documented"},
      {"page_id":306,"title":"no template record","status":"imported_documented"},
      {"page_id":307,"title":"unreadable template","status":"imported_documented"},
      {"page_id":308,"title":"zero versus zero","status":"imported_documented"},
      {"page_id":309,"title":"manual link","status":"imported_documented"},
      {"page_id":310,"title":"removed baseline","status":"imported_documented"}]');
    insert into derived.template_check(mech_id,outcome,template_rev) values
      (301,'same',123),(302,'same',0),(303,'same',null),(304,'same',19232710),
      (305,'same',200),(307,'denied',200),(308,'same',0),(310,'none',0);
    insert into derived.rev_check(mech_id,rev_task,rev_id) values
      (301,'redirect',123),(302,'bad_rev',null),(303,'bad_rev',null),(304,'bad_rev',null),
      (305,'deleted_by_rev',100),(306,'bad_rev',100),(307,'bad_rev',100),
      (308,'bad_rev',0),(309,'bad_rev',null),(310,'redirect',100);
    insert into work.manual_link(mech_id,wiki_id,reason) values(309,999,'test manual link');
    select count(*) into before_findings from derived.rev_check;
    if (select array_agg(id order by id) from api.v_rev_tasks) is distinct from
       array[301,302,303,306,307,308]::bigint[] then raise exception 'baseline filtering'; end if;
    if (select array_agg(id order by id) from api.report_rev_tasks) is distinct from
       array[301,302,303,306,307,308]::bigint[] then raise exception 'compatibility filtering'; end if;
    perform ops.refresh_counts();
    if (select n from ops.dashboard_counts where key='rev_tasks')<>6 then raise exception 'count differs from view'; end if;
    if (select count(*) from derived.rev_check)<>before_findings then raise exception 'findings deleted'; end if;
    -- Reverting the baseline makes the preserved finding visible again.
    update derived.template_check set template_rev=100 where mech_id=305;
    if not exists(select from api.v_rev_tasks where id=305) then raise exception 'finding lost'; end if;
    if (select reloptions from pg_class where oid='api.v_rev_tasks'::regclass) is distinct from
       array['security_invoker=true'] then raise exception 'view lost invoker security'; end if;
end $$;
set local role anon;
do $$ begin
    if (select count(*) from api.v_rev_tasks)<>7 then raise exception 'anon read'; end if;
    if (select count(*) from api.report_rev_tasks)<>7 then raise exception 'anon compatibility read'; end if;
end $$;
reset role;
set local role authenticated;
do $$ begin
    if (select count(*) from api.v_rev_tasks)<>7 then raise exception 'authenticated read'; end if;
end $$;
reset role;
rollback;
select 'ok t29_rev_task_freshness' as test;
