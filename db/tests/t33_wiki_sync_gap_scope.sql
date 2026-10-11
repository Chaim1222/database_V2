begin;
select api.sync_apply_wiki_pages('[{"page_id":1,"title":"local","latest_rev_id":10},{"page_id":2,"title":"missing","latest_rev_id":20}]');
insert into mirror.mech_page(page_id,title,status) values(10,'local','created_in_mech');
select derived.refresh_wiki_gap(array[1,2]::bigint[]);
-- Statement triggers detect even an unnecessary no-op refresh.
create function pg_temp.reject_gap_write() returns trigger language plpgsql as $$
begin raise exception 'gap refresh reached' using errcode='P0002'; end $$;
create trigger test_gap_write before insert or delete on derived.wiki_gap
for each statement execute function pg_temp.reject_gap_write();
do $$
declare r jsonb; failed boolean := false;
begin
  r := api.sync_apply_wiki_pages('[{"page_id":1,"title":"local","latest_rev_id":11},{"page_id":2,"title":"missing","latest_rev_id":21}]');
  if (r->>'updated')::int <> 2 or (r->>'gap_changed')::int <> 0 then raise exception 'revision update failed: %',r; end if;
  perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"local","latest_rev_id":11}]');
  begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"renamed","latest_rev_id":12}]');
  exception when no_data_found then failed := true; end;
  if not failed then raise exception 'rename did not refresh gap'; end if;
  if not exists(select 1 from mirror.wiki_page where page_id=1 and title='local' and latest_rev_id=11) then
    raise exception 'failed apply was not atomic'; end if;
end $$;
drop trigger test_gap_write on derived.wiki_gap;
do $$
begin
  perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"renamed","latest_rev_id":12},{"page_id":3,"title":"local"}]');
  if not exists(select 1 from derived.wiki_gap where wiki_id=1 and kind='missing')
     or exists(select 1 from derived.wiki_gap where wiki_id=3) then raise exception 'rename/new gap incorrect'; end if;
  perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"renamed","latest_rev_id":12},{"page_id":3,"title":"local"}]');
  perform api.sync_apply_wiki_pages('[]',array[1]::bigint[],array['missing']);
  if exists(select 1 from derived.wiki_gap where wiki_id in(1,2)) then raise exception 'deleted gaps retained'; end if;
  perform api.sync_apply_wiki_pages('[]',array[1]::bigint[],array['missing']);
  perform api.sync_apply_wiki_pages('[{"page_id":4,"title":"collision"}]');
  perform api.sync_apply_wiki_pages('[{"page_id":5,"title":"collision"}]');
  if exists(select 1 from derived.wiki_gap where wiki_id=4)
     or not exists(select 1 from derived.wiki_gap where wiki_id=5) then raise exception 'collision gap incorrect'; end if;
end $$;
rollback;
select 'ok wiki_sync_gap_scope';
