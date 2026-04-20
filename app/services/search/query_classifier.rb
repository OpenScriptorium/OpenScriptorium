module Search
  class QueryClassifier
    TYPES = %i[
      strongs citation hebrew greek lemma morphological
      proximity regex xref_traversal apparatus syntax text
    ].freeze

    # Strong's number: H430, G3056, h1234
    STRONGS_RE = /\A[HGhg]\d{1,5}\z/

    # Pure Hebrew/Aramaic script (with optional nikud/cantillation)
    HEBREW_RE  = /\A[\u0590-\u05FF\uFB1D-\uFB4F\s]+\z/

    # Pure Greek script (polytonic + basic)
    GREEK_RE   = /\A[\u0370-\u03FF\u1F00-\u1FFF\s]+\z/

    # lemma: prefix
    LEMMA_RE   = /\Alemma:/i

    # morph: prefix
    MORPH_RE   = /\Amorph:/i

    # regex: prefix
    REGEX_RE   = /\Aregex:/i

    # xref: prefix — cross-reference traversal
    XREF_RE    = /\Axref:/i

    # syntax: prefix — syntactic role search
    # "syntax: subject(אלהים) verb(ברא)" or "subj:אלהים verb:ברא"
    SYNTAX_RE = /\A(?:syntax:|subj:|obj:|verb:)/i

    # apparatus: prefix — find verses with variants
    APPARATUS_RE = /\Aapparatus\b/i

    # Proximity: "term1 NEAR/5 term2" or "term1 NEAR term2"
    PROXIMITY_RE = /\A(.+?)\s+NEAR(?:\/(\d+))?\s+(.+)\z/i

    # Citation pattern: optional numbered book + abbreviation + chapter[:verse[-end]]
    # Matches: "Gen 1:1", "1 Sam 3", "Ps 23:1-6", "Rev 21:1"
    # Loose enough to catch most inputs; CitationParser does strict validation.
    CITATION_RE = /\A(\d\s+)?[A-Z][a-z.]+\.?\s+\d+/i

    Result = Data.define(:type, :query, :raw_query, :extra) do
      def initialize(type:, query:, raw_query:, extra: {})
        super
      end
    end

    def self.classify(raw_query)
      new.classify(raw_query)
    end

    def classify(raw_query)
      q = raw_query.to_s.strip
      return Result.new(type: :text, query: q, raw_query: q) if q.blank?

      type, query, extra = detect_type_and_extract(q)
      Result.new(type: type, query: query, raw_query: q, extra: extra)
    end

    private

    def detect_type_and_extract(q)
      case q
      when STRONGS_RE
        [:strongs, q.upcase, {}]
      when LEMMA_RE
        [:lemma, q.sub(LEMMA_RE, "").strip, {}]
      when MORPH_RE
        [:morphological, q.sub(MORPH_RE, "").strip, {}]
      when REGEX_RE
        [:regex, q.sub(REGEX_RE, "").strip, {}]
      when XREF_RE
        [:xref_traversal, q.sub(XREF_RE, "").strip, {}]
      when APPARATUS_RE
        variant_type = q.sub(APPARATUS_RE, "").strip.presence
        [:apparatus, q, { variant_type: variant_type }]
      when SYNTAX_RE
        parse_syntax_query(q)
      when PROXIMITY_RE
        m = q.match(PROXIMITY_RE)
        [:proximity, q, { term_a: m[1].strip, term_b: m[3].strip, distance: (m[2] || 5).to_i }]
      when HEBREW_RE
        [:hebrew, q, {}]
      when GREEK_RE
        [:greek, q, {}]
      else
        citation_like?(q) ? [:citation, q, {}] : [:text, q, {}]
      end
    end

    # Parse syntax queries in two formats:
    #   "syntax: subject(אלהים) verb(ברא) object(שמים)"
    #   "subj:אלהים verb:ברא obj:שמים"
    ROLE_ALIASES = {
      "subject" => "s", "subj" => "s", "s" => "s",
      "verb" => "v", "v" => "v",
      "predicate" => "p", "pred" => "p", "p" => "p",
      "object" => "o", "obj" => "o", "o" => "o",
      "indirect" => "io", "io" => "io",
      "complement" => "c", "comp" => "c", "c" => "c",
      "adjunct" => "a", "adj" => "a", "a" => "a",
      "vocative" => "voc", "voc" => "voc"
    }.freeze

    # Clause type aliases for filtering.
    #
    # Macula lowfat XML does NOT use "NC"/"VC"/"Way0" as rule values.
    # Hebrew clauses use constituent-order rules like "S-V-O", "V-S",
    # "P2CL", "PP-V-S-O".  Greek clauses also carry a `cltype` attr
    # with values "Verbless", "VerbElided", "Minor".
    #
    # Each alias maps to a detection strategy:
    #   rule:           exact match on syntax_nodes.rule (IN list)
    #   rule_pattern:   SQL LIKE pattern on syntax_nodes.rule
    #   clause_type:    exact match on syntax_nodes.clause_type (Greek cltype)
    #   node_class:     match on syntax_nodes.node_class
    #   role:           match on syntax_nodes.role
    #   has_verb_slot:  clause rule has a standalone V constituent
    #   no_verb_slot:   clause rule has NO standalone V or VC constituent
    #   word_morph:     clause contains a word whose morph_code LIKE pattern
    #   word_morph_any: clause contains a word matching ANY of several patterns
    #   word_class:     clause contains an interrogative particle
    CLAUSE_ALIASES = {
      # Narrative: clause contains a wayyiqtol verb (Hebrew morph V + stem + w)
      "narrative"   => { word_morph: "V_w%" },
      # Verbal: clause rule contains a V (verb) constituent slot.
      # Uses :has_verb_slot, a custom strategy that checks for standalone
      # V in the rule (V-..., ...-V-..., ...-V) without matching ADV.
      "verbal"      => { has_verb_slot: true },
      # Nominal/verbless: Greek cltype OR Hebrew clauses with no verb.
      # Hebrew nominal clauses have rules like P2CL, PP2CL, S-P, P-S.
      # The common thread is no verb slot in the constituent order.
      # We detect this via :no_verb_slot, a custom strategy that checks
      # the rule has no standalone V constituent (avoiding false matches
      # on ADV which contains the letter V).
      "nominal"     => { clause_type: %w[Verbless VerbElided], no_verb_slot: true },
      "verbless"    => { clause_type: %w[Verbless VerbElided], no_verb_slot: true },
      # Relative: node_class = "relp" with rule = "relCL"
      "relative"    => { node_class: %w[relp], rule: %w[relCL] },
      # Imperative: clause contains a verb with imperative morph
      # Hebrew: V + stem + v (e.g. Vqv2ms); Greek: mood=M before person marker
      "imperative"  => { word_morph_any: ["V_v%", "V-__M-%", "V-___M-%"] },
      # Jussive: Hebrew morph V + stem + j
      "jussive"     => { word_morph: "V_j%" },
      # Cohortative: Hebrew morph V + stem + c
      "cohortative" => { word_morph: "V_c%" },
      # Conditional: clause contains a conditional particle.
      # Hebrew: אם (im), לו (lu); Greek: εἰ (ei), ἐάν (ean).
      # Detected via word-level lemma match.
      "conditional" => { word_lemma_any: %w[אִם לוּ εἰ ἐάν] },
      # Subordinate: clause role marks it as adverbial (common subordinate role)
      "subordinate" => { clause_role: %w[adv] },
      # Question: clause contains an interrogative particle (Hebrew class "inrg")
      "question"    => { word_class: "inrg" },
    }.freeze

    def parse_syntax_query(q)
      roles = {}
      clause_type = nil

      # Extract clause() filter
      if q.match(/clause\((\w+)\)/i)
        clause_key = $1.downcase
        clause_type = CLAUSE_ALIASES[clause_key] || [clause_key]
      end

      # Format 1: "syntax: subject(אלהים) verb(ברא)"
      q.scan(/(\w+)\(([^)]+)\)/) do |role_name, lemma|
        next if role_name.downcase == "clause"
        code = ROLE_ALIASES[role_name.downcase]
        roles[code] = lemma.strip if code
      end

      # Format 2: "subj:אלהים verb:ברא" (no parentheses)
      if roles.empty?
        q.scan(/(\w+):(\S+)/) do |role_name, lemma|
          next if role_name.downcase == "syntax"
          code = ROLE_ALIASES[role_name.downcase]
          roles[code] = lemma.strip if code
        end
      end

      [:syntax, q, { roles: roles, clause_type: clause_type }]
    end

    def citation_like?(q)
      q.match?(CITATION_RE)
    end
  end
end
