"""
נרמול כותרות. שני דברים נפרדים:

1. title_key: נרמול סימטרי לשני האתרים (NFC, סימוני כיוון, מירכאות ומקפים אחידים, רווחים). **זהה ל-mirror.title_key
   ב-SQL** (db/migrations/0001; בדיקת golden ב-tests/test_normalize.py ובדיקת t01 ב-SQL).
2. כללים סמנטיים (מכלול -> ויקיפדיה, כיוון אחד): הכותרת במכלול אחרי תיקוני כתיב ידועים. נשמרים ב-derived.mech_key
   רק כשהכותרת השתנתה. הכללים הועתקו מהמערכת הקודמת (scripts/normalize.py), החלטות המשתמש.
"""
import re
import unicodedata

_DIRECTIONAL = "\u200e\u200f\u061c\u202a\u202b\u202c\u202d\u202e"
_QUOTES = {"״": '"', "׳": "'", "“": '"', "”": '"', "‘": "'", "’": "'"}
_DASHES = "‐‑‒–—־"
_WHITESPACE = re.compile(r"[\s\u00a0\u2000-\u200a\u202f\u205f\u3000]+")


def title_key(title):
    """מפתח ההשוואה של כותרת. None נשאר None (כמו strict ב-SQL)."""
    if title is None:
        return None
    value = unicodedata.normalize("NFC", title)
    for ch in _DIRECTIONAL:
        value = value.replace(ch, "")
    for src, dst in _QUOTES.items():
        value = value.replace(src, dst)
    for ch in _DASHES:
        value = value.replace(ch, "-")
    value = value.replace("\u00a0", " ")
    return _WHITESPACE.sub(" ", value).strip(" ")


_FINAL_LETTERS = {"כ": "ך", "מ": "ם", "נ": "ן", "פ": "ף", "צ": "ץ"}


def _rule_quoted_kadosh(t):
    new = re.sub(r'(["\'])(קדוש(?:ה|ים)?)\1', r"\2", t)
    return new, "מירכאות_קדוש"


def _rule_elil_to_el(t):
    return re.sub(r"(?<![א-ת])אליל([א-ת]*)", r"אל\1", t), "אליל_לאל"


def _rule_elohim_spelling(t):
    def repl(m):
        return "אלוה" + (m.group(1) or "")

    suffixes = r"(ים|י|ינו|יכם|יכן|יו|יה)?"
    new = re.sub(r"(?<![א-ת])אלוק" + suffixes + r"(?![א-ת])", repl, t)
    new = re.sub(r"(?<![א-ת])אלק" + suffixes + r"(?![א-ת])", repl, new)
    return new, "כתיב_אלוהים"


def _rule_break_hyphen(t):
    return t.replace("א-ל", "אל").replace("י-ה", "יה"), "מקף_שובר"


def _rule_hebrew_year_final_letter(t):
    def repl(m):
        return m.group(1) + _FINAL_LETTERS.get(m.group(2), m.group(2))

    return re.sub(r"([א-ה]'[א-ת]+\")([כמנפצ])(?![א-ת])", repl, t), "אות_סופית_שנה"


def _rule_biblical_figure(t):
    return t.replace('(אישיות מהתנ"ך)', "(דמות מקראית)"), "דמות_מקראית"


def _rule_yeshu(t):
    return t.replace("אותו האיש", "ישו"), "ישו"


def _rule_center_to_synagogue(t):
    return re.sub(r"מרכז ה(נאולוגי|רפורמי|קראי|קונסרבטיבי)", r"בית הכנסת ה\1", t), "מרכז_לבית_כנסת"


def _rule_korban(t):
    return re.sub(r"(?<![א-ת])קרבן", "קורבן", t), "קרבן_לקורבן"


SEMANTIC_RULES = [
    _rule_quoted_kadosh, _rule_elil_to_el, _rule_elohim_spelling, _rule_break_hyphen,
    _rule_hebrew_year_final_letter, _rule_biblical_figure, _rule_yeshu, _rule_center_to_synagogue, _rule_korban,
]


def semantic_candidate(title):
    """(כותרת אחרי הכללים הסמנטיים, [שמות הכללים שהופעלו]). הכותרת השמורה לעולם לא משתנה."""
    value = title_key(title)
    applied = []
    for rule in SEMANTIC_RULES:
        new, name = rule(value)
        if new != value:
            applied.append(name)
        value = new
    return value, applied


def mech_key_row(mech_id, title):
    """שורה ל-derived.mech_key, או None כשהכללים לא שינו את הכותרת (קישור רגיל אינו נשמר)."""
    candidate, rules = semantic_candidate(title)
    if candidate == title_key(title):
        return None
    return {"mech_id": mech_id, "wiki_candidate_key": title_key(candidate), "rules": rules}
