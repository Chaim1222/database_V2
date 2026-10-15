-- 0046: הפעלת workflows מהדשבורד. pg_net והכספת מדומים כאן (במסד המקומי אין אותם).
begin;
do $$ begin
    if not exists (select 1 from ops.schema_migration where version='0046') then raise exception 'migration 0046 not registered'; end if;
end $$;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2');
insert into work.admin (user_id) values ('00000000-0000-0000-0000-0000000000a1');

-- בלי pg_net: שגיאה ברורה, ושום דבר לא נרשם
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ declare failed boolean := false; begin
    begin perform api.request_run('sync.yml'); exception when sqlstate '55000' then failed := sqlerrm like '%pg_net%'; end;
    if not failed then raise exception 'missing pg_net not reported'; end if;
end $$;
reset role;
do $$ begin
    if exists (select 1 from ops.dashboard_run) then raise exception 'row written without pg_net'; end if;
end $$;

-- pg_net מדומה: כל קריאה נרשמת, והקוד שמוחזר נקבע ב-test.http_code (ברירת מחדל 204)
create schema net;
create table net._http_response (id bigserial primary key, status_code integer, content text, error_msg text);
create table net.sent (id bigint, url text, body jsonb, headers jsonb);
create function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) returns bigint
language plpgsql as $$
declare v_id bigint;
begin
    insert into net._http_response (status_code, content)
    values (coalesce(nullif(current_setting('test.http_code', true), '')::integer, 204), 'rejected body') returning id into v_id;
    insert into net.sent values (v_id, url, body, headers);
    return v_id;
end $$;
create schema vault;
create table vault.decrypted_secrets (name text, decrypted_secret text);

-- בלי הסוד: שגיאה ברורה
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ declare failed boolean := false; begin
    begin perform api.request_run('sync.yml'); exception when sqlstate '55000' then failed := sqlerrm like '%github_dispatch_token%'; end;
    if not failed then raise exception 'missing secret not reported'; end if;
end $$;
reset role;
insert into vault.decrypted_secrets values ('github_dispatch_token', 'tok');

-- מנהל: הפעלה, ובקשה שנייה בזמן שהראשונה פתוחה לא נשלחת
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ declare r jsonb; s jsonb; begin
    r := api.request_run('sync.yml');
    if not (r ->> 'started')::boolean then raise exception 'first request not started: %', r; end if;
    s := api.run_status('sync.yml');
    if s ->> 'status' <> 'requested' or s ->> 'dispatch_error' is not null then raise exception 'status after request: %', s; end if;
    r := api.request_run('sync.yml');
    if (r ->> 'started')::boolean or r ->> 'reason' <> 'already_running' then raise exception 'duplicate request started: %', r; end if;
    if api.run_status('maintenance.yml') ->> 'status' is not null then raise exception 'unrelated workflow has status'; end if;
    begin perform api.request_run('rebuild.yml'); raise exception 'workflow outside the list accepted';
    exception when sqlstate '22023' then null; end;
end $$;
reset role;
do $$ declare v ops.dashboard_run; sent net.sent; begin
    select * into v from ops.dashboard_run where workflow = 'sync.yml';
    if v.requested_by is distinct from '00000000-0000-0000-0000-0000000000a1' then raise exception 'requested_by'; end if;
    if (select count(*) from net.sent) <> 1 then raise exception 'expected exactly one dispatch, got %', (select count(*) from net.sent); end if;
    select * into sent from net.sent;
    if sent.id is distinct from v.http_request_id then raise exception 'http_request_id not stored'; end if;
    if sent.url <> 'https://api.github.com/repos/Chaim1222/database_V2/actions/workflows/sync.yml/dispatches' then raise exception 'url %', sent.url; end if;
    if sent.body <> jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('dashboard_request', v.request_id::text)) then raise exception 'body %', sent.body; end if;
    if sent.headers ->> 'Authorization' <> 'Bearer tok' then raise exception 'token header'; end if;
end $$;

