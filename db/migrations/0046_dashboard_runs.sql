-- 0046: הפעלת workflows מהדשבורד (כמו כפתור "רענן נתוני תחזוקה" ב-V1). הדפדפן לא יכול להפעיל workflow לבד (צריך מפתח
-- GitHub), ולכן המסד שולח את הבקשה (pg_net) עם מפתח ששמור בכספת ולא יוצא החוצה.
--
-- הזרימה: api.request_run(workflow) - מנהל בלבד (api.is_admin), רק workflow מהרשימה הסגורה - יוצרת מזהה בקשה ושולחת
-- workflow_dispatch עם הקלט dashboard_request. ה-workflow מדווח התחלה וסיום (api.report_run, service_role בלבד) רק
-- כשהקלט הזה קיים ותואם, כך שריצה מתוזמנת או ידנית מ-GitHub לא מתערבבת בבקשה מהדשבורד. api.run_status(workflow)
-- מחזירה את המצב, ואם GitHub דחה את ההפעלה (מפתח שגוי, חסר הרשאה) את הסיבה, כי pg_net לא מחזיר שגיאה מיידית.
--
-- תנאים מוקדמים (חד-פעמיים, לא בקובץ הזה): ההרחבה pg_net מופעלת, ובכספת סוד בשם github_dispatch_token -
-- מפתח fine-grained לריפו Chaim1222/database_V2 בלבד, הרשאה Actions: Read and write. בלעדיהם request_run נכשלת
-- בהודעה ברורה ולא שולחת דבר. ה-workflow חייב להיות ב-main.

create table ops.dashboard_run (
    workflow        text primary key,
    request_id      uuid not null,
    status          text not null check (status in ('requested', 'running', 'success', 'failed')),
    requested_by    uuid,
    requested_at    timestamptz not null default now(),
    started_at      timestamptz,
    finished_at     timestamptz,
    http_request_id bigint
);
alter table ops.dashboard_run enable row level security;

-- הרשימה הסגורה, ולכל workflow חלון שבו בקשה פתוחה חוסמת בקשה חדשה (מעל משך הריצה המרבי שלו ב-GitHub).
create or replace function ops.dashboard_run_window(p_workflow text)
returns interval
language sql
immutable
set search_path = ''
as $$
    select case p_workflow
        when 'sync.yml' then interval '4 hours'           -- סנכרון 90 דקות + סריקה 120 דקות
        when 'maintenance.yml' then interval '30 minutes'  -- timeout 15 דקות
    end;
$$;

create or replace function api.request_run(p_workflow text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row     ops.dashboard_run;
    v_code    integer;
    v_token   text;
    v_request uuid := gen_random_uuid();
begin
    if not api.is_admin() then
        raise exception 'אין הרשאה להפעיל ריצה' using errcode = '42501';
    end if;
    if ops.dashboard_run_window(p_workflow) is null then
        raise exception 'workflow לא מורשה: %', p_workflow using errcode = '22023';
    end if;

    select * into v_row from ops.dashboard_run where workflow = p_workflow for update;
    if found and v_row.status in ('requested', 'running')
       and v_row.requested_at > now() - ops.dashboard_run_window(p_workflow) then
        -- בקשה שנדחתה ב-GitHub לא תתחיל לעולם, ולכן אינה חוסמת.
        if v_row.http_request_id is not null and to_regclass('net._http_response') is not null then
            execute 'select status_code from net._http_response where id = $1' into v_code using v_row.http_request_id;
        end if;
        if v_code is null or v_code = 204 then
            return jsonb_build_object('started', false, 'reason', 'already_running', 'requested_at', v_row.requested_at);
        end if;
    end if;

    if to_regprocedure('net.http_post(text, jsonb, jsonb, jsonb, integer)') is null then
        raise exception 'ההרחבה pg_net אינה מופעלת (ראו הערות 0046)' using errcode = '55000';
    end if;
    select decrypted_secret into v_token from vault.decrypted_secrets where name = 'github_dispatch_token';
    if v_token is null then
        raise exception 'חסר הסוד github_dispatch_token בכספת (ראו הערות 0046)' using errcode = '55000';
    end if;

    insert into ops.dashboard_run (workflow, request_id, status, requested_by, requested_at, started_at, finished_at, http_request_id)
    values (p_workflow, v_request, 'requested', auth.uid(), now(), null, null, null)
    on conflict (workflow) do update set request_id = excluded.request_id, status = excluded.status,
        requested_by = excluded.requested_by, requested_at = excluded.requested_at,
        started_at = null, finished_at = null, http_request_id = null;

    update ops.dashboard_run set http_request_id = net.http_post(
        url     := 'https://api.github.com/repos/Chaim1222/database_V2/actions/workflows/' || p_workflow || '/dispatches',
        body    := jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('dashboard_request', v_request::text)),
        params  := '{}'::jsonb,
        headers := jsonb_build_object(
            'Accept', 'application/vnd.github+json',
            'Authorization', 'Bearer ' || v_token,
            'X-GitHub-Api-Version', '2022-11-28',
            'User-Agent', 'mechalol-dashboard-v2',
            'Content-Type', 'application/json'),
        timeout_milliseconds := 10000)
    where workflow = p_workflow;

    return jsonb_build_object('started', true, 'requested_at', now());
end;
$$;

create or replace function api.run_status(p_workflow text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_row  ops.dashboard_run;
    v_code integer;
    v_body text;
begin
    if not api.is_admin() then
        raise exception 'אין הרשאה' using errcode = '42501';
    end if;
    select * into v_row from ops.dashboard_run where workflow = p_workflow;
    if not found then
        return jsonb_build_object('status', null);
    end if;
    if v_row.http_request_id is not null and to_regclass('net._http_response') is not null then
        execute 'select status_code, coalesce(error_msg, content) from net._http_response where id = $1'
            into v_code, v_body using v_row.http_request_id;
    end if;
    return jsonb_build_object(
        'status', v_row.status,
        'requested_at', v_row.requested_at,
        'started_at', v_row.started_at,
        'finished_at', v_row.finished_at,
        -- GitHub מחזיר 204 כשההפעלה התקבלה; כל קוד אחר = ההפעלה נדחתה.
        'dispatch_error', case when v_code is not null and v_code <> 204 then 'GitHub ' || v_code || ': ' || left(coalesce(v_body, ''), 300) end);
end;
$$;

-- ה-workflow מדווח; בקשה שהוחלפה בבקשה חדשה יותר (מזהה אחר) לא משנה דבר.
create or replace function api.report_run(p_workflow text, p_request uuid, p_status text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
    if p_status not in ('running', 'success', 'failed') then
        raise exception 'סטטוס לא חוקי: %', p_status using errcode = '22023';
    end if;
    update ops.dashboard_run
       set status = p_status,
           started_at = case when p_status = 'running' then now() else coalesce(started_at, now()) end,
           finished_at = case when p_status = 'running' then null else now() end
     where workflow = p_workflow and request_id = p_request;
    return found;
end;
$$;

revoke all on function ops.dashboard_run_window(text), api.request_run(text), api.run_status(text),
    api.report_run(text, uuid, text) from public, anon, authenticated;
grant execute on function api.request_run(text), api.run_status(text) to authenticated;
grant execute on function api.report_run(text, uuid, text) to service_role;

insert into ops.schema_migration (version) values ('0046');
