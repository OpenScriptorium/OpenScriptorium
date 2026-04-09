#!/usr/bin/env python3
"""
Extract footnotes from the Jewish Publication Society 1917 Tanakh PDF
using pdfplumber's char-level positioning.

## Why position-aware extraction

The 1917 PDF renders body text at 11pt and footnote markers as
7pt superscripts (verse numbers AND footnote letter markers are both
7pt). Footnote bodies at the bottom of each column are typeset in 8pt.

By looking at character font sizes and positions we can identify:
  - body text (11pt)
  - footnote markers (7pt single letter, spatially isolated)
  - verse numbers (7pt digit run)
  - small caps (7pt letters in a contiguous run, e.g. LORD / GOD)
  - footnote bodies (8pt text in clusters at the bottom of columns)

For each footnote marker we can find:
  - The annotated word: the closest 11pt body word to the right of
    the marker on the same line
  - The note body: the 8pt cluster whose first letter matches the
    marker letter, in the same column
  - The verse: the most recent 7pt digit run that came before the
    marker in reading order

## Pipeline

1. Identify book/chapter context from page headers (text-based, since
   the headers are large 11pt text and easy to recognize)
2. For each page, extract chars and partition by font size
3. Build the body word stream in reading order, with positions
4. Build the footnote-body stream (8pt clusters), keyed by their
   leading marker letter
5. Find inline markers (7pt isolated letters), pair each with its
   anchor (closest body word) and its footnote body (matching letter)
6. Determine the verse via the preceding verse-number run
7. Cross-validate with Sefaria to confirm the verse and emit the note
"""

import json
import re
import sys
from pathlib import Path

PDF_PATH    = Path("tmp/jps/Tanakh1917.pdf")
SEFARIA_DIR = Path("tmp/jps/sefaria")
OUTPUT      = Path("tmp/jps/notes.json")
LOG         = Path("tmp/jps/notes_extraction.log")

# Font sizes (rounded to 1 decimal) used in the JPS 1917 PDF.
BODY_SIZE     = 11.0
SUPER_SIZE    =  7.0   # superscripts: footnote markers AND verse numbers
FOOTNOTE_SIZE =  8.0   # footnote body text

# Maps PDF book header text → our canonical slug.
BOOK_HEADERS = {
    "GENESIS":           "genesis",
    "EXODUS":            "exodus",
    "LEVITICUS":         "leviticus",
    "NUMBERS":           "numbers",
    "DEUTERONOMY":       "deuteronomy",
    "JOSHUA":            "joshua",
    "JUDGES":            "judges",
    "FIRST SAMUEL":      "1-samuel",
    "SECOND SAMUEL":     "2-samuel",
    "FIRST KINGS":       "1-kings",
    "SECOND KINGS":      "2-kings",
    "ISAIAH":            "isaiah",
    "JEREMIAH":          "jeremiah",
    "EZEKIEL":           "ezekiel",
    "HOSEA":             "hosea",
    "JOEL":              "joel",
    "AMOS":              "amos",
    "OBADIAH":           "obadiah",
    "JONAH":             "jonah",
    "MICAH":             "micah",
    "NAHUM":             "nahum",
    "HABAKKUK":          "habakkuk",
    "ZEPHANIAH":         "zephaniah",
    "HAGGAI":            "haggai",
    "ZECHARIAH":         "zechariah",
    "MALACHI":           "malachi",
    "PSALMS":            "psalms",
    "PROVERBS":          "proverbs",
    "JOB":               "job",
    "SONG OF SONGS":     "song-of-solomon",
    "RUTH":              "ruth",
    "LAMENTATIONS":      "lamentations",
    "ECCLESIASTES":      "ecclesiastes",
    "ESTHER":            "esther",
    "DANIEL":            "daniel",
    "EZRA":              "ezra",
    "NEHEMIAH":          "nehemiah",
    "FIRST CHRONICLES":  "1-chronicles",
    "SECOND CHRONICLES": "2-chronicles",
}

