class PassageAliasName < ApplicationRecord
  belongs_to :passage_alias

  validates :name, presence: true

  # Common prefixes users add that the alias might not have
  STRIP_PREFIXES = /\A(the\s+|parable\s+of\s+(the\s+)?|story\s+of\s+(the\s+)?|book\s+of\s+(the\s+)?|psalm\s+of\s+(the\s+)?|song\s+of\s+(the\s+)?|prayer\s+of\s+(the\s+)?)/i

  scope :matching, ->(query) {
    stripped = query.sub(STRIP_PREFIXES, "")
    where(
      "LOWER(name) = LOWER(:q) OR LOWER(name) LIKE LOWER(:paren) OR LOWER(name) LIKE LOWER(:contains) OR LOWER(name) = LOWER(:stripped) OR LOWER(name) LIKE LOWER(:stripped_paren)",
      q: query, paren: "#{query} (%", contains: "%#{stripped}%", stripped: stripped, stripped_paren: "#{stripped} (%"
    )
  }

  scope :fuzzy, ->(query) {
    where("name % ?", query).order(Arel.sql("similarity(name, #{connection.quote(query)}) DESC"))
  }
end
