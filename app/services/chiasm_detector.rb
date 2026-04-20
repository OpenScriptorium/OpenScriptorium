# Detects chiastic (A-B-C-B'-A') structures in biblical passages.
#
# A chiasm is a literary pattern where themes/words mirror each other:
#   A: "In the beginning God created"
#   B: "the heavens"
#   B': "and the earth"
#   A': "God finished his work"
#
# Algorithm:
# 1. Extract lemma sequences for a passage range
# 2. Build a lemma co-occurrence matrix (which lemmas repeat?)
# 3. For each pair of repeated lemmas, check if they mirror symmetrically
# 4. Score by number of mirrored pairs and structural quality
# 5. Return passages with high chiasm scores

class ChiasmDetector
  MIN_PAIRS = 2      # Minimum mirrored pairs to qualify
  MIN_SCORE = 0.05   # Minimum normalized score (lenient — let UI filter)

  # Detect chiasms in a range of work_units
  # Returns array of {center:, pairs:, score:, verses:}
  def detect(canonical_work_id:, start_ord:, end_ord:)
    # Get all lemmas in order across the range
    units = load_units(canonical_work_id, start_ord, end_ord)
    return [] if units.size < 4

    # Extract lemma sequence with verse positions
    sequence = extract_sequence(units)
    return [] if sequence.size < 6

    # Find repeated lemmas
    lemma_positions = build_position_map(sequence)
    repeated = lemma_positions.select { |_, positions| positions.size >= 2 }
    return [] if repeated.size < MIN_PAIRS

    # Find mirrored pairs
    chiasms = find_chiasms(sequence, repeated)
    chiasms.select { |c| c[:score] >= MIN_SCORE }
  end

  # Quick scan: detect chiasms within a single chapter
  def scan_chapter(canonical_work_id:, chapter:)
    refs = CanonicalRef.where(canonical_work_id: canonical_work_id)
                       .where("hierarchy[1] = ?", chapter)
                       .order(:ord)
    return [] if refs.empty?

    detect(
      canonical_work_id: canonical_work_id,
      start_ord: refs.first.ord,
      end_ord: refs.last.ord
    )
  end

  private

  def load_units(canonical_work_id, start_ord, end_ord)
    WorkUnit.joins(:canonical_ref, :work)
            .where(canonical_refs: { canonical_work_id: canonical_work_id })
            .where("canonical_refs.ord BETWEEN ? AND ?", start_ord, end_ord)
            .where(works: { slug: %w[wlc nestle1904] })
            .order("canonical_refs.ord")
            .includes(:canonical_ref)
            .to_a
  end

  def extract_sequence(units)
    sequence = []
    units.each do |wu|
      citation = wu.canonical_ref.sbl_citation

      # Get content-word lemmas (skip prepositions, conjunctions, articles)
      lemmas = Word.where(work_unit_id: wu.id)
                   .where.not(lemma_id: nil)
                   .joins(:lemma)
                   .order(:position)
                   .pluck("lemmas.normalized")

      lemmas.each do |lemma|
        sequence << { lemma: lemma, verse: citation, position: sequence.size }
      end
    end
    sequence
  end

  def build_position_map(sequence)
    map = Hash.new { |h, k| h[k] = [] }
    sequence.each_with_index do |entry, idx|
      map[entry[:lemma]] << idx
    end
    map
  end

  def find_chiasms(sequence, repeated)
    n = sequence.size
    results = []
    max_radius = [n / 2, 40].min # Cap search radius to prevent OOM

    # Sample center points — every few positions to reduce work
    step = [n / 80, 1].max
    start_pos = [max_radius, 3].min
    end_pos = n - start_pos - 1
    centers = (start_pos..end_pos).step(step).to_a

    centers.each do |center|
      pairs = []

      repeated.each do |lemma, positions|
        # Only check positions within radius of center
        before = positions.select { |p| p < center && center - p <= max_radius }
        after = positions.select { |p| p > center && p - center <= max_radius }
        next if before.empty? || after.empty?

        # Find best mirror for the closest before-position
        before.sort.reverse_each do |b_pos|
          dist = center - b_pos
          # Look for a matching after-position at similar distance
          best = after.min_by { |a| (a - center - dist).abs }
          mirror_dist = best - center
          tolerance = [dist * 0.35, 3].max
          if (mirror_dist - dist).abs <= tolerance
            pairs << {
              lemma: lemma,
              first_pos: b_pos,
              second_pos: best,
              first_verse: sequence[b_pos][:verse],
              second_verse: sequence[best][:verse],
              symmetry: 1.0 - (mirror_dist - dist).abs.to_f / [dist, 1].max
            }
            break
          end
        end
      end

      next if pairs.size < MIN_PAIRS

      avg_symmetry = pairs.sum { |p| p[:symmetry] } / pairs.size
      score = (pairs.size.to_f / [n * 0.1, 1].max) * avg_symmetry

      results << {
        center: center,
        center_verse: sequence[center][:verse],
        pairs: pairs.sort_by { |p| p[:first_pos] },
        score: score.round(3),
        span: "#{sequence.first[:verse]}–#{sequence.last[:verse]}"
      }
    end

    deduplicate_chiasms(results.sort_by { |c| -c[:score] })
  end

  def deduplicate_chiasms(sorted)
    kept = []
    sorted.each do |chiasm|
      # Skip if too close to an already-kept chiasm
      next if kept.any? { |k| (k[:center] - chiasm[:center]).abs < 5 }
      kept << chiasm
      break if kept.size >= 5
    end
    kept
  end
end