SLUG_TO_FILE = {
    "genesis": "Genesis", "exodus": "Exodus", "leviticus": "Leviticus",
    "numbers": "Numbers", "deuteronomy": "Deuteronomy",
    "joshua": "Joshua", "judges": "Judges",
    "1-samuel": "I_Samuel", "2-samuel": "II_Samuel",
    "1-kings": "I_Kings", "2-kings": "II_Kings",
    "isaiah": "Isaiah", "jeremiah": "Jeremiah", "ezekiel": "Ezekiel",
    "hosea": "Hosea", "joel": "Joel", "amos": "Amos",
    "obadiah": "Obadiah", "jonah": "Jonah", "micah": "Micah",
    "nahum": "Nahum", "habakkuk": "Habakkuk", "zephaniah": "Zephaniah",
    "haggai": "Haggai", "zechariah": "Zechariah", "malachi": "Malachi",
    "psalms": "Psalms", "proverbs": "Proverbs", "job": "Job",
    "song-of-solomon": "Song_of_Songs", "ruth": "Ruth",
    "lamentations": "Lamentations", "ecclesiastes": "Ecclesiastes",
    "esther": "Esther", "daniel": "Daniel", "ezra": "Ezra",
    "nehemiah": "Nehemiah",
    "1-chronicles": "I_Chronicles", "2-chronicles": "II_Chronicles",
}


def normalize(s):
    s = re.sub(r"[^A-Za-z0-9]+", " ", s.lower())
    return re.sub(r"\s+", " ", s).strip()


# ---------------------------------------------------------------------------
# Sefaria index for verse lookup
# ---------------------------------------------------------------------------

class SefariaIndex:
    def __init__(self):
        self.books = {}

    def load(self, slug):
        if slug in self.books:
            return self.books[slug]
        fname = SLUG_TO_FILE.get(slug)
        if not fname:
            return None
        path = SEFARIA_DIR / f"{fname}.json"
        if not path.exists():
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        verses = []
        for ch_idx, chapter_verses in enumerate(data["text"]):
            for v_idx, verse_text in enumerate(chapter_verses):
                clean = re.sub(r"<[^>]+>", "", verse_text)
                verses.append((ch_idx + 1, v_idx + 1, normalize(clean)))
        self.books[slug] = verses
        return verses

    def find_containing(self, slug, anchor, context=None):
        """Find a verse that contains `anchor` (and optionally `context`)."""
        verses = self.load(slug)
        if not verses:
            return None
        a = normalize(anchor)
        if not a or len(a) < 3:
            return None
        c = normalize(context) if context else None

        # Prefer verses that contain BOTH the anchor and a context fragment
        if c:
            ctx_fragments = c.split()
            for length in (8, 6, 4):
                if len(ctx_fragments) < length:
                    continue
                for start in range(len(ctx_fragments) - length + 1):
                    phrase = " ".join(ctx_fragments[start:start + length])
                    for ch, v, text in verses:
                        if a in text and phrase in text:
                            return (ch, v)
        # Fall back to any verse containing the anchor
        for ch, v, text in verses:
            if a in text:
                return (ch, v)
        return None


# ---------------------------------------------------------------------------
# pdfplumber-based page parser
# ---------------------------------------------------------------------------

def round_pos(c):
    return (round(c["size"], 1), round(c["x0"], 1), round(c["y0"], 1))


def group_chars_into_words(chars, x_gap=2.0, y_tol=2.0):
    """
    Group a list of chars (same font size) into words by spatial
    proximity. Spaces are filtered out FIRST so they break the run.
    Each output dict represents a single word with its bounding box.
    """
    chars = [c for c in chars if c["text"].strip()]
    if not chars:
        return []
    chars = sorted(chars, key=lambda c: (-c["y0"], c["x0"]))
    words = []
    cur = [chars[0]]
    for c in chars[1:]:
        prev = cur[-1]
        # Require sequential left-to-right placement: the next char's
        # x0 must be at most x_gap to the right of prev's x1, AND not
        # significantly to the LEFT of it (negative gaps indicate the
        # next char is in a different column or row entirely).
        x_delta = c["x0"] - prev["x1"]
        if (
            abs(c["y0"] - prev["y0"]) <= y_tol
            and -2.0 <= x_delta <= x_gap
        ):
            cur.append(c)
        else:
            words.append(cur)
            cur = [c]
    words.append(cur)
    return [
        {
            "text": "".join(c["text"] for c in w),
            "x0":   min(c["x0"] for c in w),
            "x1":   max(c["x1"] for c in w),
            "y0":   sum(c["y0"] for c in w) / len(w),
            "size": w[0]["size"],
        }
        for w in words
    ]


