module Api
  module V1
    class SyntaxController < BaseController
      # GET /api/v1/syntax/:work_slug/:book/:chapter/:verse
      # Returns the syntax tree for a verse
      def show
        work = Work.find_by!(slug: params[:work_slug])
        chapter = params[:chapter].to_i
        verse = params[:verse].to_i

        wu = WorkUnit.joins(canonical_ref: :canonical_work)
                     .where(work_id: work.id)
                     .where(canonical_works: { book_key: params[:book] })
                     .where("canonical_refs.hierarchy = ARRAY[?, ?]", chapter, verse)
                     .first!

        nodes = SyntaxNode.where(work_unit_id: wu.id)
                          .order(:depth, :start_position)
                          .includes(:words)

        tree = build_tree(nodes)

        render json: {
          citation: wu.canonical_ref.sbl_citation,
          work: work.slug,
          tree: tree
        }
      end

      private

      def build_tree(nodes)
        nodes_by_id = {}
        roots = []

        nodes.each do |node|
          entry = {
            id: node.id,
            class: node.node_class,
            type: node.node_type,
            clause_type: node.clause_type,
            rule: node.rule,
            role: node.role,
            role_label: node.role_label,
            depth: node.depth,
            words: node.words.order(:position).map { |w|
              {
                surface: w.surface,
                lemma: w.lemma&.lemma,
                gloss: w.lemma&.primary_gloss&.split(";")&.first&.strip,
                pos: w.morph_code,
                role: w.role,
                role_label: SyntaxNode::ROLE_LABELS[w.role]
              }
            },
            children: []
          }
          nodes_by_id[node.id] = entry

          if node.parent_id && nodes_by_id[node.parent_id]
            nodes_by_id[node.parent_id][:children] << entry
          else
            roots << entry
          end
        end

        roots
      end
    end
  end
end
