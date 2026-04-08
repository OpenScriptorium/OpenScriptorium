module SvgHelper
  # Inline an SVG file from app/assets/images/letters/ into the rendered
  # HTML so it can inherit `currentColor` from the parent and respond to
  # theme changes (light/dark mode).
  #
  # Usage in views:
  #
  #     <%= inline_svg "dropcap-S", class: "dropcap-nav" %>
  #
  # The named SVG file is read once per process and cached in memory; the
  # CSS class (if any) is injected into the root <svg> element.
  def inline_svg(name, **opts)
    css_class = opts[:class]
    raw = SvgHelper.cached_svg(name)

    # Strip XML/DOCTYPE preamble — they're invalid inside HTML <body>
    raw = raw.sub(/\A<\?xml[^>]*\?>\s*/, "")
             .sub(/\A<!DOCTYPE[^>]*>\s*/, "")

    # Strip the intrinsic width/height attributes from the root <svg>.
    # potrace sets them in points (e.g. width="720pt") which compete with
    # CSS sizing. Without them the browser sizes the SVG entirely from
    # the CSS class + the viewBox aspect ratio.
    raw = raw.sub(/<svg([^>]*)>/) do
      attrs = $1.gsub(/\s+(?:width|height)="[^"]*"/, "")
      "<svg#{attrs}>"
    end

    if css_class
      raw = raw.sub(/<svg(\s)/, %(<svg class="#{ERB::Util.html_escape(css_class)}"\\1))
    end

    raw.html_safe
  end

  # Memoize file reads so each SVG is only loaded once per Rails process.
  @cache = {}
  @cache_mutex = Mutex.new

  def self.cached_svg(name)
    @cache_mutex.synchronize do
      @cache[name] ||= File.read(
        Rails.root.join("app/assets/images/letters/#{name}.svg")
      )
    end
  end

  def self.reset_cache!
    @cache_mutex.synchronize { @cache.clear }
  end
end
