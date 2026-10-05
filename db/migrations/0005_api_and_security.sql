-- 0005: מה שהדשבורד רואה, והרשאות. רק `api` נחשפת ב-PostgREST. ה-views הם security_invoker, ולכן כפופים
-- ל-RLS של הטבלאות שמתחתן. כתיבה אנושית רק דרך פונקציות security definer שבודקות work.admin.

-- ===== הרשאות בסיס =====
grant usage on schema api, ref, mirror, derived, enrich, work, ops to anon, authenticated;

grant select on ref.mech_status, ref.mech_source to anon, authenticated;
grant select on mirror.wiki_page, mirror.mech_page to anon, authenticated;
grant select on derived.template_link, derived.wiki_gap, derived.rev_check, derived.mech_key to anon, authenticated;
grant select on enrich.wiki_enrichment, enrich.content_scan to anon, authenticated;   -- ללא content_scan_detail
grant select on work.manual_link, work.exclusion, work.page_lock to anon, authenticated;
grant select on ops.sync_run, ops.dashboard_counts, ops.reconcile_run to anon, authenticated;
-- scan_feedback ו-admin: אין גישה ישירה; דרך הפונקציות והסיכום בלבד.

-- RLS: מופעל בכל טבלה. קריאה ציבורית רק לטבלאות שלמעלה; כל השאר סגור (service_role עוקף RLS).
do $$
declare t record;
begin
    for t in
        select schemaname, tablename from pg_tables
        where schemaname in ('ref', 'mirror', 'derived', 'enrich', 'work', 'ops')
    loop
        execute format('alter table %I.%I enable row level security', t.schemaname, t.tablename);
    end loop;
end $$;

do $$
declare t text;
begin
    foreach t in array array[
        'ref.mech_status', 'ref.mech_source', 'mirror.wiki_page', 'mirror.mech_page',
        'derived.template_link', 'derived.wiki_gap', 'derived.rev_check', 'derived.mech_key',
        'enrich.wiki_enrichment', 'enrich.content_scan',
        'work.manual_link', 'work.exclusion', 'work.page_lock',
        'ops.sync_run', 'ops.dashboard_counts', 'ops.reconcile_run'
    ] loop
        execute format('create policy public_read on %s for select to anon, authenticated using (true)', t);
    end loop;
end $$;

-- ===== פונקציות כתיבה למנהלים =====
create or replace function api.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (select 1 from work.admin where user_id = auth.uid());
$$;

