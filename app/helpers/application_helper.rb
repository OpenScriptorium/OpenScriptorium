module ApplicationHelper
  # Render a homonym number as a Roman numeral ("I", "II", "III", …)
  # for lemma headword disambiguation in the UI. Returns nil for blank
  # inputs so call sites don't have to gate on present?.
  ROMAN_NUMERALS = %w[I II III IV V VI VII VIII IX X].freeze
  def homonym_roman(n)
    return nil if n.nil?
    ROMAN_NUMERALS[n.to_i - 1] || n.to_s
  end

  def anchor_heading(text, id:, tag: :h2, **opts)
    cls = opts[:class] ? "group #{opts[:class]}" : "group"
    content_tag(tag, id: id, class: cls) do
      safe_join([
        text,
        content_tag(:a, "#", href: "##{id}",
          class: "opacity-0 group-hover:opacity-100 text-[var(--color-ink-soft)] hover:text-[var(--color-link)] no-underline ml-2 text-lg font-normal",
          "aria-hidden": "true")
      ])
    end
  end
end
