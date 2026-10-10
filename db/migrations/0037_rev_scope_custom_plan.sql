-- 0037: שמירת תיקון rev_scope שכבר פועל בייצור מ-2026-10-08.
-- מונע תוכנית כללית כבדה: PL/pgSQL, force_custom_plan, וסף מפורש גם לטבלאות המצורפות.
-- החתימה, סדר התוצאות, היקף הבדיקה והרשאות הפונקציה הקיימת נשמרים.
-- נוצר דרך supabase migration new והותאם למספור הריפו.

CREATE OR REPLACE FUNCTION api.rev_scope(p_after bigint DEFAULT 0, p_limit integer DEFAULT 2000)
 RETURNS TABLE(mech_id bigint, title text, template_rev bigint, template_title text, linked_wiki_id bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
BEGIN
    RETURN QUERY
    SELECT m.page_id, m.title, c.template_rev, c.template_title,
           coalesce(l.wiki_id, (
               SELECT w.page_id
               FROM mirror.wiki_page w
               WHERE mirror.title_key(w.title) = mirror.title_key(m.title)
               LIMIT 1
           ))
    FROM mirror.mech_page m
    JOIN derived.template_check c
      ON c.mech_id = m.page_id AND c.mech_id > p_after
    LEFT JOIN derived.template_link l
      ON l.mech_id = m.page_id AND l.mech_id > p_after
    WHERE m.page_id > p_after
      AND m.status = 'imported_documented'
      AND NOT m.is_dictionary
      AND NOT m.needs_attention
      AND c.outcome <> 'denied'
      AND NOT EXISTS (
          SELECT 1 FROM work.manual_link x
          WHERE x.mech_id = m.page_id
      )
    ORDER BY m.page_id
    LIMIT p_limit;
END;
$function$;


insert into ops.schema_migration (version) values ('0037') on conflict do nothing;
