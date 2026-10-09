begin;
insert into mirror.wiki_page(page_id,title) values (101,'אותה כותרת'),(102,'יעד מפורש');
insert into mirror.mech_page(page_id,title,status,is_dictionary,needs_attention) values
 (10,'אותה כותרת','imported_documented',false,false),
 (20,'כותרת מקומית','imported_documented',false,false),
 (30,'מילוני','imported_documented',true,false),
 (40,'לטיפול','imported_documented',false,true),
 (50,'מקומי','created_in_mech',false,false),
 (60,'בלי תאריך','imported_undocumented',false,false),
 (70,'נעול','imported_documented',false,false),
 (80,'ידני','imported_documented',false,false);
insert into derived.template_check(mech_id,outcome,template_rev,template_title) values
 (10,'same',123,'אותה כותרת'),(20,'ok',456,'יעד מפורש'),(30,'same',123,'מילוני'),
 (40,'none',0,null),(50,'ok',123,'יעד מפורש'),(60,'ok',123,'יעד מפורש'),
 (70,'denied',123,'נעול'),(80,'same',123,'ידני');
insert into derived.template_link(mech_id,wiki_id,template_ref) values (20,102,'יעד מפורש');
insert into work.manual_link(mech_id,wiki_id) values (80,101);
do $$
declare a bigint; lim integer; actual jsonb; expected jsonb;
begin
  foreach a in array array[0,10,15,20,90]::bigint[] loop
    foreach lim in array array[1,2,2000] loop
      select coalesce(jsonb_agg(to_jsonb(s) order by s.mech_id),'[]') into actual from api.rev_scope(a,lim) s;
      -- גוף הגרסה הישנה: אותם שדות, סדר וסינון, בלי תנאי הסף על הטבלאות המצורפות.
      select coalesce(jsonb_agg(to_jsonb(s) order by s.mech_id),'[]') into expected from (
        select m.page_id as mech_id,m.title,c.template_rev,c.template_title,
          coalesce(l.wiki_id,(select w.page_id from mirror.wiki_page w
            where mirror.title_key(w.title)=mirror.title_key(m.title) limit 1)) as linked_wiki_id
        from mirror.mech_page m join derived.template_check c on c.mech_id=m.page_id
        left join derived.template_link l on l.mech_id=m.page_id
        where m.page_id>a and m.status='imported_documented'
          and not m.is_dictionary and not m.needs_attention and c.outcome<>'denied'
          and not exists(select 1 from work.manual_link x where x.mech_id=m.page_id)
        order by m.page_id limit lim
      ) s;
      if actual is distinct from expected then raise exception 'scope changed: after %, limit %',a,lim; end if;
    end loop;
  end loop;
  if not exists(select 1 from pg_proc p join pg_language l on l.oid=p.prolang
    where p.oid='api.rev_scope(bigint,integer)'::regprocedure and l.lanname='plpgsql'
      and p.proconfig @> array['plan_cache_mode=force_custom_plan']) then
    raise exception 'custom plan settings missing';
  end if;
  if has_function_privilege('anon','api.rev_scope(bigint,integer)','execute')
     or has_function_privilege('authenticated','api.rev_scope(bigint,integer)','execute')
     or not has_function_privilege('service_role','api.rev_scope(bigint,integer)','execute') then
    raise exception 'scope permissions changed';
  end if;
end $$;
rollback;
select 'ok t31_rev_scope_custom_plan' as test;
