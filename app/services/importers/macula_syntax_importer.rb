require "nokogiri"

module Importers
  class MaculaSyntaxImporter < BaseImporter
    HEBREW_DIR = Rails.root.join("tmp/macula-hebrew/WLC/lowfat")
    GREEK_DIR  = Rails.root.join("tmp/macula-greek/Nestle1904/lowfat")

    # Macula book codes → our SBL abbreviations
    BOOK_MAP = {
      # Hebrew
      "GEN" => "Gen", "EXO" => "Exod", "LEV" => "Lev", "NUM" => "Num", "DEU" => "Deut",
      "JOS" => "Josh", "JDG" => "Judg", "RUT" => "Ruth",
      "1SA" => "1 Sam", "2SA" => "2 Sam", "1KI" => "1 Kgs", "2KI" => "2 Kgs",
      "1CH" => "1 Chr", "2CH" => "2 Chr", "EZR" => "Ezra", "NEH" => "Neh", "EST" => "Esth",
      "JOB" => "Job", "PSA" => "Ps", "PRO" => "Prov", "ECC" => "Eccl", "SNG" => "Song",
      "ISA" => "Isa", "JER" => "Jer", "LAM" => "Lam", "EZK" => "Ezek", "DAN" => "Dan",
      "HOS" => "Hos", "JOL" => "Joel", "AMO" => "Amos", "OBA" => "Obad",
      "JON" => "Jonah", "MIC" => "Mic", "NAM" => "Nah", "HAB" => "Hab",
      "ZEP" => "Zeph", "HAG" => "Hag", "ZEC" => "Zech", "MAL" => "Mal",
      # Greek
      "MAT" => "Matt", "MRK" => "Mark", "LUK" => "Luke", "JHN" => "John",
      "ACT" => "Acts", "ROM" => "Rom", "1CO" => "1 Cor", "2CO" => "2 Cor",
      "GAL" => "Gal", "EPH" => "Eph", "PHP" => "Phil", "COL" => "Col",
      "1TH" => "1 Thess", "2TH" => "2 Thess", "1TI" => "1 Tim", "2TI" => "2 Tim",
      "TIT" => "Titus", "PHM" => "Phlm", "HEB" => "Heb",
      "JAS" => "Jas", "1PE" => "1 Pet", "2PE" => "2 Pet",
      "1JN" => "1 John", "2JN" => "2 John", "3JN" => "3 John",
      "JUD" => "Jude", "REV" => "Rev"
    }.freeze

    def source_url
      "local:tmp/macula-{hebrew,greek}"
    end

    def perform
      wipe_previous!

      @work_unit_cache = {}
      @word_cache = {}
      @node_batch = []
      @word_updates = []
      @node_counter = 0

      import_hebrew if HEBREW_DIR.exist?
      import_greek if GREEK_DIR.exist?

      flush_batch!
      apply_word_links!

      Rails.logger.info "[MaculaSyntax] Done: #{@stats[:nodes]} nodes, #{@stats[:word_links]} word links"
    end

    private

    def wipe_previous!
      old_runs = ImportRun.where(importer_class: self.class.name).where.not(id: @import_run.id).pluck(:id)
      if old_runs.any?
        Word.where.not(syntax_node_id: nil).joins(:syntax_node)
            .where(syntax_nodes: { import_run_id: old_runs }).update_all(syntax_node_id: nil)
        SyntaxNode.where(import_run_id: old_runs).delete_all
      end
    end

    def import_hebrew
      @hebrew_work = Work.find_by!(slug: "wlc")
      files = Dir.glob(HEBREW_DIR.join("*.xml")).sort
      Rails.logger.info "[MaculaSyntax] Importing #{files.size} Hebrew chapter files"

      files.each do |path|
        doc = Nokogiri::XML(File.read(path))
        doc.css("sentence").each { |sent| process_sentence(sent, @hebrew_work, "he") }
      end
    end

    def import_greek
      @greek_work = Work.find_by!(slug: "nestle1904")
      files = Dir.glob(GREEK_DIR.join("*.xml")).sort
      Rails.logger.info "[MaculaSyntax] Importing #{files.size} Greek book files"

      files.each do |path|
        doc = Nokogiri::XML(File.read(path))
        doc.css("sentence").each { |sent| process_sentence(sent, @greek_work, "grc") }
      end
    end

    def process_sentence(sentence_el, work, lang)
      # Find verse reference from milestone or sentence id
      milestone = sentence_el.at_css("milestone[unit='verse']")
      verse_id = milestone&.[]("id") || sentence_el["id"]
      return unless verse_id

      citation = parse_citation(verse_id)
      return unless citation

      wu = find_work_unit(work, citation)
      return unless wu

      verse_path = citation.gsub(/[^a-zA-Z0-9]/, "_")

      # Walk the word groups
      sentence_el.css("> wg").each_with_index do |wg, idx|
        walk_tree(wg, work, wu, "#{verse_path}.r#{idx}", nil, 0)
      end

      bump :verses
      flush_batch! if @node_batch.size >= 5000
    end

    def walk_tree(el, work, wu, path, parent_id, depth)
      return unless el.name == "wg"

      node_class = el["class"] || infer_class(el)
      node_type = el["type"] || el["cltype"]
      role = el["role"]
      rule = el["rule"]
      clause_type = el["cltype"]

      # Collect word positions for start/end
      word_positions = el.css("w").map { |w| parse_word_position(w) }.compact

      @node_counter += 1
      node_id = @node_counter
      ltree_path = sanitize_ltree(path)

      @node_batch << {
        id: nil, # placeholder — assigned by DB
        work_id: work.id,
        work_unit_id: wu.id,
        parent_id: parent_id,
        path: ltree_path,
        node_class: node_class,
        node_type: node_type,
        clause_type: clause_type,
        rule: rule,
        role: role,
        start_position: word_positions.min,
        end_position: word_positions.max,
        depth: depth,
        import_run_id: @import_run.id,
        created_at: Time.current,
        updated_at: Time.current,
        _temp_id: node_id,
        _work_unit_id: wu.id,
        _word_positions: word_positions_for_direct_children(el),
        _word_roles: word_roles_for_direct_children(el)
      }

      bump :nodes

      # Recurse into child word groups
      el.children.each_with_index do |child, idx|
        if child.name == "wg"
          walk_tree(child, work, wu, "#{path}.n#{idx}", node_id, depth + 1)
        end
      end
    end

    def flush_batch!
      return if @node_batch.empty?

      # Insert without temp fields
      rows = @node_batch.map do |n|
        n.except(:_temp_id, :_work_unit_id, :_word_positions, :_word_roles, :id)
          .merge(parent_id: nil) # Can't set parent_id yet — resolve after insert
      end

      SyntaxNode.insert_all(rows)

      # Now we need to link words. For each node, find the words at
      # the direct child positions and update their syntax_node_id.
      # We do this in bulk after all nodes are inserted.
      inserted = SyntaxNode.where(import_run_id: @import_run.id)
                           .order(:id)
                           .offset(@stats[:flushed_nodes] || 0)
                           .limit(@node_batch.size)
                           .pluck(:id, :work_unit_id, :start_position, :end_position)

      @node_batch.each_with_index do |batch_node, idx|
        next unless inserted[idx]
        db_id = inserted[idx][0]
        positions = batch_node[:_word_positions]
        word_roles = batch_node[:_word_roles] || {}
        next if positions.empty?

        positions.each do |pos|
          @word_updates << {
            work_unit_id: batch_node[:_work_unit_id],
            position: pos,
            syntax_node_id: db_id,
            role: word_roles[pos]
          }
        end
      end

      @stats[:flushed_nodes] = (@stats[:flushed_nodes] || 0) + @node_batch.size
      @node_batch.clear
    end

    def apply_word_links!
      Rails.logger.info "[MaculaSyntax] Linking #{@word_updates.size} words to syntax nodes"

      @word_updates.each_slice(2000) do |slice|
        node_cases = slice.map { |u| "WHEN work_unit_id = #{u[:work_unit_id]} AND position = #{u[:position]} THEN #{u[:syntax_node_id]}" }
        role_cases = slice.map { |u| "WHEN work_unit_id = #{u[:work_unit_id]} AND position = #{u[:position]} THEN #{u[:role] ? ApplicationRecord.connection.quote(u[:role]) : "NULL"}" }
        where_pairs = slice.map { |u| "(#{u[:work_unit_id]}, #{u[:position]})" }

        ApplicationRecord.connection.execute(<<~SQL)
          UPDATE words
          SET syntax_node_id = CASE #{node_cases.join(" ")} END,
              role = CASE #{role_cases.join(" ")} END
          WHERE (work_unit_id, position) IN (#{where_pairs.join(", ")})
        SQL

        bump :word_links, slice.size
      end
    end

    def parse_citation(verse_id)
      # "GEN 1:1" → "Gen 1:1"
      parts = verse_id.strip.split(" ", 2)
      book_code = parts[0]
      rest = parts[1]
      sbl = BOOK_MAP[book_code]
      return nil unless sbl
      "#{sbl} #{rest}"
    end

    def find_work_unit(work, citation)
      key = "#{work.id}:#{citation}"
      return @work_unit_cache[key] if @work_unit_cache.key?(key)

      wu = WorkUnit.joins(:canonical_ref)
                   .where(work_id: work.id)
                   .where("canonical_refs.sbl_citation = ?", citation)
                   .first
      @work_unit_cache[key] = wu
      wu
    end

    def parse_word_position(w_el)
      ref = w_el["ref"]
      return nil unless ref
      # "GEN 1:1!2" → position 2
      if ref.match?(/!\d+$/)
        ref.split("!").last.to_i
      else
        nil
      end
    end

    def word_positions_for_direct_children(el)
      # Only direct child <w> elements (not nested in sub-<wg>)
      el.children.select { |c| c.name == "w" }.filter_map { |w| parse_word_position(w) }
    end

    def word_roles_for_direct_children(el)
      # Collect {position => role} for direct child words that have a role attribute
      result = {}
      el.children.select { |c| c.name == "w" && c["role"] }.each do |w|
        pos = parse_word_position(w)
        result[pos] = w["role"] if pos
      end
      result
    end

    def infer_class(el)
      # If no class attribute, infer from children
      has_clause_children = el.css("> wg[class='cl']").any?
      has_word_children = el.css("> w").any?
      if has_clause_children
        "cl"
      elsif has_word_children
        "ph"
      else
        "wg"
      end
    end

    def sanitize_ltree(path)
      # ltree labels can only contain [a-zA-Z0-9_]
      path.gsub(/[^a-zA-Z0-9_.]/, "_")
    end
  end
end
