#!/usr/bin/env python3
"""
Extract critical apparatus from the Nestle 1904 Greek New Testament PDF.

The Nestle 1904 BFBS edition (pages 1-676 of the PDF) has:
  - Main Greek text in the body of each page
  - Verse references in the margin (e.g. "1,1" for chapter 1, verse 1)
  - Apparatus criticus at the bottom of each page in smaller type
  - Each apparatus entry: verse ref, lemma (main-text reading), then
    variant reading(s) with manuscript sigla

Sigla conventions:
  ℵ = Sinaiticus, B = Vaticanus, A = Alexandrinus, C = Ephraemi,
  D = Bezae (Gospels/Acts) / Claromontanus (Paul),
  Tisch. = Tischendorf, WH = Westcott-Hort, Weiss = Weiss

This script uses pdfplumber char-level extraction with font-size-based
zone classification (same approach as extract_jps1917_notes.py).

Run after the PDF download completes:
  python3 script/extract_nestle_apparatus.py

Requires: pdfplumber (pip install pdfplumber)
"""

import json
import logging
import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PDF_PATH = Path("tmp/nestle_apparatus/nestle1904.pdf")
ALT_PDF_PATH = Path("tmp/nestle_apparatus/nestle1904_text.pdf")
OUTPUT = Path("tmp/nestle_apparatus/apparatus.json")
LOG_FILE = Path("tmp/nestle_apparatus/extraction.log")

# Page range for the BFBS edition (0-indexed for pdfplumber)
FIRST_PAGE = 0    # page 1 of PDF
LAST_PAGE = 675   # page 676 of PDF

# For proof-of-concept: just do a few pages around where Matthew starts.
# Set to None to process all pages.
PROOF_OF_CONCEPT_PAGES = list(range(9, 20))  # pages 10-20 (0-indexed)

# Minimum file size to consider download complete (100 MB)
MIN_FILE_SIZE = 100 * 1024 * 1024

# ---------------------------------------------------------------------------
# NT book order for tracking context
# ---------------------------------------------------------------------------

NT_BOOKS_GREEK = {
    "ΚΑΤΑ ΜΑΘΘΑΙΟΝ":          "Matt",
    "ΚΑΤΑ ΜΑΡΚΟΝ":            "Mark",
    "ΚΑΤΑ ΛΟΥΚΑΝ":            "Luke",
    "ΚΑΤΑ ΙΩΑΝΝΗΝ":           "John",
    "ΠΡΑΞΕΙΣ ΑΠΟΣΤΟΛΩΝ":      "Acts",
    "ΠΡΑΞΕΙΣ":                "Acts",
    "ΠΡΟΣ ΡΩΜΑΙΟΥΣ":         "Rom",
    "ΠΡΟΣ ΚΟΡΙΝΘΙΟΥΣ Α":     "1Cor",
    "ΠΡΟΣ ΚΟΡΙΝΘΙΟΥΣ Β":     "2Cor",
    "ΠΡΟΣ ΓΑΛΑΤΑΣ":           "Gal",
    "ΠΡΟΣ ΕΦΕΣΙΟΥΣ":         "Eph",
    "ΠΡΟΣ ΦΙΛΙΠΠΗΣΙΟΥΣ":     "Phil",
    "ΠΡΟΣ ΚΟΛΟΣΣΑΕΙΣ":       "Col",
    "ΠΡΟΣ ΘΕΣΣΑΛΟΝΙΚΕΙΣ Α":  "1Thess",
    "ΠΡΟΣ ΘΕΣΣΑΛΟΝΙΚΕΙΣ Β":  "2Thess",
    "ΠΡΟΣ ΤΙΜΟΘΕΟΝ Α":       "1Tim",
    "ΠΡΟΣ ΤΙΜΟΘΕΟΝ Β":       "2Tim",
    "ΠΡΟΣ ΤΙΤΟΝ":             "Titus",
    "ΠΡΟΣ ΦΙΛΗΜΟΝΑ":          "Phlm",
    "ΠΡΟΣ ΕΒΡΑΙΟΥΣ":         "Heb",
    "ΙΑΚΩΒΟΥ":                "Jas",
    "ΠΕΤΡΟΥ Α":               "1Pet",
    "ΠΕΤΡΟΥ Β":               "2Pet",
    "ΙΩΑΝΝΟΥ Α":              "1John",
    "ΙΩΑΝΝΟΥ Β":              "2John",
    "ΙΩΑΝΝΟΥ Γ":              "3John",
    "ΙΟΥΔΑ":                  "Jude",
    "ΑΠΟΚΑΛΥΨΙΣ ΙΩΑΝΝΟΥ":    "Rev",
    "ΑΠΟΚΑΛΥΨΙΣ":             "Rev",
}

