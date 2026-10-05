-- 0002: מראות המקורות. נכתבות רק על ידי הסנכרון (service_role). בלי הפניות, בלי נגזרים.
-- זהות = page_id. הכותרת היא תכונה; הייחודיות שלה נאכפת, והסנכרון מביא למצב סופי (DESIGN.md סעיף 5).
-- בכוונה בלי עמודות שאין להן צרכן (seen_at, rev_ts, גרסת המכלול: מעקב גרסת מקור מחוץ להיקף), ובלי
-- title_key כעמודה: אינדקס ביטוי שומר עותק אחד של המפתח (נמדד: חוסך כ-60 MB ב-406 אלף שורות).

create table mirror.wiki_page (
    page_id       bigint primary key,
    title         text not null,
    latest_rev_id bigint,          -- לדילוג בסריקת התוכן על ערך שלא השתנה
    constraint wiki_page_title_key unique (title)
);
create index wiki_page_title_key_idx on mirror.wiki_page (mirror.title_key(title));

create table mirror.mech_page (
    page_id         bigint primary key,
    title           text not null,
    status          text not null references ref.mech_status (code),
    source_type     text not null default 'unknown' references ref.mech_source (code),
    needs_attention boolean not null default false,   -- הכותרת קיימת, אין תוכן ("ערכים לפתיחה")
    is_dictionary   boolean not null default false,   -- תקציר מילוני
    constraint mech_page_title_key unique (title)
);
create index mech_page_title_key_idx on mirror.mech_page (mirror.title_key(title));

-- "הרב/רבי": התאמה רק אחרי הסרת הקידומת מצד אחד, לבדיקה אנושית. הסרת הקידומת מהמפתח:
create or replace function mirror.rav_strip(k text)
returns text
language sql
immutable
parallel safe
strict
as $$ select regexp_replace(k, '^(הרב|רבי) ', '') $$;
-- אינדקס חלקי קטן (רק ערכי מכלול עם קידומת): מחליף אינדקס מלא של 31 MB על כל הכותרות
create index mech_page_rav_idx on mirror.mech_page (mirror.rav_strip(mirror.title_key(title)))
    where title ~ '^(הרב|רבי)\s';

-- טבלת אירועים אחת (במקום שבע). הסנכרון כותב; הדוחות והמשימות קוראים.
create table mirror.page_event (
    id         bigserial primary key,
    site       text not null check (site in ('wikipedia', 'mechalol')),
    kind       text not null check (kind in ('create', 'delete', 'move', 'restore')),
    page_id    bigint not null,           -- 0 כשהאירוע נרשם לפי כותרת בלבד
    title      text not null,
    new_title  text,                      -- ב-move: הכותרת החדשה
    ts         timestamptz not null,
    run_id     uuid,
    constraint page_event_unique unique (site, kind, page_id, ts, title)
);
create index page_event_page_idx on mirror.page_event (site, page_id);
create index page_event_ts_idx on mirror.page_event (site, kind, ts desc);
