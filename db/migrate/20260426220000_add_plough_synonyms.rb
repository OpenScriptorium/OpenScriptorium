class AddPloughSynonyms < ActiveRecord::Migration[8.1]
  # Adds bidirectional plough↔plow spelling variants to bible_synonyms.
  # Without this, "plowshare" finds Isa 2:4 / Joel 3:10 / Micah 4:3 (BSB)
  # but "ploughshare" finds only Joel 3:10 (WEBBE), because the FTS
  # query rewriter doesn't bridge the spellings.
  #
  # Same direction-aware pattern as the existing British/American pairs
  # (honour↔honor, colour↔colour, etc.).

  PAIRS = [
    %w[plough plow],
    %w[ploughs plows],
    %w[ploughed plowed],
    %w[ploughing plowing],
    %w[plougher plower],
    %w[ploughman plowman],
    %w[ploughmen plowmen],
    %w[ploughshare plowshare],
    %w[ploughshares plowshares],
  ].freeze

  def up
    PAIRS.each do |source, target|
      [[source, target], [target, source]].each do |s, t|
        execute(
          "INSERT INTO bible_synonyms (source, target) VALUES " \
          "(#{ActiveRecord::Base.connection.quote(s)}, #{ActiveRecord::Base.connection.quote(t)}) " \
          "ON CONFLICT (source) DO NOTHING"
        )
      end
    end
  end

  def down
    sources = PAIRS.flat_map { |a, b| [a, b] }
    quoted = sources.map { |s| ActiveRecord::Base.connection.quote(s) }.join(", ")
    execute "DELETE FROM bible_synonyms WHERE source IN (#{quoted})"
  end
end
