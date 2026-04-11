module ApplicationHelper
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
