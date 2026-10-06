begin;
do $$
declare before_n bigint;
begin
    select n into before_n from ops.mirror_count where key = 'wiki_pages';
    perform api.sync_apply_wiki_pages('[{"page_id":901,"title":"counter one"},{"page_id":902,"title":"counter two"}]');
    perform api.sync_apply_wiki_pages('[{"page_id":901,"title":"counter one"},{"page_id":902,"title":"counter two"}]');
    if (select n from ops.mirror_count where key = 'wiki_pages') <> before_n + 2 then raise exception 'replay double counted'; end if;
    -- שלב שני אחרי עצירה: עדכון קיים ומחיקה אינם נספרים כהוספה.
    perform api.sync_apply_wiki_pages('[{"page_id":901,"title":"counter renamed"}]', array[902]::bigint[]);
    if (select n from ops.mirror_count where key = 'wiki_pages') <> before_n + 1 then raise exception 'wrong delete count'; end if;
    begin
        insert into mirror.wiki_page(page_id,title) values (903,'rolled back');
        raise exception 'simulate stopped transaction';
    exception when raise_exception then null;
    end;
    if (select n from ops.mirror_count where key = 'wiki_pages') <> before_n + 1 then raise exception 'counter survived rollback'; end if;
    analyze mirror.wiki_page;
    insert into mirror.wiki_page(page_id,title) values (904,'after analyze');
    perform ops.refresh_counts();
    if (select n from ops.dashboard_counts where key='wiki_pages') <> (select count(*) from mirror.wiki_page) then raise exception 'count used stale statistics'; end if;
    perform api.sync_apply_mech_pages('[{"page_id":905,"title":"counter mech","status":"created_in_mech"}]');
    perform api.sync_apply_mech_pages('[{"page_id":905,"title":"counter mech","status":"created_in_mech"}]');
    if (select n from ops.mirror_count where key='mech_pages') <> (select count(*) from mirror.mech_page) then raise exception 'mech replay counter'; end if;
    if has_table_privilege('anon','ops.mirror_count','SELECT') or has_function_privilege('anon','ops.track_mirror_count()','EXECUTE') then raise exception 'counter exposed'; end if;
end $$;
rollback;
select 'ok t25_exact_counts' as test;
