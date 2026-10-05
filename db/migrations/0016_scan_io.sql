-- 0016: כניסה ויציאה של הסינון (word-filter/tools/scan-missing.js עם --backend v2).
-- scan_pending: כל דפי "חסר" עם מצב הסריקה הקודם (rev_id, lists_version, topic), בעימוד לפי מזהה.
-- sync_apply_scan: כותבת סיכום ופירוט באותה טרנזקציה (חוזה טריות: rev_id שנסרק + lists_version, שכולל רשימות, מנוע, כללי מילוני ונושאים).
-- scan_prune מכילה `delete from`: להחיל בעורך ה-SQL של סופרבייס.

create or replace function api.scan_pending(p_after bigint default 0, p_limit integer default 1000)
returns table (wiki_id bigint, title text, wikidata_desc text, scan_rev_id bigint, scan_lists_version text, scan_topic text)
language sql
stable
set search_path = ''
as $$
    select g.wiki_id, w.title, e.wikidata_desc, s.rev_id, s.lists_version, s.topic
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    left join enrich.content_scan s on s.wiki_id = g.wiki_id
    where g.kind = 'missing' and g.wiki_id > p_after
    order by g.wiki_id
    limit p_limit;
$$;

-- p_rows בצורה של scan-missing.js (שמות v1): wikipedia_id, rev_id, lists_version, verdict..., counts, matches, images
create or replace function api.sync_apply_scan(p_rows jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
    v_n integer;
begin
    create temp table _scan on commit drop as
    select r.* from jsonb_to_recordset(p_rows) as r(
        wikipedia_id bigint, rev_id bigint, lists_version text, verdict text, verdict_suggested text,
        ctx_verdict text, ctx_suspicion text, ctx_verdict_suggested text, ctx_suspicion_suggested text,
        hidden_count integer, hidden_count_suggested integer, names_count integer, names_count_suggested integer,
        matches_total integer, photo_count integer, has_images boolean, dictionary text, dictionary_why text,
        topic text, scanned_at timestamptz, counts jsonb, matches jsonb, images jsonb)
    where exists (select 1 from mirror.wiki_page w where w.page_id = r.wikipedia_id);

    insert into enrich.content_scan as s (wiki_id, rev_id, lists_version, verdict_list_a, verdict_list_s, verdict_ctx_a, verdict_ctx_s,
        suspicion_a, suspicion_s, hidden_count_a, hidden_count_s, names_count_a, names_count_s, matches_total, photo_count,
        has_images, dictionary, dictionary_why, topic, scanned_at)
    select wikipedia_id, rev_id, lists_version, verdict, verdict_suggested, ctx_verdict, ctx_verdict_suggested,
           ctx_suspicion, ctx_suspicion_suggested, hidden_count, hidden_count_suggested, names_count, names_count_suggested,
           matches_total, photo_count, has_images, dictionary, dictionary_why, topic, coalesce(scanned_at, now())
    from _scan
    on conflict (wiki_id) do update set
        rev_id = excluded.rev_id, lists_version = excluded.lists_version,
        verdict_list_a = excluded.verdict_list_a, verdict_list_s = excluded.verdict_list_s,
        verdict_ctx_a = excluded.verdict_ctx_a, verdict_ctx_s = excluded.verdict_ctx_s,
        suspicion_a = excluded.suspicion_a, suspicion_s = excluded.suspicion_s,
        hidden_count_a = excluded.hidden_count_a, hidden_count_s = excluded.hidden_count_s,
        names_count_a = excluded.names_count_a, names_count_s = excluded.names_count_s,
        matches_total = excluded.matches_total, photo_count = excluded.photo_count, has_images = excluded.has_images,
        dictionary = excluded.dictionary, dictionary_why = excluded.dictionary_why, topic = excluded.topic,
        scanned_at = excluded.scanned_at;
    get diagnostics v_n = row_count;

    insert into enrich.content_scan_detail as d (wiki_id, counts, matches, images)
    select wikipedia_id, counts, matches, images from _scan
    on conflict (wiki_id) do update set counts = excluded.counts, matches = excluded.matches, images = excluded.images;

    drop table _scan;
    return v_n;
end;
$$;

create or replace function api.scan_set_topic(p_id bigint, p_topic text)
returns void
language sql
set search_path = ''
as $$ update enrich.content_scan set topic = p_topic where wiki_id = p_id; $$;

create or replace function api.scan_prune(p_ids bigint[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
    v_n integer;
begin
    delete from enrich.content_scan where wiki_id = any (p_ids);   -- הפירוט נמחק ב-cascade
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

revoke all on function api.scan_pending(bigint, integer), api.sync_apply_scan(jsonb), api.scan_set_topic(bigint, text),
    api.scan_prune(bigint[]) from public, anon, authenticated;
grant execute on function api.scan_pending(bigint, integer), api.sync_apply_scan(jsonb), api.scan_set_topic(bigint, text),
    api.scan_prune(bigint[]) to service_role;

-- הדשבורד מבחין בין "נקי", "לא נסרק" ו"תוצאה ישנה": עמודה חדשה בסוף ה-view התואם (scan_state)
create or replace view api.report_missing_word_filter with (security_invoker = true) as
select m.id, m.title, m.checked_at, m.wikidata_desc, m.easy_import_length, m.created_at, m.mechalol_redirect_exists,
       s.verdict_list_a as verdict, s.verdict_list_s as verdict_suggested, s.has_images, s.photo_count,
       null::jsonb as counts, s.matches_total, null::jsonb as images, s.scanned_at,
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
left join enrich.content_scan s on s.wiki_id = m.id;
grant select on api.report_missing_word_filter to anon, authenticated;
