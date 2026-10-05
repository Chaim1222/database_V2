-- 0015: העשרה. api.enrich_pending: דפי ויקיפדיה "חסרים" שקבוצת שדות מסוימת שלהם טרם נבדקה או התיישנה.
-- api.sync_apply_enrichment: כותבת רק את קבוצת השדות שנשלחה; כישלון בבדיקה לא נשלח, ולכן הערך הקודם לא נדרס.
-- קבוצות וכללי רענון (PLAN_STAGE4.md 4.2): created (פעם אחת), length (7 ימים), desc (30 ימים), redirect (יום).

create or replace function api.enrich_pending(p_group text, p_after bigint default 0, p_limit integer default 500)
returns table (wiki_id bigint, title text)
language plpgsql
stable
set search_path = ''
as $$
begin
    if p_group not in ('created', 'length', 'desc', 'redirect') then
        raise exception 'bad group %', p_group using errcode = '22023';
    end if;
    return query
    select g.wiki_id, w.title
    from derived.wiki_gap g
    join mirror.wiki_page w on w.page_id = g.wiki_id
    left join enrich.wiki_enrichment e on e.wiki_id = g.wiki_id
    where g.kind = 'missing' and g.wiki_id > p_after
      and case p_group
              when 'created'  then e.created_checked_at is null
              when 'length'   then e.length_checked_at is null or e.length_checked_at < now() - interval '7 days'
              when 'desc'     then e.desc_checked_at is null or e.desc_checked_at < now() - interval '30 days'
              else                 e.redirect_checked_at is null or e.redirect_checked_at < now() - interval '1 day'
          end
    order by g.wiki_id
    limit p_limit;
end;
$$;

-- p_rows: [{wiki_id, created_at?, length?, wikidata_desc?, mech_redirect?}] עבור קבוצה אחת. ערך ריק נשמר כ"נבדק".
create or replace function api.sync_apply_enrichment(p_group text, p_rows jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
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
revoke all on function api.enrich_pending(text, bigint, integer), api.sync_apply_enrichment(text, jsonb) from public, anon, authenticated;
grant execute on function api.enrich_pending(text, bigint, integer), api.sync_apply_enrichment(text, jsonb) to service_role;
