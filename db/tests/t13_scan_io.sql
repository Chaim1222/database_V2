begin;
do $$
declare n int;
begin
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"א","latest_rev_id":100},{"page_id":2,"title":"ב","latest_rev_id":200}]');
    if (select count(*) from api.scan_pending(0, 10)) <> 2 then raise exception 'two missing pages'; end if;
    if (select scan_state from api.report_missing_word_filter where id = 1) <> 'not_scanned' then raise exception 'not_scanned expected'; end if;

    n := api.sync_apply_scan('[
      {"wikipedia_id":1,"rev_id":100,"lists_version":"v1","verdict":"clean","verdict_suggested":"review","ctx_verdict":"clean","ctx_verdict_suggested":"review","ctx_suspicion_suggested":"low",
       "matches_total":1,"photo_count":2,"has_images":true,"topic":"geo","counts":{"a":{"problem":0}},"matches":[{"w":"x"}],"images":["a.jpg"]},
      {"wikipedia_id":999,"rev_id":1,"lists_version":"v1","verdict":"clean"}]');
    if n <> 1 then raise exception 'unknown wiki ids must be skipped, wrote %', n; end if;
    if (select count(*) from enrich.content_scan_detail where wiki_id = 1 and matches = '[{"w":"x"}]') <> 1 then raise exception 'detail not written with summary'; end if;
    if (select scan_state from api.report_missing_word_filter where id = 1) <> 'scanned' then raise exception 'scanned expected'; end if;
    if (select verdict_suggested from api.report_missing_word_filter where id = 1) <> 'review' then raise exception 'compat mapping'; end if;

    -- הדף נערך (rev חדש): stale
    perform api.sync_apply_wiki_pages('[{"page_id":1,"title":"א","latest_rev_id":101}]');
    if (select scan_state from api.report_missing_word_filter where id = 1) <> 'stale' then raise exception 'stale expected'; end if;
    if (select scan_rev_id from api.scan_pending(0, 10) where wiki_id = 1) <> 100 then raise exception 'pending should expose the scanned rev'; end if;

    -- הרצה חוזרת: אותה תוצאה, והפירוט מתעדכן יחד עם הסיכום
    perform api.sync_apply_scan('[{"wikipedia_id":1,"rev_id":101,"lists_version":"v2","verdict":"problem","matches":[]}]');
    if (select lists_version from enrich.content_scan where wiki_id = 1) <> 'v2' or (select matches from enrich.content_scan_detail where wiki_id = 1) <> '[]' then
        raise exception 'summary and detail must update together';
    end if;
    perform api.scan_set_topic(1, 'sport');
    if (select topic from enrich.content_scan where wiki_id = 1) <> 'sport' then raise exception 'topic'; end if;
    n := api.scan_prune(array[1]::bigint[]);
    if n <> 1 then raise exception 'prune count %', n; end if;
    if exists (select 1 from enrich.content_scan_detail where wiki_id = 1) then raise exception 'prune must cascade'; end if;
end $$;
rollback;
select 'ok t13_scan_io' as test;
