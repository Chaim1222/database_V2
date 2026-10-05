begin;
do $$
begin
    -- ויקיפדיה "אברהם כהן" (בלי תואר); במכלול "הרב אברהם כהן": התאמה לבדיקה אנושית (rav_review), בשני סדרי ההחלה
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"אברהם כהן"},{"page_id":2,"title":"הרב משה לוי"}]');
    perform api.sync_apply_mech_pages('[{"page_id":10,"title":"הרב אברהם כהן","status":"created_in_mech"},{"page_id":11,"title":"משה לוי","status":"created_in_mech"}]');
    if not exists (select 1 from derived.wiki_gap where wiki_id = 1 and kind = 'rav_review') then
        raise exception 'wiki without title vs mech with title: expected rav_review, got %', (select string_agg(wiki_id || kind, ',') from derived.wiki_gap);
    end if;
    if not exists (select 1 from derived.wiki_gap where wiki_id = 2 and kind = 'rav_review') then
        raise exception 'wiki with title vs mech without title: expected rav_review';
    end if;
    -- הרענון המלא נותן אותה תוצאה (כלומר ההחלה המצטברת לא מחמיצה)
    perform derived.refresh_wiki_gap();
    if (select count(*) from derived.wiki_gap where kind = 'rav_review') <> 2 then raise exception 'full refresh differs'; end if;
end $$;
rollback;
select 'ok t17_rav_direction' as test;
