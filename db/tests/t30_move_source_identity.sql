begin;
insert into mirror.wiki_page(page_id,title) values (555733,'מקדש קונקורדיה (רומא)'),(2580912,'מקדש קונקורדיה');
insert into mirror.mech_page(page_id,title,status) values (439373,'מקדש קונקורדיה (רומא)','imported_documented'),(1178550,'מקדש קונקורדיה','imported_documented');
insert into mirror.page_event(site,kind,page_id,title,new_title,ts) values
('wikipedia','move',555733,'מקדש קונקורדיה','מקדש קונקורדיה (רומא)','2026-10-06');
insert into derived.template_check(mech_id,outcome,rev_id,template_rev,template_title)
values (1178550,'same',3837860,44032199,'מקדש קונקורדיה');
do $$ begin
    if not exists(select from api.v_moves where id=1178550) then raise exception 'fixture does not reproduce false candidate'; end if;
    perform api.sync_apply_move_sources('[{"mech_id":1178550,"mech_rev_id":3837860,"source_rev_id":44032199,"source_title":"מקדש קונקורדיה","wiki_id":2580912}]');
    if exists(select from api.v_moves where id=1178550) then raise exception 'verified new identity remains a task'; end if;
    if not exists(select from api.move_source_scope() where mech_id=1178550) then raise exception 'hidden candidate cannot be rechecked'; end if;
    -- A title-only match must not suppress: the original template revision may belong to the moved page.
    update derived.move_source set wiki_id=555733;
    if not exists(select from api.v_moves where id=1178550) then raise exception 'real move hidden'; end if;
    update derived.move_source set wiki_id=2580912;
    update derived.template_check set rev_id=3837861;
    if not exists(select from api.v_moves where id=1178550) then raise exception 'stale local revision hides task'; end if;
    update derived.template_check set rev_id=3837860,template_rev=44032200;
    if not exists(select from api.v_moves where id=1178550) then raise exception 'stale source revision hides task'; end if;
    update derived.template_check set template_rev=44032199,template_title='שונה';
    if not exists(select from api.v_moves where id=1178550) then raise exception 'stale explicit source hides task'; end if;
    update derived.template_check set template_title='מקדש קונקורדיה',outcome='denied';
    if not exists(select from api.v_moves where id=1178550) then raise exception 'denied hides task'; end if;
    update derived.template_check set outcome='same';
    perform api.sync_apply_move_sources('[{"mech_id":1178550,"wiki_id":null}]');
    if not exists(select from api.v_moves where id=1178550) then raise exception 'failed proof hides task'; end if;
    if exists(select from derived.template_link) then raise exception 'proof changed matching'; end if;
    set local role anon;
    perform count(*) from api.report_wikipedia_moves;
    begin
        perform api.sync_apply_move_sources('[]');
        raise exception 'anon can write proof';
    exception when insufficient_privilege then null; end;
    reset role;
    set local role authenticated;
    perform count(*) from api.v_moves;
    reset role;
end $$;
rollback;
select 'ok t30_move_source_identity' as test;
