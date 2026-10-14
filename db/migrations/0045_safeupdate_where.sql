-- 0045: תיקון 0043. בסופרבייס פועל pg-safeupdate על חיבורי ה-API (authenticator: session_preload_libraries=safeupdate):
-- UPDATE בלי WHERE נחסם ("UPDATE requires a WHERE clause", 21000). מונה הדורות ב-0043 עדכן את השורה היחידה בלי WHERE,
-- ורץ מכל כתיבה לטבלאות הקלט - ולכן נחסמו מ-14.10 17:17 כל כתיבות הסנכרון, ההעשרה, הסריקה וההחרגה דרך ה-API.
-- במסד מקומי אין safeupdate, ולכן הבדיקות לא תפסו; t38 בודקת עכשיו שאין UPDATE/DELETE בלי WHERE בפונקציות.

create or replace function ops.bump_missing_summary()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update ops.missing_summary set gen = gen + 1 where id;
    return null;
end;
$$;

create or replace function ops.refresh_missing_summary()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
    g bigint;
    r jsonb;
begin
    select gen into g from ops.missing_summary;
    select coalesce(jsonb_agg(to_jsonb(l)), '[]') into r from ops.missing_summary_live l;
    update ops.missing_summary set rows = r, built_gen = g, built_at = now() where id;
    return (select coalesce(sum((x ->> 'n')::bigint), 0) from jsonb_array_elements(r) x);
end;
$$;

insert into ops.schema_migration (version) values ('0045');
