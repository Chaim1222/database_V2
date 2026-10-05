-- 0006: חיזוק (advisor של סופרבייס, 0011): לנעול search_path בפונקציות הנרמול. הן משתמשות רק בפונקציות מובנות
-- (pg_catalog), ולכן search_path ריק בטוח. אינדקסי הביטוי ממשיכים לעבוד (הפונקציות נשארות immutable).
alter function mirror.title_key(text) set search_path = '';
alter function mirror.rav_strip(text) set search_path = '';
