class CreateBibleSynonyms < ActiveRecord::Migration[8.1]
  # Table-driven synonym expansion for Bible English. Instead of a
  # Postgres tsearch dictionary (which requires filesystem access to
  # tsearch_data), we use a lookup table and a SQL function that
  # rewrites query text before it hits websearch_to_tsquery.
  #
  # This handles British/American spelling variants (honour→honor),
  # archaic pronouns (thy→your, thou→you), and KJV verb forms
  # (hath→has, saith→says, loveth→loves).

  def up
    create_table :bible_synonyms, id: false do |t|
      t.string :source, null: false
      t.string :target, null: false
      t.index :source, unique: true
    end

    # Populate synonym pairs
    pairs = [
      # British → American
      %w[honour honor], %w[honoured honored], %w[honoureth honors], %w[honouring honoring],
      %w[favour favor], %w[favoured favored], %w[favoureth favors],
      %w[behaviour behavior], %w[colour color],
      %w[neighbour neighbor], %w[neighbours neighbors],
      %w[saviour savior], %w[saviours saviors],
      %w[judgement judgment], %w[judgements judgments],
      %w[labour labor], %w[laboured labored], %w[labourers laborers],
      %w[defence defense], %w[offence offense], %w[offences offenses],
      # Archaic pronouns
      %w[thy your], %w[thee you], %w[thou you], %w[ye you],
      %w[thine your], %w[thyself yourself],
      # Archaic verb forms
      %w[hast have], %w[hath has], %w[doth does], %w[dost do],
      %w[shalt shall], %w[wilt will],
      %w[saith says], %w[doeth does], %w[goeth goes], %w[cometh comes],
      %w[maketh makes], %w[giveth gives], %w[loveth loves], %w[liveth lives],
      %w[abideth abides], %w[seeketh seeks], %w[keepeth keeps], %w[taketh takes],
      %w[knoweth knows], %w[believeth believes], %w[receiveth receives],
      %w[passeth passes], %w[heareth hears], %w[leadeth leads],
      %w[bringeth brings], %w[turneth turns], %w[endureth endures],
      %w[sendeth sends], %w[answereth answers],
      # Archaic adverbs/conjunctions
      %w[wherefore why], %w[unto to],
      %w[whosoever whoever], %w[whatsoever whatever], %w[whomsoever whomever],
      %w[howbeit however], %w[peradventure perhaps], %w[verily truly],
      # Common archaic verbs
      %w[beseech implore], %w[wroth angry],
      %w[smite strike], %w[smote struck], %w[slew killed],
      %w[begat fathered], %w[begotten born],
    ]

    pairs.each do |source, target|
      execute "INSERT INTO bible_synonyms (source, target) VALUES (#{quote(source)}, #{quote(target)})"
    end

    # SQL function: expand synonyms in a query string.
    # Replaces each word with its synonym (if one exists), preserving
    # words that have no synonym. Runs in ~0.1ms for typical queries.
    execute <<~'SQL'
      CREATE OR REPLACE FUNCTION expand_bible_synonyms(query text)
      RETURNS text AS $$
        SELECT string_agg(COALESCE(s.target, w.word), ' ' ORDER BY w.ord)
        FROM unnest(string_to_array(lower(query), ' ')) WITH ORDINALITY AS w(word, ord)
        LEFT JOIN bible_synonyms s ON s.source = w.word
      $$ LANGUAGE sql STABLE;
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS expand_bible_synonyms(text);"
    drop_table :bible_synonyms, if_exists: true
  end

  private

  def quote(s)
    ActiveRecord::Base.connection.quote(s)
  end
end
