begin;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2');
insert into work.admin (user_id) values ('00000000-0000-0000-0000-0000000000a1');
do $$ begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"סריקה תקינה","latest_rev_id":101},{"page_id":2,"title":"לא נסרק","latest_rev_id":102},{"page_id":3,"title":"סריקה ישנה","latest_rev_id":103},{"page_id":4,"title":"מקושר","latest_rev_id":104}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"שם מכלול","status":"imported_documented"}]');
    perform api.sync_apply_template_checks('[{"mech_id":10,"outcome":"ok","wiki_id":4,"template_rev":104}]');
    perform api.sync_apply_scan('[{"wikipedia_id":1,"rev_id":101,"lists_version":"v","verdict":"clean","ctx_verdict":"clean","counts":{"a":{"problem":0}},"matches":[],"images":["x.jpg"]},{"wikipedia_id":3,"rev_id":103,"lists_version":"v","verdict":"clean","ctx_verdict":"clean","counts":{"a":{"problem":0}},"matches":[]}]');
    update mirror.wiki_page set latest_rev_id = 203 where page_id = 3;
    insert into derived.rev_check (mech_id, rev_task, rev_id, linked_wiki_id) values (10, 'bad_rev', 104, 4);
    insert into work.page_lock (site,page_id,level,detected_by) values ('wikipedia',1,'read','test'),('mechalol',10,'read','test');
end $$;

set local role anon;
do $$ begin
    if (select mechalol_redirect_exists from api.report_missing_from_mechalol where id=2) is not null then raise exception 'unchecked redirect must remain unknown'; end if;
    if (select counts from api.report_missing_word_filter where id=1) is distinct from '{"a":{"problem":0}}'::jsonb then raise exception 'row counts missing'; end if;
    if (select images from api.report_missing_word_filter where id=1) is not null then raise exception 'row images must stay lazy'; end if;
    if (select images from api.word_filter_results where wikipedia_id=1) is distinct from '["x.jpg"]'::jsonb then raise exception 'detail images'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary) is distinct from 3 then raise exception 'summary scope'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary where verdict='clean') is distinct from 1 then raise exception 'stale cannot count clean'; end if;
    if not exists (select 1 from api.report_missing_word_filter_summary where scan_state='stale' and verdict is null) then raise exception 'stale summary'; end if;
    if (select wikipedia_id from api.report_rev_tasks where id=10) is distinct from 4 then raise exception 'revision linked identity'; end if;
    if not exists (select 1 from api.report_locked_pages where site='wikipedia' and wikipedia_id=1 and mechalol_id is null) then raise exception 'wiki lock identity'; end if;
    if not exists (select 1 from api.report_locked_pages where site='mechalol' and mechalol_id=10 and wikipedia_id is null) then raise exception 'mech lock identity'; end if;
end $$;
reset role;

-- Existing callers with five arguments still work; repeated marks update one row.
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ begin
    perform api.mark_feedback(1,'k','word',array['entry'],'false',p_before=>'before',p_after=>'after');
    perform api.mark_feedback(1,'k','word',array['entry'],'true');
    if (select count(*) from api.word_filter_feedback where wikipedia_id=1) is distinct from 1 then raise exception 'duplicate feedback'; end if;
    perform api.unmark_feedback(1,'k');
    perform api.unmark_feedback(1,'k');
    perform api.mark_feedback(1,'k','word',array['entry'],'false',p_before=>'before',p_after=>'after');
    perform api.mark_feedback(1,'k','word',array['entry'],'true'); -- old caller preserves context
    begin
        perform api.mark_feedback(1,'k','word',array['entry'],'invalid',p_before=>'must not persist');
        raise exception 'invalid feedback accepted';
    exception when check_violation then null;
    end;
    perform api.set_manual_link(10,1);
    perform api.set_manual_link(10,1);
end $$;
reset role;
do $$ begin
    if (select context_before from work.scan_feedback where wiki_id=1 and match_key='k') is distinct from 'before' then raise exception 'feedback context'; end if;
    if (select context_after from work.scan_feedback where wiki_id=1 and match_key='k') is distinct from 'after' then raise exception 'feedback trailing context'; end if;
    if (select count(*) from work.manual_link where mech_id=10) is distinct from 1 then raise exception 'manual repeat'; end if;
    if exists (select 1 from api.report_missing_word_filter where id=1) then raise exception 'manual link did not refresh missing'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary) is distinct from 2 then raise exception 'manual and template coverage must both remain effective'; end if;
end $$;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';
do $$ declare denied boolean := false; begin
    begin perform api.mark_feedback(2,'bad','word',array['entry'],'false'); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'non-admin feedback allowed'; end if;
    if exists (select 1 from api.word_filter_feedback) then raise exception 'feedback leaked between users'; end if;
    denied := false;
    begin perform api.set_manual_link(10,2); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'non-admin manual association allowed'; end if;
    denied := false;
    begin perform api.add_exclusion('import_excluded',2,null,null); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'non-admin exclusion allowed'; end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
select api.add_exclusion('import_excluded',2,null,null);
select api.add_exclusion('import_excluded',2,null,null);
reset role;
do $$ begin
    if exists(select 1 from api.report_missing_word_filter where id=2) then raise exception 'excluded page still visible'; end if;
    if (select sum(n) from api.report_missing_word_filter_summary) is distinct from 1 then raise exception 'exclusion summary'; end if;
    insert into work.exclusion (kind,title) values ('locked_create','סריקה ישנה');
    if exists (select 1 from api.report_missing_from_mechalol where id=3) then raise exception 'locked-create page visible'; end if;
    if exists (select 1 from api.report_missing_word_filter_summary) then raise exception 'locked-create page counted'; end if;
end $$;
rollback;
select 'ok t31_shared_dashboard' as test;
