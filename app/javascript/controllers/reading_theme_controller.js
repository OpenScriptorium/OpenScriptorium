// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Reading-theme slider.
//
// Maps a 0..100 slider value to a (background, foreground) pair via a
// piecewise interpolation through four named stops:
//
//   0%   black on white
//   33%  Solarized Light
//   67%  Solarized Dark
//   100% white on black
//
// **Contrast invariant.** Naive linear interpolation between Solarized
// Light and Dark crosses through a medium-tone middle that has nearly
// zero contrast — unreadable. To avoid that, the middle segment uses a
// hard flip at exactly 50%: 0..50% interpolates between light themes
// only, and 50..100% interpolates between dark themes only. The light
// side ends on Solarized base2/base01 (still high-contrast light) and
// the dark side begins on Solarized base02/base1 (still high-contrast
// dark), so there's a single visible click where the theme inverts but
// no point in the slider's range produces an unreadable cell.
//
// All four computed colors (page, ink, ink-soft, rule) plus link/accent
// are written to CSS custom properties on <html>, where the rest of the
// app's existing `var(--color-page)` etc. references pick them up
// automatically. The chosen value is persisted in a `reading_theme`
// cookie for one year.
//
// Note: setting the slider for the first time can cause a brief flash
// on subsequent navigations because the colors aren't applied until
// Stimulus connects. A future enhancement would emit an inline
// <style> tag from the layout based on the cookie to avoid FOUC.
// Light-side stops (used for t < 0.5). The 0.50 stop is the "lightest"
// readable light theme — Solarized base2 / base01. When the slider
// crosses to >= 0.5, the dark stops kick in instead. This hard split at
// 50% is intentional: any continuous interpolation between Solarized
// Light and Dark would pass through a medium-tone middle with
// near-zero contrast.
const LIGHT_STOPS = [
  [0.00, [255, 255, 255], [ 26,  26,  26]],   // black on white
  [0.25, [253, 246, 227], [  7,  54,  66]],   // Solarized base3 / base02
  [0.50, [238, 232, 213], [101, 123, 131]]    // Solarized base2 / base00 — low-contrast light edge
]

const DARK_STOPS = [
  [0.50, [  7,  54,  66], [131, 148, 150]],   // Solarized base02 / base0  — low-contrast dark edge
  [0.75, [  0,  43,  54], [147, 161, 161]],   // Solarized base03 / base1
  [1.00, [  0,   0,   0], [255, 255, 255]]    // white on black
]

const LINK_LIGHT = [ 31,  77, 138]   // navy
const LINK_DARK  = [122, 176, 232]   // sky
const ACC_LIGHT  = [107,  52,  16]   // brick
const ACC_DARK   = [212, 165, 116]   // ochre

function lerp(a, b, t)    { return Math.round(a + (b - a) * t) }
function lerpRgb(a, b, t) { return [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)] }
function rgbCss(c)        { return `rgb(${c[0]}, ${c[1]}, ${c[2]})` }

function interpolateStops(stops, t) {
  for (let i = 0; i < stops.length - 1; i++) {
    const [t0, bg0, fg0] = stops[i]
    const [t1, bg1, fg1] = stops[i + 1]
    if (t >= t0 && t <= t1) {
      const seg = (t1 === t0) ? 0 : (t - t0) / (t1 - t0)
      return { bg: lerpRgb(bg0, bg1, seg), fg: lerpRgb(fg0, fg1, seg) }
    }
  }
  const last = stops[stops.length - 1]
  return { bg: last[1], fg: last[2] }
}

function colorAt(t) {
  // Hard split at exactly 50%: < 0.5 uses light themes, >= 0.5 uses
  // dark themes. The slider passes through a single visible flip but
  // never lands on a low-contrast intermediate.
  return t < 0.5 ? interpolateStops(LIGHT_STOPS, t)
                 : interpolateStops(DARK_STOPS,  t)
}

export default class extends Controller {
  static targets = ["slider"]

  connect() {
    this.lastSide = null      // "light" | "dark" — which side of 50 we last applied
    this.cliffLockUntil = 0   // timestamp ms; ignore further cliff crossings until then
    this.rafPending = false   // rAF coalesce flag
    this.pendingValue = null

    const stored = this.readCookie()
    const initial = (stored != null) ? stored : parseInt(this.sliderTarget.value, 10)
    this.sliderTarget.value = initial
    this.lastSide = initial >= 50 ? "dark" : "light"
    this.apply(initial / 100)
    this.updateValueText(initial)
  }

  update(event) {
    const v = parseInt(this.sliderTarget.value, 10)
    this.pendingValue = v
    if (this.rafPending) return
    this.rafPending = true
    requestAnimationFrame(() => this.commit())
  }

  commit() {
    this.rafPending = false
    const v = this.pendingValue
    if (v == null) return

    const newSide = v >= 50 ? "dark" : "light"
    const now = performance.now()

    // Cliff debounce: if the user just crossed the flip line, ignore
    // attempts to cross back for 250ms. This stops the slider from
    // strobing if the mouse jitters across 49/50.
    if (newSide !== this.lastSide && now < this.cliffLockUntil) {
      // Snap the slider value back to the safe side rather than
      // letting it sit on the locked-out value.
      this.sliderTarget.value = (this.lastSide === "light") ? 49 : 50
      return
    }

    if (newSide !== this.lastSide) {
      this.cliffLockUntil = now + 250
      this.lastSide = newSide
    }

    this.apply(v / 100)
    this.updateValueText(v)
    this.writeCookie(v)
  }

  updateValueText(v) {
    let label
    if (v < 17)      label = "Light"
    else if (v < 33) label = "Warm light"
    else if (v < 50) label = "Warm"
    else if (v < 67) label = "Dark"
    else if (v < 83) label = "Deep dark"
    else              label = "High contrast dark"
    this.sliderTarget.setAttribute("aria-valuetext", label)
  }

  apply(t) {
    const { bg, fg } = colorAt(t)
    // ink-soft: pulled 35% from fg toward bg (a quieter version of fg)
    const inkSoft = lerpRgb(fg, bg, 0.35)
    // rule: pulled 10% from bg toward fg (a faint border line)
    const rule    = lerpRgb(bg, fg, 0.10)
    // link/accent: simple linear lerp through the whole slider range —
    // both colors are already legible against any computed bg/fg pair.
    const link    = lerpRgb(LINK_LIGHT, LINK_DARK, t)
    const accent  = lerpRgb(ACC_LIGHT,  ACC_DARK,  t)

    const root = document.documentElement
    root.style.setProperty("--color-page",     rgbCss(bg))
    root.style.setProperty("--color-ink",      rgbCss(fg))
    root.style.setProperty("--color-ink-soft", rgbCss(inkSoft))
    root.style.setProperty("--color-rule",     rgbCss(rule))
    root.style.setProperty("--color-link",     rgbCss(link))
    root.style.setProperty("--color-accent",   rgbCss(accent))
  }

  readCookie() {
    const m = document.cookie.match(/(?:^|; )reading_theme=(\d+)/)
    return m ? parseInt(m[1], 10) : null
  }

  writeCookie(v) {
    document.cookie = `reading_theme=${v}; path=/; max-age=31536000; samesite=lax`
  }
}
// @license-end
