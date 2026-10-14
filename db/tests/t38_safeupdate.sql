-- בסופרבייס pg-safeupdate חוסם UPDATE/DELETE בלי WHERE בחיבורי ה-API (נשבר כך ב-0043). המסד המקומי לא טוען אותו,
-- ולכן בודקים את גוף הפונקציות: כל משפט update/delete בפונקציה של הסכמות שלנו חייב where.
do $$
declare bad text;
begin
    select string_agg(n.nspname || '.' || p.proname || ': ' || left(regexp_replace(m[1], '\s+', ' ', 'g'), 80), E'\n') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, '((?:\mupdate\s+[a-z_]+\.[a-z_]+\s+(?:as\s+)?[a-z_]*\s*set\M|\mdelete\s+from\M)[^;]*);', 'gi') m
    where n.nspname in ('api', 'ops', 'derived', 'work', 'mirror', 'enrich', 'ref')
      and m[1] !~* '\mwhere\M';
    if bad is not null then raise exception 'UPDATE/DELETE without WHERE (blocked by safeupdate):%', E'\n' || bad; end if;
end $$;
select 'ok t38_safeupdate';