def group_chars_into_lines_with_text(chars, y_tol=2.0):
    """
    Group chars (any font size) into lines and return each line's
    full text (with spaces preserved) plus its bounding box. This is
    what we want for footnote bodies — the whole line as one string.
    """
    if not chars:
        return []
    chars_sorted = sorted(chars, key=lambda c: (-c["y0"], c["x0"]))
    lines = []
    cur = [chars_sorted[0]]
    for c in chars_sorted[1:]:
        if abs(c["y0"] - cur[-1]["y0"]) <= y_tol:
            cur.append(c)
        else:
            lines.append(cur)
            cur = [c]
    lines.append(cur)
    return [
        {
            "text": "".join(c["text"] for c in sorted(l, key=lambda c: c["x0"])),
            "x0":   min(c["x0"] for c in l),
            "x1":   max(c["x1"] for c in l),
            "y0":   sum(c["y0"] for c in l) / len(l),
        }
        for l in lines
    ]


def cluster_lines(words, y_tol=2.0):
    """Group words into lines by y0."""
    if not words:
        return []
    words = sorted(words, key=lambda w: (-w["y0"], w["x0"]))
    lines = []
    cur = [words[0]]
    for w in words[1:]:
        if abs(w["y0"] - cur[-1]["y0"]) <= y_tol:
            cur.append(w)
        else:
            lines.append(sorted(cur, key=lambda x: x["x0"]))
            cur = [w]
    lines.append(sorted(cur, key=lambda x: x["x0"]))
    return lines


def markers_7pt(super_words):
    """Single 7pt lowercase letter tokens — these are footnote markers
    (both inline and footnote-body forms)."""
    return [
        w for w in super_words
        if len(w["text"]) == 1 and w["text"].isalpha() and w["text"].islower()
    ]


def read_footnote_body_8pt(foot_lines, body_marker, line_tol_y=10):
    """8pt body text fallback. Find an 8pt line at y0 ≈ marker.y0 - 6
    and return its text."""
    line_y0_max = body_marker["y0"]
    line_y0_min = body_marker["y0"] - line_tol_y
    for ln in foot_lines:
        if line_y0_min < ln["y0"] < line_y0_max:
            text = ln["text"].strip()
            if text:
                return text
    return None


def read_footnote_body(body_words, body_marker, all_markers,
                        line_tol_y=10, x_tol=12):
    """Read the (possibly multi-line) footnote body following a body
    marker.

    The body starts on the line at y0 ≈ marker.y0 - 6 just to the
    right of marker.x0. It may continue on the line below it in the
    same column. We stop the continuation as soon as we encounter
    another marker letter in the same column at a lower y0 — that's
    the next footnote starting.

    Two-column page heuristic: column 1 is x0 in [30, 220], column 2
    in [220, 410].
    """
    marker_col_right = body_marker["x0"] >= 220
    col_x0_min, col_x0_max = (220, 415) if marker_col_right else (30, 220)

    # First line: starts to the right of the marker
    line_y0_max = body_marker["y0"]
    line_y0_min = body_marker["y0"] - line_tol_y
    first_line = [
        w for w in body_words
        if line_y0_min < w["y0"] < line_y0_max
        and w["x0"] >= body_marker["x0"] - x_tol
        and col_x0_min <= w["x0"] < col_x0_max
    ]
    if not first_line:
        return None
    first_line.sort(key=lambda w: w["x0"])
    first_line_y0 = first_line[0]["y0"]
    parts = [w["text"] for w in first_line]

    # Find the next marker (any letter) that's BELOW this body marker
    # in the same column — that's where the next footnote starts and
    # where we should stop reading body continuation.
    next_marker_y0 = None
    for m in all_markers:
        if m["y0"] >= body_marker["y0"]:
            continue
        if not (col_x0_min <= m["x0"] < col_x0_max):
            continue
        if next_marker_y0 is None or m["y0"] > next_marker_y0:
            next_marker_y0 = m["y0"]

    # Continuation lines: lower y0 than first line, but ABOVE the next
    # marker (so we don't bleed into the next footnote). At most 2
    # continuation lines — JPS notes are short.
    next_y_max = first_line_y0
    for _ in range(2):
        candidate_y_min = next_marker_y0 + 1 if next_marker_y0 is not None else next_y_max - 16
        candidate_y_max = next_y_max - 1
        if candidate_y_max <= candidate_y_min:
            break
        cont_words = [
            w for w in body_words
            if candidate_y_min < w["y0"] < candidate_y_max
            and col_x0_min <= w["x0"] < col_x0_max
        ]
        if not cont_words:
            break
        # Group by line — take the topmost (closest to next_y_max)
        ys = sorted({round(w["y0"], 1) for w in cont_words}, reverse=True)
        next_line_y = ys[0]
        line_words = [w for w in cont_words if abs(w["y0"] - next_line_y) < 1]
        line_words.sort(key=lambda w: w["x0"])
        parts.extend(w["text"] for w in line_words)
        next_y_max = next_line_y

    body_text = " ".join(parts).strip()
    # Strip trailing page numbers. JPS body lines run right up to the
    # column edge so the page-number digit at the bottom of the
    # column gets pulled into the body. Detect: a number at the end
    # of the body that's PRECEDED by a sentence-final period (so it
    # isn't part of a real cross-reference like "see verse 20").
    body_text = re.sub(r"(\.)\s+\d+\s*$", r"\1", body_text)
    return body_text


