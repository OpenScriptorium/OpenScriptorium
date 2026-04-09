module ReadingThemeHelper
  # Server-side mirror of `reading_theme_controller.js` so the layout
  # can emit an inline `style="--color-page: …"` block on the <html>
  # element. Without this, users with a non-default `reading_theme`
  # cookie see a flash of the default theme on every page load before
  # the Stimulus controller connects and applies the cookie.
  #
  # Stops MUST stay in sync with `LIGHT_STOPS` / `DARK_STOPS` in the JS
  # controller. The slider hard-flips at exactly 0.5 because no
  # continuous interpolation between Solarized Light and Dark can
  # maintain WCAG-AA contrast through the medium-luminance middle.
  LIGHT_STOPS = [
    [0.00, [255, 255, 255], [ 26,  26,  26]].freeze,   # black on white
    [0.25, [253, 246, 227], [  7,  54,  66]].freeze,   # Solarized base3 / base02
    [0.50, [238, 232, 213], [101, 123, 131]].freeze    # Solarized base2 / base00 — low-contrast light edge
  ].freeze

  DARK_STOPS = [
    [0.50, [  7,  54,  66], [131, 148, 150]].freeze,   # Solarized base02 / base0  — low-contrast dark edge
    [0.75, [  0,  43,  54], [147, 161, 161]].freeze,   # Solarized base03 / base1
    [1.00, [  0,   0,   0], [255, 255, 255]].freeze    # white on black
  ].freeze

  LINK_LIGHT = [ 31,  77, 138].freeze
  LINK_DARK  = [122, 176, 232].freeze
  ACC_LIGHT  = [107,  52,  16].freeze
  ACC_DARK   = [212, 165, 116].freeze

  # Returns an inline-style string of CSS custom properties for the
  # given slider value (0..100), or nil if the cookie is unset (in
  # which case the existing `dark` class behavior takes over).
  def reading_theme_inline_style
    raw = cookies[:reading_theme]
    return nil if raw.blank?

    v = raw.to_i.clamp(0, 100)
    t = v / 100.0

    bg, fg   = color_at(t)
    ink_soft = lerp_rgb(fg, bg, 0.35)
    rule     = lerp_rgb(bg, fg, 0.10)
    link     = lerp_rgb(LINK_LIGHT, LINK_DARK, t)
    accent   = lerp_rgb(ACC_LIGHT,  ACC_DARK,  t)

    [
      "--color-page: #{rgb_css(bg)}",
      "--color-ink: #{rgb_css(fg)}",
      "--color-ink-soft: #{rgb_css(ink_soft)}",
      "--color-rule: #{rgb_css(rule)}",
      "--color-link: #{rgb_css(link)}",
      "--color-accent: #{rgb_css(accent)}"
    ].join("; ")
  end

  private

  def color_at(t)
    stops = t < 0.5 ? LIGHT_STOPS : DARK_STOPS
    stops.each_cons(2) do |(t0, bg0, fg0), (t1, bg1, fg1)|
      next unless t >= t0 && t <= t1
      seg = t1 == t0 ? 0 : (t - t0) / (t1 - t0)
      return [lerp_rgb(bg0, bg1, seg), lerp_rgb(fg0, fg1, seg)]
    end
    last = stops.last
    [last[1], last[2]]
  end

  def lerp_rgb(a, b, t)
    [
      (a[0] + (b[0] - a[0]) * t).round,
      (a[1] + (b[1] - a[1]) * t).round,
      (a[2] + (b[2] - a[2]) * t).round
    ]
  end

  def rgb_css(c)
    "rgb(#{c[0]}, #{c[1]}, #{c[2]})"
  end
end
