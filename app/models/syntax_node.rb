class SyntaxNode < ApplicationRecord
  belongs_to :work
  belongs_to :work_unit
  belongs_to :parent, class_name: "SyntaxNode", optional: true
  belongs_to :import_run, optional: true

  has_many :children, class_name: "SyntaxNode", foreign_key: :parent_id, dependent: :destroy
  has_many :words

  scope :clauses, -> { where(node_class: "cl") }
  scope :phrases, -> { where(node_class: %w[ph np vp pp]) }
  scope :with_role, ->(role) { where(role: role) }
  scope :subjects, -> { with_role("s") }
  scope :predicates, -> { with_role("p") }
  scope :objects, -> { with_role("o") }

  # ltree queries — find all descendants of a node
  scope :descendants_of, ->(path) {
    where("path <@ ?", path)
  }

  # Find all ancestors of a node
  scope :ancestors_of, ->(path) {
    where("path @> ?", path)
  }

  # Find clauses containing a word with a given lemma in a specific role
  scope :with_lemma_in_role, ->(lemma_text, role) {
    clauses
      .joins("INNER JOIN syntax_nodes child ON child.path <@ syntax_nodes.path AND child.role = #{connection.quote(role)}")
      .joins("INNER JOIN words ON words.syntax_node_id = child.id")
      .joins("INNER JOIN lemmas ON lemmas.id = words.lemma_id")
      .where("lemmas.lemma = ? OR lemmas.normalized = ?", lemma_text, lemma_text)
      .distinct
  }

  ROLE_LABELS = {
    "s" => "Subject", "p" => "Predicate", "o" => "Object",
    "v" => "Verb", "vc" => "Copula",
    "io" => "Indirect Object", "c" => "Complement", "a" => "Adjunct",
    "pp" => "Prepositional Phrase", "adv" => "Adverbial",
    "appos" => "Apposition", "rel" => "Relative",
    "cond" => "Conditional", "temp" => "Temporal",
    "causal" => "Causal", "purp" => "Purpose", "result" => "Result",
    "topic" => "Topic"
  }.freeze

  def role_label
    ROLE_LABELS[role] || role&.titleize
  end
end