def detect_book_from_header(chars):
    """Find a book header in the page chars. Book headers are typeset
    at larger sizes (20-28pt) than the 11pt body — but the cleanest
    detection is to just scan all chars in the top portion of the page
    for any of the known book header strings."""
    if not chars:
        return None
    # Sort top-down (high y0) and stop after we leave the header band
    top_chars = sorted(chars, key=lambda c: (-c["y0"], c["x0"]))[:200]
    # Concatenate all text in reading order (header chars usually
    # appear consecutively because they're at the top)
    text = "".join(c["text"] for c in top_chars).upper()
    # Match longest headers first so "FIRST SAMUEL" wins over a
    # spurious "SAMUEL" substring elsewhere
    for header in sorted(BOOK_HEADERS.keys(), key=len, reverse=True):
        if header in text:
            return BOOK_HEADERS[header]
    return None


def parse_page(page, sefaria_index, state, log, page_idx=None):
    chars = page.chars
    if not chars:
        return []

    body_chars = [c for c in chars if abs(c["size"] - BODY_SIZE) < 0.3]
    super_chars = [c for c in chars if abs(c["size"] - SUPER_SIZE) < 0.3]
    foot_chars = [c for c in chars if abs(c["size"] - FOOTNOTE_SIZE) < 0.3]

    body_words = group_chars_into_words(body_chars)
    super_words = group_chars_into_words(super_chars)
    # Some pages typeset footnote bodies at 8pt instead of 11pt
    # (Job 1 is the canonical example). 8pt body lines are clustered
    # by line so spaces stay in the text — we look up the body text
    # there in addition to the 11pt body words.
    foot_lines_8pt = group_chars_into_lines_with_text(foot_chars)

    book = detect_book_from_header(chars)
    if book:
        state["book"] = book
    if not state.get("book"):
        return []

    # Footnote markers: 7pt single lowercase letter tokens.
    markers = markers_7pt(super_words)
    verse_nums = [w for w in super_words if w["text"].isdigit()]

    # Classify each marker as either a "body marker" (sits at the
    # bottom of a column with note text just to its right) or an
    # "inline marker" (sits in the middle of verse text). We then
    # pair them by letter — for each body marker, find an inline
    # marker with the same letter on this page; if no match, look
    # in `state["pending_markers"]` from previous pages (cross-page
    # footnotes).
    #
    # 8pt body text is unambiguous (only footnotes use 8pt). For 11pt
    # we ALSO require the body text to start with a recognizable note
    # prefix ("Heb.", "That is,", "Or", etc.) to avoid claiming a
    # verse-continuation line as a footnote body.
    classified = []  # list of (marker, kind, body_text_or_None)
    for m in markers:
        body_8pt = read_footnote_body_8pt(foot_lines_8pt, m)
        if body_8pt:
            classified.append((m, "body", body_8pt))
            continue
        body_11pt = read_footnote_body(body_words, m, markers)
        if body_11pt and NOTE_BODY_PREFIX_RE.match(body_11pt):
            classified.append((m, "body", body_11pt))
        else:
            classified.append((m, "inline", None))

    body_entries   = [(m, b) for (m, k, b) in classified if k == "body"]
    inline_entries = [m for (m, k, _) in classified if k == "inline"]

    # Cross-page state: any unpaired markers from previous pages.
    # Entries expire after 1 page — cross-page footnotes only ever
    # span adjacent pages (the inline marker on page N pairs with a
    # body on page N-1 or N+1). Stale entries from further back
    # produce false matches in dense books like 1 Chronicles.
    pending = state.setdefault("pending_markers", [])
    pending[:] = [p for p in pending if (page_idx or 0) - p["page"] <= 1]

    notes = []
    used_inline_ids = set()

    # Pair each body marker with an inline marker.
    for body_marker, body_text in body_entries:
        letter = body_marker["text"]

        # Try to pair on the SAME page first. The inline marker must
        # have the same letter and be HIGHER on the page (larger y0)
        # than the body marker.
        same_page_candidates = [
            m for m in inline_entries
            if m["text"] == letter
            and m["y0"] > body_marker["y0"]
            and id(m) not in used_inline_ids
        ]
        if same_page_candidates:
            inline_marker = min(same_page_candidates,
                                key=lambda m: m["y0"] - body_marker["y0"])
            used_inline_ids.add(id(inline_marker))
            note = _emit_note(state, body_text, inline_marker, body_marker,
                              body_words, verse_nums, sefaria_index, log, page_idx)
            if note:
                notes.append(note)
            continue

        # Look in pending for a cross-page inline marker with the same letter.
        match_idx = next(
            (i for i, p in enumerate(pending)
             if p["letter"] == letter and p["kind"] == "inline"),
            None,
        )
        if match_idx is not None:
            p = pending.pop(match_idx)
            note = _emit_note(state, body_text, p["marker"], body_marker,
                              p["body_words"], p["verse_nums"],
                              sefaria_index, log, page_idx)
            if note:
                notes.append(note)
            continue

        # No partner found anywhere — store the body marker as pending
        # so a future page's inline marker can claim it.
        pending.append({
            "page":       page_idx,
            "letter":     letter,
            "kind":       "body",
            "marker":     body_marker,
            "body_text":  body_text,
            "body_words": body_words,
            "verse_nums": verse_nums,
        })

    # Inline markers that didn't get paired with a body on this page:
    # check pending for a cross-page body marker, otherwise add to pending.
    for m in inline_entries:
        if id(m) in used_inline_ids:
            continue
        letter = m["text"]
        match_idx = next(
            (i for i, p in enumerate(pending)
             if p["letter"] == letter and p["kind"] == "body"),
            None,
        )
        if match_idx is not None:
            p = pending.pop(match_idx)
            note = _emit_note(state, p["body_text"], m, p["marker"],
                              body_words, verse_nums,
                              sefaria_index, log, page_idx)
            if note:
                notes.append(note)
            continue
        pending.append({
            "page":       page_idx,
            "letter":     letter,
            "kind":       "inline",
            "marker":     m,
            "body_words": body_words,
            "verse_nums": verse_nums,
        })

    return notes


