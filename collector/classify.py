"""
סיווג ערך מכלול לפי הקטגוריות של הדף עצמו (קודי הסטטוס כמו ב-ref.mech_status). סדר העדיפויות הועתק מהמערכת
הקודמת (fetch_mechalol.classify_page_from_own_categories) ואין לשנות אותו בלי החלטה.
"""
import re

CAT_CREATED = "קטגוריה:המכלול: ערכים שנוצרו במכלול"
CAT_TRANSLATED = "קטגוריה:המכלול: ערכים שתורגמו במכלול"
CAT_PIRUSHON = "קטגוריה:המכלול: פירושונים שנוצרו במכלול"
CAT_MISSING_SORT = "קטגוריה:המכלול: ערכים מוויקיפדיה ללא תבנית מיון ויקיפדיה"
CAT_PAGES_TO_OPEN = "קטגוריה:ערכים לפתיחה"
CAT_DICTIONARY = "קטגוריה:המכלול: ערכים מילוניים"
CAT_CHABADPEDIA = 'קטגוריה:המכלול: דפים שיובאו מחב"דפדיה'
CAT_WIKISHIVA = "קטגוריה:המכלול: דפים שיובאו מויקישיבה"
CAT_KEPT_AFTER_DELETE = "קטגוריה:המכלול: ערכים שנמחקו בוויקיפדיה"
CAT_SPLIT = "קטגוריה:המכלול: ערכים מוויקיפדיה שפוצלו במכלול"
MAINTENANCE_PREFIX = "קטגוריה:המכלול:"

HEBREW_MONTHS = {
    "ינואר": "01", "פברואר": "02", "מרץ": "03", "אפריל": "04", "מאי": "05", "יוני": "06",
    "יולי": "07", "אוגוסט": "08", "ספטמבר": "09", "אוקטובר": "10", "נובמבר": "11", "דצמבר": "12",
}


def parse_update_month(category):
    """'קטגוריה:המכלול: ערכים שעודכנו לאחרונה בדצמבר 2020' -> '2020-12', או None."""
    match = re.search(r"ב([א-ת]+)\s+(\d{4})", category)
    if not match or match.group(1) not in HEBREW_MONTHS:
        return None
    return f"{match.group(2)}-{HEBREW_MONTHS[match.group(1)]}"


def classify(categories):
    """categories: קבוצת שמות קטגוריה מלאים. מחזיר {status, source_type, needs_attention, is_dictionary}."""
    cats = set(categories)
    has_update = any(c.startswith(MAINTENANCE_PREFIX) and parse_update_month(c) for c in cats)
    if CAT_CREATED in cats:
        status, source = "created_in_mech", "created"
    elif CAT_TRANSLATED in cats:
        status, source = "created_in_mech", "translated"
    elif CAT_PIRUSHON in cats:
        status, source = "created_in_mech", "pirushon"
    elif CAT_CHABADPEDIA in cats:
        status, source = "chabadpedia", "chabadpedia"
    elif CAT_WIKISHIVA in cats:
        status, source = "wikishiva", "wikishiva"
    elif CAT_KEPT_AFTER_DELETE in cats:
        status, source = "kept_after_wiki_delete", "wikipedia_deleted_kept"
    elif CAT_SPLIT in cats:
        status, source = "split_from_wiki", "split_from_wikipedia"
    elif has_update:
        status, source = "imported_documented", "wikipedia_documented"
    elif CAT_MISSING_SORT in cats:
        status, source = "imported_undocumented", "missing_sort"
    else:
        status, source = "imported_undocumented", "unknown"
    return {
        "status": status,
        "source_type": source,
        "needs_attention": CAT_PAGES_TO_OPEN in cats,
        "is_dictionary": CAT_DICTIONARY in cats,
    }
