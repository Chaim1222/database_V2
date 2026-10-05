-- 0004: העשרה, החלטות אדם ותפעול.

-- ===== enrich: יקר להשגה, שורד =====
create table enrich.wiki_enrichment (
    wiki_id            bigint primary key,
    wikidata_desc      text,
    wiki_created_at    timestamptz,          -- תאריך הגרסה הראשונה בוויקיפדיה
    length             bigint,               -- אורך הדף (קלות ייבוא)
    mech_redirect      boolean,              -- קיימת הפניה במכלול באותה כותרת
    -- מתי כל קבוצת שדות נבדקה (גם כשהתוצאה ריקה): מחליף את דגלי ה-*_checked הבוליאניים
    desc_checked_at    timestamptz,
    created_checked_at timestamptz,
    length_checked_at  timestamptz,
    redirect_checked_at timestamptz
);

-- תוצאת הסינון (word-filter) לדף. הרמות: שיטה (רשימה/הקשר) x רשימה (מאושרות/הצעות).
create table enrich.content_scan (
    wiki_id            bigint primary key,
    rev_id             bigint,
    lists_version      text,
    verdict_list_a     text check (verdict_list_a in ('problem', 'review', 'wording', 'clean')),
    verdict_list_s     text check (verdict_list_s in ('problem', 'review', 'wording', 'clean')),
    verdict_ctx_a      text check (verdict_ctx_a in ('problem', 'review', 'wording', 'clean')),
    verdict_ctx_s      text check (verdict_ctx_s in ('problem', 'review', 'wording', 'clean')),
    suspicion_a        text check (suspicion_a in ('high', 'medium', 'low')),
    suspicion_s        text check (suspicion_s in ('high', 'medium', 'low')),
    hidden_count_a     integer,
    hidden_count_s     integer,
    names_count_a      integer,
    names_count_s      integer,
    matches_total      integer,
    photo_count        integer,
    has_images         boolean,
    dictionary         text,                 -- סוג ('ספורט'...) או null
    dictionary_why     text,
    topic              text,
    scanned_at         timestamptz not null default now()
);
create index content_scan_topic_idx on enrich.content_scan (topic);

-- הפירוט הכבד, בטבלה נפרדת: רשימות לא שולפות אותו.
create table enrich.content_scan_detail (
    wiki_id bigint primary key references enrich.content_scan (wiki_id) on delete cascade,
    counts  jsonb,
    matches jsonb,
    images  jsonb
);

-- ===== work: החלטות אדם =====
create table work.admin (
    user_id  uuid primary key references auth.users (id) on delete cascade,
    added_at timestamptz not null default now()
);

create table work.manual_link (
    mech_id    bigint primary key,
    wiki_id    bigint not null,
    reason     text,
    created_by uuid default auth.uid(),
    created_at timestamptz not null default now()
);

-- החרגות: דף ויקיפדיה שבכוונה לא יובא, או כותרת נעולה ליצירה במכלול.
create table work.exclusion (
    id         bigserial primary key,
    kind       text not null check (kind in ('import_excluded', 'locked_create')),
    wiki_id    bigint,
    title      text,
    reason     text,
    created_by uuid default auth.uid(),
    created_at timestamptz not null default now(),
    check (wiki_id is not null or title is not null)
);
create unique index exclusion_wiki_idx on work.exclusion (kind, wiki_id) where wiki_id is not null;
create unique index exclusion_title_idx on work.exclusion (kind, title) where title is not null;

-- נעילות: מקור אחד (במקום חמישה). site+page_id.
create table work.page_lock (
    site        text not null check (site in ('wikipedia', 'mechalol')),
    page_id     bigint not null,
    level       text not null check (level in ('read', 'read-semi', 'create')),
    detected_by text not null,
    detected_at timestamptz not null default now(),
    primary key (site, page_id)
);

create table work.scan_feedback (
    id           bigint generated always as identity primary key,
    wiki_id      bigint not null,
    match_key    text not null,
    word         text not null,
    entries      text[] not null,
    topic        text,
    hidden       text,
    label        text not null check (label in ('false', 'true')),
    level        text,
    context_before text,
    context_after  text,
    lists_version  text,
    user_id      uuid not null default auth.uid(),
    created_at   timestamptz not null default now(),
    unique (wiki_id, match_key, user_id)
);

-- ===== ops: תפעול =====
create table ops.sync_run (
    run_id            uuid primary key default gen_random_uuid(),
    kind              text not null check (kind in ('sync', 'reconcile', 'enrich', 'scan', 'maintenance', 'rebuild')),
    started_at        timestamptz not null default now(),
    finished_at       timestamptz,
    status            text not null default 'running' check (status in ('running', 'succeeded', 'failed', 'cancelled')),
    step              text,                      -- השלב האחרון שהושלם (להמשך אחרי עצירה)
    stats             jsonb not null default '{}',
    error             text,
    watermark_before  jsonb,
    watermark_after   jsonb
);
create index sync_run_kind_idx on ops.sync_run (kind, started_at desc);

create table ops.watermark (
    site   text not null check (site in ('wikipedia', 'mechalol')),
    stream text not null,
    ts     timestamptz not null,
    primary key (site, stream)
);

create table ops.reconcile_run (
    run_id        uuid primary key default gen_random_uuid(),
    started_at    timestamptz not null default now(),
    finished_at   timestamptz,
    snapshot_meta jsonb not null default '{}',   -- נקודות דלתא, גודל מקור וטבלה, חלון, אורך ריצה
    summary       jsonb not null default '{}'
);

create table ops.reconcile_finding (
    id                 bigserial primary key,
    run_id             uuid not null references ops.reconcile_run (run_id) on delete cascade,
    site               text not null check (site in ('wikipedia', 'mechalol')),
    class              text not null,            -- only_source / only_db / title / status / ...
    page_id            bigint not null,
    title              text,
    detail             jsonb,
    explained_by_window boolean not null default false
);
create index reconcile_finding_run_idx on ops.reconcile_finding (run_id, site, class);

-- ספירות מחושבות מראש לדשבורד. מתעדכנות בסוף כל ריצת סנכרון (ops.refresh_counts).
create table ops.dashboard_counts (
    key        text primary key,
    n          bigint not null,
    updated_at timestamptz not null default now()
);

create or replace function ops.refresh_counts()
returns void
language sql
set search_path = ''
as $$
    insert into ops.dashboard_counts (key, n, updated_at)
    values
        ('wiki_pages',   (select count(*) from mirror.wiki_page), now()),
        ('mech_pages',   (select count(*) from mirror.mech_page), now()),
        ('missing',      (select count(*) from derived.wiki_gap g
                           where g.kind = 'missing'
                             and not exists (select 1 from work.exclusion e
                                             where e.kind = 'import_excluded' and e.wiki_id = g.wiki_id)), now()),
        ('rav_review',   (select count(*) from derived.wiki_gap where kind = 'rav_review'), now()),
        ('locks',        (select count(*) from work.page_lock), now()),
        ('rev_tasks',    (select count(*) from derived.rev_check c
                           where not exists (select 1 from work.manual_link m where m.mech_id = c.mech_id)), now())
    on conflict (key) do update set n = excluded.n, updated_at = excluded.updated_at;
$$;