NOTE_BODY_PREFIX_RE = re.compile(
    r"^(?:Heb\b|Gr\b|Chal\b|Or,|or,|Or\s|or\s|That is\b|That was\b|"
    r"Lit\.|Some\b|Cf\.|See\b|From\b|i\.e\.|I\.e\.|Acc\.)"
)


def _hint_prefix_from_body(body_text):
    """If the body text is 'Heb./Gr./Chal. X' where X is a
    transliterated proper noun, return the first 2 (or 1) letters
    of X (lowercase) to bias anchor selection toward the matching
    English word. The 2-letter prefix is more specific — 'Heb.
    Abshai' should look for words starting with 'Ab' (Abishai),
    not just any 'A' word like 'And'.

    NOT used for 'That is, X' notes — those give the MEANING of
    the annotated word, not its transliteration, so first-letter
    matching is wrong. For those we fall through to the proper-noun
    fallback in the caller."""
    m = re.match(r"^(?:Heb\.|Gr\.|Chal\.)\s+([A-Z][A-Za-z'\-]*)", body_text)
    if not m:
        return None
    word = m.group(1)
    return word[:2].lower() if len(word) >= 2 else word[0].lower()


def _is_proper_noun_word(text):
    """True if text looks like a capitalised proper noun (excluding
    sentence-start common words)."""
    s = text.lstrip("'\u2018\u2019([").rstrip(",.;:!?'\u2018\u2019)]").strip()
    if not s or len(s) < 2:
        return False
    if not s[0].isupper():
        return False
    # Avoid sentence-start common words that happen to be capitalised
    SENTENCE_START_COMMON = {
        "And", "But", "For", "Now", "Then", "So", "When", "If",
        "He", "She", "It", "They", "We", "You", "I",
        "The", "A", "An", "In", "On", "At", "Behold",
    }
    if s in SENTENCE_START_COMMON:
        return False
    return True