# Latin headers that may appear in some editions
NT_BOOKS_LATIN = {
    "EVANGELIUM SECUNDUM MATTHAEUM":  "Matt",
    "MATTHAEUS":                      "Matt",
    "MARCUS":                         "Mark",
    "LUCAS":                          "Luke",
    "IOANNES":                        "John",
    "ACTUS APOSTOLORUM":              "Acts",
}

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

def setup_logging():
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(LOG_FILE, mode="w", encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )
    return logging.getLogger("nestle_apparatus")


# ---------------------------------------------------------------------------
# Character / word grouping utilities
# (Adapted from extract_jps1917_notes.py)
# ---------------------------------------------------------------------------

def group_chars_into_words(chars, x_gap=3.0, y_tol=2.0):
    """
    Group a list of chars (same font-size bucket) into words by spatial
    proximity. Returns list of word dicts with text, bounding box, size.
    """
    chars = [c for c in chars if c["text"].strip()]
    if not chars:
        return []
    # Sort top-down then left-to-right
    chars = sorted(chars, key=lambda c: (-c["y0"], c["x0"]))
    words = []
    cur = [chars[0]]
    for c in chars[1:]:
        prev = cur[-1]
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
            "y1":   max(c.get("y1", c["y0"] + c["size"]) for c in w),
            "size": round(w[0]["size"], 1),
        }
        for w in words
    ]


