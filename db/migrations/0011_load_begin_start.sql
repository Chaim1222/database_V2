-- 0011: api.sync_load_begin מקבלת נקודת התחלה מוצעת (טעינה מדמפ: תחילת יום הדמפ). בלי נקודה מוצעת: now() כמקודם.
-- ניסיון שנכשל ונשאר פתוח שומר את הנקודה המוקדמת מבין השתיים, כך שהחלון מכסה כל מה שניסיון קודם יכול היה לטעון.
-- (הפונקציה אינה מכילה delete; ה-drop מפנה את החתימה הישנה כדי שלא תהיה עמימות ב-PostgREST.)
drop function if exists api.sync_load_begin(text);

create or replace function api.sync_load_begin(p_site text, p_start timestamptz default null)
returns timestamptz
language plpgsql
set search_path = ''
as $$
declare
    v_start timestamptz;
    v_delta timestamptz;
begin
    select ts into v_start from ops.watermark where site = p_site and stream = 'load_start';
    select ts into v_delta from ops.watermark where site = p_site and stream = 'delta';
    if v_start is null or (v_delta is not null and v_delta >= v_start) then
        v_start := coalesce(p_start, clock_timestamp());           -- אין ניסיון פתוח: חלון חדש
    elsif p_start is not null and p_start < v_start then
        v_start := p_start;                                        -- ניסיון פתוח: נשארים עם המוקדם
    else
        return v_start;
    end if;
    insert into ops.watermark (site, stream, ts) values (p_site, 'load_start', v_start)
    on conflict (site, stream) do update set ts = excluded.ts;
    return v_start;
end;
$$;
revoke all on function api.sync_load_begin(text, timestamptz) from public, anon, authenticated;
grant execute on function api.sync_load_begin(text, timestamptz) to service_role;
