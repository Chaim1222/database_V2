begin;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1');
do $$
declare r jsonb;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"אחד"},{"page_id":2,"title":"שניים"},{"page_id":3,"title":"נעול ליצירה"}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"מכלול","status":"created_in_mech"}]');
    if (select count(*) from api.report_missing_from_mechalol) <> 3 then raise exception 'precondition: 3 missing'; end if;

    r := api.import_human_data('00000000-0000-0000-0000-0000000000a1',
        '[{"mechalol_page_id":10,"wikipedia_page_id":1,"reason":"x"},{"mechalol_page_id":99,"wikipedia_page_id":2}]',
        '[{"title":"נעול ליצירה","reason":"y"}]',
        '[{"wikipedia_id":1,"match_key":"k","word":"w","entries":["e"],"label":"false"}]',
        '[{"mechalol_id":10,"allevel":"read-semi"},{"mechalol_id":98,"allevel":"read"},{"mechalol_id":10,"allevel":"weird"}]');
    if (r #>> '{inserted,manual}')::int <> 1 or jsonb_array_length(r #> '{skipped,manual}') <> 1 then raise exception 'manual: %', r; end if;
    if (r #>> '{inserted,blacklist}')::int <> 1 or (r #>> '{inserted,feedback}')::int <> 1 then raise exception 'blacklist/feedback: %', r; end if;
    if (r #>> '{inserted,locks}')::int <> 1 or jsonb_array_length(r #> '{skipped,locks}') <> 2 then raise exception 'locks: %', r; end if;
    -- שיוך ידני הסתיר את דף 1, והכותרת הנעולה הוצאה מ"חסר": נשאר רק דף 2
    if (select array_agg(id) from api.report_missing_from_mechalol) <> array[2::bigint] then
        raise exception 'missing should be only page 2: %', (select array_agg(id) from api.report_missing_from_mechalol);
    end if;
    -- מאז 0029 הייבוא מדלג על ספירות בכל שורה; הקולקטור מרענן פעם אחת אחרי כל המנות.
    perform api.maintenance_refresh_counts();
    if (select n from ops.dashboard_counts where key = 'missing') is distinct from 1 then raise exception 'missing count after import'; end if;
    -- הרצה חוזרת: לא מוסיפה שורות
    r := api.import_human_data('00000000-0000-0000-0000-0000000000a1',
        '[{"mechalol_page_id":10,"wikipedia_page_id":1}]', '[{"title":"נעול ליצירה"}]',
        '[{"wikipedia_id":1,"match_key":"k","word":"w","entries":["e"],"label":"false"}]', '[{"mechalol_id":10,"allevel":"read-semi"}]');
    if (r #>> '{inserted,manual}')::int <> 0 or (r #>> '{inserted,blacklist}')::int <> 0 or (r #>> '{inserted,feedback}')::int <> 0 or (r #>> '{inserted,locks}')::int <> 0 then
        raise exception 'replay must insert nothing: %', r;
    end if;
    begin perform api.import_human_data('00000000-0000-0000-0000-0000000000ff'); raise exception 'unknown admin accepted';
    exception when invalid_parameter_value then null; end;
end $$;
rollback;
select 'ok t14_human_data' as test;
