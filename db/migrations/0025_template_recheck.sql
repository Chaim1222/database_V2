-- 0025: מחזור חיים של אימות תבניות (PLAN_STAGE4.md 4.1): בדיקה שהסתיימה ב-unresolved (כותרת שאינה דף חי) או denied (נעול)
-- נבדקת שוב אחרי 7 ימים, כי ויקיפדיה משתנה (דף נוצר, הועבר) ונעילה יכולה להיות מוסרת. ערכים שטרם נבדקו קודמים כמו קודם.
-- (הפונקציה אינה מכילה delete, ולכן ניתנת להחלה גם דרך ה-MCP.)

create or replace function api.template_pending(p_after bigint default 0, p_limit integer default 1000)
returns table (page_id bigint, title text)
language sql
stable
set search_path = ''
as $$
    select x.page_id, x.title from (
        (select m.page_id, m.title from mirror.mech_page m
          where m.page_id > p_after and m.status in ('imported_documented', 'imported_undocumented')
            and not exists (select 1 from derived.template_check c where c.mech_id = m.page_id)
          order by m.page_id limit p_limit)
        union all
        (select m.page_id, m.title from derived.template_check c join mirror.mech_page m on m.page_id = c.mech_id
          where c.outcome in ('unresolved', 'denied') and c.checked_at < now() - interval '7 days'
            and m.page_id > p_after and m.status in ('imported_documented', 'imported_undocumented')
          order by m.page_id limit p_limit)
    ) x order by x.page_id limit p_limit;
$$;
revoke all on function api.template_pending(bigint, integer) from public, anon, authenticated;
grant execute on function api.template_pending(bigint, integer) to service_role;
insert into ops.schema_migration (version) values ('0025') on conflict do nothing;