SKIP_ANCHOR_WORDS = {
    "the", "a", "an", "and", "of", "to", "in",
    "hath", "had", "is", "was", "be", "shall", "shalt",
    "thou", "ye", "for", "as", "or", "his", "her", "thy",
}


def _emit_note(state, body_text, inline_marker, body_marker,
               body_words, verse_nums, sefaria_index, log, page_idx):
    """Build a note record for a paired (inline, body) marker pair.
    Returns the note dict, or None if anchor lookup or Sefaria
    validation fails."""
    marker = inline_marker
    letter = inline_marker["text"]

    # Anchor: pick the word on the line just below the marker that
    # the marker is annotating. The marker is a 7pt superscript ~6pt
    # above the verse baseline. We use these heuristics in order:
    #
    #   1. If the body text looks like "Heb. X" or "That is, X" with
    #      X being a capitalised proper noun, prefer a same-line word
    #      whose first letter matches X's first letter (case-insensitive).
    #      This catches "Heb. Beraah" → annotates "Beriah" even when
    #      the marker isn't physically adjacent.
    #
    #   2. Otherwise, the leftmost word with x0 >= marker.x0 that
    #      isn't a function word ("the", "and", "hath", ...).
    #
    #   3. Otherwise, the leftmost function word with x0 >= marker.x0.
    #
    # All searches are restricted to the same COLUMN as the marker —
    # the PDF lays out two columns per page and a single y0 line
    # contains BOTH columns' text simultaneously, so without column
    # filtering we'd grab words from the other column.
    marker_col_right = marker["x0"] >= 220
    col_x0_min, col_x0_max = (220, 415) if marker_col_right else (30, 220)
    line_y0_min = marker["y0"] - 10
    line_y0_max = marker["y0"]
    same_line_words = [
        w for w in body_words
        if line_y0_min < w["y0"] < line_y0_max
        and col_x0_min <= w["x0"] < col_x0_max
    ]
    same_line_words.sort(key=lambda w: w["x0"])

    anchor_word = None

    # Heuristic 1: "Heb. X" → look for a CAPITALIZED same-line word
    # starting with the same prefix as X (the transliteration's
    # English cognate). Capitalisation is required so we don't match
    # function words like "she" for "Heb. Shimeon". Try the 2-letter
    # prefix first (more specific) then fall back to 1-letter.
    target_prefix = _hint_prefix_from_body(body_text)
    if target_prefix:
        for plen in (2, 1):
            tp = target_prefix[:plen]
            for w in same_line_words:
                first = w["text"].lstrip("'\u2018\u2019([").rstrip(",.;:!?'\u2018\u2019)]").strip()
                if not first or len(first) < plen:
                    continue
                if not first[0].isupper():
                    continue
                if first[:plen].lower() == tp:
                    anchor_word = w
                    break
            if anchor_word is not None:
                break

    # Heuristic 2: "That is, X" → look for the only proper-noun word
    # on the line (the annotated name being explained)
    if anchor_word is None and body_text.startswith("That is"):
        proper_nouns = [w for w in same_line_words if _is_proper_noun_word(w["text"])]
        if len(proper_nouns) == 1:
            anchor_word = proper_nouns[0]
        elif len(proper_nouns) > 1:
            # Pick the one closest to the marker
            anchor_word = min(proper_nouns, key=lambda w: abs(w["x0"] - marker["x0"]))

    # Heuristic 3: leftmost word with x0 >= marker.x0 that isn't a
    # function word. If no non-function-word is found on the same
    # line, look at the line BELOW (the marker may be at end of a
    # column line and the annotated word wraps to the next line).
    if anchor_word is None:
        right_of = [w for w in same_line_words if w["x0"] >= marker["x0"] - 2]
        for w in right_of:
            cleaned = w["text"].rstrip(",.;:!?'\u2018\u2019").lower()
            if cleaned not in SKIP_ANCHOR_WORDS:
                anchor_word = w
                break

    if anchor_word is None:
        # Try the next line down, in the same column. Round y0 to 1
        # decimal so floating-point jitter doesn't break the
        # left-to-right sort order on the same visual line.
        next_line = [
            w for w in body_words
            if marker["y0"] - 25 < w["y0"] <= line_y0_min
            and (w["x0"] >= 220) == (marker["x0"] >= 220)
        ]
        next_line.sort(key=lambda w: (-round(w["y0"], 1), w["x0"]))
        for w in next_line:
            cleaned = w["text"].rstrip(",.;:!?'\u2018\u2019").lower()
            if cleaned not in SKIP_ANCHOR_WORDS:
                anchor_word = w
                break

    # Last-resort fallback: take the first same-line word with x0
    # >= marker.x0, even if it's a function word
    if anchor_word is None:
        right_of = [w for w in same_line_words if w["x0"] >= marker["x0"] - 2]
        if right_of:
            anchor_word = right_of[0]

    if not anchor_word:
        print(f"  p{page_idx} {state['book']}: no anchor word for marker '{letter}'", file=log)
        return None

    anchor = anchor_word["text"]
    # Strip surrounding punctuation: brackets, em-dashes, quotes, etc.
    anchor = anchor.lstrip("'\u2018\u2019([{")
    anchor = anchor.rstrip(",.;:!?'\u2018\u2019)]}—–-")

    # Find the most recent verse number on the page that's BEFORE
    # the inline marker in reading order (within the same column).
    # A verse number "marks" the verse it starts. Verse numbers above
    # the marker (higher y0) AND verse numbers ON THE SAME LINE but
    # to the LEFT of the marker count. Verse numbers on the same
    # line but to the RIGHT mark the NEXT verse (which the marker
    # is BEFORE), so they don't count.
    prior_nums = [
        v for v in verse_nums
        if col_x0_min <= v["x0"] < col_x0_max
        and (
            v["y0"] > marker["y0"] + 1
            or (abs(v["y0"] - marker["y0"]) <= 1 and v["x0"] < marker["x0"])
        )
    ]
    # Among those, the closest one above (smallest y0 distance,
    # ties broken by largest x0 — closest in reading order)
    prior_nums.sort(key=lambda v: (v["y0"] - marker["y0"], -v["x0"]))
    pdf_verse = None
    for v in prior_nums:
        try:
            pdf_verse = int(v["text"])
            break
        except ValueError:
            continue

    # Build context from body words on the SAME line as the marker
    # plus the lines just before and after, in the same column.
    # This gives us a meaningful chunk of verse text to match
    # against Sefaria — without it, generic anchors like "God" or
    # "and" land on the wrong verse because the same word appears
    # in many places.
    line_words = [
        w for w in body_words
        if abs(w["y0"] - (marker["y0"] - 6)) < 4
        and col_x0_min <= w["x0"] < col_x0_max
    ]
    line_words.sort(key=lambda w: w["x0"])
    line_text = " ".join(w["text"] for w in line_words)

    # Also pull a few words from the surrounding lines for fallback
    surrounding = [
        w for w in body_words
        if marker["y0"] - 30 < w["y0"] < marker["y0"] + 5
        and col_x0_min <= w["x0"] < col_x0_max
    ]
    surrounding.sort(key=lambda w: (-w["y0"], w["x0"]))
    context = " ".join(w["text"] for w in surrounding[:25])
    context = re.sub(r"\b\d{1,3}\b", " ", context)

    # Try the full-line text first (most specific), then fall back
    # to the surrounding context phrase
    loc = sefaria_index.find_containing(state["book"], anchor, line_text)
    if not loc:
        loc = sefaria_index.find_containing(state["book"], anchor, context)
    if not loc:
        print(f"  p{page_idx} {state['book']}: '{letter}' anchor={anchor!r} note={body_text[:60]!r} — no Sefaria match", file=log)
        return None

    chapter, verse = loc
    # If the PDF verse number agrees with Sefaria's verse, great.
    # If they DISAGREE (pdf says 5, sefaria says 13), the inline
    # marker is more likely on the verse the PDF reports — Sefaria
    # may have matched the wrong place because the anchor word is
    # too generic. Keep the chapter from Sefaria but use the PDF
    # verse number when they conflict.
    if pdf_verse is not None and pdf_verse != verse:
        verses = sefaria_index.load(state["book"]) or []
        if any(ch == chapter and v == pdf_verse for ch, v, _ in verses):
            verse = pdf_verse
        else:
            # The PDF verse doesn't exist in the Sefaria chapter Sefaria
            # picked. Sefaria matched the wrong chapter. Find a chapter
            # where the PDF verse number exists AND the line context
            # matches more closely.
            best_chapter = None
            best_score = 0
            line_words_set = set(normalize(line_text).split())
            for ch, v, text in verses:
                if v != pdf_verse:
                    continue
                text_words = set(text.split())
                score = len(line_words_set & text_words)
                if score > best_score:
                    best_score = score
                    best_chapter = ch
            if best_chapter and best_score >= 3:
                chapter = best_chapter
                verse = pdf_verse

    return {
        "book":      state["book"],
        "chapter":   chapter,
        "verse":     verse,
        "anchor":    anchor,
        "note":      body_text.strip(),
        "note_type": classify_note(body_text),
    }


