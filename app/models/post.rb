class Post < ApplicationRecord
  has_paper_trail
  has_rich_text :body

  before_validation :set_slug_from_title, if: -> { slug.blank? && title.present? }

  validates :title, presence: true
  validates :slug,  presence: true, uniqueness: true,
                    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                              message: "must be lowercase, hyphen-separated" }

  scope :published, -> {
    where.not(published_at: nil).where("published_at <= ?", Time.current)
  }
  scope :recent, -> { order(published_at: :desc, created_at: :desc) }

  def published?
    published_at.present? && published_at <= Time.current
  end

  def to_param = slug

  private

  def set_slug_from_title
    self.slug = title.to_s.downcase
                     .gsub(/[^\p{Alnum}\s-]/, "")
                     .gsub(/\s+/, "-")
                     .gsub(/-+/, "-")
                     .gsub(/\A-|-\z/, "")
  end
end
