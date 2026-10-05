-- 0021: views לדשבורד החדש (dashboard/): v_missing מקבלת scan_state ו-mech_redirect נשאר; v_template_issues למשימות תבנית.
-- scan_state: not_scanned / stale (rev שנסרק שונה מהנוכחי) / scanned.

create or replace view api.v_missing with (security_invoker = true) as
select w.page_id           as id,
       w.title,
       e.wiki_created_at   as created_at,
       e.wikidata_desc,
       e.length,
       coalesce(e.mech_redirect, false) as mech_redirect,
       s.has_images,
       s.photo_count,
       s.verdict_list_a, s.verdict_list_s, s.verdict_ctx_a, s.verdict_ctx_s,
       s.suspicion_a, s.suspicion_s,
       s.hidden_count_a, s.hidden_count_s, s.names_count_a, s.names_count_s,
       s.matches_total, s.dictionary, s.dictionary_why, s.topic, s.scanned_at,
       case when s.wiki_id is null then 'not_scanned'
            when s.rev_id is distinct from w.latest_rev_id then 'stale'
            else 'scanned' end as scan_state
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = w.page_id
left join enrich.content_scan s on s.wiki_id = w.page_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                  and (x.wiki_id = w.page_id or x.title = w.title));

-- תבניות שדורשות טיפול: כותרת שאינה דף חי בוויקיפדיה (unresolved), או דף נעול לקריאה (denied)
create or replace view api.v_template_issues with (security_invoker = true) as
select m.page_id as id, m.title, c.outcome, l.template_ref, c.checked_at
from derived.template_check c
join mirror.mech_page m on m.page_id = c.mech_id
left join derived.template_link l on l.mech_id = c.mech_id
where c.outcome in ('unresolved', 'denied')
  and not exists (select 1 from work.manual_link x where x.mech_id = c.mech_id);

grant select on api.v_missing, api.v_template_issues to anon, authenticated;
