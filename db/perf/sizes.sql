-- גודל בפועל של הטבלאות והאינדקסים (להריץ בייצור, קריאה בלבד): מדידת אחסון (DESIGN.md 12.8). המכסה: 500 MB לפרויקט.
select n.nspname || '.' || c.relname as rel, c.relkind, pg_size_pretty(pg_total_relation_size(c.oid)) as total,
       pg_total_relation_size(c.oid) as bytes
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('mirror', 'derived', 'enrich', 'work', 'ops') and c.relkind in ('r', 'm')
order by bytes desc;
select pg_size_pretty(pg_database_size(current_database())) as database_size;
