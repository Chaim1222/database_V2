begin;
do $$
declare r jsonb;
begin
    -- ויקיפדיה: "קורבן פסח" קיים; במכלול הערך נקרא "קרבן פסח" (כלל סמנטי)
    perform api.sync_apply_wiki_pages('[{"page_id":100,"title":"קורבן פסח"},{"page_id":101,"title":"ערך אחר"}]');
    if not exists (select 1 from derived.wiki_gap where wiki_id = 100 and kind = 'missing') then
        raise exception 'precondition: 100 should be missing';
    end if;

    for i in 1..2 loop   -- כולל הרצה חוזרת
        r := api.sync_apply_mech_pages(
            '[{"page_id":500,"title":"קרבן פסח","status":"created_in_mech","wiki_candidate_key":"קורבן פסח","rules":["קרבן_לקורבן"]}]');
        if (select count(*) from derived.mech_key where mech_id = 500 and wiki_candidate_key = 'קורבן פסח') <> 1 then
            raise exception 'mech_key row missing (iteration %)', i;
        end if;
        if exists (select 1 from derived.wiki_gap where wiki_id = 100 and kind = 'missing') then
            raise exception 'semantic link should remove the gap (iteration %)', i;
        end if;
    end loop;

    -- הכלל כבר לא חל (הכותרת תוקנה): השורה נמחקת והפער חוזר
    perform api.sync_apply_mech_pages('[{"page_id":500,"title":"קורבן פסח","status":"created_in_mech"}]');
    if exists (select 1 from derived.mech_key where mech_id = 500) then raise exception 'stale mech_key kept'; end if;
    if exists (select 1 from derived.wiki_gap where wiki_id = 100 and kind = 'missing') then
        raise exception 'same title is a regular link: no gap expected';
    end if;

    -- חוזרים לכותרת הישנה, ואז הדף נמחק: mech_key נעלם והפער חוזר
    perform api.sync_apply_mech_pages(
        '[{"page_id":500,"title":"קרבן פסח","status":"created_in_mech","wiki_candidate_key":"קורבן פסח"}]');
    perform api.sync_apply_mech_pages('[]', array[500]::bigint[]);
    if exists (select 1 from derived.mech_key where mech_id = 500) then raise exception 'mech_key kept after delete'; end if;
    if not exists (select 1 from derived.wiki_gap where wiki_id = 100 and kind = 'missing') then
        raise exception 'gap should return after the mech page is gone';
    end if;
end $$;
rollback;
select 'ok t07_mech_key_sync' as test;