def classify_note(body):
    if not body:
        return "explanation"
    if re.match(r"^(Heb|Gr|Chal)\.", body):
        return "translation"
    if re.match(r"^(Or,|or,|Or\s|or\s)", body):
        return "textual"
    if re.match(r"^Lit\.", body):
        return "translation"
    if re.match(r"^Some\b", body):
        return "textual"
    if re.match(r"^(Cf\.|See\b)", body):
        return "cross_reference"
    if re.match(r"^That is", body):
        return "explanation"
    if re.match(r"^From\b", body):
        return "explanation"
    return "explanation"


def main():
    import pdfplumber

    sefaria_index = SefariaIndex()
    all_notes = []
    state = {"book": None}

    # Skip front-matter pages (table of contents, preface). Book
    # detection still happens via page headers, but no Bible content
    # is in pages before ~30.
    SKIP_PAGES_BEFORE = 30

    print(f"Opening {PDF_PATH}…", file=sys.stderr)
    with LOG.open("w", encoding="utf-8") as log:
        with pdfplumber.open(PDF_PATH) as pdf:
            for page_idx, page in enumerate(pdf.pages):
                if page_idx < SKIP_PAGES_BEFORE:
                    continue
                try:
                    notes = parse_page(page, sefaria_index, state, log, page_idx=page_idx)
                    all_notes.extend(notes)
                finally:
                    # Critical: flush pdfplumber's per-page char cache
                    # so memory doesn't grow unbounded across 1370 pages.
                    page.flush_cache()
                    page.get_textmap.cache_clear()
                if page_idx % 100 == 0 and page_idx > 0:
                    print(f"  page {page_idx}: {len(all_notes)} notes so far", file=sys.stderr)

    OUTPUT.write_text(json.dumps(all_notes, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nWrote {len(all_notes)} notes to {OUTPUT}", file=sys.stderr)

    by_book = {}
    by_type = {}
    for n in all_notes:
        by_book[n["book"]] = by_book.get(n["book"], 0) + 1
        by_type[n["note_type"]] = by_type.get(n["note_type"], 0) + 1
    print("\nNotes by book:", file=sys.stderr)
    for b in sorted(by_book):
        print(f"  {b:25s} {by_book[b]:5d}", file=sys.stderr)
    print("\nNotes by type:", file=sys.stderr)
    for t, c in sorted(by_type.items()):
        print(f"  {t:15s} {c}", file=sys.stderr)


if __name__ == "__main__":
    main()
