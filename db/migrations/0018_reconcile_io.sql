-- 0018: כניסה ויציאה ל-reconcile (PLAN_STAGE4.md 4.4). reconcile_pages: רשימת הדפים במראה (לפי אתר) להשוואה מול צילום מקור.
-- reconcile_record: רושמת ריצה וממצאים ב-ops.reconcile_run / reconcile_finding.

create or replace function api.reconcile_pages(p_site text, p_after bigint default 0, p_limit integer default 5000)
returns table (page_id bigint, title text, status text, source_type text, needs_attention boolean, is_dictionary boolean)
language plpgsql
stable
set search_path = ''
as $$
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

-- p_findings: [{site, class, page_id, title, detail, explained_by_window}]
create or replace function api.reconcile_record(p_snapshot_meta jsonb, p_summary jsonb, p_findings jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
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
revoke all on function api.reconcile_pages(text, bigint, integer), api.reconcile_record(jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function api.reconcile_pages(text, bigint, integer), api.reconcile_record(jsonb, jsonb, jsonb) to service_role;