def group_chars_into_lines(chars, y_tol=2.0):
    """
    Group chars into lines by y-position. Returns list of line dicts,
    each with full text and bounding box.
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
            "text": "".join(
                c["text"] for c in sorted(l, key=lambda c: c["x0"])
            ),
            "x0":   min(c["x0"] for c in l),
            "x1":   max(c["x1"] for c in l),
            "y0":   sum(c["y0"] for c in l) / len(l),
            "y1":   max(c.get("y1", c["y0"] + c["size"]) for c in l),
        }
        for l in lines
    ]


# ---------------------------------------------------------------------------
# Font-size survey: run on a few pages to discover the size distribution
# ---------------------------------------------------------------------------

def survey_font_sizes(pdf, pages, log):
    """
    Collect font-size frequencies across the given pages. This helps us
    calibrate which sizes correspond to main text vs apparatus.
    """
    size_counts = defaultdict(int)
    for page_idx in pages:
        page = pdf.pages[page_idx]
        for c in page.chars:
            size_counts[round(c["size"], 1)] += 1

    log.info("Font-size distribution across surveyed pages:")
    for size in sorted(size_counts.keys()):
        log.info(f"  {size:6.1f}pt : {size_counts[size]:>8d} chars")
    return size_counts


# ---------------------------------------------------------------------------
# Zone classification
# ---------------------------------------------------------------------------

def classify_zones(page, main_size, apparatus_size, y_tol=2.0):
    """
    Split page chars into zones based on font size:
      - main_chars: chars at the main text size
      - apparatus_chars: chars at the apparatus size
      - margin_chars: chars that are far left or far right of the text block
      - header_chars: chars in the top ~5% of the page (running headers)

    Returns a dict of char lists.
    """
    chars = page.chars
    if not chars:
        return {"main": [], "apparatus": [], "margin": [], "header": [],
                "all": []}

    page_height = page.height
    page_width = page.width
    header_cutoff = page_height * 0.06  # top 6%

    main_chars = []
    apparatus_chars = []
    header_chars = []
    other_chars = []

    for c in chars:
        sz = round(c["size"], 1)
        # Running header at top of page
        if c["top"] < header_cutoff:
            header_chars.append(c)
        elif abs(sz - main_size) < 0.6:
            main_chars.append(c)
        elif abs(sz - apparatus_size) < 0.6:
            apparatus_chars.append(c)
        else:
            other_chars.append(c)

    return {
        "main": main_chars,
        "apparatus": apparatus_chars,
        "header": header_chars,
        "other": other_chars,
        "all": chars,
    }


# ---------------------------------------------------------------------------
# Apparatus line parsing
# ---------------------------------------------------------------------------

# Verse reference pattern: e.g. "1,1" or "12,36" or just a verse number
VERSE_REF_RE = re.compile(
    r"^(\d{1,3})\s*[,\.]\s*(\d{1,3})$"
)

# Standalone verse number (continuation from same chapter)
VERSE_NUM_RE = re.compile(r"^(\d{1,3})$")

# Common manuscript sigla
SIGLA_PATTERN = re.compile(
    r"(?:ℵ[¹²³ᵃᵇᶜ]*|[ABCDELPW]\b|Tisch\.?|WH|Weiss|TR|"
    r"it[a-z]*|vg|syr[a-z]*|cop[a-z]*|arm|eth|geo|"
    r"\d{1,4}\b)"
)

# Bracket patterns used in apparatus: [] for WH, () for explanatory
BRACKET_RE = re.compile(r"[\[\](){}]")


def detect_book_from_header(header_chars, log):
    """
    Try to detect the NT book from running header text. Headers are at
    the top of the page and typically contain the book name in Greek
    (or sometimes Latin in early editions).
    """
    if not header_chars:
        return None
    text = "".join(
        c["text"] for c in sorted(header_chars, key=lambda c: c["x0"])
    ).strip()
    text_upper = text.upper()

    # Try Greek headers
    for header, abbrev in sorted(
        NT_BOOKS_GREEK.items(), key=lambda kv: len(kv[0]), reverse=True
    ):
        if header in text_upper:
            return abbrev

    # Try Latin headers
    for header, abbrev in sorted(
        NT_BOOKS_LATIN.items(), key=lambda kv: len(kv[0]), reverse=True
    ):
        if header in text_upper:
            return abbrev

    return None


def find_apparatus_boundary(page, main_size, apparatus_size):
    """
    Find the y-coordinate that separates main text from apparatus.
    The apparatus sits at the bottom; we look for the transition point
    where text size shifts from main to apparatus. Often there is a
    thin horizontal rule separating them.

    Returns the y-coordinate (in page coords, measured from top) above
    which is main text and below which is apparatus, or None if no
    apparatus is detected.
    """
    chars = page.chars
    if not chars:
        return None

    # Collect y-positions of apparatus-sized chars
    app_ys = [
        c["top"] for c in chars
        if abs(round(c["size"], 1) - apparatus_size) < 0.6
    ]
    if not app_ys:
        return None

    # The apparatus zone starts at roughly the minimum top of apparatus chars
    # (i.e. the highest apparatus char on the page, since top increases
    # downward in pdfplumber)
    return min(app_ys)


def parse_apparatus_text(text, current_chapter, log):
    """
    Parse a line (or block) of apparatus text into structured entries.

    Nestle apparatus entries typically look like:
      1,1 Ἰησοῦ Χριστοῦ] Χριστοῦ Ἰησοῦ ℵ B
      3 ὁ] om. D
      5 αὐτῶν] αὐτοῦ ℵ* B

    The ] (right square bracket) separates the lemma (main text reading)
    from the variant(s). Multiple entries may be separated by | or —
    or simply by the next verse reference.

    Returns a list of dicts:
      {
        "chapter": int,
        "verse": int,
        "lemma": str,
        "variants": [{"reading": str, "witnesses": [str]}]
      }
    """
    entries = []
    if not text.strip():
        return entries

    # Split on apparent entry boundaries: a new verse reference at the
    # start of a segment
    # First, try to split on verse references preceded by whitespace or
    # line start
    segments = re.split(r"(?:^|\s+)(?=\d{1,3}\s*[,\.]\s*\d{1,3}\b)", text)
    # Also handle continuation verses (just a number)
    if len(segments) <= 1:
        segments = re.split(r"(?:^|\s+)(?=\d{1,3}\b)", text)

    for segment in segments:
        segment = segment.strip()
        if not segment:
            continue

        entry = parse_single_entry(segment, current_chapter, log)
        if entry:
            entries.append(entry)

    return entries


def parse_single_entry(text, current_chapter, log):
    """
    Parse a single apparatus entry. Expected format:
      [chapter,]verse lemma] variant witness1 witness2 ...
    or:
      [chapter,]verse lemma] variant1 witness1; variant2 witness2
    """
    text = text.strip()
    if not text:
        return None

    chapter = current_chapter
    verse = None

    # Try to extract chapter,verse reference
    m = re.match(r"(\d{1,3})\s*[,\.]\s*(\d{1,3})\s+", text)
    if m:
        chapter = int(m.group(1))
        verse = int(m.group(2))
        text = text[m.end():]
    else:
        # Try standalone verse number
        m = re.match(r"(\d{1,3})\s+", text)
        if m:
            verse = int(m.group(1))
            text = text[m.end():]

    if verse is None:
        return None

    # Split on ] to separate lemma from variants
    bracket_pos = text.find("]")
    if bracket_pos == -1:
        # No bracket — might use other conventions. Log and skip.
        log.debug(
            f"  No ] bracket in entry ch{chapter}:{verse}: {text[:60]}..."
        )
        return {
            "chapter": chapter,
            "verse": verse,
            "lemma": text.strip(),
            "variants": [],
            "raw": text,
            "parse_status": "no_bracket",
        }

    lemma = text[:bracket_pos].strip()
    variant_text = text[bracket_pos + 1:].strip()

    # Parse variants: separated by ; or |
    variants = []
    if variant_text:
        variant_parts = re.split(r"\s*[;|]\s*", variant_text)
        for vp in variant_parts:
            vp = vp.strip()
            if not vp:
                continue
            # Try to separate reading from witnesses
            # Witnesses are typically at the end: capital letters, numbers,
            # or known abbreviations
            variant = parse_variant(vp)
            variants.append(variant)

    return {
        "chapter": chapter,
        "verse": verse,
        "lemma": lemma,
        "variants": variants,
        "raw": text[:bracket_pos + 1] + variant_text,
        "parse_status": "ok",
    }


def parse_variant(text):
    """
    Parse a variant reading + witnesses string.
    E.g. "Χριστοῦ Ἰησοῦ ℵ B" -> reading="Χριστοῦ Ἰησοῦ", witnesses=["ℵ","B"]
    E.g. "om. D" -> reading="om.", witnesses=["D"]
    """
    text = text.strip()

    # Find witness sigla at the end of the string
    # Work backwards: known sigla patterns
    witnesses = []
    remaining = text

    # Iteratively strip known sigla from the end
    changed = True
    while changed:
        changed = False
        remaining_stripped = remaining.rstrip()
        # Try known single-letter witnesses
        for sigil_re in [
            r"\s+(ℵ[¹²³ᵃᵇᶜ]*)$",
            r"\s+([ABCDELPWΔΘΨ][¹²³ᵃᵇᶜ]*)$",
            r"\s+(Tisch\.?)$",
            r"\s+(WH)$",
            r"\s+(Weiss)$",
            r"\s+(TR)$",
            r"\s+(\d{1,4})$",
            r"\s+(it[a-z]*)$",
            r"\s+(vg)$",
            r"\s+(syr[a-z]*)$",
            r"\s+(cop[a-z]*)$",
            r"\s+(arm)$",
            r"\s+(eth)$",
            r"\s+(geo)$",
        ]:
            m = re.search(sigil_re, remaining_stripped)
            if m:
                witnesses.insert(0, m.group(1))
                remaining = remaining_stripped[:m.start()]
                changed = True
                break

    reading = remaining.strip()
    return {
        "reading": reading if reading else text,
        "witnesses": witnesses,
    }


# ---------------------------------------------------------------------------
# Page processing
# ---------------------------------------------------------------------------

def process_page(page, page_idx, state, main_size, apparatus_size, log):
    """
    Process a single page: extract apparatus entries.

    state dict tracks:
      - book: current NT book abbreviation
      - chapter: current chapter number
    """
    zones = classify_zones(page, main_size, apparatus_size)

    # Detect book from running header
    book = detect_book_from_header(zones["header"], log)
    if book:
        if book != state.get("book"):
            log.info(f"  Page {page_idx + 1}: detected book = {book}")
            state["book"] = book
            state["chapter"] = 1

    if not state.get("book"):
        log.debug(f"  Page {page_idx + 1}: no book context yet, skipping")
        return []

    # Get apparatus lines
    apparatus_lines = group_chars_into_lines(zones["apparatus"])
    if not apparatus_lines:
        log.debug(f"  Page {page_idx + 1}: no apparatus text found")
        return []

    # Sort lines top-to-bottom (increasing y0 in page coords, but our
    # group_chars_into_lines sorts by -y0 so reverse)
    apparatus_lines.sort(key=lambda l: l["y0"], reverse=True)

    # Concatenate all apparatus text for this page
    full_apparatus_text = " ".join(l["text"] for l in apparatus_lines)

    log.info(
        f"  Page {page_idx + 1}: {len(apparatus_lines)} apparatus lines, "
        f"{len(full_apparatus_text)} chars"
    )
    log.debug(f"  Apparatus text: {full_apparatus_text[:200]}...")

    # Parse the apparatus text
    entries = parse_apparatus_text(
        full_apparatus_text, state.get("chapter", 1), log
    )

    # Update chapter tracking from the entries
    for entry in entries:
        if entry.get("chapter"):
            state["chapter"] = entry["chapter"]

    # Tag each entry with book and page
    for entry in entries:
        entry["book"] = state["book"]
        entry["page"] = page_idx + 1

    if entries:
        log.info(
            f"  Page {page_idx + 1}: parsed {len(entries)} apparatus entries"
        )

    return entries


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    log = setup_logging()
    log.info("Nestle 1904 apparatus extraction starting")

    # Find the PDF
    pdf_path = None
    for candidate in [PDF_PATH, ALT_PDF_PATH]:
        if candidate.exists():
            size = candidate.stat().st_size
            log.info(f"Found {candidate} ({size / 1024 / 1024:.1f} MB)")
            if size >= MIN_FILE_SIZE:
                pdf_path = candidate
                break
            else:
                log.warning(
                    f"  File exists but only {size / 1024 / 1024:.1f} MB "
                    f"(need >= {MIN_FILE_SIZE / 1024 / 1024:.0f} MB). "
                    f"Download may still be in progress."
                )

    if pdf_path is None:
        # Fall back to smaller file if it exists, with a warning
        for candidate in [ALT_PDF_PATH, PDF_PATH]:
            if candidate.exists():
                size = candidate.stat().st_size
                if size > 1024 * 1024:  # at least 1 MB
                    log.warning(
                        f"Using {candidate} ({size / 1024 / 1024:.1f} MB) — "
                        f"smaller than expected, may be incomplete or a "
                        f"text-only variant"
                    )
                    pdf_path = candidate
                    break

    if pdf_path is None:
        log.error(
            "No PDF found. Expected one of:\n"
            f"  {PDF_PATH}\n"
            f"  {ALT_PDF_PATH}\n"
            "Download the Nestle 1904 PDF first."
        )
        sys.exit(1)

    import pdfplumber
    log.info(f"Opening {pdf_path}...")
    pdf = pdfplumber.open(pdf_path)
    total_pages = len(pdf.pages)
    log.info(f"PDF has {total_pages} pages")

    # --- Phase 1: Font-size survey ---
    survey_pages = PROOF_OF_CONCEPT_PAGES or list(range(9, 20))
    survey_pages = [p for p in survey_pages if p < total_pages]
    size_counts = survey_font_sizes(pdf, survey_pages, log)

    # Determine main text and apparatus font sizes
    # The two most frequent sizes should be main text and apparatus,
    # with main text being larger
    sorted_sizes = sorted(size_counts.items(), key=lambda kv: kv[1],
                          reverse=True)
    if len(sorted_sizes) < 2:
        log.error(
            "Could not identify two distinct font sizes. "
            "Sizes found: %s", sorted_sizes
        )
        sys.exit(1)

    # Take the two most common sizes; the larger one is main text
    top_two = sorted(
        [sorted_sizes[0][0], sorted_sizes[1][0]], reverse=True
    )
    main_size = top_two[0]
    apparatus_size = top_two[1]
    log.info(
        f"Auto-detected sizes: main text = {main_size}pt, "
        f"apparatus = {apparatus_size}pt"
    )

    # If the sizes are suspiciously close or identical, warn
    if abs(main_size - apparatus_size) < 0.5:
        log.warning(
            "Main and apparatus sizes are very close — detection may be "
            "unreliable. Top sizes: %s",
            sorted_sizes[:5],
        )
        # Try the third most common size as apparatus
        if len(sorted_sizes) >= 3:
            candidate = sorted_sizes[2][0]
            if candidate < main_size:
                apparatus_size = candidate
                log.info(f"  Using third-most-common size as apparatus: "
                         f"{apparatus_size}pt")

    # --- Phase 2: Process pages ---
    pages_to_process = PROOF_OF_CONCEPT_PAGES
    if pages_to_process is None:
        pages_to_process = list(range(FIRST_PAGE, min(LAST_PAGE + 1,
                                                       total_pages)))
    else:
        pages_to_process = [p for p in pages_to_process if p < total_pages]

    log.info(f"Processing {len(pages_to_process)} pages...")

    state = {"book": None, "chapter": 1}
    all_entries = []

    for i, page_idx in enumerate(pages_to_process):
        if i % 50 == 0 and i > 0:
            log.info(f"  Progress: {i}/{len(pages_to_process)} pages")

        page = pdf.pages[page_idx]
        try:
            entries = process_page(
                page, page_idx, state, main_size, apparatus_size, log
            )
            all_entries.extend(entries)
        except Exception as e:
            log.error(f"  Page {page_idx + 1}: ERROR: {e}", exc_info=True)

    # --- Phase 3: Output ---
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    output_data = {
        "source": "Nestle 1904 Greek New Testament (BFBS edition)",
        "pdf": str(pdf_path),
        "extraction_note": (
            "Machine-extracted critical apparatus. Entries with "
            "parse_status != 'ok' need manual review."
        ),
        "font_sizes": {
            "main_text_pt": main_size,
            "apparatus_pt": apparatus_size,
        },
        "pages_processed": len(pages_to_process),
        "total_entries": len(all_entries),
        "entries": all_entries,
    }

    OUTPUT.write_text(
        json.dumps(output_data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    log.info(f"Wrote {len(all_entries)} entries to {OUTPUT}")

    # Summary statistics
    ok = sum(1 for e in all_entries if e.get("parse_status") == "ok")
    no_bracket = sum(
        1 for e in all_entries if e.get("parse_status") == "no_bracket"
    )
    books_seen = sorted(set(e["book"] for e in all_entries if e.get("book")))

    log.info(f"Summary:")
    log.info(f"  Total entries: {len(all_entries)}")
    log.info(f"  Fully parsed (ok): {ok}")
    log.info(f"  No bracket (need review): {no_bracket}")
    log.info(f"  Books seen: {', '.join(books_seen)}")

    pdf.close()
    log.info("Done.")


if __name__ == "__main__":
    main()