create or replace function api.set_manual_link(p_mech_id bigint, p_wiki_id bigint, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    insert into work.manual_link (mech_id, wiki_id, reason, created_by)
    values (p_mech_id, p_wiki_id, p_reason, auth.uid())
    on conflict (mech_id) do update
        set wiki_id = excluded.wiki_id, reason = excluded.reason, created_by = auth.uid(), created_at = now();
end;
$$;

create or replace function api.remove_manual_link(p_mech_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    delete from work.manual_link where mech_id = p_mech_id;
end;
$$;

create or replace function api.add_exclusion(p_kind text, p_wiki_id bigint, p_title text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    insert into work.exclusion (kind, wiki_id, title, reason, created_by)
    values (p_kind, p_wiki_id, p_title, p_reason, auth.uid())
    on conflict do nothing;
end;
$$;

create or replace function api.mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[],
                                              p_label text, p_topic text default null, p_hidden text default null,
                                              p_level text default null, p_lists_version text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    insert into work.scan_feedback (wiki_id, match_key, word, entries, label, topic, hidden, level, lists_version, user_id)
    values (p_wiki_id, p_match_key, p_word, p_entries, p_label, p_topic, p_hidden, p_level, p_lists_version, auth.uid())
    on conflict (wiki_id, match_key, user_id) do update set label = excluded.label, created_at = now();
end;
$$;

revoke all on function api.is_admin(), api.set_manual_link(bigint, bigint, text), api.remove_manual_link(bigint),
    api.add_exclusion(text, bigint, text, text),
    api.mark_feedback(bigint, text, text, text[], text, text, text, text, text) from public;
grant execute on function api.is_admin() to anon, authenticated;
grant execute on function api.set_manual_link(bigint, bigint, text), api.remove_manual_link(bigint),
    api.add_exclusion(text, bigint, text, text),
    api.mark_feedback(bigint, text, text, text[], text, text, text, text, text) to authenticated;

-- ===== views לדשבורד =====
-- חסר במכלול: דף ויקיפדיה בלי ערך מכלול, שאינו מוחרג, עם ההעשרה והסינון.
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
       s.matches_total, s.dictionary, s.dictionary_why, s.topic, s.scanned_at
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = w.page_id
left join enrich.content_scan s on s.wiki_id = w.page_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind = 'import_excluded'
                  and (x.wiki_id = w.page_id or x.title = w.title));

-- התאמות "הרב/רבי" לבדיקה אנושית: דף ויקיפדיה, והמועמדים במכלול (כולם מוצגים, בלי בחירה אוטומטית)
create or replace view api.v_rav_review with (security_invoker = true) as
select w.page_id as wiki_id, w.title as wiki_title, m.page_id as mech_id, m.title as mech_title,
       m.status as mech_status
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
join mirror.mech_page m
  on (m.title ~ '^(הרב|רבי)\s' and mirror.rav_strip(mirror.title_key(m.title)) = mirror.title_key(w.title))
  or mirror.title_key(m.title) = mirror.rav_strip(mirror.title_key(w.title))
where g.kind = 'rav_review'
  and not exists (select 1 from work.manual_link x where x.mech_id = m.page_id);

-- ערכי מכלול מיובאים שאין להם תבנית מיון תקינה (משימת תחזוקה)
create or replace view api.v_undocumented with (security_invoker = true) as
select m.page_id as id, m.title, m.source_type, w.page_id as wiki_id
from mirror.mech_page m
left join mirror.wiki_page w on mirror.title_key(w.title) = mirror.title_key(m.title)
where m.status = 'imported_undocumented'
  and not m.needs_attention and not m.is_dictionary
  and not exists (select 1 from work.manual_link x where x.mech_id = m.page_id);

-- משימות גרסה
create or replace view api.v_rev_tasks with (security_invoker = true) as
select c.mech_id as id, m.title, ms.label_he as status_label, c.rev_task, c.rev_id,
       c.linked_wiki_id, lw.title as linked_title, c.rev_page_id, c.rev_page_title, c.checked_at
from derived.rev_check c
join mirror.mech_page m on m.page_id = c.mech_id
join ref.mech_status ms on ms.code = m.status
left join mirror.wiki_page lw on lw.page_id = c.linked_wiki_id
where not exists (select 1 from work.manual_link x where x.mech_id = c.mech_id);

-- ערכים שהדף שלהם הועבר בוויקיפדיה ואצלנו עדיין השם הישן
create or replace view api.v_moves with (security_invoker = true) as
select m.page_id as id, m.title, ev.title as old_title, ev.new_title as wikipedia_title, ev.ts as moved_at
from mirror.page_event ev
join mirror.mech_page m on mirror.title_key(m.title) = mirror.title_key(ev.title)
where ev.site = 'wikipedia' and ev.kind = 'move'
  and not exists (select 1 from mirror.wiki_page w where mirror.title_key(w.title) = mirror.title_key(m.title));

-- נעילות
create or replace view api.v_locks with (security_invoker = true) as
select p.site, p.page_id, p.level, p.detected_by, p.detected_at,
       coalesce(m.title, w.title) as title
from work.page_lock p
left join mirror.mech_page m on p.site = 'mechalol' and m.page_id = p.page_id
left join mirror.wiki_page w on p.site = 'wikipedia' and w.page_id = p.page_id
union all
select 'mechalol', 0, 'create', 'exclusion', x.created_at, x.title
from work.exclusion x where x.kind = 'locked_create' and x.title is not null;

-- ספירות ומצב המערכת
create or replace view api.v_counts with (security_invoker = true) as
select key, n, updated_at from ops.dashboard_counts;

create or replace view api.v_sync_status with (security_invoker = true) as
select distinct on (kind) kind, status, started_at, finished_at, step, stats, error
from ops.sync_run
order by kind, started_at desc;

grant select on all tables in schema api to anon, authenticated;
