-- Shared V1 interface over the existing V2 model. No update/merge dashboard.
-- Keep the V2 matching, exclusions and freshness rules in their existing views.
-- Reuse the existing public missing-page detail projection. Append only counts;
-- matches and images remain available only when the interface requests details.
create or replace view api.word_filter_results as
select s.wiki_id as wikipedia_id, d.matches, s.matches_total, d.images, s.photo_count, s.scanned_at, s.rev_id, s.lists_version, d.counts
from enrich.content_scan s
left join enrich.content_scan_detail d on d.wiki_id = s.wiki_id
where exists (select 1 from derived.wiki_gap g where g.wiki_id = s.wiki_id and g.kind = 'missing');

-- Preserve an unchecked redirect as unknown for the existing interface filters.
create or replace view api.report_missing_from_mechalol with (security_invoker = true) as
select g.wiki_id as id, w.title, e.desc_checked_at as checked_at, e.wikidata_desc,
       e.length as easy_import_length, s.has_images as easy_import_has_images,
       null::boolean as problematic_words_clean, e.wiki_created_at as created_at,
       e.mech_redirect as mechalol_redirect_exists,
       (e.length_checked_at is not null) as easy_import_checked, (e.created_checked_at is not null) as created_at_checked
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
left join enrich.content_scan s on s.wiki_id = g.wiki_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create') and (x.wiki_id = w.page_id or x.title = w.title));

create or replace view api.report_missing_word_filter with (security_invoker = true) as
select m.id, m.title, m.checked_at, m.wikidata_desc, m.easy_import_length, m.created_at, m.mechalol_redirect_exists,
       s.verdict_list_a as verdict, s.verdict_list_s as verdict_suggested, s.has_images, s.photo_count,
       d.counts, s.matches_total, null::jsonb as images, s.scanned_at,
       s.verdict_ctx_a as ctx_verdict, s.suspicion_a as ctx_suspicion,
       s.verdict_ctx_s as ctx_verdict_suggested, s.suspicion_s as ctx_suspicion_suggested,
       s.hidden_count_a as hidden_count, s.hidden_count_s as hidden_count_suggested,
       s.dictionary, s.dictionary_why, s.topic,
       s.names_count_a as names_count, s.names_count_s as names_count_suggested,
       case when s.wiki_id is null then 'not_scanned'
            when s.rev_id is distinct from w.latest_rev_id then 'stale'
            else 'scanned' end as scan_state
from api.report_missing_from_mechalol m
join mirror.wiki_page w on w.page_id = m.id
left join enrich.content_scan s on s.wiki_id = m.id
left join api.word_filter_results d on d.wikipedia_id = m.id;

create view api.report_missing_word_filter_summary with (security_invoker = true) as
select coalesce(mechalol_redirect_exists, false) as redirect, has_images,
       case when scan_state = 'scanned' then verdict end as verdict,
       case when scan_state = 'scanned' then verdict_suggested end as verdict_suggested,
       case when scan_state = 'scanned' then ctx_verdict end as ctx_verdict,
       case when scan_state = 'scanned' then ctx_suspicion end as ctx_suspicion,
       case when scan_state = 'scanned' then ctx_verdict_suggested end as ctx_verdict_suggested,
       case when scan_state = 'scanned' then ctx_suspicion_suggested end as ctx_suspicion_suggested,
       dictionary is not null as dictionary, topic, count(*)::int as n, scan_state
from api.report_missing_word_filter
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12;
grant select on api.report_missing_word_filter_summary to anon, authenticated;

create or replace view api.report_rev_tasks with (security_invoker = true) as
select v.id, v.title, v.status_label as status, v.rev_task, v.rev_id as sort_template_rev, null::date as sort_template_date,
       v.linked_wiki_id as wikipedia_id, v.linked_title, v.rev_page_id, v.rev_page_title, v.checked_at
from api.v_rev_tasks v;

create or replace view api.report_locked_pages with (security_invoker = true) as
select l.page_id as id, l.title,
       case when l.level = 'create' then 'נעול ליצירה' else 'נעול לקריאה' end as lock_level,
       l.detected_by as lock_source,
       case when l.site = 'wikipedia' then nullif(l.page_id, 0) end as wikipedia_id,
       case when l.site = 'mechalol' then nullif(l.page_id, 0) end as mechalol_id,
       l.detected_at, l.site
from api.v_locks l;

-- Extend the existing endpoint without keeping an ambiguous default-argument overload.
-- Existing V2 callers omit the two new optional fields and remain supported.
drop function api.mark_feedback(bigint, text, text, text[], text, text, text, text, text);
create function api.mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[], p_label text,
    p_topic text default null, p_hidden text default null, p_level text default null, p_lists_version text default null,
    p_before text default null, p_after text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
    if not api.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
    insert into work.scan_feedback as f
        (wiki_id, match_key, word, entries, label, topic, hidden, level, lists_version, context_before, context_after, user_id)
    values (p_wiki_id, p_match_key, p_word, p_entries, p_label, p_topic, p_hidden, p_level, p_lists_version, p_before, p_after, auth.uid())
    on conflict (wiki_id, match_key, user_id) do update
        set label = excluded.label, created_at = now(),
            context_before = coalesce(excluded.context_before, f.context_before),
            context_after = coalesce(excluded.context_after, f.context_after);
end;
$$;
revoke all on function api.mark_feedback(bigint, text, text, text[], text, text, text, text, text, text, text) from public;
grant execute on function api.mark_feedback(bigint, text, text, text[], text, text, text, text, text, text, text) to authenticated;

insert into ops.schema_migration (version) values ('0037') on conflict do nothing;
