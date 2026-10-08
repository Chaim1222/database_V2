-- 0036: תיקון שני פערים שאומתו בבדיקת האמינות מ-2026-10-08.
-- קשר מאומת מסיר חסר גם עבור נוצר במכלול; סיווג והיקף משימות גרסה אינם משתנים.
-- שלב 2 בודק גם את הערכים המקומיים הקיימים שטרם נבדקו, בלי בנייה מחדש.
-- העברה היסטורית אינה משימה כשאותה כותרת שייכת כיום לדף חי אחר,
-- אלא אם קישור תבנית או שיוך ידני קובע במפורש שהמקור הוא הדף ההיסטורי.
-- נוצר דרך supabase migration new והותאם למספור הריפו.

create or replace function api.template_pending(p_after bigint default 0, p_limit integer default 1000)
returns table (page_id bigint, title text)
language sql
stable
set search_path = ''
as $$
    select x.page_id, x.title from (
        (select m.page_id, m.title from mirror.mech_page m
          where m.page_id > p_after and m.status in ('imported_documented', 'imported_undocumented', 'created_in_mech')
            and not exists (select 1 from derived.template_check c where c.mech_id = m.page_id)
          order by m.page_id limit p_limit)
        union all
        (select m.page_id, m.title from derived.template_check c join mirror.mech_page m on m.page_id = c.mech_id
          where c.outcome in ('unresolved', 'denied') and c.checked_at < now() - interval '7 days'
            and m.page_id > p_after and m.status in ('imported_documented', 'imported_undocumented', 'created_in_mech')
          order by m.page_id limit p_limit)
    ) x order by x.page_id limit p_limit;
$$;
revoke all on function api.template_pending(bigint, integer) from public, anon, authenticated;
grant execute on function api.template_pending(bigint, integer) to service_role;

create or replace view api.v_moves with (security_invoker = true) as
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
      -- השם הישן נתפס בידי ערך חי אחר. קשר מפורש למזהה ההיסטורי גובר על שם בלבד.
      and not (
          exists (select 1 from mirror.wiki_page live
                  where mirror.title_key(live.title) = mirror.title_key(m.title)
                    and live.page_id <> lm.page_id)
          and not exists (select 1 from derived.template_link t
                          where t.mech_id = m.page_id and t.wiki_id = lm.page_id)
          and not exists (select 1 from work.manual_link x
                          where x.mech_id = m.page_id and x.wiki_id = lm.page_id)
      )
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


insert into ops.schema_migration (version) values ('0036') on conflict do nothing;
