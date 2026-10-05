-- 0001: סכמות, טבלאות ייחוס ופונקציית נרמול הכותרת היחידה.
-- עקרון: כל מחזור חיים בסכמה משלו. רק `api` נחשפת לדשבורד (Exposed schemas בסופרבייס).
--   ref      - ערכי ייחוס קטנים (סטטוסים, סוגי מקור)
--   mirror   - עובדות מהמקורות; נכתב רק על ידי הסנכרון
--   derived  - נגזר, ניתן לבנייה מחדש בכל רגע
--   enrich   - העשרה יקרה להשגה, שורדת
--   work     - החלטות אדם
--   ops      - תפעול: ריצות, נקודות התקדמות, דוחות פערים, ספירות
--   api      - views ופונקציות שהדשבורד קורא

create schema if not exists ref;
create schema if not exists mirror;
create schema if not exists derived;
create schema if not exists enrich;
create schema if not exists work;
create schema if not exists ops;
create schema if not exists api;

-- ברירות מחדל בטוחות: אובייקט חדש לא נחשף ל-anon/authenticated בלי grant מפורש.
alter default privileges in schema ref, mirror, derived, enrich, work, ops, api
    revoke all on tables from public, anon, authenticated;
alter default privileges in schema ref, mirror, derived, enrich, work, ops, api
    revoke all on sequences from public, anon, authenticated;
alter default privileges in schema ref, mirror, derived, enrich, work, ops, api
    revoke execute on functions from public, anon, authenticated;

-- service_role (הקולקטור) כותב בכל הסכמות. בסופרבייס אין לו הרשאה אוטומטית על סכמות מותאמות, ולכן מפורש.
grant usage on schema ref, mirror, derived, enrich, work, ops, api to service_role;
alter default privileges in schema ref, mirror, derived, enrich, work, ops, api
    grant all on tables to service_role;
alter default privileges in schema ref, mirror, derived, enrich, work, ops, api
    grant all on sequences to service_role;
alter default privileges in schema ref, mirror, derived, enrich, work, ops, api
    grant execute on functions to service_role;

-- נרמול כותרת יחיד (סימטרי, לשני האתרים): NFC, הסרת סימוני כיוון, אחידות מירכאות ומקפים,
-- רווח קשיח לרווח, איחוד רווחים. זהה ל-`hygiene` ב-scripts/normalize.py (בדיקת golden ב-db/tests).
-- הכללים הסמנטיים (מכלול -> ויקיפדיה) אינם כאן: הם נגזרים בקולקטור ונשמרים ב-derived.mech_key.
create or replace function mirror.title_key(t text)
returns text
language sql
immutable
parallel safe
strict
as $$
    select btrim(
        regexp_replace(
            translate(
                translate(normalize(t, NFC), E'‎‏؜‪‫‬‭‮', ''),
                E'״׳“”‘’‐‑‒–—־ ',
                E'"\'""\'\'------ '
            ),
            E'[\\s -   　]+', ' ', 'g'
        ),
        ' '
    )
$$;

-- ערכי ייחוס. הקודים באנגלית; התוויות בעברית מרוכזות כאן ולא פזורות בקוד.
create table ref.mech_status (
    code text primary key,
    label_he text not null,
    is_imported boolean not null,         -- יובא מוויקיפדיה (לא נוצר במכלול ולא ממקור אחר)
    expects_wiki_match boolean not null   -- אין טעם להתריע על חוסר התאמה כשזה false
);
insert into ref.mech_status (code, label_he, is_imported, expects_wiki_match) values
    ('created_in_mech',      'נוצר במכלול',                          false, false),
    ('imported_documented',  'מיובא ומתועד',                         true,  true),
    ('imported_undocumented','מיובא ללא תיעוד',                      true,  true),
    ('chabadpedia',          'ייבוא מחב"דפדיה',                      false, false),
    ('wikishiva',            'ייבוא מוויקישיבה',                     false, false),
    ('kept_after_wiki_delete','נשמר במכלול למרות מחיקה בוויקיפדיה',  true,  false),
    ('split_from_wiki',      'פוצל מתוכן ויקיפדי',                   false, false);

create table ref.mech_source (
    code text primary key,
    description text not null
);
insert into ref.mech_source (code, description) values
    ('created',               'נוצר במכלול'),
    ('translated',            'תורגם במכלול'),
    ('pirushon',              'פירושון שנוצר במכלול'),
    ('chabadpedia',           'יובא מחב"דפדיה'),
    ('wikishiva',             'יובא מוויקישיבה'),
    ('wikipedia_documented',  'ויקיפדיה, עם תבנית מיון ותאריך עדכון'),
    ('wikipedia_deleted_kept','ויקיפדיה, נשמר אחרי מחיקה'),
    ('split_from_wikipedia',  'פוצל מתוכן ויקיפדי'),
    ('missing_sort',          'ויקיפדיה, חסרה תבנית מיון (סימון של המכלול)'),
    ('unknown',               'מקור לא ידוע');
