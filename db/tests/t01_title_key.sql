-- golden: הפלט של hygiene ב-scripts/normalize.py על אותם קלטים (נוצר אוטומטית).
do $$
declare r record; bad int := 0;
begin
  for r in select * from (values
    (E'  \u05d1\u05d9\u05ea  \u05d4\u05d0\u05d6\u05e8\u05d7 ', E'\u05d1\u05d9\u05ea \u05d4\u05d0\u05d6\u05e8\u05d7'),
    (E'\u05d1\u05d9\u05ea\u00a0\u05d4\u05d0\u05d6\u05e8\u05d7', E'\u05d1\u05d9\u05ea \u05d4\u05d0\u05d6\u05e8\u05d7'),
    (E'\u200f\u05e9\u05dd\u200e \u05e2\u05dd \u05e1\u05d9\u05de\u05d5\u05e0\u05d9 \u05db\u05d9\u05d5\u05d5\u05df\u202b', E'\u05e9\u05dd \u05e2\u05dd \u05e1\u05d9\u05de\u05d5\u05e0\u05d9 \u05db\u05d9\u05d5\u05d5\u05df'),
    (E'\u05d4\u2019\u05ea\u05e9\u05f4\u05e3', E'\u05d4\u0027\u05ea\u05e9"\u05e3'),
    (E'\u05d4\u05f3\u05ea\u05e9\u05f4\u05e3', E'\u05d4\u0027\u05ea\u05e9"\u05e3'),
    (E'\u201c\u05e6\u05d9\u05d8\u05d5\u05d8\u201d \u05d5\u2018\u05d0\u05d7\u05e8\u2019', E'"\u05e6\u05d9\u05d8\u05d5\u05d8" \u05d5\u0027\u05d0\u05d7\u05e8\u0027'),
    (E'\u05e7\u05d9\u05e5 \u2013 \u05d7\u05d5\u05e8\u05e3 \u2014 \u05e1\u05ea\u05d9\u05d5', E'\u05e7\u05d9\u05e5 - \u05d7\u05d5\u05e8\u05e3 - \u05e1\u05ea\u05d9\u05d5'),
    (E'\u05d0\u05d1\u05df\u05be\u05e2\u05d6\u05e8\u05d0', E'\u05d0\u05d1\u05df-\u05e2\u05d6\u05e8\u05d0'),
    (E'a\u2010b\u2011c\u2012d', E'a-b-c-d'),
    (E'Morphine (band)', E'Morphine (band)'),
    (E'\u05d0\u05b7\u05d1', E'\u05d0\u05b7\u05d1'),
    (E'\u05db\u05d5\u05ea\u05e8\u05ea   \u05e2\u05dd\u0009\u0009\u05d8\u05d0\u05d1\u05d9\u05dd\u000a\u05d5\u05e9\u05d5\u05e8\u05d5\u05ea', E'\u05db\u05d5\u05ea\u05e8\u05ea \u05e2\u05dd \u05d8\u05d0\u05d1\u05d9\u05dd \u05d5\u05e9\u05d5\u05e8\u05d5\u05ea'),
    (E'\u200f', E''),
    (E'', E''),
    (E'\u05e8\u05d1 \u05d9\u05e9\u05e8\u05d0\u05dc \u05d7\u05d9\u05d9\u05dd \u05d5\u05d9\u05d9\u05e1', E'\u05e8\u05d1 \u05d9\u05e9\u05e8\u05d0\u05dc \u05d7\u05d9\u05d9\u05dd \u05d5\u05d9\u05d9\u05e1'),
    (E'\u05e9\u05d5\u05de\u05d9\u05d9\u05e7\u05e8-\u05dc\u05d5\u05d9 9', E'\u05e9\u05d5\u05de\u05d9\u05d9\u05e7\u05e8-\u05dc\u05d5\u05d9 9')
  ) as v(input, expected) loop
    if mirror.title_key(r.input) is distinct from r.expected then
      bad := bad + 1;
      raise warning 'title_key mismatch: % -> % (expected %)', r.input, mirror.title_key(r.input), r.expected;
    end if;
  end loop;
  if bad > 0 then raise exception 'title_key golden: % mismatches', bad; end if;
  -- null נשאר null (strict)
  if mirror.title_key(null) is not null then raise exception 'title_key(null) should be null'; end if;
end $$;
select 'ok t01_title_key' as test;
