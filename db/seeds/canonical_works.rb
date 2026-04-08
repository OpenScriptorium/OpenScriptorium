# Seed the canonical_works metadata for the standard 66 + deuterocanonical
# books. canonical_refs (the verse-level rows) are NOT created here — those
# come from the BSB importer in Phase 2, which has the authoritative verse
# count for the KJV versification scheme.
#
# Each book gets a canonical_work under the KJV versification scheme.
# Other versification schemes (MT, LXX, etc.) get their own canonical_works
# when those translations are imported.

kjv = VersificationScheme.find_by!(code: "KJV")

# [slug, title, native_title (or nil), osis_book_id, testament, position, sbl_abbreviation]
# SBL abbreviations follow the SBL Handbook of Style, 2nd ed., Appendix F.
BOOKS = [
  # ── Hebrew Bible / OT (in Christian canonical order, KJV scheme) ────────────
  ["genesis",         "Genesis",         "בְּרֵאשִׁית",       "Gen",   "ot",  1],
  ["exodus",          "Exodus",          "שְׁמוֹת",           "Exod",  "ot",  2],
  ["leviticus",       "Leviticus",       "וַיִּקְרָא",         "Lev",   "ot",  3],
  ["numbers",         "Numbers",         "בְּמִדְבַּר",         "Num",   "ot",  4],
  ["deuteronomy",     "Deuteronomy",     "דְּבָרִים",          "Deut",  "ot",  5],
  ["joshua",          "Joshua",          "יְהוֹשֻׁעַ",          "Josh",  "ot",  6],
  ["judges",          "Judges",          "שׁוֹפְטִים",          "Judg",  "ot",  7],
  ["ruth",            "Ruth",            "רוּת",              "Ruth",  "ot",  8],
  ["1-samuel",        "1 Samuel",        "שְׁמוּאֵל א",        "1Sam",  "ot",  9],
  ["2-samuel",        "2 Samuel",        "שְׁמוּאֵל ב",        "2Sam",  "ot", 10],
  ["1-kings",         "1 Kings",         "מְלָכִים א",         "1Kgs",  "ot", 11],
  ["2-kings",         "2 Kings",         "מְלָכִים ב",         "2Kgs",  "ot", 12],
  ["1-chronicles",    "1 Chronicles",    "דִּבְרֵי הַיָּמִים א",  "1Chr",  "ot", 13],
  ["2-chronicles",    "2 Chronicles",    "דִּבְרֵי הַיָּמִים ב",  "2Chr",  "ot", 14],
  ["ezra",            "Ezra",            "עֶזְרָא",            "Ezra",  "ot", 15],
  ["nehemiah",        "Nehemiah",        "נְחֶמְיָה",           "Neh",   "ot", 16],
  ["esther",          "Esther",          "אֶסְתֵּר",            "Esth",  "ot", 17],
  ["job",             "Job",             "אִיּוֹב",            "Job",   "ot", 18],
  ["psalms",          "Psalms",          "תְּהִלִּים",          "Ps",    "ot", 19],
  ["proverbs",        "Proverbs",        "מִשְׁלֵי",            "Prov",  "ot", 20],
  ["ecclesiastes",    "Ecclesiastes",    "קֹהֶלֶת",            "Eccl",  "ot", 21],
  ["song-of-solomon", "Song of Solomon", "שִׁיר הַשִּׁירִים",     "Song",  "ot", 22],
  ["isaiah",          "Isaiah",          "יְשַׁעְיָהוּ",          "Isa",   "ot", 23],
  ["jeremiah",        "Jeremiah",        "יִרְמְיָהוּ",          "Jer",   "ot", 24],
  ["lamentations",    "Lamentations",    "אֵיכָה",             "Lam",   "ot", 25],
  ["ezekiel",         "Ezekiel",         "יְחֶזְקֵאל",          "Ezek",  "ot", 26],
  ["daniel",          "Daniel",          "דָּנִיֵּאל",          "Dan",   "ot", 27],
  ["hosea",           "Hosea",           "הוֹשֵׁעַ",           "Hos",   "ot", 28],
  ["joel",            "Joel",            "יוֹאֵל",             "Joel",  "ot", 29],
  ["amos",            "Amos",            "עָמוֹס",             "Amos",  "ot", 30],
  ["obadiah",         "Obadiah",         "עֹבַדְיָה",           "Obad",  "ot", 31],
  ["jonah",           "Jonah",           "יוֹנָה",             "Jonah", "ot", 32],
  ["micah",           "Micah",           "מִיכָה",             "Mic",   "ot", 33],
  ["nahum",           "Nahum",           "נַחוּם",             "Nah",   "ot", 34],
  ["habakkuk",        "Habakkuk",        "חֲבַקּוּק",           "Hab",   "ot", 35],
  ["zephaniah",       "Zephaniah",       "צְפַנְיָה",           "Zeph",  "ot", 36],
  ["haggai",          "Haggai",          "חַגַּי",             "Hag",   "ot", 37],
  ["zechariah",       "Zechariah",       "זְכַרְיָה",           "Zech",  "ot", 38],
  ["malachi",         "Malachi",         "מַלְאָכִי",           "Mal",   "ot", 39],

  # ── Greek New Testament ────────────────────────────────────────────────────
  ["matthew",         "Matthew",         "Κατὰ Ματθαῖον",       "Matt",  "nt", 40],
  ["mark",            "Mark",            "Κατὰ Μᾶρκον",         "Mark",  "nt", 41],
  ["luke",            "Luke",            "Κατὰ Λουκᾶν",         "Luke",  "nt", 42],
  ["john",            "John",            "Κατὰ Ἰωάννην",        "John",  "nt", 43],
  ["acts",            "Acts",            "Πράξεις τῶν Ἀποστόλων", "Acts",  "nt", 44],
  ["romans",          "Romans",          "Πρὸς Ῥωμαίους",       "Rom",   "nt", 45],
  ["1-corinthians",   "1 Corinthians",   "Πρὸς Κορινθίους Α",   "1Cor",  "nt", 46],
  ["2-corinthians",   "2 Corinthians",   "Πρὸς Κορινθίους Β",   "2Cor",  "nt", 47],
  ["galatians",       "Galatians",       "Πρὸς Γαλάτας",        "Gal",   "nt", 48],
  ["ephesians",       "Ephesians",       "Πρὸς Ἐφεσίους",       "Eph",   "nt", 49],
  ["philippians",     "Philippians",     "Πρὸς Φιλιππησίους",   "Phil",  "nt", 50],
  ["colossians",      "Colossians",      "Πρὸς Κολοσσαεῖς",     "Col",   "nt", 51],
  ["1-thessalonians", "1 Thessalonians", "Πρὸς Θεσσαλονικεῖς Α", "1Thess", "nt", 52],
  ["2-thessalonians", "2 Thessalonians", "Πρὸς Θεσσαλονικεῖς Β", "2Thess", "nt", 53],
  ["1-timothy",       "1 Timothy",       "Πρὸς Τιμόθεον Α",     "1Tim",  "nt", 54],
  ["2-timothy",       "2 Timothy",       "Πρὸς Τιμόθεον Β",     "2Tim",  "nt", 55],
  ["titus",           "Titus",           "Πρὸς Τίτον",          "Titus", "nt", 56],
  ["philemon",        "Philemon",        "Πρὸς Φιλήμονα",        "Phlm",  "nt", 57],
  ["hebrews",         "Hebrews",         "Πρὸς Ἑβραίους",        "Heb",   "nt", 58],
  ["james",           "James",           "Ἰακώβου",             "Jas",   "nt", 59],
  ["1-peter",         "1 Peter",         "Πέτρου Α",            "1Pet",  "nt", 60],
  ["2-peter",         "2 Peter",         "Πέτρου Β",            "2Pet",  "nt", 61],
  ["1-john",          "1 John",          "Ἰωάννου Α",           "1John", "nt", 62],
  ["2-john",          "2 John",          "Ἰωάννου Β",           "2John", "nt", 63],
  ["3-john",          "3 John",          "Ἰωάννου Γ",           "3John", "nt", 64],
  ["jude",            "Jude",            "Ἰούδα",               "Jude",  "nt", 65],
  ["revelation",      "Revelation",      "Ἀποκάλυψις Ἰωάννου",   "Rev",   "nt", 66],

  # ── Deuterocanon / Apocrypha (positions 70+ to leave room) ─────────────────
  ["tobit",                "Tobit",                nil, "Tob",   "deuterocanon", 70],
  ["judith",               "Judith",               nil, "Jdt",   "deuterocanon", 71],
  ["esther-greek",         "Esther (Greek)",       nil, "EsthGr", "deuterocanon", 72],
  ["wisdom",               "Wisdom of Solomon",    nil, "Wis",   "deuterocanon", 73],
  ["sirach",               "Sirach (Ecclesiasticus)", nil, "Sir", "deuterocanon", 74],
  ["baruch",               "Baruch",               nil, "Bar",   "deuterocanon", 75],
  ["letter-of-jeremiah",   "Letter of Jeremiah",   nil, "EpJer", "deuterocanon", 76],
  ["prayer-of-azariah",    "Prayer of Azariah",    nil, "PrAzar","deuterocanon", 77],
  ["susanna",              "Susanna",              nil, "Sus",   "deuterocanon", 78],
  ["bel-and-the-dragon",   "Bel and the Dragon",   nil, "Bel",   "deuterocanon", 79],
  ["1-maccabees",          "1 Maccabees",          nil, "1Macc", "deuterocanon", 80],
  ["2-maccabees",          "2 Maccabees",          nil, "2Macc", "deuterocanon", 81],
  ["3-maccabees",          "3 Maccabees",          nil, "3Macc", "deuterocanon", 82],
  ["4-maccabees",          "4 Maccabees",          nil, "4Macc", "deuterocanon", 83],
  ["1-esdras",             "1 Esdras",             nil, "1Esd",  "deuterocanon", 84],
  ["2-esdras",             "2 Esdras",             nil, "2Esd",  "deuterocanon", 85],
  ["prayer-of-manasseh",   "Prayer of Manasseh",   nil, "PrMan", "deuterocanon", 86],
  ["psalm-151",            "Psalm 151",            nil, "AddPs", "deuterocanon", 87],
].freeze

