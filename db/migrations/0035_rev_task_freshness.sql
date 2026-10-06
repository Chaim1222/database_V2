-- Display-only baseline validity. NULL and 0 both mean no valid source revision.
-- Missing/unreadable template information is not evidence that a finding is stale.
-- Keep findings themselves: the existing revcheck writer owns their lifecycle.
create or replace view api.v_rev_tasks with (security_invoker = true) as
select c.mech_id as id, m.title, ms.label_he as status_label, c.rev_task, c.rev_id,
       c.linked_wiki_id, lw.title as linked_title, c.rev_page_id, c.rev_page_title, c.checked_at
from derived.rev_check c
join mirror.mech_page m on m.page_id = c.mech_id
join ref.mech_status ms on ms.code = m.status
left join mirror.wiki_page lw on lw.page_id = c.linked_wiki_id
left join derived.template_check t on t.mech_id = c.mech_id
where not exists (select 1 from work.manual_link x where x.mech_id = c.mech_id)
  and (t.mech_id is null or t.outcome = 'denied'
       or coalesce(c.rev_id, 0) = coalesce(t.template_rev, 0));

-- Existing counts already read v_rev_tasks. Refresh this small counter only;
-- do not rerun or change the mirror count mechanism introduced by 0031.
update ops.dashboard_counts
set n = (select count(*) from api.v_rev_tasks), updated_at = now()
where key = 'rev_tasks';
insert into ops.schema_migration (version) values ('0035') on conflict do nothing;
