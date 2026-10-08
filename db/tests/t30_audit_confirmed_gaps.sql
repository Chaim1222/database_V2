begin;
do $$
begin
    perform api.sync_apply_wiki_pages('[{"page_id":840992,"title":"ערבות (משפט עברי)"},{"page_id":555733,"title":"מקדש קונקורדיה (רומא)"},{"page_id":2580912,"title":"מקדש קונקורדיה"}]');
    perform api.sync_apply_mech_pages('[{"page_id":940591,"title":"ערבות (הלכה)","status":"created_in_mech","source_type":"created"},{"page_id":1178550,"title":"מקדש קונקורדיה","status":"imported_documented"},{"page_id":444,"title":"ללא תאריך","status":"imported_undocumented"}]');
    if not exists(select 1 from api.template_pending(940590, 1) where page_id=940591) then
        raise exception 'local-created page not eligible for initial template check';
    end if;
    perform api.sync_apply_template_checks('[{"mech_id":940591,"outcome":"ok","wiki_id":840992,"template_ref":"ערבות (משפט עברי)","template_rev":0},{"mech_id":444,"outcome":"ok","wiki_id":840992,"template_ref":"ערבות (משפט עברי)","template_rev":123},{"mech_id":1178550,"outcome":"same","template_title":"מקדש קונקורדיה","template_rev":44032199}]');
    if exists(select 1 from api.v_missing where id=840992) then raise exception 'validated local-created link remains missing'; end if;
    if (select status from mirror.mech_page where page_id=940591) <> 'created_in_mech'
       or (select status from mirror.mech_page where page_id=444) <> 'imported_undocumented' then
        raise exception 'template validation changed source classification';
    end if;
    if exists(select 1 from api.rev_scope(0, 100) where mech_id in (940591,444)) then
        raise exception 'local-created or undated page entered imported revision maintenance';
    end if;
    insert into mirror.page_event(site,kind,page_id,title,new_title,ts) values
      ('wikipedia','move',555733,'מקדש קונקורדיה','מקדש קונקורדיה (רומא)','2026-10-06');
    if exists(select 1 from api.v_moves where id=1178550) then raise exception 'new page inherited old page move'; end if;
    -- קישור מפורש לדף ההיסטורי: השם לבדו לא מבטל משימה אמיתית.
    perform api.sync_apply_template_checks('[{"mech_id":1178550,"outcome":"ok","wiki_id":555733,"template_ref":"מקדש קונקורדיה (רומא)"}]');
    if not exists(select 1 from api.v_moves where id=1178550 and wiki_id=555733) then raise exception 'explicit source identity ignored'; end if;
    perform api.sync_apply_template_checks('[{"mech_id":1178550,"outcome":"same"}]');
    insert into work.manual_link(mech_id,wiki_id) values (1178550,555733);
    if not exists(select 1 from api.v_moves where id=1178550 and wiki_id=555733) then raise exception 'manual source identity ignored'; end if;
    -- קשר מקומי שלא נפתר חוזר לבדיקה לאחר שבוע, בדומה לערך מיובא.
    perform api.sync_apply_template_checks('[{"mech_id":940591,"outcome":"unresolved","template_ref":"ערבות (משפט עברי)"}]');
    update derived.template_check set checked_at=now()-interval '8 days' where mech_id=940591;
    if not exists(select 1 from api.template_pending(940590,1) where page_id=940591) then raise exception 'local-created unresolved not retried'; end if;
    if has_function_privilege('anon','api.template_pending(bigint,integer)','execute')
       or not has_function_privilege('service_role','api.template_pending(bigint,integer)','execute') then
        raise exception 'template pending permissions changed';
    end if;
end $$;
rollback;
select 'ok t30_audit_confirmed_gaps' as test;
