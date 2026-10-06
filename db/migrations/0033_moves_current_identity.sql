-- 0033: דוח העברות לפי מזהה הדף והכותרת הנוכחית במראה, לא יעד היסטורי מהיומן.
-- משחזר את כוונת V1: כותרת ישנה או שדה דף שלא נפתר; כותרת מקומית שונה כשלעצמה אינה משימה.
-- template_link עם wiki_id ריק היא המקבילה ל-template_referenced_title ב-V1.
-- שורה אחת לכל ערך; title קודם ל-template. העברה שבוטלה או דף שנמחק אינם משימה כאן.
-- נוצר דרך supabase migration new והותאם למספור הריפו. לא הוחל בייצור.

create index if not exists template_link_unresolved_title_idx
    on derived.template_link (mirror.title_key(template_ref))
    where wiki_id is null and template_ref is not null;

create or replace view api.v_moves with (security_invoker = true) as
with last_move as (
    select distinct on (ev.page_id, ev.title) ev.page_id, ev.title, ev.ts
    from mirror.page_event ev
    where ev.site = 'wikipedia' and ev.kind = 'move'
    order by ev.page_id, ev.title, ev.ts desc, ev.id desc
), hits as (
    select m.page_id as mech_id, lm.page_id as wiki_id, lm.title as old_title, lm.ts, 'title'::text as via
    from last_move lm
    join mirror.mech_page m on mirror.title_key(m.title) = mirror.title_key(lm.title)
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
join mirror.wiki_page w on w.page_id = h.wiki_id
where mirror.title_key(m.title) <> mirror.title_key(w.title)
order by h.mech_id, (h.via = 'title') desc, h.ts desc, h.wiki_id, h.old_title;

create or replace view api.report_wikipedia_moves with (security_invoker = true) as
select v.id, v.title, v.old_title, v.wikipedia_title, v.moved_at as renamed_at, v.via,
       ms.label_he as status, v.wiki_id as wikipedia_id
from api.v_moves v
join mirror.mech_page m on m.page_id = v.id
join ref.mech_status ms on ms.code = m.status;

grant select on api.v_moves, api.report_wikipedia_moves to anon, authenticated, service_role;
insert into ops.schema_migration (version) values ('0033') on conflict do nothing;