-- לא-מנהל ו-anon: אין הפעלה ואין מצב; authenticated לא מדווח
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';
do $$ declare denied boolean := false; begin
    begin perform api.request_run('maintenance.yml'); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'non-admin request allowed'; end if;
    denied := false;
    begin perform api.run_status('sync.yml'); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'non-admin status allowed'; end if;
    denied := false;
    begin perform api.report_run('sync.yml', gen_random_uuid(), 'success'); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'authenticated report allowed'; end if;
end $$;
reset role;
set local role anon;
do $$ declare denied boolean := false; begin
    begin perform api.request_run('sync.yml'); exception when insufficient_privilege then denied := true; end;
    if not denied then raise exception 'anon request allowed'; end if;
end $$;
reset role;

-- דיווח ה-workflow: מזהה זר לא משנה; התחלה וסיום לפי המזהה
set local role service_role;
do $$ declare id uuid; begin
    if api.report_run('sync.yml', gen_random_uuid(), 'success') then raise exception 'foreign request id accepted'; end if;
    select request_id into id from ops.dashboard_run where workflow = 'sync.yml';
    if not api.report_run('sync.yml', id, 'running') then raise exception 'running not recorded'; end if;
    begin perform api.report_run('sync.yml', id, 'requested'); raise exception 'invalid status accepted';
    exception when sqlstate '22023' then null; end;
end $$;
reset role;
do $$ begin
    if (select status from ops.dashboard_run where workflow = 'sync.yml') <> 'running' or
       (select started_at from ops.dashboard_run where workflow = 'sync.yml') is null then raise exception 'running state'; end if;
end $$;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ declare r jsonb; begin
    r := api.request_run('sync.yml');
    if (r ->> 'started')::boolean then raise exception 'request started while running'; end if;
end $$;
reset role;
set local role service_role;
do $$ declare id uuid; begin
    select request_id into id from ops.dashboard_run where workflow = 'sync.yml';
    perform api.report_run('sync.yml', id, 'success');
end $$;
reset role;

-- אחרי סיום: בקשה חדשה מותרת, ודיווח מאוחר של הריצה הקודמת לא דורס אותה
create temp table old_req as select request_id from ops.dashboard_run where workflow = 'sync.yml';
grant select on old_req to service_role;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ declare s jsonb; begin
    s := api.run_status('sync.yml');
    if s ->> 'status' <> 'success' or s ->> 'finished_at' is null then raise exception 'success state %', s; end if;
    if not (api.request_run('sync.yml') ->> 'started')::boolean then raise exception 'request after success not started'; end if;
end $$;
reset role;
set local role service_role;
do $$ begin
    if api.report_run('sync.yml', (select request_id from old_req), 'failed') then raise exception 'stale report accepted'; end if;
end $$;
reset role;
do $$ begin
    if (select status from ops.dashboard_run where workflow = 'sync.yml') <> 'requested' then raise exception 'stale report changed state'; end if;
end $$;

-- GitHub דחה את ההפעלה: הסיבה מוחזרת, והבקשה הדחויה לא חוסמת בקשה חדשה
set local test.http_code = '401';
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ declare s jsonb; begin
    if not (api.request_run('maintenance.yml') ->> 'started')::boolean then raise exception 'maintenance not started'; end if;
    s := api.run_status('maintenance.yml');
    if s ->> 'dispatch_error' not like 'GitHub 401:%' then raise exception 'dispatch error not reported: %', s; end if;
    perform set_config('test.http_code', '204', true);
    if not (api.request_run('maintenance.yml') ->> 'started')::boolean then raise exception 'rejected request blocked a new one'; end if;
    if api.run_status('maintenance.yml') ->> 'dispatch_error' is not null then raise exception 'old dispatch error shown'; end if;
end $$;
reset role;

-- בקשה פתוחה שעבר החלון שלה (ריצה שאבדה בלי דיווח) לא חוסמת לנצח
update ops.dashboard_run set requested_at = now() - interval '31 minutes' where workflow = 'maintenance.yml';
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ begin
    if not (api.request_run('maintenance.yml') ->> 'started')::boolean then raise exception 'expired request still blocks'; end if;
end $$;
reset role;
rollback;
select 'ok t39_dashboard_runs';
