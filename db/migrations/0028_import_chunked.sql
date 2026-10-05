-- 0028: api.import_human_data נתקעה בפסק זמן (57014) על כל הנתונים בקריאה אחת: הסיום קרא ל-ops.refresh_counts (כ-7 שניות),
-- וגם הטריגרים של השיוכים וההחרגות רצים לכל שורה. עכשיו: הפונקציה אינה מרעננת ספירות (הקולט קורא ל-api.maintenance_refresh_counts
-- בסוף), והקולט שולח במנות קטנות. נשארת security definer (0027) ופתוחה ל-service_role בלבד.
create or replace function api.import_human_data(
    p_admin uuid, p_manual jsonb default '[]', p_blacklist jsonb default '[]',
    p_feedback jsonb default '[]', p_locks jsonb default '[]')
returns jsonb
language plpgsql
security definer
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

    return jsonb_build_object('inserted', v_ins, 'skipped', v_skipped);
end;
$$;
revoke all on function api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function api.import_human_data(uuid, jsonb, jsonb, jsonb, jsonb) to service_role;
insert into ops.schema_migration (version) values ('0028') on conflict do nothing;
