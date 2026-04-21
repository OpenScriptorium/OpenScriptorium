module Search
  module Strategies
    class PericopeRetrieval
      # For natural language queries ("What did Jesus say about war?"),
      # finds relevant passages by searching pericope names via embedding
      # similarity, then filters to verses where the named person is active.
      #
      # Returns results grouped by pericope, with the pericope name as context.
      # This gives users the multi-passage answer they expect for research
      # questions, rather than a single best-match verse.

      MAX_PERICOPES = 15
      MIN_SIMILARITY = 0.4
      MAX_VERSES_PER_PERICOPE = 2

      PERSON_NAMES = Search::Strategies::SemanticMerge::PERSON_TESTAMENT rescue {}

      def initialize(query, existing_result, scope: nil)
        @query = query
        @existing_result = existing_result
        @scope = scope
      end

      def call
        return @existing_result unless question_query?
        return @existing_result unless pericope_embeddings_available?

        person = detect_person
        embeddings = encode_topic_hops

        return @existing_result if embeddings.empty?

        # Multi-hop: find pericopes near ANY of the topic facets
        all_pericopes = {}
        embeddings.each do |embedding|
          find_relevant_pericopes(embedding).each do |p|
            key = p["id"]
            existing = all_pericopes[key]
            # Keep the higher similarity score
            if existing.nil? || p["similarity"].to_f > existing["similarity"].to_f
              all_pericopes[key] = p
            end
          end
        end

        pericopes = all_pericopes.values
                      .sort_by { |p| -p["similarity"].to_f }
                      .first(MAX_PERICOPES)
        return @existing_result if pericopes.empty?

        # Within matched pericopes, find the best verses (optionally filtered by person)
        pericope_results = fetch_pericope_verses(pericopes, person)
        return @existing_result if pericope_results.empty?

        # Merge pericope results with existing results
        merge_results(pericope_results)
      end

      private

      def question_query?
        @query.strip.match?(/\A(what|where|when|who|why|how|is|does|did|can|should|are)\b/i) ||
          @query.strip.end_with?("?")
      end

      def pericope_embeddings_available?
        Pericope.where.not(name_embedding: nil).exists?
      end

      def detect_person
        query_lower = @query.downcase
        PERSON_NAMES.each_key do |name|
          return name if query_lower.include?(name)
        end
        nil
      end

      # Conceptual expansions: when the user searches for a broad topic,
      # expand it with related biblical concepts so the embedding finds
      # pericopes named with different but related words.
      TOPIC_EXPANSIONS = {
        "war" => "war violence enemies peace sword fight battle conflict",
        "money" => "money wealth riches treasure mammon poor poverty",
        "love" => "love compassion mercy kindness charity beloved",
        "forgiveness" => "forgiveness mercy pardon forgive sin repent",
        "prayer" => "prayer pray intercession supplication worship",
        "faith" => "faith believe trust faithful doubt",
        "death" => "death die dead burial resurrection mourning",
        "sin" => "sin transgression iniquity wickedness evil repent",
        "marriage" => "marriage wedding husband wife divorce bride",
        "children" => "children child son daughter family born",
        "suffering" => "suffering affliction pain trial tribulation persecution",
        "justice" => "justice judgment righteous judge oppressed poor",
        "heaven" => "heaven paradise kingdom glory eternal life",
        "hell" => "hell gehenna fire judgment punishment wrath",
        "healing" => "healing heal sick disease miracle restore",
        "temptation" => "temptation tempt test trial desire lust",
        "wisdom" => "wisdom wise understanding knowledge foolish",
        "worship" => "worship praise glory honor sacrifice offering",
        "salvation" => "salvation save redeem deliver rescue ransom",
        "covenant" => "covenant promise oath agreement law",
        "prophecy" => "prophecy prophet foretell vision oracle",
        "end times" => "end times second coming judgment day apocalypse revelation",
      }.freeze

      def extract_topic
        words = @query.gsub(/[?!.,;:]/, "").split
        stops = %w[what where when who why how does did do is are was were
                   the a an of in to for and or but with about from by
                   that this say says said tell told teach taught]
        person = detect_person
        content = words.reject { |w|
          stops.include?(w.downcase) || w.downcase == person
        }
        content.join(" ").downcase.strip
      end

      # Encode multiple facets of a topic and return all embeddings.
      # "war" → encode "war violence battle sword", "peace nonviolence",
      # "enemies love enemies retaliation" — each finds different pericopes.
      MULTI_HOP = {
        "war" => ["war violence battle sword fight", "peace nonviolence turn cheek", "enemies love enemies retaliation forgive"],
        "money" => ["money wealth riches treasure mammon", "poor poverty generosity giving", "greed covetousness stewardship"],
        "love" => ["love compassion mercy kindness", "marriage husband wife beloved", "neighbor enemy forgiveness"],
        "forgiveness" => ["forgiveness pardon mercy grace", "sin repentance confession", "reconciliation restoration"],
        "prayer" => ["prayer pray intercession supplication", "worship praise thanksgiving", "fasting meditation"],
        "faith" => ["faith believe trust faithful", "doubt fear unbelief", "works obedience"],
        "death" => ["death die burial mourning", "resurrection eternal life hope", "judgment afterlife"],
        "sin" => ["sin transgression iniquity evil", "repentance forgiveness redemption", "temptation fall"],
        "suffering" => ["suffering affliction pain trial", "patience endurance perseverance", "comfort hope deliverance"],
        "marriage" => ["marriage wedding husband wife", "divorce adultery faithfulness", "love covenant family"],
        "justice" => ["justice judgment righteous law", "oppression poor widow orphan", "mercy compassion liberation"],
        "heaven" => ["heaven paradise kingdom glory", "eternal life reward inheritance", "new creation restoration"],
        "hell" => ["hell gehenna fire punishment", "judgment wrath destruction", "repentance salvation escape"],
        "healing" => ["healing heal sick disease", "miracle faith restoration", "physician medicine"],
        "wisdom" => ["wisdom wise understanding knowledge", "foolish folly instruction", "fear of the lord"],
        "salvation" => ["salvation save redeem deliver", "grace faith baptism", "atonement sacrifice blood"],
        "worship" => ["worship praise glory honor", "sacrifice offering temple", "prayer song thanksgiving"],
        "end times" => ["end times second coming judgment", "apocalypse revelation tribulation", "kingdom resurrection"],
        "divorce" => ["divorce marriage covenant", "adultery unfaithfulness", "remarriage Moses certificate"],
        "anxiety" => ["anxiety worry fear trouble", "peace trust faith", "provision care protection"],
        "children" => ["children child son daughter", "family parent discipline", "inheritance blessing"],
      }.freeze

      def encode_topic_hops
        topic = extract_topic
        return [] if topic.empty?

        # Find multi-hop expansions
        hops = nil
        MULTI_HOP.each do |key, expansions|
          if topic.include?(key) || key.include?(topic)
            hops = expansions
            break
          end
        end

        # Fall back to single encoding of the raw topic
        hops ||= [topic]

        encoder = Search::EmbeddingEncoder.instance
        hops.filter_map { |hop| encoder.encode(hop) }
      rescue => e
        Rails.logger.warn("[PericopeRetrieval] encode failed: #{e.message}")
        []
      end

      def find_relevant_pericopes(embedding)
        vector_literal = "[#{embedding.join(',')}]"
        conn = ApplicationRecord.connection

        rows = conn.select_all(<<~SQL)
          SELECT p.id, p.name, p.canonical_work_id, p.canonical_range,
                 cw.book_key, cw.title as book_title,
                 1 - (p.name_embedding <=> '#{vector_literal}'::vector) AS similarity
          FROM pericopes p
          JOIN canonical_works cw ON cw.id = p.canonical_work_id
          WHERE p.name_embedding IS NOT NULL
          ORDER BY p.name_embedding <=> '#{vector_literal}'::vector
          LIMIT #{MAX_PERICOPES}
        SQL

        rows.select { |r| r["similarity"].to_f >= MIN_SIMILARITY }
      end

      def fetch_pericope_verses(pericopes, person)
        results = []
        testament = person ? (PERSON_NAMES[person] || :nt) : nil

        pericopes.each do |pericope|
          cw_id = pericope["canonical_work_id"]
          range = pericope["canonical_range"]
          name = pericope["name"]
          similarity = pericope["similarity"].to_f

          # Skip pericopes from wrong testament if person is specified
          if testament && person
            book = pericope["book_key"]
            nt_books = Search::Strategies::SemanticMerge::NT_BOOKS rescue Set.new
            ot_books = Search::Strategies::SemanticMerge::OT_BOOKS rescue Set.new
            if testament == :nt && !nt_books.include?(book)
              next
            elsif testament == :ot && !ot_books.include?(book)
              next
            end
          end

          # Find English work_units in this pericope's range
          wus = WorkUnit.joins(:work, :canonical_ref)
                       .where(works: { language: "en" })
                       .where(canonical_refs: { canonical_work_id: cw_id })
                       .where("canonical_refs.ord <@ ?::int4range", range)
                       .includes(:canonical_ref, work: :license)
                       .order("canonical_refs.ord")
                       .limit(20)

          # If person specified, prefer verses mentioning them
          if person
            person_wus = wus.select { |wu| wu.body&.downcase&.include?(person) }
            wus = person_wus.any? ? person_wus : wus.to_a
          else
            wus = wus.to_a
          end

          # Take best verses (first few, which are usually most relevant)
          wus.first(MAX_VERSES_PER_PERICOPE).each do |wu|
            results << {
              id: wu.id,
              work_slug: wu.work.slug,
              work_title: wu.work.title,
              language: wu.work.language,
              canonical_ref_id: wu.canonical_ref_id,
              citation: wu.canonical_ref.sbl_citation,
              hierarchy: wu.canonical_ref.hierarchy,
              body: wu.body,
              headline: wu.body,
              relevance: similarity * 15.0,  # Must outrank generic person-topic results
              license: wu.work.license.name,
              book_slug: wu.canonical_ref.canonical_work.book_key,
              pericope_name: name,
              pericope_match: true
            }
          end
        end

        # Deduplicate by citation
        seen = {}
        results.select { |r|
          cite = r[:citation]
          if seen[cite]
            false
          else
            seen[cite] = true
            true
          end
        }
      end

      def merge_results(pericope_results)
        existing = @existing_result.results

        # Preserve alias matches and strong phrase matches at the top —
        # these are high-confidence results that shouldn't be buried by
        # pericope suggestions.
        pinned, rest = existing.partition { |r|
          r[:alias_match] || r[:relevance].to_f > 5.0
        }

        # Remove non-pinned existing results that overlap with pericope results
        pericope_citations = pericope_results.map { |r| r[:citation] }.to_set
        filtered = rest.reject { |r| pericope_citations.include?(r[:citation]) }

        # Pinned first, then pericope results, then remaining
        combined = pinned + pericope_results + filtered

        ResultSet.new(
          results: combined.first(25),
          query: @existing_result.query,
          query_type: @existing_result.query_type,
          total_count: @existing_result.total_count + pericope_results.size,
          facets: @existing_result.facets,
          cross_language_card: @existing_result.cross_language_card,
          redirect: @existing_result.redirect,
          page: @existing_result.page,
          per_page: @existing_result.per_page
        )
      end
    end
  end
end
