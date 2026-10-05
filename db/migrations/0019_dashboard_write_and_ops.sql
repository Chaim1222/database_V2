-- 0019: השלמות מהתכנון (סעיפים 8, 12.1, 12.8):
--  א. כתיבה מהדשבורד ב-v2: api.unmark_feedback (ביטול סימון), ו-views תואמי v1 לקריאת פירוט הסינון ומשוב המשתמש המחובר.
--  ב. דוח סתירות בין סוגי ההתאמה: api.match_conflicts (ל-reconcile).
--  ג. מדיניות שמירה: api.maintenance_prune מוחקת העשרה וסינון של דפים שכבר אינם "חסרים" וישנים מהסף (ברירת מחדל 90 יום).
-- unmark_feedback ו-maintenance_prune מכילות `delete from`: להחיל בעורך ה-SQL של סופרבייס.

-- פירוט הסינון לדף "חסר" (matches, images): ללא security_invoker כי content_scan_detail סגורה ל-anon, וב-v1 הוא ציבורי באותה צורה
-- (report_missing_word_filter). מוגבל לדפים שחסרים בלבד.
create or replace view api.word_filter_results as
select s.wiki_id as wikipedia_id, d.matches, s.matches_total, d.images, s.photo_count, s.scanned_at, s.rev_id, s.lists_version
from enrich.content_scan s
left join enrich.content_scan_detail d on d.wiki_id = s.wiki_id
where exists (select 1 from derived.wiki_gap g where g.wiki_id = s.wiki_id and g.kind = 'missing');
grant select on api.word_filter_results to anon, authenticated;

-- הסימונים של המשתמש המחובר בלבד
create or replace view api.word_filter_feedback as
select f.wiki_id as wikipedia_id, f.match_key, f.label, f.user_id
from work.scan_feedback f
where f.user_id = auth.uid();
grant select on api.word_filter_feedback to authenticated;

create or replace function api.unmark_feedback(p_wiki_id bigint, p_match_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not api.is_admin() then
        raise exception 'not allowed' using errcode = '42501';
    end if;
    delete from work.scan_feedback where wiki_id = p_wiki_id and match_key = p_match_key and user_id = auth.uid();
end;
$$;
revoke all on function api.unmark_feedback(bigint, text) from public;
grant execute on function api.unmark_feedback(bigint, text) to authenticated;

-- סתירות בין סוגי ההתאמה (DESIGN.md 12.1). kind:
--   template_vs_title: ערך מכלול שהתבנית שלו מצביעה לדף ויקיפדיה אחד וכותרתו זהה לדף ויקיפדיה אחר: שניהם נחשבים מכוסים.
--   unrelated_same_title: ערך שנוצר במכלול (לא יובא) שכותרתו זהה לדף ויקיפדיה: נחשב מכוסה (כמו ב-v1) אך ייתכן שאינו אותו נושא.
create or replace function api.match_conflicts()
returns table (kind text, mech_id bigint, mech_title text, wiki_id bigint, other_wiki_id bigint)
language sql
stable
set search_path = ''
as $$
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
revoke all on function api.match_conflicts() from public, anon, authenticated;
grant execute on function api.match_conflicts() to service_role;

-- שמירה: העשרה וסינון של דף שאינו "חסר" נשמרים p_keep אחרי הבדיקה האחרונה, ואז נמחקים. הפירוט נמחק ב-cascade.
create or replace function api.maintenance_prune(p_keep interval default interval '90 days')
returns jsonb
language plpgsql
set search_path = ''
as $$
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
revoke all on function api.maintenance_prune(interval) from public, anon, authenticated;
grant execute on function api.maintenance_prune(interval) to service_role;
