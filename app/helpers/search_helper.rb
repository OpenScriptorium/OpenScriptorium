module SearchHelper
  ORIGINAL_LANGUAGE_CODES_FOR_SEARCH = %w[he arc el el-koine].to_set.freeze

  def original_language_search_result?(result)
    ORIGINAL_LANGUAGE_CODES_FOR_SEARCH.include?(result[:language])
  end

  # Render a search-result snippet. Original-language results
  # (Hebrew/Greek) get word-span rendering so each word becomes a
  # clickable link to its lemma page (and triggers the popover via the
  # word-popover Stimulus controller mounted on the results container).
  # English/Latin results keep the existing FTS-highlighted headline
  # since their `words` rows follow source-language order rather than
  # surface order — making English-word clickability a separate
  # interlinear feature, not a search-result fix.
  def render_search_result_body(result)
    if original_language_search_result?(result)
      words = Word.where(work_unit_id: result[:id])
                  .order(:position)
                  .includes(:lemma)
                  .to_a
      if words.any?
        return render_word_spans(words)
      end
    end
    sanitize(result[:headline].to_s, tags: %w[mark], attributes: [])
  end

  # Tailwind classes for the search-result snippet, language-aware so
  # Hebrew/Greek render in their proper fonts/sizes.
  def search_result_body_classes(result)
    base = "leading-relaxed text-[var(--color-ink)] [&>mark]:bg-yellow-200 [&>mark]:dark:bg-yellow-800/50 [&>mark]:rounded-sm [&>mark]:px-0.5"
    case result[:language]
    when "he", "arc"
      "font-hebrew text-base #{base}"
    when "el", "el-koine"
      "font-greek text-base #{base}"
    else
      "font-serif text-sm #{base}"
    end
  end

  def rtl_search_result?(result)
    %w[he arc].include?(result[:language])
  end
end
