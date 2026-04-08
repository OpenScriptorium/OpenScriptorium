# Seed Crosswire-style v11n schemes. We default everything to KJV for
# display; non-Christian / divergent traditions get their own scheme so
# imports can preserve the source's native versification, with
# divergences captured in versification_mappings later.
#
# Names follow Crosswire SWORD project conventions.
SCHEMES = [
  { code: "KJV",      display_name: "King James (Standard Christian)",
    description: "1611 KJV verse numbering. The de facto standard for English Bible references." },
  { code: "NRSV",     display_name: "NRSV",
    description: "New Revised Standard Version (slight differences from KJV in Psalms)." },
  { code: "NRSVA",    display_name: "NRSV with Apocrypha",
    description: "NRSV including the deuterocanonical books." },
  { code: "MT",       display_name: "Masoretic Text (Hebrew Bible)",
    description: "The Hebrew Masoretic versification, including superscriptions counted as v.1 of each Psalm." },
  { code: "LXX",      display_name: "Septuagint (Greek)",
    description: "Greek Septuagint versification (notably different in Psalms, Jeremiah, parts of Samuel/Kings)." },
  { code: "Vulgate",  display_name: "Latin Vulgate",
    description: "The Catholic Latin tradition." },
  { code: "Catholic", display_name: "Catholic",
    description: "Modern Catholic versification with deuterocanon." },
  { code: "German",   display_name: "German (Luther tradition)",
    description: "Luther Bible verse numbering." },
  { code: "Synodal",  display_name: "Russian Synodal",
    description: "Russian Orthodox Synodal Bible versification." },
  { code: "Leningrad", display_name: "Leningrad Codex",
    description: "Versification of the Leningrad Codex (basis of BHS)." },
  { code: "Orthodox", display_name: "Eastern Orthodox",
    description: "Eastern Orthodox canon and versification." }
].freeze

SCHEMES.each do |attrs|
  scheme = VersificationScheme.find_or_initialize_by(code: attrs[:code])
  scheme.assign_attributes(attrs)
  scheme.source_url ||= "https://wiki.crosswire.org/DevTools:Versification"
  scheme.save!
end

puts "  versification_schemes: #{VersificationScheme.count}"
