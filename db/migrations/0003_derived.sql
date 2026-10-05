-- 0003: נגזר. ניתן לבנייה מחדש בכל רגע; לעולם לא נערך ביד.
-- עיקרון (נמדד, ראו perf/): קישור "רגיל" בין ערך מכלול לדף ויקיפדיה (אותה כותרת אחרי נרמול) **אינו נשמר**:
-- הוא תוצאה של join על אינדקס הביטוי. נשמרים רק החריגים (~2% מהשורות): התאמה סמנטית, תבנית שאומתה ב-API,
-- וחסר/הרב-רבי לדפי ויקיפדיה.

-- מפתח התאמה סמנטי (מכלול -> ויקיפדיה, כיוון אחד): נשמר **רק** כשהכללים הסמנטיים (scripts/normalize.py)
-- שינו את הכותרת. מחושב בקולקטור (מקום אחד לכללים).
create table derived.mech_key (
    mech_id            bigint primary key,
    wiki_candidate_key text not null,
    rules              text[] not null default '{}'
);
create index mech_key_candidate_idx on derived.mech_key (wiki_candidate_key);

-- תבנית {{מיון ויקיפדיה}} שאומתה מול ה-API: wiki_id של הדף שהתבנית מצביעה עליו (null + template_ref = "בעיה בשם").
create table derived.template_link (
    mech_id      bigint primary key,
    wiki_id      bigint,
    template_ref text,
    verified_at  timestamptz not null default now()
);
create index template_link_wiki_idx on derived.template_link (wiki_id) where wiki_id is not null;

-- חריגים בצד ויקיפדיה: דף שאין לו ערך מכלול ('missing'), או שיש רק התאמת הרב/רבי ('rav_review').
-- דף שנעדר מהטבלה = מקושר. שורה לכל דף חסר בלבד (~27 אלף), לא לכל 406 אלף.
create table derived.wiki_gap (
    wiki_id bigint primary key,
    kind    text not null check (kind in ('missing', 'rav_review'))
);
create index wiki_gap_kind_idx on derived.wiki_gap (kind, wiki_id);

-- תוצאות הבדיקה החודשית מול גרסת המקור (`גרסה=` בתבנית). נכתבת על ידי maintenance.
create table derived.rev_check (
    mech_id             bigint primary key,
    rev_task            text not null check (rev_task in ('rename', 'redirect', 'bad_rev', 'deleted_by_rev')),
    rev_id              bigint,
    linked_wiki_id      bigint,
    rev_page_id         bigint,
    rev_page_title      text,
    checked_at          timestamptz not null default now()
);
create index rev_check_task_idx on derived.rev_check (rev_task, mech_id);

-- חישוב מחדש של wiki_gap לקבוצת דפים (או לכולם כש-null). כותבת רק מה שהשתנה, ומסירה שורות של דפים
-- שנעלמו או שקושרו. אידמפוטנטית. ההתאמה, לפי סדר: אותה כותרת (אינדקס ביטוי), התאמה סמנטית (mech_key),
-- תבנית שאומתה, שיוך ידני; ואם אין, הרב/רבי (אינדקס חלקי) -> 'rav_review'; אחרת 'missing'.
create or replace function derived.refresh_wiki_gap(p_ids bigint[] default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
    changed integer;
begin
    with scope as (
        select w.page_id, w.title, mirror.title_key(w.title) as k
        from mirror.wiki_page w
        where p_ids is null or w.page_id = any (p_ids)
    ), matched as (
        select s.page_id, s.k,
               (exists (select 1 from mirror.mech_page m where mirror.title_key(m.title) = s.k)
                or exists (select 1 from derived.mech_key mk where mk.wiki_candidate_key = s.k)
                or exists (select 1 from derived.template_link t where t.wiki_id = s.page_id)
                or exists (select 1 from work.manual_link x where x.wiki_id = s.page_id)) as strict_match
        from scope s
    ), target as (
        select m.page_id as wiki_id,
               case
                   when m.strict_match then null
                   when exists (select 1 from mirror.mech_page mm
                                where mm.title ~ '^(הרב|רבי)\s'
                                  and mirror.rav_strip(mirror.title_key(mm.title)) = m.k)
                        or (m.k ~ '^(הרב|רבי) '
                            and exists (select 1 from mirror.mech_page mm
                                        where mirror.title_key(mm.title) = mirror.rav_strip(m.k)))
                        then 'rav_review'
                   else 'missing'
               end as kind
        from matched m
    ), upserted as (
        insert into derived.wiki_gap as g (wiki_id, kind)
        select wiki_id, kind from target where kind is not null
        on conflict (wiki_id) do update set kind = excluded.kind
            where g.kind is distinct from excluded.kind
        returning 1
    ), removed as (
        delete from derived.wiki_gap g
        where (p_ids is null or g.wiki_id = any (p_ids))
          and not exists (select 1 from target t where t.wiki_id = g.wiki_id and t.kind is not null)
        returning 1
    )
    select (select count(*) from upserted) + (select count(*) from removed) into changed;
    return changed;
end;
$$;
