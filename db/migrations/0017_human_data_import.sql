-- 0017: העברת נתוני אדם מ-v1 (PLAN_STAGE4.md 4.5) + תיקון זוגיות: כותרת נעולה ליצירה (blacklist_titles ב-v1) מוחרגת גם מ"חסר",
-- כמו ב-v1 (report_missing_from_mechalol הוציא כותרות מה-blacklist). import_human_data אידמפוטנטית, מאמתת כל שורה מול המראה
-- ומחזירה את השורות שדולגו (לא מוחקת דבר בשקט). p_admin: חשבון Supabase Auth של המנהל ב-v2, שאליו משויכים משובי הסינון הישנים.

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
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                  and (x.wiki_id = w.page_id or x.title = w.title));

create or replace view api.report_missing_from_mechalol with (security_invoker = true) as
select g.wiki_id as id, w.title, e.desc_checked_at as checked_at, e.wikidata_desc,
       e.length as easy_import_length, s.has_images as easy_import_has_images,
       null::boolean as problematic_words_clean, e.wiki_created_at as created_at,
       coalesce(e.mech_redirect, false) as mechalol_redirect_exists,
       (e.length_checked_at is not null) as easy_import_checked, (e.created_checked_at is not null) as created_at_checked
from derived.wiki_gap g
join mirror.wiki_page w on w.page_id = g.wiki_id
left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
left join enrich.content_scan s on s.wiki_id = g.wiki_id
where g.kind = 'missing'
  and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                  and (x.wiki_id = w.page_id or x.title = w.title));

create or replace function ops.refresh_counts()
returns void
language sql
set search_path = ''
as $$
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages',   (select count(*) from mirror.wiki_page), now()),
        ('mech_pages',   (select count(*) from mirror.mech_page), now()),
        ('missing',      (select count(*) from derived.wiki_gap g
                           join mirror.wiki_page w on w.page_id = g.wiki_id
                           where g.kind = 'missing'
                             and not exists (select 1 from work.exclusion e
                                             where e.kind in ('import_excluded', 'locked_create')
                                               and (e.wiki_id = g.wiki_id or e.title = w.title))), now()),
        ('rav_review',   (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks',        (select count(*) from work.page_lock), now()),
        ('rev_tasks',    (select count(*) from derived.rev_check c
                           where not exists (select 1 from work.manual_link m where m.mech_id = c.mech_id)), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
$$;

create or replace function api.import_human_data(
    p_admin uuid, p_manual jsonb default '[]', p_blacklist jsonb default '[]',
    p_feedback jsonb default '[]', p_locks jsonb default '[]')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_skipped jsonb := '{}';
    v_ins jsonb := '{}';
    v_n integer;
    v_bad jsonb;
begin
    if p_admin is null or not exists (select 1 from auth.users u where u.id = p_admin) then
        raise exception 'p_admin must be an existing auth user' using errcode = '22023';
    end if;

    -- שיוכים ידניים: שני המזהים חייבים להיות קיימים במראה
    select coalesce(jsonb_agg(to_jsonb(r)), '[]') into v_bad
    from jsonb_to_recordset(p_manual) as r(mechalol_page_id bigint, wikipedia_page_id bigint, reason text, added_at timestamptz)
    where not exists (select 1 from mirror.mech_page m where m.page_id = r.mechalol_page_id)
       or not exists (select 1 from mirror.wiki_page w where w.page_id = r.wikipedia_page_id);
    v_skipped := v_skipped || jsonb_build_object('manual', v_bad);
    insert into work.manual_link (mech_id, wiki_id, reason, created_by, created_at)
    select r.mechalol_page_id, r.wikipedia_page_id, r.reason, p_admin, coalesce(r.added_at, now())
    from jsonb_to_recordset(p_manual) as r(mechalol_page_id bigint, wikipedia_page_id bigint, reason text, added_at timestamptz)
    where exists (select 1 from mirror.mech_page m where m.page_id = r.mechalol_page_id)
      and exists (select 1 from mirror.wiki_page w where w.page_id = r.wikipedia_page_id)
    on conflict (mech_id) do nothing;
    get diagnostics v_n = row_count;
    v_ins := v_ins || jsonb_build_object('manual', v_n);

    -- כותרות נעולות ליצירה
    insert into work.exclusion (kind, title, reason, created_by, created_at)
    select 'locked_create', r.title, r.reason, p_admin, coalesce(r.added_at, now())
    from jsonb_to_recordset(p_blacklist) as r(title text, reason text, added_at timestamptz)
    where r.title is not null
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_ins := v_ins || jsonb_build_object('blacklist', v_n);

    -- נעילות קריאה: רק ערכי מכלול קיימים ורמות מוכרות
    select coalesce(jsonb_agg(to_jsonb(r)), '[]') into v_bad
    from jsonb_to_recordset(p_locks) as r(mechalol_id bigint, allevel text, checked_at timestamptz)
    where r.allevel not in ('read', 'read-semi', 'create')
       or not exists (select 1 from mirror.mech_page m where m.page_id = r.mechalol_id);
    v_skipped := v_skipped || jsonb_build_object('locks', v_bad);
    insert into work.page_lock (site, page_id, level, detected_by, detected_at)
    select 'mechalol', r.mechalol_id, r.allevel, 'v1', coalesce(r.checked_at, now())
    from jsonb_to_recordset(p_locks) as r(mechalol_id bigint, allevel text, checked_at timestamptz)
    where r.allevel in ('read', 'read-semi', 'create')
      and exists (select 1 from mirror.mech_page m where m.page_id = r.mechalol_id)
    on conflict do nothing;
    get diagnostics v_n = row_count;
    v_ins := v_ins || jsonb_build_object('locks', v_n);

    -- משוב סינון: כולם משויכים ל-p_admin (המנהל היחיד ב-v1)
    insert into work.scan_feedback (wiki_id, match_key, word, entries, topic, hidden, label, level, context_before, context_after,
                                    lists_version, user_id, created_at)
    select r.wikipedia_id, r.match_key, r.word, r.entries, r.topic, r.hidden, r.label, r.level, r.before, r.after,
           r.lists_version, p_admin, coalesce(r.created_at, now())
    from jsonb_to_recordset(p_feedback) as r(wikipedia_id bigint, match_key text, word text, entries text[], topic text,
         hidden text, label text, level text, before text, after text, lists_version text, created_at timestamptz)
    on conflict (wiki_id, match_key, user_id) do nothing;
    get diagnostics v_n = row_count;
    v_ins := v_ins || jsonb_build_object('feedback', v_n);

    perform ops.refresh_counts();
    return jsonb_build_object('inserted', v_ins, 'skipped', v_skipped);
end;
$$;
revoke all on function api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb) to service_role;
