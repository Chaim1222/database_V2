-- נוצר אוטומטית מ-db/migrations (db/gen_schema.sh). אין לערוך ידנית.
--
-- PostgreSQL database dump
--

--
-- Name: api; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA api;

--
-- Name: derived; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA derived;

--
-- Name: enrich; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA enrich;

--
-- Name: mirror; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA mirror;

--
-- Name: ops; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ops;

--
-- Name: ref; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ref;

--
-- Name: work; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA work;

--
-- Name: add_exclusion(text, bigint, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.add_exclusion(p_kind text, p_wiki_id bigint, p_title text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    insert into work.exclusion (kind, wiki_id, title, reason, created_by)
    values (p_kind, p_wiki_id, p_title, p_reason, auth.uid())
    on conflict do nothing;
end;
$$;

--
-- Name: enrich_pending(text, bigint, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.enrich_pending(p_group text, p_after bigint DEFAULT 0, p_limit integer DEFAULT 500) RETURNS TABLE(wiki_id bigint, title text)
    LANGUAGE plpgsql STABLE
    SET search_path TO ''
    AS $$
begin
    if p_group not in ('created', 'length', 'desc', 'redirect', 'locks') then
        raise exception 'bad group %', p_group using errcode = '22023';
    end if;
    return query
    select g.wiki_id, w.title
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    where g.kind = 'missing' and g.wiki_id > p_after
      and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                      and (x.wiki_id = g.wiki_id or x.title = w.title))
      and case p_group
              when 'created'  then e.created_checked_at is null
              when 'length'   then e.length_checked_at is null or e.length_checked_at < now() - interval '7 days'
              when 'desc'     then e.desc_checked_at is null or e.desc_checked_at < now() - interval '30 days'
              when 'locks'    then e.locks_checked_at is null or e.locks_checked_at < now() - interval '30 days'
              else                 e.redirect_checked_at is null or e.redirect_checked_at < now() - interval '1 day'
          end
    order by g.wiki_id
    limit p_limit;
end;
$$;

--
-- Name: health_check(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.health_check() RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
    select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from ops.health() h where h.state <> 'ok';
$$;

--
-- Name: import_human_data(uuid, jsonb, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.import_human_data(p_admin uuid, p_manual jsonb DEFAULT '[]'::jsonb, p_blacklist jsonb DEFAULT '[]'::jsonb, p_feedback jsonb DEFAULT '[]'::jsonb, p_locks jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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

--
-- Name: is_admin(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    select exists (select 1 from work.admin where user_id = auth.uid());
$$;

--
-- Name: maintenance_prune(interval); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.maintenance_prune(p_keep interval DEFAULT '90 days'::interval) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_enrich integer;
    v_scan integer;
begin
    delete from enrich.wiki_enrichment e
    where not exists (select 1 from derived.wiki_gap g where g.wiki_id = e.wiki_id and g.kind = 'missing')
      and coalesce(greatest(e.desc_checked_at, e.created_checked_at, e.length_checked_at, e.redirect_checked_at), '-infinity') < now() - p_keep;
    get diagnostics v_enrich = row_count;
    delete from enrich.content_scan s
    where not exists (select 1 from derived.wiki_gap g where g.wiki_id = s.wiki_id and g.kind = 'missing')
      and s.scanned_at < now() - p_keep;
    get diagnostics v_scan = row_count;
    return jsonb_build_object('enrichment', v_enrich, 'scan', v_scan);
end;
$$;

--
-- Name: maintenance_refresh_counts(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.maintenance_refresh_counts() RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select ops.refresh_counts(); $$;

--
-- Name: maintenance_refresh_gap(bigint, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.maintenance_refresh_gap(p_after bigint DEFAULT 0, p_limit integer DEFAULT 5000) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_ids bigint[];
    v_changed integer;
begin
    select array_agg(x.page_id) into v_ids from (
        select w.page_id from mirror.wiki_page w where w.page_id > p_after order by w.page_id limit p_limit) x;
    if v_ids is null then
        return jsonb_build_object('last_id', null, 'changed', 0);
    end if;
    v_changed := derived.refresh_wiki_gap(v_ids);
    return jsonb_build_object('last_id', v_ids[cardinality(v_ids)], 'changed', v_changed);
end;
$$;

--
-- Name: mark_feedback(bigint, text, text, text[], text, text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[], p_label text, p_topic text DEFAULT NULL::text, p_hidden text DEFAULT NULL::text, p_level text DEFAULT NULL::text, p_lists_version text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    insert into work.scan_feedback (wiki_id, match_key, word, entries, label, topic, hidden, level, lists_version, user_id)
    values (p_wiki_id, p_match_key, p_word, p_entries, p_label, p_topic, p_hidden, p_level, p_lists_version, auth.uid())
    on conflict (wiki_id, match_key, user_id) do update set label = excluded.label, created_at = now();
end;
$$;

--
-- Name: match_conflicts(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.match_conflicts() RETURNS TABLE(kind text, mech_id bigint, mech_title text, wiki_id bigint, other_wiki_id bigint)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
    select 'template_vs_title', m.page_id, m.title, t.wiki_id, w.page_id
    from derived.template_link t
    join mirror.mech_page m on m.page_id = t.mech_id
    join mirror.wiki_page w on mirror.title_key(w.title) = mirror.title_key(m.title) and w.page_id <> t.wiki_id
    where t.wiki_id is not null
    union all
    select 'unrelated_same_title', m.page_id, m.title, w.page_id, null::bigint
    from mirror.mech_page m
    join mirror.wiki_page w on mirror.title_key(w.title) = mirror.title_key(m.title)
    where m.status = 'created_in_mech';
$$;

--
-- Name: reconcile_pages(text, bigint, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.reconcile_pages(p_site text, p_after bigint DEFAULT 0, p_limit integer DEFAULT 5000) RETURNS TABLE(page_id bigint, title text, status text, source_type text, needs_attention boolean, is_dictionary boolean)
    LANGUAGE plpgsql STABLE
    SET search_path TO ''
    AS $$
begin
    if p_site = 'wikipedia' then
        return query select w.page_id, w.title, null::text, null::text, null::boolean, null::boolean
                     from mirror.wiki_page w where w.page_id > p_after order by w.page_id limit p_limit;
    elsif p_site = 'mechalol' then
        return query select m.page_id, m.title, m.status, m.source_type, m.needs_attention, m.is_dictionary
                     from mirror.mech_page m where m.page_id > p_after order by m.page_id limit p_limit;
    else
        raise exception 'bad site %', p_site using errcode = '22023';
    end if;
end;
$$;

--
-- Name: reconcile_record(jsonb, jsonb, jsonb); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.reconcile_record(p_snapshot_meta jsonb, p_summary jsonb, p_findings jsonb) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_run uuid;
begin
    insert into ops.reconcile_run (finished_at, snapshot_meta, summary) values (now(), p_snapshot_meta, p_summary)
    returning run_id into v_run;
    insert into ops.reconcile_finding (run_id, site, class, page_id, title, detail, explained_by_window)
    select v_run, f.site, f.class, f.page_id, f.title, f.detail, coalesce(f.explained_by_window, false)
    from jsonb_to_recordset(p_findings) as f(site text, class text, page_id bigint, title text, detail jsonb, explained_by_window boolean);
    return v_run;
end;
$$;

--
-- Name: rev_scope(bigint, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.rev_scope(p_after bigint DEFAULT 0, p_limit integer DEFAULT 2000) RETURNS TABLE(mech_id bigint, title text, template_rev bigint, template_title text, linked_wiki_id bigint)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
    select m.page_id, m.title, c.template_rev, c.template_title,
           coalesce(l.wiki_id, (select w.page_id from mirror.wiki_page w where mirror.title_key(w.title) = mirror.title_key(m.title) limit 1))
    from mirror.mech_page m
    join derived.template_check c on c.mech_id = m.page_id
    left join derived.template_link l on l.mech_id = m.page_id
    where m.page_id > p_after
      and m.status = 'imported_documented' and not m.is_dictionary and not m.needs_attention
      and c.outcome <> 'denied'
      and not exists (select 1 from work.manual_link x where x.mech_id = m.page_id)
    order by m.page_id
    limit p_limit;
$$;

--
-- Name: scan_pending(bigint, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.scan_pending(p_after bigint DEFAULT 0, p_limit integer DEFAULT 1000) RETURNS TABLE(wiki_id bigint, title text, wikidata_desc text, scan_rev_id bigint, scan_lists_version text, scan_topic text)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
    select g.wiki_id, w.title, e.wikidata_desc, s.rev_id, s.lists_version, s.topic
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    left join enrich.content_scan s on s.wiki_id = g.wiki_id
    where g.kind = 'missing' and g.wiki_id > p_after
      and not exists (select 1 from work.exclusion x where x.kind in ('import_excluded', 'locked_create')
                      and (x.wiki_id = g.wiki_id or x.title = w.title))
    order by g.wiki_id
    limit p_limit;
$$;

--
-- Name: scan_prune(bigint[]); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.scan_prune(p_ids bigint[]) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_n integer;
begin
    delete from enrich.content_scan where wiki_id = any (p_ids);   -- הפירוט נמחק ב-cascade
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

--
-- Name: scan_set_topic(bigint, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.scan_set_topic(p_id bigint, p_topic text) RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$ update enrich.content_scan set topic = p_topic where wiki_id = p_id; $$;

--
-- Name: set_manual_link(bigint, bigint, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.set_manual_link(p_mech_id bigint, p_wiki_id bigint, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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

--
-- Name: sync_apply_enrichment(text, jsonb); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_apply_enrichment(p_group text, p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_n integer;
begin
    if p_group = 'created' then
        insert into enrich.wiki_enrichment as e (wiki_id, wiki_created_at, created_checked_at)
        select r.wiki_id, r.created_at, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, created_at timestamptz)
        on conflict (wiki_id) do update set wiki_created_at = excluded.wiki_created_at, created_checked_at = now();
    elsif p_group = 'length' then
        insert into enrich.wiki_enrichment as e (wiki_id, length, length_checked_at)
        select r.wiki_id, r.length, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, length bigint)
        on conflict (wiki_id) do update set length = excluded.length, length_checked_at = now();
    elsif p_group = 'desc' then
        insert into enrich.wiki_enrichment as e (wiki_id, wikidata_desc, desc_checked_at)
        select r.wiki_id, r.wikidata_desc, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, wikidata_desc text)
        on conflict (wiki_id) do update set wikidata_desc = excluded.wikidata_desc, desc_checked_at = now();
    elsif p_group = 'locks' then
        -- p_rows: [{wiki_id, title, allevel, pageid}]. create: כותרת שאי אפשר ליצור במכלול (החרגה, לא ייבוא);
        -- read: דף קיים במכלול שנעול לקריאה (נעילה במקור אחד). none/אחר: רק נרשם שנבדק.
        insert into work.exclusion (kind, title, reason)
        select 'locked_create', r.title, 'allevel=create (זוהה אוטומטית)'
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, title text, allevel text, pageid bigint)
        where r.allevel = 'create' and r.title is not null
        on conflict do nothing;
        insert into work.page_lock (site, page_id, level, detected_by)
        select 'mechalol', r.pageid, 'read', 'missing_check'
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, title text, allevel text, pageid bigint)
        where r.allevel = 'read' and r.pageid is not null
        on conflict (site, page_id) do nothing;
        insert into enrich.wiki_enrichment as e (wiki_id, locks_checked_at)
        select r.wiki_id, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint)
        on conflict (wiki_id) do update set locks_checked_at = now();
    elsif p_group = 'redirect' then
        insert into enrich.wiki_enrichment as e (wiki_id, mech_redirect, redirect_checked_at)
        select r.wiki_id, r.mech_redirect, now()
        from jsonb_to_recordset(p_rows) as r(wiki_id bigint, mech_redirect boolean)
        on conflict (wiki_id) do update set mech_redirect = excluded.mech_redirect, redirect_checked_at = now();
    else
        raise exception 'bad group %', p_group using errcode = '22023';
    end if;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

--
-- Name: sync_apply_mech_pages(jsonb, bigint[], text[]); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_apply_mech_pages(p_live jsonb, p_gone_ids bigint[] DEFAULT '{}'::bigint[], p_gone_titles text[] DEFAULT '{}'::text[]) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_deleted integer := 0;
    v_rows integer;
    v_inserted integer;
    v_updated integer;
    v_ids bigint[];
    v_keys text[] := '{}';
    v_old text[];
    v_gone text[];
    v_wiki_ids bigint[];
    v_gap integer;
    v_ck text[];
    v_aff bigint[];
    v_link_wiki bigint[];
begin
    if exists (select 1 from jsonb_to_recordset(p_live) as l(page_id bigint) group by page_id having count(*) > 1)
       or exists (select 1 from jsonb_to_recordset(p_live) as l(title text) group by title having count(*) > 1) then
        raise exception 'duplicate page_id or title in p_live' using errcode = '22023';
    end if;

    select coalesce(array_agg(page_id), '{}') into v_ids from jsonb_to_recordset(p_live) as l(page_id bigint);

    -- הדפים המושפעים (לפני כל שינוי): חיים בקלט, מזהים שנעלמו, כותרות שנעלמו, ובעלי כותרת שדף חי תופס.
    -- מהם: המפתחות הסמנטיים שלהם, ודפי ויקיפדיה שקושרו אליהם בתבנית או בשיוך ידני (לרענון "חסר").
    select coalesce(array_agg(m.page_id), '{}') into v_aff
    from mirror.mech_page m
    where m.page_id = any (v_ids) or m.page_id = any (p_gone_ids) or m.title = any (p_gone_titles)
       or m.title = any (select l.title from jsonb_to_recordset(p_live) as l(title text));
    v_aff := v_aff || v_ids || p_gone_ids;
    select coalesce(array_agg(k.wiki_candidate_key), '{}') into v_ck from derived.mech_key k where k.mech_id = any (v_aff);
    select coalesce(array_agg(x.w), '{}') into v_link_wiki from (
        select t.wiki_id as w from derived.template_link t where t.mech_id = any (v_aff) and t.wiki_id is not null
        union select m.wiki_id from work.manual_link m where m.mech_id = any (v_aff)) x;

    -- הכותרות שמשתנות או נמחקות (לחישוב מחדש של "חסר" בצד ויקיפדיה)
    select coalesce(array_agg(w.title), '{}') into v_old
    from mirror.mech_page w
    join jsonb_to_recordset(p_live) as l(page_id bigint, title text) on l.page_id = w.page_id
    where w.title <> l.title;

    with d as (
        delete from mirror.mech_page w
        where w.page_id = any (p_gone_ids) and not (w.page_id = any (v_ids))
        returning w.title
    ), d2 as (
        delete from mirror.mech_page w
        where w.title = any (p_gone_titles) and not (w.page_id = any (v_ids))
          and not (w.page_id = any (p_gone_ids))
        returning w.title
    )
    select coalesce((select array_agg(title) from d), '{}') || coalesce((select array_agg(title) from d2), '{}'),
           (select count(*) from d) + (select count(*) from d2)
    into v_gone, v_rows;
    v_deleted := v_deleted + v_rows;

    update mirror.mech_page w set title = '#tmp-' || w.page_id
    from jsonb_to_recordset(p_live) as l(page_id bigint, title text)
    where w.page_id = l.page_id and w.title <> l.title;

    with s as (
        delete from mirror.mech_page w
        using jsonb_to_recordset(p_live) as l(page_id bigint, title text)
        where w.title = l.title and w.page_id <> l.page_id and not (w.page_id = any (v_ids))
        returning w.title
    )
    select v_gone || coalesce(array_agg(title), '{}'), v_deleted + count(*) into v_gone, v_deleted from s;

    with up as (
        insert into mirror.mech_page as m (page_id, title, status, source_type, needs_attention, is_dictionary)
        select l.page_id, l.title, l.status, coalesce(l.source_type, 'unknown'),
               coalesce(l.needs_attention, false), coalesce(l.is_dictionary, false)
        from jsonb_to_recordset(p_live) as l(page_id bigint, title text, status text, source_type text,
                                             needs_attention boolean, is_dictionary boolean)
        on conflict (page_id) do update
            set title = excluded.title, status = excluded.status, source_type = excluded.source_type,
                needs_attention = excluded.needs_attention, is_dictionary = excluded.is_dictionary
            where (m.title, m.status, m.source_type, m.needs_attention, m.is_dictionary)
                  is distinct from (excluded.title, excluded.status, excluded.source_type,
                                    excluded.needs_attention, excluded.is_dictionary)
        returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_inserted, v_updated from up;

    -- כללים סמנטיים: נשמרים רק כשהכותרת השתנתה (שורה לכל דף חי שיש לו wiki_candidate_key; אחרת נמחקת)
    delete from derived.mech_key k
    where k.mech_id = any (v_ids) or not exists (select 1 from mirror.mech_page m where m.page_id = k.mech_id);
    insert into derived.mech_key (mech_id, wiki_candidate_key, rules)
    select l.page_id, l.wiki_candidate_key, coalesce(l.rules, '{}')
    from jsonb_to_recordset(p_live) as l(page_id bigint, wiki_candidate_key text, rules text[])
    where l.wiki_candidate_key is not null;
    delete from derived.template_link t
    where t.mech_id = any (v_aff) and not exists (select 1 from mirror.mech_page m where m.page_id = t.mech_id);
    select v_ck || coalesce(array_agg(l.wiki_candidate_key), '{}') into v_ck
    from jsonb_to_recordset(p_live) as l(wiki_candidate_key text) where l.wiki_candidate_key is not null;

    -- מפתחות הכותרות שהושפעו (חדשות, ישנות ומחוקות) ווריאציות הרב/רבי שלהן
    select coalesce(array_agg(distinct k), '{}') into v_keys from (
        select mirror.title_key(t) as k from unnest(v_old || v_gone || v_ck) as t
        union select mirror.title_key(l.title) from jsonb_to_recordset(p_live) as l(title text)
    ) x;
    -- דפי ויקיפדיה שהמפתחות האלה משפיעים עליהם: אותה כותרת, או אותה כותרת עם הרב/רבי. שני ענפים עם `= any (מערך)`,
    -- כדי שהאינדקס על title_key ישמש (בגרסה הקודמת תנאי OR עם rav_strip וביטויי select גרמו לסריקה מלאה של 406 אלף שורות).
    select coalesce(array_agg(distinct w.page_id), '{}') into v_wiki_ids from (
        select w1.page_id from mirror.wiki_page w1 where mirror.title_key(w1.title) = any (v_keys)
        union all
        select w2.page_id from mirror.wiki_page w2
        where mirror.title_key(w2.title) = any (select p || k from unnest(v_keys) as k, unnest(array['הרב ', 'רבי ']) as p)
        union all
        -- הכיוון ההפוך: ערך מכלול עם תואר ("הרב כהן") מול דף ויקיפדיה בלי תואר ("כהן")
        select w3.page_id from mirror.wiki_page w3
        where mirror.title_key(w3.title) = any (select mirror.rav_strip(k) from unnest(v_keys) as k)
    ) w;
    v_wiki_ids := v_wiki_ids || v_link_wiki;
    v_gap := derived.refresh_wiki_gap(v_wiki_ids);
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap, 'wiki_refreshed', cardinality(v_wiki_ids));
end;
$$;

--
-- Name: sync_apply_rev_checks(jsonb, bigint[]); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_apply_rev_checks(p_rows jsonb, p_scope_ids bigint[]) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_up integer;
    v_del integer;
begin
    insert into derived.rev_check as r (mech_id, rev_task, rev_id, linked_wiki_id, rev_page_id, rev_page_title, checked_at)
    select f.mech_id, f.rev_task, f.rev_id, f.linked_wiki_id, f.rev_page_id, f.rev_page_title, now()
    from jsonb_to_recordset(p_rows) as f(mech_id bigint, rev_task text, rev_id bigint, linked_wiki_id bigint, rev_page_id bigint, rev_page_title text)
    on conflict (mech_id) do update set rev_task = excluded.rev_task, rev_id = excluded.rev_id, linked_wiki_id = excluded.linked_wiki_id,
        rev_page_id = excluded.rev_page_id, rev_page_title = excluded.rev_page_title, checked_at = now();
    get diagnostics v_up = row_count;
    delete from derived.rev_check r
    where r.mech_id = any (p_scope_ids)
      and not exists (select 1 from jsonb_to_recordset(p_rows) as f(mech_id bigint) where f.mech_id = r.mech_id);
    get diagnostics v_del = row_count;
    perform ops.refresh_counts();
    return jsonb_build_object('written', v_up, 'removed', v_del);
end;
$$;

--
-- Name: sync_apply_scan(jsonb); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_apply_scan(p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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

--
-- Name: sync_apply_template_checks(jsonb); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_apply_template_checks(p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_old bigint[];
    v_new bigint[];
    v_gap integer;
    v_n integer;
begin
    if exists (select 1 from jsonb_to_recordset(p_rows) as r(mech_id bigint) group by mech_id having count(*) > 1) then
        raise exception 'duplicate mech_id in p_rows' using errcode = '22023';
    end if;

    create temp table _tc as
    select r.mech_id, r.rev_id, r.template_ref, r.template_rev, r.template_title,
           case when r.outcome = 'ok' and not exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then 'unresolved' else r.outcome end as outcome,
           case when r.outcome = 'ok' and exists (select 1 from mirror.wiki_page w where w.page_id = r.wiki_id)
                then r.wiki_id end as wiki_id
    from jsonb_to_recordset(p_rows) as r(mech_id bigint, outcome text, rev_id bigint, wiki_id bigint, template_ref text, template_rev bigint, template_title text);

    select coalesce(array_agg(t.wiki_id), '{}') into v_old
    from derived.template_link t join _tc c on c.mech_id = t.mech_id
    where t.wiki_id is not null and c.outcome <> 'denied';

    -- denied משאיר את גרסת התבנית והכותרת הקודמות (לא נקראו)
    insert into derived.template_check as k (mech_id, outcome, rev_id, template_rev, template_title, checked_at)
    select mech_id, outcome, rev_id, template_rev, template_title, now() from _tc
    on conflict (mech_id) do update set outcome = excluded.outcome, rev_id = excluded.rev_id, checked_at = now(),
        template_rev = case when excluded.outcome = 'denied' then k.template_rev else excluded.template_rev end,
        template_title = case when excluded.outcome = 'denied' then k.template_title else excluded.template_title end;
    get diagnostics v_n = row_count;

    delete from derived.template_link t
    using _tc c
    where t.mech_id = c.mech_id and c.outcome in ('none', 'same');

    insert into derived.template_link as t (mech_id, wiki_id, template_ref, verified_at)
    select mech_id, wiki_id, template_ref, now() from _tc where outcome in ('ok', 'unresolved')
    on conflict (mech_id) do update
        set wiki_id = excluded.wiki_id, template_ref = excluded.template_ref, verified_at = now();

    -- נעילות קריאה שזוהו בבדיקה: מקור אחד (work.page_lock); בדיקה מוצלחת מסירה נעילה שזוהתה כך
    insert into work.page_lock (site, page_id, level, detected_by, detected_at)
    select 'mechalol', mech_id, 'read', 'template_check', now() from _tc where outcome = 'denied'
    on conflict (site, page_id) do nothing;
    delete from work.page_lock l using _tc c
    where l.site = 'mechalol' and l.page_id = c.mech_id and l.detected_by = 'template_check' and c.outcome <> 'denied';

    select coalesce(array_agg(wiki_id), '{}') into v_new from _tc where wiki_id is not null;
    v_gap := derived.refresh_wiki_gap(v_old || v_new);
    drop table _tc;
    return jsonb_build_object('checked', v_n, 'gap_changed', v_gap);
end;
$$;

--
-- Name: sync_apply_wiki_pages(jsonb, bigint[], text[]); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_apply_wiki_pages(p_live jsonb, p_gone_ids bigint[] DEFAULT '{}'::bigint[], p_gone_titles text[] DEFAULT '{}'::text[]) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_deleted integer := 0;
    v_rows integer;
    v_inserted integer;
    v_updated integer;
    v_ids bigint[];
    v_gap integer;
begin
    if exists (select 1 from jsonb_to_recordset(p_live) as l(page_id bigint) group by page_id having count(*) > 1)
       or exists (select 1 from jsonb_to_recordset(p_live) as l(title text) group by title having count(*) > 1) then
        raise exception 'duplicate page_id or title in p_live' using errcode = '22023';
    end if;

    select coalesce(array_agg(page_id), '{}') into v_ids from jsonb_to_recordset(p_live) as l(page_id bigint);

    -- מזהים שנעלמו (אלא אם הם גם חיים בקלט: אז המצב החי גובר)
    delete from mirror.wiki_page w
    where w.page_id = any (p_gone_ids) and not (w.page_id = any (v_ids));
    get diagnostics v_rows = row_count; v_deleted := v_deleted + v_rows;

    -- כותרות שנעלמו: רק שורה שהמזהה שלה אינו חי
    delete from mirror.wiki_page w
    where w.title = any (p_gone_titles) and not (w.page_id = any (v_ids));
    get diagnostics v_rows = row_count; v_deleted := v_deleted + v_rows;

    -- פינוי כותרות: דף חי שהכותרת שלו השתנתה עובר לכותרת זמנית ייחודית, כך שהחלפות והעברות שרשרת לא מתנגשות
    update mirror.wiki_page w set title = '#tmp-' || w.page_id
    from jsonb_to_recordset(p_live) as l(page_id bigint, title text)
    where w.page_id = l.page_id and w.title <> l.title;

    -- שורה מיושנת (מזהה שאינו בקלט) שמחזיקה כותרת של דף חי: נמחקת
    delete from mirror.wiki_page w
    using jsonb_to_recordset(p_live) as l(page_id bigint, title text)
    where w.title = l.title and w.page_id <> l.page_id and not (w.page_id = any (v_ids));
    get diagnostics v_rows = row_count; v_deleted := v_deleted + v_rows;

    with up as (
        insert into mirror.wiki_page as w (page_id, title, latest_rev_id)
        select l.page_id, l.title, l.latest_rev_id
        from jsonb_to_recordset(p_live) as l(page_id bigint, title text, latest_rev_id bigint)
        on conflict (page_id) do update
            set title = excluded.title,
                latest_rev_id = coalesce(excluded.latest_rev_id, w.latest_rev_id)
            where w.title is distinct from excluded.title
               or (excluded.latest_rev_id is not null and w.latest_rev_id is distinct from excluded.latest_rev_id)
        returning (xmax = 0) as inserted
    )
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_inserted, v_updated from up;

    v_gap := derived.refresh_wiki_gap(v_ids || p_gone_ids);
    return jsonb_build_object('live', cardinality(v_ids), 'inserted', v_inserted, 'updated', v_updated,
                              'deleted', v_deleted, 'gap_changed', v_gap);
end;
$$;

--
-- Name: sync_load_begin(text, timestamp with time zone); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_load_begin(p_site text, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS timestamp with time zone
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_start timestamptz;
    v_delta timestamptz;
begin
    select ts into v_start from ops.watermark where site = p_site and stream = 'load_start';
    select ts into v_delta from ops.watermark where site = p_site and stream = 'delta';
    if v_start is null or (v_delta is not null and v_delta >= v_start) then
        v_start := coalesce(p_start, clock_timestamp());           -- אין ניסיון פתוח: חלון חדש
    elsif p_start is not null and p_start < v_start then
        v_start := p_start;                                        -- ניסיון פתוח: נשארים עם המוקדם
    else
        return v_start;
    end if;
    insert into ops.watermark (site, stream, ts) values (p_site, 'load_start', v_start)
    on conflict (site, stream) do update set ts = excluded.ts;
    return v_start;
end;
$$;

--
-- Name: sync_record_events(jsonb, uuid); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_record_events(p_events jsonb, p_run uuid DEFAULT NULL::uuid) RETURNS integer
    LANGUAGE sql
    SET search_path TO ''
    AS $$
    with ins as (
        insert into mirror.page_event (site, kind, page_id, title, new_title, ts, run_id)
        select e.site, e.kind, e.page_id, e.title, e.new_title, e.ts, p_run
        from jsonb_to_recordset(p_events) as e(site text, kind text, page_id bigint, title text, new_title text, ts timestamptz)
        on conflict (site, kind, page_id, ts, title) do nothing
        returning 1
    )
    select count(*)::integer from ins;
$$;

--
-- Name: sync_run_finish(uuid, text, jsonb, text, jsonb); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_run_finish(p_run uuid, p_status text, p_stats jsonb DEFAULT '{}'::jsonb, p_error text DEFAULT NULL::text, p_watermarks jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    k text;
begin
    if p_status not in ('succeeded', 'failed', 'cancelled') then
        raise exception 'bad status %', p_status using errcode = '22023';
    end if;
    if p_status = 'succeeded' and p_watermarks is not null then
        for k in select jsonb_object_keys(p_watermarks) loop
            insert into ops.watermark (site, stream, ts)
            values (split_part(k, '/', 1), split_part(k, '/', 2), (p_watermarks ->> k)::timestamptz)
            on conflict (site, stream) do update set ts = excluded.ts;
        end loop;
    end if;
    update ops.sync_run
       set status = p_status, finished_at = now(), stats = p_stats, error = p_error,
           watermark_after = case when p_status = 'succeeded' then p_watermarks end
     where run_id = p_run;
    if p_status = 'succeeded' then
        perform ops.refresh_counts();
    end if;
end;
$$;

--
-- Name: sync_run_start(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.sync_run_start(p_kind text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    v_run uuid;
begin
    insert into ops.sync_run (kind, watermark_before)
    values (p_kind, (select coalesce(jsonb_object_agg(site || '/' || stream, ts), '{}') from ops.watermark))
    returning run_id into v_run;
    return jsonb_build_object('run_id', v_run,
        'watermarks', (select coalesce(jsonb_object_agg(site || '/' || stream, ts), '{}') from ops.watermark));
end;
$$;

--
-- Name: template_pending(bigint, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.template_pending(p_after bigint DEFAULT 0, p_limit integer DEFAULT 1000) RETURNS TABLE(page_id bigint, title text)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
    select m.page_id, m.title
    from mirror.mech_page m
    left join derived.template_check c on c.mech_id = m.page_id
    where m.page_id > p_after
      and m.status in ('imported_documented', 'imported_undocumented')
      and (c.mech_id is null
           or (c.outcome in ('unresolved', 'denied') and c.checked_at < now() - interval '7 days'))
    order by m.page_id
    limit p_limit;
$$;

--
-- Name: unmark_feedback(bigint, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.unmark_feedback(p_wiki_id bigint, p_match_key text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    delete from work.scan_feedback where wiki_id = p_wiki_id and match_key = p_match_key and user_id = auth.uid();
end;
$$;

--
-- Name: refresh_wiki_gap(bigint[]); Type: FUNCTION; Schema: derived; Owner: -
--

CREATE FUNCTION derived.refresh_wiki_gap(p_ids bigint[] DEFAULT NULL::bigint[]) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
    changed integer;
begin
    with scope as (
        select w.page_id, w.title, mirror.title_key(w.title) as k
        from mirror.wiki_page w
        where p_ids is null or w.page_id = any (p_ids)
    ), matched as (
        select s.page_id, s.k,
               (exists (select 1 from mirror.mech_page m where mirror.title_key(m.title) = s.k)
                or exists (select 1 from derived.mech_key mk where mk.wiki_candidate_key = s.k)
                or exists (select 1 from derived.template_link t
                           join mirror.mech_page m on m.page_id = t.mech_id where t.wiki_id = s.page_id)
                or exists (select 1 from work.manual_link x
                           join mirror.mech_page m on m.page_id = x.mech_id where x.wiki_id = s.page_id)) as strict_match
        from scope s
    ), target as (
        select m.page_id as wiki_id,
               case
                   when m.strict_match then null
                   when exists (select 1 from mirror.mech_page mm
                                where mm.title ~ '^(הרב|רבי)\s'
                                  and mirror.rav_strip(mirror.title_key(mm.title)) = m.k)
                        or (m.k ~ '^(הרב|רבי) '
                            and exists (select 1 from mirror.mech_page mm
                                        where mirror.title_key(mm.title) = mirror.rav_strip(m.k)))
                        then 'rav_review'
                   else 'missing'
               end as kind
        from matched m
    ), upserted as (
        insert into derived.wiki_gap as g (wiki_id, kind)
        select wiki_id, kind from target where kind is not null
        on conflict (wiki_id) do update set kind = excluded.kind
            where g.kind is distinct from excluded.kind
        returning 1
    ), removed as (
        delete from derived.wiki_gap g
        where (p_ids is null or g.wiki_id = any (p_ids))
          and not exists (select 1 from target t where t.wiki_id = g.wiki_id and t.kind is not null)
        returning 1
    )
    select (select count(*) from upserted) + (select count(*) from removed) into changed;
    return changed;
end;
$$;

--
-- Name: rav_strip(text); Type: FUNCTION; Schema: mirror; Owner: -
--

CREATE FUNCTION mirror.rav_strip(k text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    SET search_path TO ''
    AS $$ select regexp_replace(k, '^(הרב|רבי) ', '') $$;

--
-- Name: title_key(text); Type: FUNCTION; Schema: mirror; Owner: -
--

CREATE FUNCTION mirror.title_key(t text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    SET search_path TO ''
    AS $$
    select btrim(
        regexp_replace(
            translate(
                translate(normalize(t, NFC), chr(8206) || chr(8207) || chr(1564) || chr(8234) || chr(8235) || chr(8236) || chr(8237) || chr(8238), ''),
                chr(1524) || chr(1523) || chr(8220) || chr(8221) || chr(8216) || chr(8217) || chr(8208) || chr(8209) || chr(8210) || chr(8211) || chr(8212) || chr(1470) || chr(160),
                '"''""''''------ '
            ),
            '[' || chr(92) || 's' || chr(8192) || '-' || chr(8202) || chr(8239) || chr(8287) || chr(12288) || ']+', ' ', 'g'
        ),
        ' '
    )
$$;

--
-- Name: health(); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.health() RETURNS TABLE(kind text, state text, last_success_at timestamp with time zone, running_since timestamp with time zone)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
    select t.kind,
           case
               when r.running_since is not null and r.running_since < now() - t.max_running then 'stuck'
               when s.last_success_at is null then 'never'
               when s.last_success_at < now() - t.max_age then 'stale'
               else 'ok'
           end,
           s.last_success_at,
           r.running_since
    from ops.health_threshold t
    left join lateral (select max(x.finished_at) as last_success_at
                       from ops.sync_run x where x.kind = t.kind and x.status = 'succeeded') s on true
    left join lateral (select min(x.started_at) as running_since
                       from ops.sync_run x where x.kind = t.kind and x.status = 'running') r on true;
$$;

--
-- Name: refresh_counts(); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.refresh_counts() RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages',   (select case when c.reltuples >= 0 then c.reltuples::bigint
                                      else (select count(*) from mirror.wiki_page) end
                           from pg_class c where c.oid = 'mirror.wiki_page'::regclass), now()),
        ('mech_pages',   (select case when c.reltuples >= 0 then c.reltuples::bigint
                                      else (select count(*) from mirror.mech_page) end
                           from pg_class c where c.oid = 'mirror.mech_page'::regclass), now()),
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

--
-- Name: after_exclusion_change(); Type: FUNCTION; Schema: work; Owner: -
--

CREATE FUNCTION work.after_exclusion_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
    perform ops.refresh_counts();
    return null;
end;
$$;

--
-- Name: after_link_change(); Type: FUNCTION; Schema: work; Owner: -
--

CREATE FUNCTION work.after_link_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
    perform derived.refresh_wiki_gap(array_remove(array[
        case when tg_op <> 'INSERT' then old.wiki_id end,
        case when tg_op <> 'DELETE' then new.wiki_id end], null));
    perform ops.refresh_counts();
    return null;
end;
$$;

--
-- Name: mech_page; Type: TABLE; Schema: mirror; Owner: -
--

CREATE TABLE mirror.mech_page (
    page_id bigint NOT NULL,
    title text NOT NULL,
    status text NOT NULL,
    source_type text DEFAULT 'unknown'::text NOT NULL,
    needs_attention boolean DEFAULT false NOT NULL,
    is_dictionary boolean DEFAULT false NOT NULL
);

--
-- Name: mech_status; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.mech_status (
    code text NOT NULL,
    label_he text NOT NULL,
    is_imported boolean NOT NULL,
    expects_wiki_match boolean NOT NULL
);

--
-- Name: mechalol_pages; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.mechalol_pages WITH (security_invoker='true') AS
 SELECT m.page_id AS id,
    m.title,
    ms.label_he AS status,
    NULL::bigint AS wikipedia_id,
    ''::text AS match_type
   FROM (mirror.mech_page m
     JOIN ref.mech_status ms ON ((ms.code = m.status)));

--
-- Name: wiki_page; Type: TABLE; Schema: mirror; Owner: -
--

CREATE TABLE mirror.wiki_page (
    page_id bigint NOT NULL,
    title text NOT NULL,
    latest_rev_id bigint
);

--
-- Name: exclusion; Type: TABLE; Schema: work; Owner: -
--

CREATE TABLE work.exclusion (
    id bigint NOT NULL,
    kind text NOT NULL,
    wiki_id bigint,
    title text,
    reason text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT exclusion_check CHECK (((wiki_id IS NOT NULL) OR (title IS NOT NULL))),
    CONSTRAINT exclusion_kind_check CHECK ((kind = ANY (ARRAY['import_excluded'::text, 'locked_create'::text])))
);

--
-- Name: page_lock; Type: TABLE; Schema: work; Owner: -
--

CREATE TABLE work.page_lock (
    site text NOT NULL,
    page_id bigint NOT NULL,
    level text NOT NULL,
    detected_by text NOT NULL,
    detected_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT page_lock_level_check CHECK ((level = ANY (ARRAY['read'::text, 'read-semi'::text, 'create'::text]))),
    CONSTRAINT page_lock_site_check CHECK ((site = ANY (ARRAY['wikipedia'::text, 'mechalol'::text])))
);

--
-- Name: v_locks; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_locks WITH (security_invoker='true') AS
 SELECT p.site,
    p.page_id,
    p.level,
    p.detected_by,
    p.detected_at,
    COALESCE(m.title, w.title) AS title
   FROM ((work.page_lock p
     LEFT JOIN mirror.mech_page m ON (((p.site = 'mechalol'::text) AND (m.page_id = p.page_id))))
     LEFT JOIN mirror.wiki_page w ON (((p.site = 'wikipedia'::text) AND (w.page_id = p.page_id))))
UNION ALL
 SELECT 'mechalol'::text AS site,
    0 AS page_id,
    'create'::text AS level,
    'exclusion'::text AS detected_by,
    x.created_at AS detected_at,
    x.title
   FROM work.exclusion x
  WHERE ((x.kind = 'locked_create'::text) AND (x.title IS NOT NULL));

--
-- Name: report_locked_pages; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_locked_pages WITH (security_invoker='true') AS
 SELECT page_id AS id,
    title,
        CASE
            WHEN (level = 'create'::text) THEN 'נעול ליצירה'::text
            ELSE 'נעול לקריאה'::text
        END AS lock_level,
    detected_by AS lock_source,
    NULL::bigint AS wikipedia_id,
    page_id AS mechalol_id,
    detected_at
   FROM api.v_locks l;

--
-- Name: wiki_gap; Type: TABLE; Schema: derived; Owner: -
--

CREATE TABLE derived.wiki_gap (
    wiki_id bigint NOT NULL,
    kind text NOT NULL,
    CONSTRAINT wiki_gap_kind_check CHECK ((kind = ANY (ARRAY['missing'::text, 'rav_review'::text])))
);

--
-- Name: content_scan; Type: TABLE; Schema: enrich; Owner: -
--

CREATE TABLE enrich.content_scan (
    wiki_id bigint NOT NULL,
    rev_id bigint,
    lists_version text,
    verdict_list_a text,
    verdict_list_s text,
    verdict_ctx_a text,
    verdict_ctx_s text,
    suspicion_a text,
    suspicion_s text,
    hidden_count_a integer,
    hidden_count_s integer,
    names_count_a integer,
    names_count_s integer,
    matches_total integer,
    photo_count integer,
    has_images boolean,
    dictionary text,
    dictionary_why text,
    topic text,
    scanned_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT content_scan_suspicion_a_check CHECK ((suspicion_a = ANY (ARRAY['high'::text, 'medium'::text, 'low'::text]))),
    CONSTRAINT content_scan_suspicion_s_check CHECK ((suspicion_s = ANY (ARRAY['high'::text, 'medium'::text, 'low'::text]))),
    CONSTRAINT content_scan_verdict_ctx_a_check CHECK ((verdict_ctx_a = ANY (ARRAY['problem'::text, 'review'::text, 'wording'::text, 'clean'::text]))),
    CONSTRAINT content_scan_verdict_ctx_s_check CHECK ((verdict_ctx_s = ANY (ARRAY['problem'::text, 'review'::text, 'wording'::text, 'clean'::text]))),
    CONSTRAINT content_scan_verdict_list_a_check CHECK ((verdict_list_a = ANY (ARRAY['problem'::text, 'review'::text, 'wording'::text, 'clean'::text]))),
    CONSTRAINT content_scan_verdict_list_s_check CHECK ((verdict_list_s = ANY (ARRAY['problem'::text, 'review'::text, 'wording'::text, 'clean'::text])))
);

--
-- Name: wiki_enrichment; Type: TABLE; Schema: enrich; Owner: -
--

CREATE TABLE enrich.wiki_enrichment (
    wiki_id bigint NOT NULL,
    wikidata_desc text,
    wiki_created_at timestamp with time zone,
    length bigint,
    mech_redirect boolean,
    desc_checked_at timestamp with time zone,
    created_checked_at timestamp with time zone,
    length_checked_at timestamp with time zone,
    redirect_checked_at timestamp with time zone,
    locks_checked_at timestamp with time zone
);

--
-- Name: report_missing_from_mechalol; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_missing_from_mechalol WITH (security_invoker='true') AS
 SELECT g.wiki_id AS id,
    w.title,
    e.desc_checked_at AS checked_at,
    e.wikidata_desc,
    e.length AS easy_import_length,
    s.has_images AS easy_import_has_images,
    NULL::boolean AS problematic_words_clean,
    e.wiki_created_at AS created_at,
    COALESCE(e.mech_redirect, false) AS mechalol_redirect_exists,
    (e.length_checked_at IS NOT NULL) AS easy_import_checked,
    (e.created_checked_at IS NOT NULL) AS created_at_checked
   FROM (((derived.wiki_gap g
     JOIN mirror.wiki_page w ON ((w.page_id = g.wiki_id)))
     LEFT JOIN enrich.wiki_enrichment e ON ((e.wiki_id = g.wiki_id)))
     LEFT JOIN enrich.content_scan s ON ((s.wiki_id = g.wiki_id)))
  WHERE ((g.kind = 'missing'::text) AND (NOT (EXISTS ( SELECT 1
           FROM work.exclusion x
          WHERE ((x.kind = ANY (ARRAY['import_excluded'::text, 'locked_create'::text])) AND ((x.wiki_id = w.page_id) OR (x.title = w.title)))))));

--
-- Name: report_missing_word_filter; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_missing_word_filter WITH (security_invoker='true') AS
 SELECT m.id,
    m.title,
    m.checked_at,
    m.wikidata_desc,
    m.easy_import_length,
    m.created_at,
    m.mechalol_redirect_exists,
    s.verdict_list_a AS verdict,
    s.verdict_list_s AS verdict_suggested,
    s.has_images,
    s.photo_count,
    NULL::jsonb AS counts,
    s.matches_total,
    NULL::jsonb AS images,
    s.scanned_at,
    s.verdict_ctx_a AS ctx_verdict,
    s.suspicion_a AS ctx_suspicion,
    s.verdict_ctx_s AS ctx_verdict_suggested,
    s.suspicion_s AS ctx_suspicion_suggested,
    s.hidden_count_a AS hidden_count,
    s.hidden_count_s AS hidden_count_suggested,
    s.dictionary,
    s.dictionary_why,
    s.topic,
    s.names_count_a AS names_count,
    s.names_count_s AS names_count_suggested,
        CASE
            WHEN (s.wiki_id IS NULL) THEN 'not_scanned'::text
            WHEN (s.rev_id IS DISTINCT FROM w.latest_rev_id) THEN 'stale'::text
            ELSE 'scanned'::text
        END AS scan_state
   FROM ((api.report_missing_from_mechalol m
     JOIN mirror.wiki_page w ON ((w.page_id = m.id)))
     LEFT JOIN enrich.content_scan s ON ((s.wiki_id = m.id)));

--
-- Name: manual_link; Type: TABLE; Schema: work; Owner: -
--

CREATE TABLE work.manual_link (
    mech_id bigint NOT NULL,
    wiki_id bigint NOT NULL,
    reason text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: v_rav_review; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_rav_review WITH (security_invoker='true') AS
 SELECT w.page_id AS wiki_id,
    w.title AS wiki_title,
    m.page_id AS mech_id,
    m.title AS mech_title,
    m.status AS mech_status
   FROM ((derived.wiki_gap g
     JOIN mirror.wiki_page w ON ((w.page_id = g.wiki_id)))
     JOIN mirror.mech_page m ON ((((m.title ~ '^(הרב|רבי)\s'::text) AND (mirror.rav_strip(mirror.title_key(m.title)) = mirror.title_key(w.title))) OR (mirror.title_key(m.title) = mirror.rav_strip(mirror.title_key(w.title))))))
  WHERE ((g.kind = 'rav_review'::text) AND (NOT (EXISTS ( SELECT 1
           FROM work.manual_link x
          WHERE (x.mech_id = m.page_id)))));

--
-- Name: report_rav_prefix_normalization; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_rav_prefix_normalization WITH (security_invoker='true') AS
 SELECT r.wiki_id AS wikipedia_id,
    r.wiki_title AS wikipedia_title,
    mirror.title_key(r.wiki_title) AS normalized_title,
    r.mech_id AS mechalol_id,
    r.mech_title AS mechalol_title,
    ms.label_he AS mechalol_status,
    NULL::text AS mechalol_source_type,
    ''::text AS mechalol_match_type,
    count(*) OVER (PARTITION BY r.wiki_id) AS candidate_count
   FROM (api.v_rav_review r
     JOIN ref.mech_status ms ON ((ms.code = r.mech_status)));

--
-- Name: rev_check; Type: TABLE; Schema: derived; Owner: -
--

CREATE TABLE derived.rev_check (
    mech_id bigint NOT NULL,
    rev_task text NOT NULL,
    rev_id bigint,
    linked_wiki_id bigint,
    rev_page_id bigint,
    rev_page_title text,
    checked_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rev_check_rev_task_check CHECK ((rev_task = ANY (ARRAY['rename'::text, 'redirect'::text, 'bad_rev'::text, 'deleted_by_rev'::text])))
);

--
-- Name: v_rev_tasks; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_rev_tasks WITH (security_invoker='true') AS
 SELECT c.mech_id AS id,
    m.title,
    ms.label_he AS status_label,
    c.rev_task,
    c.rev_id,
    c.linked_wiki_id,
    lw.title AS linked_title,
    c.rev_page_id,
    c.rev_page_title,
    c.checked_at
   FROM (((derived.rev_check c
     JOIN mirror.mech_page m ON ((m.page_id = c.mech_id)))
     JOIN ref.mech_status ms ON ((ms.code = m.status)))
     LEFT JOIN mirror.wiki_page lw ON ((lw.page_id = c.linked_wiki_id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM work.manual_link x
          WHERE (x.mech_id = c.mech_id))));

--
-- Name: report_rev_tasks; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_rev_tasks WITH (security_invoker='true') AS
 SELECT id,
    title,
    status_label AS status,
    rev_task,
    rev_id AS sort_template_rev,
    NULL::date AS sort_template_date,
    NULL::bigint AS wikipedia_id,
    linked_title,
    rev_page_id,
    rev_page_title,
    checked_at
   FROM api.v_rev_tasks v;

--
-- Name: report_source_update; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_source_update WITH (security_invoker='true') AS
 SELECT NULL::bigint AS id,
    NULL::text AS title,
    NULL::date AS sort_template_date,
    NULL::text AS update_bucket,
    NULL::bigint AS sort_template_rev,
    NULL::bigint AS wikipedia_id
  WHERE false;

--
-- Name: v_undocumented; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_undocumented WITH (security_invoker='true') AS
 SELECT m.page_id AS id,
    m.title,
    m.source_type,
    w.page_id AS wiki_id
   FROM (mirror.mech_page m
     LEFT JOIN mirror.wiki_page w ON ((mirror.title_key(w.title) = mirror.title_key(m.title))))
  WHERE ((m.status = 'imported_undocumented'::text) AND (NOT m.needs_attention) AND (NOT m.is_dictionary) AND (NOT (EXISTS ( SELECT 1
           FROM work.manual_link x
          WHERE (x.mech_id = m.page_id)))));

--
-- Name: report_undocumented_import; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_undocumented_import WITH (security_invoker='true') AS
 SELECT id,
    title,
    source_type,
    wiki_id AS wikipedia_id,
    ''::text AS match_type
   FROM api.v_undocumented u;

--
-- Name: page_event; Type: TABLE; Schema: mirror; Owner: -
--

CREATE TABLE mirror.page_event (
    id bigint NOT NULL,
    site text NOT NULL,
    kind text NOT NULL,
    page_id bigint NOT NULL,
    title text NOT NULL,
    new_title text,
    ts timestamp with time zone NOT NULL,
    run_id uuid,
    CONSTRAINT page_event_kind_check CHECK ((kind = ANY (ARRAY['create'::text, 'delete'::text, 'move'::text, 'restore'::text]))),
    CONSTRAINT page_event_site_check CHECK ((site = ANY (ARRAY['wikipedia'::text, 'mechalol'::text])))
);

--
-- Name: v_moves; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_moves WITH (security_invoker='true') AS
 SELECT m.page_id AS id,
    m.title,
    ev.title AS old_title,
    ev.new_title AS wikipedia_title,
    ev.ts AS moved_at
   FROM (mirror.page_event ev
     JOIN mirror.mech_page m ON ((mirror.title_key(m.title) = mirror.title_key(ev.title))))
  WHERE ((ev.site = 'wikipedia'::text) AND (ev.kind = 'move'::text) AND (NOT (EXISTS ( SELECT 1
           FROM mirror.wiki_page w
          WHERE (mirror.title_key(w.title) = mirror.title_key(m.title))))));

--
-- Name: report_wikipedia_moves; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.report_wikipedia_moves WITH (security_invoker='true') AS
 SELECT v.id,
    v.title,
    v.old_title,
    v.wikipedia_title,
    v.moved_at AS renamed_at,
    'title'::text AS via,
    ms.label_he AS status
   FROM ((api.v_moves v
     JOIN mirror.mech_page m ON ((m.page_id = v.id)))
     JOIN ref.mech_status ms ON ((ms.code = m.status)));

--
-- Name: watermark; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.watermark (
    site text NOT NULL,
    stream text NOT NULL,
    ts timestamp with time zone NOT NULL,
    CONSTRAINT watermark_site_check CHECK ((site = ANY (ARRAY['wikipedia'::text, 'mechalol'::text])))
);

--
-- Name: sync_watermarks; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.sync_watermarks WITH (security_invoker='true') AS
 SELECT ts AS last_synced_ts
   FROM ops.watermark w
  WHERE (stream = 'delta'::text);

--
-- Name: dashboard_counts; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.dashboard_counts (
    key text NOT NULL,
    n bigint NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: v_counts; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_counts WITH (security_invoker='true') AS
 SELECT key,
    n,
    updated_at
   FROM ops.dashboard_counts;

--
-- Name: v_missing; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_missing WITH (security_invoker='true') AS
 SELECT w.page_id AS id,
    w.title,
    e.wiki_created_at AS created_at,
    e.wikidata_desc,
    e.length,
    COALESCE(e.mech_redirect, false) AS mech_redirect,
    s.has_images,
    s.photo_count,
    s.verdict_list_a,
    s.verdict_list_s,
    s.verdict_ctx_a,
    s.verdict_ctx_s,
    s.suspicion_a,
    s.suspicion_s,
    s.hidden_count_a,
    s.hidden_count_s,
    s.names_count_a,
    s.names_count_s,
    s.matches_total,
    s.dictionary,
    s.dictionary_why,
    s.topic,
    s.scanned_at,
        CASE
            WHEN (s.wiki_id IS NULL) THEN 'not_scanned'::text
            WHEN (s.rev_id IS DISTINCT FROM w.latest_rev_id) THEN 'stale'::text
            ELSE 'scanned'::text
        END AS scan_state
   FROM (((derived.wiki_gap g
     JOIN mirror.wiki_page w ON ((w.page_id = g.wiki_id)))
     LEFT JOIN enrich.wiki_enrichment e ON ((e.wiki_id = w.page_id)))
     LEFT JOIN enrich.content_scan s ON ((s.wiki_id = w.page_id)))
  WHERE ((g.kind = 'missing'::text) AND (NOT (EXISTS ( SELECT 1
           FROM work.exclusion x
          WHERE ((x.kind = ANY (ARRAY['import_excluded'::text, 'locked_create'::text])) AND ((x.wiki_id = w.page_id) OR (x.title = w.title)))))));

--
-- Name: sync_run; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.sync_run (
    run_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    status text DEFAULT 'running'::text NOT NULL,
    step text,
    stats jsonb DEFAULT '{}'::jsonb NOT NULL,
    error text,
    watermark_before jsonb,
    watermark_after jsonb,
    CONSTRAINT sync_run_kind_check CHECK ((kind = ANY (ARRAY['sync'::text, 'reconcile'::text, 'enrich'::text, 'scan'::text, 'maintenance'::text, 'rebuild'::text]))),
    CONSTRAINT sync_run_status_check CHECK ((status = ANY (ARRAY['running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))
);

--
-- Name: v_sync_status; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_sync_status WITH (security_invoker='true') AS
 SELECT DISTINCT ON (r.kind) r.kind,
    r.status,
    r.started_at,
    r.finished_at,
    r.step,
    r.stats,
    r.error,
    COALESCE(h.state, 'ok'::text) AS health,
    h.last_success_at
   FROM (ops.sync_run r
     LEFT JOIN ops.health() h(kind, state, last_success_at, running_since) ON ((h.kind = r.kind)))
  ORDER BY r.kind, r.started_at DESC;

--
-- Name: template_check; Type: TABLE; Schema: derived; Owner: -
--

CREATE TABLE derived.template_check (
    mech_id bigint NOT NULL,
    outcome text NOT NULL,
    rev_id bigint,
    checked_at timestamp with time zone DEFAULT now() NOT NULL,
    template_rev bigint,
    template_title text,
    CONSTRAINT template_check_outcome_check CHECK ((outcome = ANY (ARRAY['none'::text, 'same'::text, 'ok'::text, 'unresolved'::text, 'denied'::text])))
);

--
-- Name: template_link; Type: TABLE; Schema: derived; Owner: -
--

CREATE TABLE derived.template_link (
    mech_id bigint NOT NULL,
    wiki_id bigint,
    template_ref text,
    verified_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: v_template_issues; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.v_template_issues WITH (security_invoker='true') AS
 SELECT m.page_id AS id,
    m.title,
    c.outcome,
    l.template_ref,
    c.checked_at
   FROM ((derived.template_check c
     JOIN mirror.mech_page m ON ((m.page_id = c.mech_id)))
     LEFT JOIN derived.template_link l ON ((l.mech_id = c.mech_id)))
  WHERE ((c.outcome = ANY (ARRAY['unresolved'::text, 'denied'::text])) AND (NOT (EXISTS ( SELECT 1
           FROM work.manual_link x
          WHERE (x.mech_id = c.mech_id)))));

--
-- Name: wikipedia_pages; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.wikipedia_pages WITH (security_invoker='true') AS
 SELECT page_id AS id,
    title
   FROM mirror.wiki_page w;

--
-- Name: scan_feedback; Type: TABLE; Schema: work; Owner: -
--

CREATE TABLE work.scan_feedback (
    id bigint NOT NULL,
    wiki_id bigint NOT NULL,
    match_key text NOT NULL,
    word text NOT NULL,
    entries text[] NOT NULL,
    topic text,
    hidden text,
    label text NOT NULL,
    level text,
    context_before text,
    context_after text,
    lists_version text,
    user_id uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT scan_feedback_label_check CHECK ((label = ANY (ARRAY['false'::text, 'true'::text])))
);

--
-- Name: word_filter_feedback; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.word_filter_feedback AS
 SELECT wiki_id AS wikipedia_id,
    match_key,
    label,
    user_id
   FROM work.scan_feedback f
  WHERE (user_id = auth.uid());

--
-- Name: content_scan_detail; Type: TABLE; Schema: enrich; Owner: -
--

CREATE TABLE enrich.content_scan_detail (
    wiki_id bigint NOT NULL,
    counts jsonb,
    matches jsonb,
    images jsonb
);

--
-- Name: word_filter_results; Type: VIEW; Schema: api; Owner: -
--

CREATE VIEW api.word_filter_results AS
 SELECT s.wiki_id AS wikipedia_id,
    d.matches,
    s.matches_total,
    d.images,
    s.photo_count,
    s.scanned_at,
    s.rev_id,
    s.lists_version
   FROM (enrich.content_scan s
     LEFT JOIN enrich.content_scan_detail d ON ((d.wiki_id = s.wiki_id)))
  WHERE (EXISTS ( SELECT 1
           FROM derived.wiki_gap g
          WHERE ((g.wiki_id = s.wiki_id) AND (g.kind = 'missing'::text))));

--
-- Name: mech_key; Type: TABLE; Schema: derived; Owner: -
--

CREATE TABLE derived.mech_key (
    mech_id bigint NOT NULL,
    wiki_candidate_key text NOT NULL,
    rules text[] DEFAULT '{}'::text[] NOT NULL
);

--
-- Name: page_event_id_seq; Type: SEQUENCE; Schema: mirror; Owner: -
--

CREATE SEQUENCE mirror.page_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: page_event_id_seq; Type: SEQUENCE OWNED BY; Schema: mirror; Owner: -
--

ALTER SEQUENCE mirror.page_event_id_seq OWNED BY mirror.page_event.id;

--
-- Name: health_threshold; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.health_threshold (
    kind text NOT NULL,
    max_age interval NOT NULL,
    max_running interval NOT NULL,
    CONSTRAINT health_threshold_kind_check CHECK ((kind = ANY (ARRAY['sync'::text, 'reconcile'::text, 'enrich'::text, 'scan'::text, 'maintenance'::text, 'rebuild'::text])))
);

--
-- Name: reconcile_finding; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.reconcile_finding (
    id bigint NOT NULL,
    run_id uuid NOT NULL,
    site text NOT NULL,
    class text NOT NULL,
    page_id bigint NOT NULL,
    title text,
    detail jsonb,
    explained_by_window boolean DEFAULT false NOT NULL,
    CONSTRAINT reconcile_finding_site_check CHECK ((site = ANY (ARRAY['wikipedia'::text, 'mechalol'::text])))
);

--
-- Name: reconcile_finding_id_seq; Type: SEQUENCE; Schema: ops; Owner: -
--

CREATE SEQUENCE ops.reconcile_finding_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: reconcile_finding_id_seq; Type: SEQUENCE OWNED BY; Schema: ops; Owner: -
--

ALTER SEQUENCE ops.reconcile_finding_id_seq OWNED BY ops.reconcile_finding.id;

--
-- Name: reconcile_run; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.reconcile_run (
    run_id uuid DEFAULT gen_random_uuid() NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    snapshot_meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    summary jsonb DEFAULT '{}'::jsonb NOT NULL
);

--
-- Name: schema_migration; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.schema_migration (
    version text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: mech_source; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.mech_source (
    code text NOT NULL,
    description text NOT NULL
);

--
-- Name: admin; Type: TABLE; Schema: work; Owner: -
--

CREATE TABLE work.admin (
    user_id uuid NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: exclusion_id_seq; Type: SEQUENCE; Schema: work; Owner: -
--

CREATE SEQUENCE work.exclusion_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: exclusion_id_seq; Type: SEQUENCE OWNED BY; Schema: work; Owner: -
--

ALTER SEQUENCE work.exclusion_id_seq OWNED BY work.exclusion.id;

--
-- Name: scan_feedback_id_seq; Type: SEQUENCE; Schema: work; Owner: -
--

ALTER TABLE work.scan_feedback ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME work.scan_feedback_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: page_event id; Type: DEFAULT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.page_event ALTER COLUMN id SET DEFAULT nextval('mirror.page_event_id_seq'::regclass);

--
-- Name: reconcile_finding id; Type: DEFAULT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.reconcile_finding ALTER COLUMN id SET DEFAULT nextval('ops.reconcile_finding_id_seq'::regclass);

--
-- Name: exclusion id; Type: DEFAULT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.exclusion ALTER COLUMN id SET DEFAULT nextval('work.exclusion_id_seq'::regclass);

--
-- Name: mech_key mech_key_pkey; Type: CONSTRAINT; Schema: derived; Owner: -
--

ALTER TABLE ONLY derived.mech_key
    ADD CONSTRAINT mech_key_pkey PRIMARY KEY (mech_id);

--
-- Name: rev_check rev_check_pkey; Type: CONSTRAINT; Schema: derived; Owner: -
--

ALTER TABLE ONLY derived.rev_check
    ADD CONSTRAINT rev_check_pkey PRIMARY KEY (mech_id);

--
-- Name: template_check template_check_pkey; Type: CONSTRAINT; Schema: derived; Owner: -
--

ALTER TABLE ONLY derived.template_check
    ADD CONSTRAINT template_check_pkey PRIMARY KEY (mech_id);

--
-- Name: template_link template_link_pkey; Type: CONSTRAINT; Schema: derived; Owner: -
--

ALTER TABLE ONLY derived.template_link
    ADD CONSTRAINT template_link_pkey PRIMARY KEY (mech_id);

--
-- Name: wiki_gap wiki_gap_pkey; Type: CONSTRAINT; Schema: derived; Owner: -
--

ALTER TABLE ONLY derived.wiki_gap
    ADD CONSTRAINT wiki_gap_pkey PRIMARY KEY (wiki_id);

--
-- Name: content_scan_detail content_scan_detail_pkey; Type: CONSTRAINT; Schema: enrich; Owner: -
--

ALTER TABLE ONLY enrich.content_scan_detail
    ADD CONSTRAINT content_scan_detail_pkey PRIMARY KEY (wiki_id);

--
-- Name: content_scan content_scan_pkey; Type: CONSTRAINT; Schema: enrich; Owner: -
--

ALTER TABLE ONLY enrich.content_scan
    ADD CONSTRAINT content_scan_pkey PRIMARY KEY (wiki_id);

--
-- Name: wiki_enrichment wiki_enrichment_pkey; Type: CONSTRAINT; Schema: enrich; Owner: -
--

ALTER TABLE ONLY enrich.wiki_enrichment
    ADD CONSTRAINT wiki_enrichment_pkey PRIMARY KEY (wiki_id);

--
-- Name: mech_page mech_page_pkey; Type: CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.mech_page
    ADD CONSTRAINT mech_page_pkey PRIMARY KEY (page_id);

--
-- Name: mech_page mech_page_title_key; Type: CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.mech_page
    ADD CONSTRAINT mech_page_title_key UNIQUE (title);

--
-- Name: page_event page_event_pkey; Type: CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.page_event
    ADD CONSTRAINT page_event_pkey PRIMARY KEY (id);

--
-- Name: page_event page_event_unique; Type: CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.page_event
    ADD CONSTRAINT page_event_unique UNIQUE (site, kind, page_id, ts, title);

--
-- Name: wiki_page wiki_page_pkey; Type: CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.wiki_page
    ADD CONSTRAINT wiki_page_pkey PRIMARY KEY (page_id);

--
-- Name: wiki_page wiki_page_title_key; Type: CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.wiki_page
    ADD CONSTRAINT wiki_page_title_key UNIQUE (title);

--
-- Name: dashboard_counts dashboard_counts_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.dashboard_counts
    ADD CONSTRAINT dashboard_counts_pkey PRIMARY KEY (key);

--
-- Name: health_threshold health_threshold_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.health_threshold
    ADD CONSTRAINT health_threshold_pkey PRIMARY KEY (kind);

--
-- Name: reconcile_finding reconcile_finding_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.reconcile_finding
    ADD CONSTRAINT reconcile_finding_pkey PRIMARY KEY (id);

--
-- Name: reconcile_run reconcile_run_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.reconcile_run
    ADD CONSTRAINT reconcile_run_pkey PRIMARY KEY (run_id);

--
-- Name: schema_migration schema_migration_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.schema_migration
    ADD CONSTRAINT schema_migration_pkey PRIMARY KEY (version);

--
-- Name: sync_run sync_run_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.sync_run
    ADD CONSTRAINT sync_run_pkey PRIMARY KEY (run_id);

--
-- Name: watermark watermark_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.watermark
    ADD CONSTRAINT watermark_pkey PRIMARY KEY (site, stream);

--
-- Name: mech_source mech_source_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.mech_source
    ADD CONSTRAINT mech_source_pkey PRIMARY KEY (code);

--
-- Name: mech_status mech_status_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.mech_status
    ADD CONSTRAINT mech_status_pkey PRIMARY KEY (code);

--
-- Name: admin admin_pkey; Type: CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.admin
    ADD CONSTRAINT admin_pkey PRIMARY KEY (user_id);

--
-- Name: exclusion exclusion_pkey; Type: CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.exclusion
    ADD CONSTRAINT exclusion_pkey PRIMARY KEY (id);

--
-- Name: manual_link manual_link_pkey; Type: CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.manual_link
    ADD CONSTRAINT manual_link_pkey PRIMARY KEY (mech_id);

--
-- Name: page_lock page_lock_pkey; Type: CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.page_lock
    ADD CONSTRAINT page_lock_pkey PRIMARY KEY (site, page_id);

--
-- Name: scan_feedback scan_feedback_pkey; Type: CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.scan_feedback
    ADD CONSTRAINT scan_feedback_pkey PRIMARY KEY (id);

--
-- Name: scan_feedback scan_feedback_wiki_id_match_key_user_id_key; Type: CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.scan_feedback
    ADD CONSTRAINT scan_feedback_wiki_id_match_key_user_id_key UNIQUE (wiki_id, match_key, user_id);

--
-- Name: mech_key_candidate_idx; Type: INDEX; Schema: derived; Owner: -
--

CREATE INDEX mech_key_candidate_idx ON derived.mech_key USING btree (wiki_candidate_key);

--
-- Name: rev_check_task_idx; Type: INDEX; Schema: derived; Owner: -
--

CREATE INDEX rev_check_task_idx ON derived.rev_check USING btree (rev_task, mech_id);

--
-- Name: template_check_outcome_idx; Type: INDEX; Schema: derived; Owner: -
--

CREATE INDEX template_check_outcome_idx ON derived.template_check USING btree (outcome) WHERE (outcome = ANY (ARRAY['unresolved'::text, 'denied'::text]));

--
-- Name: template_link_wiki_idx; Type: INDEX; Schema: derived; Owner: -
--

CREATE INDEX template_link_wiki_idx ON derived.template_link USING btree (wiki_id) WHERE (wiki_id IS NOT NULL);

--
-- Name: wiki_gap_kind_idx; Type: INDEX; Schema: derived; Owner: -
--

CREATE INDEX wiki_gap_kind_idx ON derived.wiki_gap USING btree (kind, wiki_id);

--
-- Name: content_scan_topic_idx; Type: INDEX; Schema: enrich; Owner: -
--

CREATE INDEX content_scan_topic_idx ON enrich.content_scan USING btree (topic);

--
-- Name: mech_page_rav_idx; Type: INDEX; Schema: mirror; Owner: -
--

CREATE INDEX mech_page_rav_idx ON mirror.mech_page USING btree (mirror.rav_strip(mirror.title_key(title))) WHERE (title ~ '^(הרב|רבי)\s'::text);

--
-- Name: mech_page_title_key_idx; Type: INDEX; Schema: mirror; Owner: -
--

CREATE INDEX mech_page_title_key_idx ON mirror.mech_page USING btree (mirror.title_key(title));

--
-- Name: page_event_page_idx; Type: INDEX; Schema: mirror; Owner: -
--

CREATE INDEX page_event_page_idx ON mirror.page_event USING btree (site, page_id);

--
-- Name: page_event_ts_idx; Type: INDEX; Schema: mirror; Owner: -
--

CREATE INDEX page_event_ts_idx ON mirror.page_event USING btree (site, kind, ts DESC);

--
-- Name: wiki_page_title_key_idx; Type: INDEX; Schema: mirror; Owner: -
--

CREATE INDEX wiki_page_title_key_idx ON mirror.wiki_page USING btree (mirror.title_key(title));

--
-- Name: reconcile_finding_run_idx; Type: INDEX; Schema: ops; Owner: -
--

CREATE INDEX reconcile_finding_run_idx ON ops.reconcile_finding USING btree (run_id, site, class);

--
-- Name: sync_run_kind_idx; Type: INDEX; Schema: ops; Owner: -
--

CREATE INDEX sync_run_kind_idx ON ops.sync_run USING btree (kind, started_at DESC);

--
-- Name: exclusion_title_idx; Type: INDEX; Schema: work; Owner: -
--

CREATE UNIQUE INDEX exclusion_title_idx ON work.exclusion USING btree (kind, title) WHERE (title IS NOT NULL);

--
-- Name: exclusion_wiki_idx; Type: INDEX; Schema: work; Owner: -
--

CREATE UNIQUE INDEX exclusion_wiki_idx ON work.exclusion USING btree (kind, wiki_id) WHERE (wiki_id IS NOT NULL);

--
-- Name: exclusion exclusion_refresh; Type: TRIGGER; Schema: work; Owner: -
--

CREATE TRIGGER exclusion_refresh AFTER INSERT OR DELETE OR UPDATE ON work.exclusion FOR EACH ROW EXECUTE FUNCTION work.after_exclusion_change();

--
-- Name: manual_link manual_link_refresh; Type: TRIGGER; Schema: work; Owner: -
--

CREATE TRIGGER manual_link_refresh AFTER INSERT OR DELETE OR UPDATE ON work.manual_link FOR EACH ROW EXECUTE FUNCTION work.after_link_change();

--
-- Name: content_scan_detail content_scan_detail_wiki_id_fkey; Type: FK CONSTRAINT; Schema: enrich; Owner: -
--

ALTER TABLE ONLY enrich.content_scan_detail
    ADD CONSTRAINT content_scan_detail_wiki_id_fkey FOREIGN KEY (wiki_id) REFERENCES enrich.content_scan(wiki_id) ON DELETE CASCADE;

--
-- Name: mech_page mech_page_source_type_fkey; Type: FK CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.mech_page
    ADD CONSTRAINT mech_page_source_type_fkey FOREIGN KEY (source_type) REFERENCES ref.mech_source(code);

--
-- Name: mech_page mech_page_status_fkey; Type: FK CONSTRAINT; Schema: mirror; Owner: -
--

ALTER TABLE ONLY mirror.mech_page
    ADD CONSTRAINT mech_page_status_fkey FOREIGN KEY (status) REFERENCES ref.mech_status(code);

--
-- Name: reconcile_finding reconcile_finding_run_id_fkey; Type: FK CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.reconcile_finding
    ADD CONSTRAINT reconcile_finding_run_id_fkey FOREIGN KEY (run_id) REFERENCES ops.reconcile_run(run_id) ON DELETE CASCADE;

--
-- Name: admin admin_user_id_fkey; Type: FK CONSTRAINT; Schema: work; Owner: -
--

ALTER TABLE ONLY work.admin
    ADD CONSTRAINT admin_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

--
-- Name: mech_key; Type: ROW SECURITY; Schema: derived; Owner: -
--

ALTER TABLE derived.mech_key ENABLE ROW LEVEL SECURITY;

--
-- Name: mech_key public_read; Type: POLICY; Schema: derived; Owner: -
--

CREATE POLICY public_read ON derived.mech_key FOR SELECT TO anon, authenticated USING (true);

--
-- Name: rev_check public_read; Type: POLICY; Schema: derived; Owner: -
--

CREATE POLICY public_read ON derived.rev_check FOR SELECT TO anon, authenticated USING (true);

--
-- Name: template_check public_read; Type: POLICY; Schema: derived; Owner: -
--

CREATE POLICY public_read ON derived.template_check FOR SELECT TO anon, authenticated USING (true);

--
-- Name: template_link public_read; Type: POLICY; Schema: derived; Owner: -
--

CREATE POLICY public_read ON derived.template_link FOR SELECT TO anon, authenticated USING (true);

--
-- Name: wiki_gap public_read; Type: POLICY; Schema: derived; Owner: -
--

CREATE POLICY public_read ON derived.wiki_gap FOR SELECT TO anon, authenticated USING (true);

--
-- Name: rev_check; Type: ROW SECURITY; Schema: derived; Owner: -
--

ALTER TABLE derived.rev_check ENABLE ROW LEVEL SECURITY;

--
-- Name: template_check; Type: ROW SECURITY; Schema: derived; Owner: -
--

ALTER TABLE derived.template_check ENABLE ROW LEVEL SECURITY;

--
-- Name: template_link; Type: ROW SECURITY; Schema: derived; Owner: -
--

ALTER TABLE derived.template_link ENABLE ROW LEVEL SECURITY;

--
-- Name: wiki_gap; Type: ROW SECURITY; Schema: derived; Owner: -
--

ALTER TABLE derived.wiki_gap ENABLE ROW LEVEL SECURITY;

--
-- Name: content_scan; Type: ROW SECURITY; Schema: enrich; Owner: -
--

ALTER TABLE enrich.content_scan ENABLE ROW LEVEL SECURITY;

--
-- Name: content_scan_detail; Type: ROW SECURITY; Schema: enrich; Owner: -
--

ALTER TABLE enrich.content_scan_detail ENABLE ROW LEVEL SECURITY;

--
-- Name: content_scan public_read; Type: POLICY; Schema: enrich; Owner: -
--

CREATE POLICY public_read ON enrich.content_scan FOR SELECT TO anon, authenticated USING (true);

--
-- Name: wiki_enrichment public_read; Type: POLICY; Schema: enrich; Owner: -
--

CREATE POLICY public_read ON enrich.wiki_enrichment FOR SELECT TO anon, authenticated USING (true);

--
-- Name: wiki_enrichment; Type: ROW SECURITY; Schema: enrich; Owner: -
--

ALTER TABLE enrich.wiki_enrichment ENABLE ROW LEVEL SECURITY;

--
-- Name: mech_page; Type: ROW SECURITY; Schema: mirror; Owner: -
--

ALTER TABLE mirror.mech_page ENABLE ROW LEVEL SECURITY;

--
-- Name: page_event; Type: ROW SECURITY; Schema: mirror; Owner: -
--

ALTER TABLE mirror.page_event ENABLE ROW LEVEL SECURITY;

--
-- Name: mech_page public_read; Type: POLICY; Schema: mirror; Owner: -
--

CREATE POLICY public_read ON mirror.mech_page FOR SELECT TO anon, authenticated USING (true);

--
-- Name: page_event public_read; Type: POLICY; Schema: mirror; Owner: -
--

CREATE POLICY public_read ON mirror.page_event FOR SELECT TO anon, authenticated USING (true);

--
-- Name: wiki_page public_read; Type: POLICY; Schema: mirror; Owner: -
--

CREATE POLICY public_read ON mirror.wiki_page FOR SELECT TO anon, authenticated USING (true);

--
-- Name: wiki_page; Type: ROW SECURITY; Schema: mirror; Owner: -
--

ALTER TABLE mirror.wiki_page ENABLE ROW LEVEL SECURITY;

--
-- Name: dashboard_counts; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.dashboard_counts ENABLE ROW LEVEL SECURITY;

--
-- Name: health_threshold; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.health_threshold ENABLE ROW LEVEL SECURITY;

--
-- Name: dashboard_counts public_read; Type: POLICY; Schema: ops; Owner: -
--

CREATE POLICY public_read ON ops.dashboard_counts FOR SELECT TO anon, authenticated USING (true);

--
-- Name: health_threshold public_read; Type: POLICY; Schema: ops; Owner: -
--

CREATE POLICY public_read ON ops.health_threshold FOR SELECT TO anon, authenticated USING (true);

--
-- Name: reconcile_run public_read; Type: POLICY; Schema: ops; Owner: -
--

CREATE POLICY public_read ON ops.reconcile_run FOR SELECT TO anon, authenticated USING (true);

--
-- Name: sync_run public_read; Type: POLICY; Schema: ops; Owner: -
--

CREATE POLICY public_read ON ops.sync_run FOR SELECT TO anon, authenticated USING (true);

--
-- Name: watermark public_read; Type: POLICY; Schema: ops; Owner: -
--

CREATE POLICY public_read ON ops.watermark FOR SELECT TO anon, authenticated USING (true);

--
-- Name: reconcile_finding; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.reconcile_finding ENABLE ROW LEVEL SECURITY;

--
-- Name: reconcile_run; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.reconcile_run ENABLE ROW LEVEL SECURITY;

--
-- Name: schema_migration; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.schema_migration ENABLE ROW LEVEL SECURITY;

--
-- Name: sync_run; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.sync_run ENABLE ROW LEVEL SECURITY;

--
-- Name: watermark; Type: ROW SECURITY; Schema: ops; Owner: -
--

ALTER TABLE ops.watermark ENABLE ROW LEVEL SECURITY;

--
-- Name: mech_source; Type: ROW SECURITY; Schema: ref; Owner: -
--

ALTER TABLE ref.mech_source ENABLE ROW LEVEL SECURITY;

--
-- Name: mech_status; Type: ROW SECURITY; Schema: ref; Owner: -
--

ALTER TABLE ref.mech_status ENABLE ROW LEVEL SECURITY;

--
-- Name: mech_source public_read; Type: POLICY; Schema: ref; Owner: -
--

CREATE POLICY public_read ON ref.mech_source FOR SELECT TO anon, authenticated USING (true);

--
-- Name: mech_status public_read; Type: POLICY; Schema: ref; Owner: -
--

CREATE POLICY public_read ON ref.mech_status FOR SELECT TO anon, authenticated USING (true);

--
-- Name: admin; Type: ROW SECURITY; Schema: work; Owner: -
--

ALTER TABLE work.admin ENABLE ROW LEVEL SECURITY;

--
-- Name: manual_link admin_delete; Type: POLICY; Schema: work; Owner: -
--

CREATE POLICY admin_delete ON work.manual_link FOR DELETE TO authenticated USING (api.is_admin());

--
-- Name: exclusion; Type: ROW SECURITY; Schema: work; Owner: -
--

ALTER TABLE work.exclusion ENABLE ROW LEVEL SECURITY;

--
-- Name: manual_link; Type: ROW SECURITY; Schema: work; Owner: -
--

ALTER TABLE work.manual_link ENABLE ROW LEVEL SECURITY;

--
-- Name: page_lock; Type: ROW SECURITY; Schema: work; Owner: -
--

ALTER TABLE work.page_lock ENABLE ROW LEVEL SECURITY;

--
-- Name: exclusion public_read; Type: POLICY; Schema: work; Owner: -
--

CREATE POLICY public_read ON work.exclusion FOR SELECT TO anon, authenticated USING (true);

--
-- Name: manual_link public_read; Type: POLICY; Schema: work; Owner: -
--

CREATE POLICY public_read ON work.manual_link FOR SELECT TO anon, authenticated USING (true);

--
-- Name: page_lock public_read; Type: POLICY; Schema: work; Owner: -
--

CREATE POLICY public_read ON work.page_lock FOR SELECT TO anon, authenticated USING (true);

--
-- Name: scan_feedback; Type: ROW SECURITY; Schema: work; Owner: -
--

ALTER TABLE work.scan_feedback ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA api; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA api TO service_role;
GRANT USAGE ON SCHEMA api TO anon;
GRANT USAGE ON SCHEMA api TO authenticated;

--
-- Name: SCHEMA derived; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA derived TO service_role;
GRANT USAGE ON SCHEMA derived TO anon;
GRANT USAGE ON SCHEMA derived TO authenticated;

--
-- Name: SCHEMA enrich; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA enrich TO service_role;
GRANT USAGE ON SCHEMA enrich TO anon;
GRANT USAGE ON SCHEMA enrich TO authenticated;

--
-- Name: SCHEMA mirror; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA mirror TO service_role;
GRANT USAGE ON SCHEMA mirror TO anon;
GRANT USAGE ON SCHEMA mirror TO authenticated;

--
-- Name: SCHEMA ops; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ops TO service_role;
GRANT USAGE ON SCHEMA ops TO anon;
GRANT USAGE ON SCHEMA ops TO authenticated;

--
-- Name: SCHEMA ref; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ref TO service_role;
GRANT USAGE ON SCHEMA ref TO anon;
GRANT USAGE ON SCHEMA ref TO authenticated;

--
-- Name: SCHEMA work; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA work TO service_role;
GRANT USAGE ON SCHEMA work TO anon;
GRANT USAGE ON SCHEMA work TO authenticated;

--
-- Name: FUNCTION add_exclusion(p_kind text, p_wiki_id bigint, p_title text, p_reason text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.add_exclusion(p_kind text, p_wiki_id bigint, p_title text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.add_exclusion(p_kind text, p_wiki_id bigint, p_title text, p_reason text) TO service_role;
GRANT ALL ON FUNCTION api.add_exclusion(p_kind text, p_wiki_id bigint, p_title text, p_reason text) TO authenticated;

--
-- Name: FUNCTION enrich_pending(p_group text, p_after bigint, p_limit integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.enrich_pending(p_group text, p_after bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.enrich_pending(p_group text, p_after bigint, p_limit integer) TO service_role;

--
-- Name: FUNCTION health_check(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.health_check() FROM PUBLIC;
GRANT ALL ON FUNCTION api.health_check() TO service_role;

--
-- Name: FUNCTION import_human_data(p_admin uuid, p_manual jsonb, p_blacklist jsonb, p_feedback jsonb, p_locks jsonb); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.import_human_data(p_admin uuid, p_manual jsonb, p_blacklist jsonb, p_feedback jsonb, p_locks jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.import_human_data(p_admin uuid, p_manual jsonb, p_blacklist jsonb, p_feedback jsonb, p_locks jsonb) TO service_role;

--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.is_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION api.is_admin() TO service_role;
GRANT ALL ON FUNCTION api.is_admin() TO anon;
GRANT ALL ON FUNCTION api.is_admin() TO authenticated;

--
-- Name: FUNCTION maintenance_prune(p_keep interval); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.maintenance_prune(p_keep interval) FROM PUBLIC;
GRANT ALL ON FUNCTION api.maintenance_prune(p_keep interval) TO service_role;

--
-- Name: FUNCTION maintenance_refresh_counts(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.maintenance_refresh_counts() FROM PUBLIC;
GRANT ALL ON FUNCTION api.maintenance_refresh_counts() TO service_role;

--
-- Name: FUNCTION maintenance_refresh_gap(p_after bigint, p_limit integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.maintenance_refresh_gap(p_after bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.maintenance_refresh_gap(p_after bigint, p_limit integer) TO service_role;

--
-- Name: FUNCTION mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[], p_label text, p_topic text, p_hidden text, p_level text, p_lists_version text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[], p_label text, p_topic text, p_hidden text, p_level text, p_lists_version text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[], p_label text, p_topic text, p_hidden text, p_level text, p_lists_version text) TO service_role;
GRANT ALL ON FUNCTION api.mark_feedback(p_wiki_id bigint, p_match_key text, p_word text, p_entries text[], p_label text, p_topic text, p_hidden text, p_level text, p_lists_version text) TO authenticated;

--
-- Name: FUNCTION match_conflicts(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.match_conflicts() FROM PUBLIC;
GRANT ALL ON FUNCTION api.match_conflicts() TO service_role;

--
-- Name: FUNCTION reconcile_pages(p_site text, p_after bigint, p_limit integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.reconcile_pages(p_site text, p_after bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.reconcile_pages(p_site text, p_after bigint, p_limit integer) TO service_role;

--
-- Name: FUNCTION reconcile_record(p_snapshot_meta jsonb, p_summary jsonb, p_findings jsonb); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.reconcile_record(p_snapshot_meta jsonb, p_summary jsonb, p_findings jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.reconcile_record(p_snapshot_meta jsonb, p_summary jsonb, p_findings jsonb) TO service_role;

--
-- Name: FUNCTION rev_scope(p_after bigint, p_limit integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.rev_scope(p_after bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.rev_scope(p_after bigint, p_limit integer) TO service_role;

--
-- Name: FUNCTION scan_pending(p_after bigint, p_limit integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.scan_pending(p_after bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.scan_pending(p_after bigint, p_limit integer) TO service_role;

--
-- Name: FUNCTION scan_prune(p_ids bigint[]); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.scan_prune(p_ids bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION api.scan_prune(p_ids bigint[]) TO service_role;

--
-- Name: FUNCTION scan_set_topic(p_id bigint, p_topic text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.scan_set_topic(p_id bigint, p_topic text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.scan_set_topic(p_id bigint, p_topic text) TO service_role;

--
-- Name: FUNCTION set_manual_link(p_mech_id bigint, p_wiki_id bigint, p_reason text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.set_manual_link(p_mech_id bigint, p_wiki_id bigint, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.set_manual_link(p_mech_id bigint, p_wiki_id bigint, p_reason text) TO service_role;
GRANT ALL ON FUNCTION api.set_manual_link(p_mech_id bigint, p_wiki_id bigint, p_reason text) TO authenticated;

--
-- Name: FUNCTION sync_apply_enrichment(p_group text, p_rows jsonb); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_apply_enrichment(p_group text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_apply_enrichment(p_group text, p_rows jsonb) TO service_role;

--
-- Name: FUNCTION sync_apply_mech_pages(p_live jsonb, p_gone_ids bigint[], p_gone_titles text[]); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_apply_mech_pages(p_live jsonb, p_gone_ids bigint[], p_gone_titles text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_apply_mech_pages(p_live jsonb, p_gone_ids bigint[], p_gone_titles text[]) TO service_role;

--
-- Name: FUNCTION sync_apply_rev_checks(p_rows jsonb, p_scope_ids bigint[]); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_apply_rev_checks(p_rows jsonb, p_scope_ids bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_apply_rev_checks(p_rows jsonb, p_scope_ids bigint[]) TO service_role;

--
-- Name: FUNCTION sync_apply_scan(p_rows jsonb); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_apply_scan(p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_apply_scan(p_rows jsonb) TO service_role;

--
-- Name: FUNCTION sync_apply_template_checks(p_rows jsonb); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_apply_template_checks(p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_apply_template_checks(p_rows jsonb) TO service_role;

--
-- Name: FUNCTION sync_apply_wiki_pages(p_live jsonb, p_gone_ids bigint[], p_gone_titles text[]); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_apply_wiki_pages(p_live jsonb, p_gone_ids bigint[], p_gone_titles text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_apply_wiki_pages(p_live jsonb, p_gone_ids bigint[], p_gone_titles text[]) TO service_role;

--
-- Name: FUNCTION sync_load_begin(p_site text, p_start timestamp with time zone); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_load_begin(p_site text, p_start timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_load_begin(p_site text, p_start timestamp with time zone) TO service_role;

--
-- Name: FUNCTION sync_record_events(p_events jsonb, p_run uuid); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_record_events(p_events jsonb, p_run uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_record_events(p_events jsonb, p_run uuid) TO service_role;

--
-- Name: FUNCTION sync_run_finish(p_run uuid, p_status text, p_stats jsonb, p_error text, p_watermarks jsonb); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_run_finish(p_run uuid, p_status text, p_stats jsonb, p_error text, p_watermarks jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_run_finish(p_run uuid, p_status text, p_stats jsonb, p_error text, p_watermarks jsonb) TO service_role;

--
-- Name: FUNCTION sync_run_start(p_kind text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.sync_run_start(p_kind text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_run_start(p_kind text) TO service_role;

--
-- Name: FUNCTION template_pending(p_after bigint, p_limit integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.template_pending(p_after bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.template_pending(p_after bigint, p_limit integer) TO service_role;

--
-- Name: FUNCTION unmark_feedback(p_wiki_id bigint, p_match_key text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.unmark_feedback(p_wiki_id bigint, p_match_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.unmark_feedback(p_wiki_id bigint, p_match_key text) TO service_role;
GRANT ALL ON FUNCTION api.unmark_feedback(p_wiki_id bigint, p_match_key text) TO authenticated;

--
-- Name: FUNCTION refresh_wiki_gap(p_ids bigint[]); Type: ACL; Schema: derived; Owner: -
--

GRANT ALL ON FUNCTION derived.refresh_wiki_gap(p_ids bigint[]) TO service_role;

--
-- Name: FUNCTION rav_strip(k text); Type: ACL; Schema: mirror; Owner: -
--

GRANT ALL ON FUNCTION mirror.rav_strip(k text) TO service_role;

--
-- Name: FUNCTION title_key(t text); Type: ACL; Schema: mirror; Owner: -
--

GRANT ALL ON FUNCTION mirror.title_key(t text) TO service_role;

--
-- Name: FUNCTION health(); Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON FUNCTION ops.health() TO service_role;
GRANT ALL ON FUNCTION ops.health() TO anon;
GRANT ALL ON FUNCTION ops.health() TO authenticated;

--
-- Name: FUNCTION refresh_counts(); Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON FUNCTION ops.refresh_counts() TO service_role;

--
-- Name: FUNCTION after_exclusion_change(); Type: ACL; Schema: work; Owner: -
--

REVOKE ALL ON FUNCTION work.after_exclusion_change() FROM PUBLIC;
GRANT ALL ON FUNCTION work.after_exclusion_change() TO service_role;

--
-- Name: FUNCTION after_link_change(); Type: ACL; Schema: work; Owner: -
--

REVOKE ALL ON FUNCTION work.after_link_change() FROM PUBLIC;
GRANT ALL ON FUNCTION work.after_link_change() TO service_role;

--
-- Name: TABLE mech_page; Type: ACL; Schema: mirror; Owner: -
--

GRANT ALL ON TABLE mirror.mech_page TO service_role;
GRANT SELECT ON TABLE mirror.mech_page TO anon;
GRANT SELECT ON TABLE mirror.mech_page TO authenticated;

--
-- Name: TABLE mech_status; Type: ACL; Schema: ref; Owner: -
--

GRANT ALL ON TABLE ref.mech_status TO service_role;
GRANT SELECT ON TABLE ref.mech_status TO anon;
GRANT SELECT ON TABLE ref.mech_status TO authenticated;

--
-- Name: TABLE mechalol_pages; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.mechalol_pages TO service_role;
GRANT SELECT ON TABLE api.mechalol_pages TO anon;
GRANT SELECT ON TABLE api.mechalol_pages TO authenticated;

--
-- Name: TABLE wiki_page; Type: ACL; Schema: mirror; Owner: -
--

GRANT ALL ON TABLE mirror.wiki_page TO service_role;
GRANT SELECT ON TABLE mirror.wiki_page TO anon;
GRANT SELECT ON TABLE mirror.wiki_page TO authenticated;

--
-- Name: TABLE exclusion; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON TABLE work.exclusion TO service_role;
GRANT SELECT ON TABLE work.exclusion TO anon;
GRANT SELECT ON TABLE work.exclusion TO authenticated;

--
-- Name: TABLE page_lock; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON TABLE work.page_lock TO service_role;
GRANT SELECT ON TABLE work.page_lock TO anon;
GRANT SELECT ON TABLE work.page_lock TO authenticated;

--
-- Name: TABLE v_locks; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_locks TO service_role;
GRANT SELECT ON TABLE api.v_locks TO anon;
GRANT SELECT ON TABLE api.v_locks TO authenticated;

--
-- Name: TABLE report_locked_pages; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_locked_pages TO service_role;
GRANT SELECT ON TABLE api.report_locked_pages TO anon;
GRANT SELECT ON TABLE api.report_locked_pages TO authenticated;

--
-- Name: TABLE wiki_gap; Type: ACL; Schema: derived; Owner: -
--

GRANT ALL ON TABLE derived.wiki_gap TO service_role;
GRANT SELECT ON TABLE derived.wiki_gap TO anon;
GRANT SELECT ON TABLE derived.wiki_gap TO authenticated;

--
-- Name: TABLE content_scan; Type: ACL; Schema: enrich; Owner: -
--

GRANT ALL ON TABLE enrich.content_scan TO service_role;
GRANT SELECT ON TABLE enrich.content_scan TO anon;
GRANT SELECT ON TABLE enrich.content_scan TO authenticated;

--
-- Name: TABLE wiki_enrichment; Type: ACL; Schema: enrich; Owner: -
--

GRANT ALL ON TABLE enrich.wiki_enrichment TO service_role;
GRANT SELECT ON TABLE enrich.wiki_enrichment TO anon;
GRANT SELECT ON TABLE enrich.wiki_enrichment TO authenticated;

--
-- Name: TABLE report_missing_from_mechalol; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_missing_from_mechalol TO service_role;
GRANT SELECT ON TABLE api.report_missing_from_mechalol TO anon;
GRANT SELECT ON TABLE api.report_missing_from_mechalol TO authenticated;

--
-- Name: TABLE report_missing_word_filter; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_missing_word_filter TO service_role;
GRANT SELECT ON TABLE api.report_missing_word_filter TO anon;
GRANT SELECT ON TABLE api.report_missing_word_filter TO authenticated;

--
-- Name: TABLE manual_link; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON TABLE work.manual_link TO service_role;
GRANT SELECT ON TABLE work.manual_link TO anon;
GRANT SELECT,DELETE ON TABLE work.manual_link TO authenticated;

--
-- Name: TABLE v_rav_review; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_rav_review TO service_role;
GRANT SELECT ON TABLE api.v_rav_review TO anon;
GRANT SELECT ON TABLE api.v_rav_review TO authenticated;

--
-- Name: TABLE report_rav_prefix_normalization; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_rav_prefix_normalization TO service_role;
GRANT SELECT ON TABLE api.report_rav_prefix_normalization TO anon;
GRANT SELECT ON TABLE api.report_rav_prefix_normalization TO authenticated;

--
-- Name: TABLE rev_check; Type: ACL; Schema: derived; Owner: -
--

GRANT ALL ON TABLE derived.rev_check TO service_role;
GRANT SELECT ON TABLE derived.rev_check TO anon;
GRANT SELECT ON TABLE derived.rev_check TO authenticated;

--
-- Name: TABLE v_rev_tasks; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_rev_tasks TO service_role;
GRANT SELECT ON TABLE api.v_rev_tasks TO anon;
GRANT SELECT ON TABLE api.v_rev_tasks TO authenticated;

--
-- Name: TABLE report_rev_tasks; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_rev_tasks TO service_role;
GRANT SELECT ON TABLE api.report_rev_tasks TO anon;
GRANT SELECT ON TABLE api.report_rev_tasks TO authenticated;

--
-- Name: TABLE report_source_update; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_source_update TO service_role;
GRANT SELECT ON TABLE api.report_source_update TO anon;
GRANT SELECT ON TABLE api.report_source_update TO authenticated;

--
-- Name: TABLE v_undocumented; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_undocumented TO service_role;
GRANT SELECT ON TABLE api.v_undocumented TO anon;
GRANT SELECT ON TABLE api.v_undocumented TO authenticated;

--
-- Name: TABLE report_undocumented_import; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_undocumented_import TO service_role;
GRANT SELECT ON TABLE api.report_undocumented_import TO anon;
GRANT SELECT ON TABLE api.report_undocumented_import TO authenticated;

--
-- Name: TABLE page_event; Type: ACL; Schema: mirror; Owner: -
--

GRANT ALL ON TABLE mirror.page_event TO service_role;
GRANT SELECT ON TABLE mirror.page_event TO anon;
GRANT SELECT ON TABLE mirror.page_event TO authenticated;

--
-- Name: TABLE v_moves; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_moves TO service_role;
GRANT SELECT ON TABLE api.v_moves TO anon;
GRANT SELECT ON TABLE api.v_moves TO authenticated;

--
-- Name: TABLE report_wikipedia_moves; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.report_wikipedia_moves TO service_role;
GRANT SELECT ON TABLE api.report_wikipedia_moves TO anon;
GRANT SELECT ON TABLE api.report_wikipedia_moves TO authenticated;

--
-- Name: TABLE watermark; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.watermark TO service_role;
GRANT SELECT ON TABLE ops.watermark TO anon;
GRANT SELECT ON TABLE ops.watermark TO authenticated;

--
-- Name: TABLE sync_watermarks; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.sync_watermarks TO service_role;
GRANT SELECT ON TABLE api.sync_watermarks TO anon;
GRANT SELECT ON TABLE api.sync_watermarks TO authenticated;

--
-- Name: TABLE dashboard_counts; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.dashboard_counts TO service_role;
GRANT SELECT ON TABLE ops.dashboard_counts TO anon;
GRANT SELECT ON TABLE ops.dashboard_counts TO authenticated;

--
-- Name: TABLE v_counts; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_counts TO service_role;
GRANT SELECT ON TABLE api.v_counts TO anon;
GRANT SELECT ON TABLE api.v_counts TO authenticated;

--
-- Name: TABLE v_missing; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_missing TO service_role;
GRANT SELECT ON TABLE api.v_missing TO anon;
GRANT SELECT ON TABLE api.v_missing TO authenticated;

--
-- Name: TABLE sync_run; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.sync_run TO service_role;
GRANT SELECT ON TABLE ops.sync_run TO anon;
GRANT SELECT ON TABLE ops.sync_run TO authenticated;

--
-- Name: TABLE v_sync_status; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_sync_status TO service_role;
GRANT SELECT ON TABLE api.v_sync_status TO anon;
GRANT SELECT ON TABLE api.v_sync_status TO authenticated;

--
-- Name: TABLE template_check; Type: ACL; Schema: derived; Owner: -
--

GRANT ALL ON TABLE derived.template_check TO service_role;
GRANT SELECT ON TABLE derived.template_check TO anon;
GRANT SELECT ON TABLE derived.template_check TO authenticated;

--
-- Name: TABLE template_link; Type: ACL; Schema: derived; Owner: -
--

GRANT ALL ON TABLE derived.template_link TO service_role;
GRANT SELECT ON TABLE derived.template_link TO anon;
GRANT SELECT ON TABLE derived.template_link TO authenticated;

--
-- Name: TABLE v_template_issues; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.v_template_issues TO service_role;
GRANT SELECT ON TABLE api.v_template_issues TO anon;
GRANT SELECT ON TABLE api.v_template_issues TO authenticated;

--
-- Name: TABLE wikipedia_pages; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.wikipedia_pages TO service_role;
GRANT SELECT ON TABLE api.wikipedia_pages TO anon;
GRANT SELECT ON TABLE api.wikipedia_pages TO authenticated;

--
-- Name: TABLE scan_feedback; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON TABLE work.scan_feedback TO service_role;

--
-- Name: TABLE word_filter_feedback; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.word_filter_feedback TO service_role;
GRANT SELECT ON TABLE api.word_filter_feedback TO authenticated;

--
-- Name: TABLE content_scan_detail; Type: ACL; Schema: enrich; Owner: -
--

GRANT ALL ON TABLE enrich.content_scan_detail TO service_role;

--
-- Name: TABLE word_filter_results; Type: ACL; Schema: api; Owner: -
--

GRANT ALL ON TABLE api.word_filter_results TO service_role;
GRANT SELECT ON TABLE api.word_filter_results TO anon;
GRANT SELECT ON TABLE api.word_filter_results TO authenticated;

--
-- Name: TABLE mech_key; Type: ACL; Schema: derived; Owner: -
--

GRANT ALL ON TABLE derived.mech_key TO service_role;
GRANT SELECT ON TABLE derived.mech_key TO anon;
GRANT SELECT ON TABLE derived.mech_key TO authenticated;

--
-- Name: SEQUENCE page_event_id_seq; Type: ACL; Schema: mirror; Owner: -
--

GRANT ALL ON SEQUENCE mirror.page_event_id_seq TO service_role;

--
-- Name: TABLE health_threshold; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.health_threshold TO service_role;
GRANT SELECT ON TABLE ops.health_threshold TO anon;
GRANT SELECT ON TABLE ops.health_threshold TO authenticated;

--
-- Name: TABLE reconcile_finding; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.reconcile_finding TO service_role;

--
-- Name: SEQUENCE reconcile_finding_id_seq; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON SEQUENCE ops.reconcile_finding_id_seq TO service_role;

--
-- Name: TABLE reconcile_run; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.reconcile_run TO service_role;
GRANT SELECT ON TABLE ops.reconcile_run TO anon;
GRANT SELECT ON TABLE ops.reconcile_run TO authenticated;

--
-- Name: TABLE schema_migration; Type: ACL; Schema: ops; Owner: -
--

GRANT ALL ON TABLE ops.schema_migration TO service_role;

--
-- Name: TABLE mech_source; Type: ACL; Schema: ref; Owner: -
--

GRANT ALL ON TABLE ref.mech_source TO service_role;
GRANT SELECT ON TABLE ref.mech_source TO anon;
GRANT SELECT ON TABLE ref.mech_source TO authenticated;

--
-- Name: TABLE admin; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON TABLE work.admin TO service_role;

--
-- Name: SEQUENCE exclusion_id_seq; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON SEQUENCE work.exclusion_id_seq TO service_role;

--
-- Name: SEQUENCE scan_feedback_id_seq; Type: ACL; Schema: work; Owner: -
--

GRANT ALL ON SEQUENCE work.scan_feedback_id_seq TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: api; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: api; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: api; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT ALL ON TABLES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: derived; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA derived GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: derived; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA derived GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: derived; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA derived GRANT ALL ON TABLES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: enrich; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA enrich GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: enrich; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA enrich GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: enrich; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA enrich GRANT ALL ON TABLES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: mirror; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA mirror GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: mirror; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA mirror GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: mirror; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA mirror GRANT ALL ON TABLES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: ops; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: ops; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: ops; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT ALL ON TABLES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: ref; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: ref; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: ref; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT ALL ON TABLES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: work; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA work GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: work; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA work GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: work; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA work GRANT ALL ON TABLES TO service_role;

--
-- PostgreSQL database dump complete
--