# SBL Handbook of Style, 2nd ed., Appendix F. Map by slug → abbreviation.
SBL_ABBREVIATIONS = {
  "genesis"=>"Gen", "exodus"=>"Exod", "leviticus"=>"Lev", "numbers"=>"Num",
  "deuteronomy"=>"Deut", "joshua"=>"Josh", "judges"=>"Judg", "ruth"=>"Ruth",
  "1-samuel"=>"1 Sam", "2-samuel"=>"2 Sam", "1-kings"=>"1 Kgs", "2-kings"=>"2 Kgs",
  "1-chronicles"=>"1 Chr", "2-chronicles"=>"2 Chr",
  "ezra"=>"Ezra", "nehemiah"=>"Neh", "esther"=>"Esth", "job"=>"Job",
  "psalms"=>"Ps", "proverbs"=>"Prov", "ecclesiastes"=>"Eccl",
  "song-of-solomon"=>"Song",
  "isaiah"=>"Isa", "jeremiah"=>"Jer", "lamentations"=>"Lam", "ezekiel"=>"Ezek",
  "daniel"=>"Dan", "hosea"=>"Hos", "joel"=>"Joel", "amos"=>"Amos",
  "obadiah"=>"Obad", "jonah"=>"Jonah", "micah"=>"Mic", "nahum"=>"Nah",
  "habakkuk"=>"Hab", "zephaniah"=>"Zeph", "haggai"=>"Hag", "zechariah"=>"Zech",
  "malachi"=>"Mal",
  "matthew"=>"Matt", "mark"=>"Mark", "luke"=>"Luke", "john"=>"John",
  "acts"=>"Acts", "romans"=>"Rom", "1-corinthians"=>"1 Cor", "2-corinthians"=>"2 Cor",
  "galatians"=>"Gal", "ephesians"=>"Eph", "philippians"=>"Phil", "colossians"=>"Col",
  "1-thessalonians"=>"1 Thess", "2-thessalonians"=>"2 Thess",
  "1-timothy"=>"1 Tim", "2-timothy"=>"2 Tim", "titus"=>"Titus", "philemon"=>"Phlm",
  "hebrews"=>"Heb", "james"=>"Jas", "1-peter"=>"1 Pet", "2-peter"=>"2 Pet",
  "1-john"=>"1 John", "2-john"=>"2 John", "3-john"=>"3 John",
  "jude"=>"Jude", "revelation"=>"Rev",
  "tobit"=>"Tob", "judith"=>"Jdt", "esther-greek"=>"Add Esth",
  "wisdom"=>"Wis", "sirach"=>"Sir", "baruch"=>"Bar",
  "letter-of-jeremiah"=>"Ep Jer", "prayer-of-azariah"=>"Pr Azar",
  "susanna"=>"Sus", "bel-and-the-dragon"=>"Bel",
  "1-maccabees"=>"1 Macc", "2-maccabees"=>"2 Macc",
  "3-maccabees"=>"3 Macc", "4-maccabees"=>"4 Macc",
  "1-esdras"=>"1 Esd", "2-esdras"=>"2 Esd",
  "prayer-of-manasseh"=>"Pr Man", "psalm-151"=>"Ps 151"
}.freeze

BOOKS.each do |slug, title, native_title, osis_id, testament, position|
  cw = CanonicalWork.find_or_initialize_by(slug: slug)
  cw.assign_attributes(
    title: title,
    native_title: native_title,
    osis_book_id: osis_id,
    testament: testament,
    position: position,
    versification_scheme: kjv,
    sbl_abbreviation: SBL_ABBREVIATIONS[slug] || title,
    citation_format: "scripture"
  )
  cw.save!
end

puts "  canonical_works: #{CanonicalWork.count}"
