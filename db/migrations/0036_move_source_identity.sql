-- Scoped revision identity proof for historical move candidates. Not a matching source.
create table derived.move_source (
    mech_id bigint primary key,
    mech_rev_id bigint,
    source_rev_id bigint,
    source_title text,
    wiki_id bigint,
    checked_at timestamptz not null default now(),
    check (wiki_id is null or (wiki_id > 0 and mech_rev_id is not null and mech_rev_id > 0 and source_rev_id is not null and source_rev_id > 1 and source_title is not null))
);
alter table derived.move_source enable row level security;
create policy public_read on derived.move_source for select to anon, authenticated using (true);
grant select on derived.move_source to anon, authenticated;
grant select, insert, update, delete on derived.move_source to service_role;
create or replace view api.move_candidates with (security_invoker = true) as
with last_move as (
    select distinct on (ev.page_id, ev.title) ev.page_id, ev.title, ev.ts
    from mirror.page_event ev
    where ev.site = 'wikipedia' and ev.kind = 'move'
    order by ev.page_id, ev.title, ev.ts desc, ev.id desc
), latest_event as (
    select distinct on (ev.page_id) ev.page_id, ev.kind, ev.new_title
    from mirror.page_event ev
    where ev.site = 'wikipedia' and ev.page_id > 0
    order by ev.page_id, ev.ts desc, ev.id desc
), current_source as (
    select e.page_id, coalesce(w.title, e.new_title) as title
    from latest_event e
    left join mirror.wiki_page w on w.page_id = e.page_id
    where w.page_id is not null
       or (e.kind = 'move' and e.new_title like 'טיוטה:%')
), hits as (
    select m.page_id as mech_id, lm.page_id as wiki_id, lm.title as old_title, lm.ts, 'title'::text as via
    from last_move lm
    join mirror.mech_page m on mirror.title_key(m.title) = mirror.title_key(lm.title)
    where not exists (select 1 from derived.template_link t
                      where t.mech_id = m.page_id and t.wiki_id is not null and t.wiki_id <> lm.page_id)
      and not exists (select 1 from work.manual_link x
                      where x.mech_id = m.page_id and x.wiki_id <> lm.page_id)
    union all
    select m.page_id, lm.page_id, lm.title, lm.ts, 'template'::text
    from last_move lm
    join derived.template_link t on mirror.title_key(t.template_ref) = mirror.title_key(lm.title)
        and t.wiki_id is null and t.template_ref is not null
    join mirror.mech_page m on m.page_id = t.mech_id
    where m.status <> 'kept_after_wiki_delete'
      and not exists (select 1 from work.manual_link x where x.mech_id = m.page_id)
)
select distinct on (h.mech_id)
    h.mech_id as id, m.title, h.old_title, w.title as wikipedia_title, h.ts as moved_at,
    h.via, h.wiki_id
from hits h
join mirror.mech_page m on m.page_id = h.mech_id
join current_source w on w.page_id = h.wiki_id
where mirror.title_key(m.title) <> mirror.title_key(w.title)
order by h.mech_id, (h.via = 'title') desc, h.ts desc, h.wiki_id, h.old_title;


revoke all on api.move_candidates from public, anon, authenticated;
grant select on api.move_candidates to service_role;

create or replace view api.v_moves with (security_invoker = true) as
select h.* from api.move_candidates h
where not exists (
    select from derived.move_source e
    join derived.template_check t on t.mech_id = e.mech_id
    where e.mech_id = h.id and e.wiki_id <> h.wiki_id
      and t.outcome <> 'denied' and t.rev_id = e.mech_rev_id
      and t.template_rev = e.source_rev_id
      and mirror.title_key(t.template_title) = mirror.title_key(e.source_title)
);
-- v_moves is security_invoker: its readers need candidate access; this is the same
-- public candidate information as before, without suppression. The writer scope is private.
grant select on api.move_candidates to anon, authenticated;

create function api.move_source_scope(p_after bigint default 0, p_limit integer default 50)
returns table (mech_id bigint, title text, local_rev_id bigint, template_rev bigint, template_title text)
language sql stable set search_path = '' as $$
    select distinct h.id, h.title, t.rev_id, t.template_rev, t.template_title
    from api.move_candidates h
    left join derived.template_check t on t.mech_id = h.id and t.outcome <> 'denied'
    where h.id > p_after
    order by h.id limit p_limit;
$$;
create function api.sync_apply_move_sources(p_rows jsonb)
returns void language sql set search_path = '' as $$
    insert into derived.move_source as e (mech_id, mech_rev_id, source_rev_id, source_title, wiki_id)
    select r.mech_id, r.mech_rev_id, r.source_rev_id, r.source_title, r.wiki_id
    from jsonb_to_recordset(p_rows) r(mech_id bigint, mech_rev_id bigint, source_rev_id bigint, source_title text, wiki_id bigint)
    on conflict (mech_id) do update set mech_rev_id = excluded.mech_rev_id,
        source_rev_id = excluded.source_rev_id, source_title = excluded.source_title,
        wiki_id = excluded.wiki_id, checked_at = now();
$$;
revoke all on function api.move_source_scope(bigint, integer), api.sync_apply_move_sources(jsonb) from public, anon, authenticated;
grant execute on function api.move_source_scope(bigint, integer), api.sync_apply_move_sources(jsonb) to service_role;
insert into ops.schema_migration(version) values ('0036') on conflict do nothing;
