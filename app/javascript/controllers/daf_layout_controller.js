import { Controller } from "@hotwired/stimulus"

// Vilna daf layout controller.
//
// 1. Toggle between Vilna (3-column wrapping) and Simple (Gemara only)
// 2. Insert invisible floated spacer divs into the aside so that the
//    Tosafot text wraps around the center Gemara block. Without these
//    spacers, the Tosafot would flow straight across under the Rashi
//    float without leaving room for the Gemara in the center.
//
// The spacers use shape-outside: inset(0) to participate in the float
// flow, carving out the center column space.
export default class extends Controller {
  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"
    this.setLayout(saved)
    this.insertSpacers()
  }

  toggle() {
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    const mode = checkbox?.checked ? "vilna" : "simple"
    this.setLayout(mode)
    this.setCookie("daf_layout", mode, 365)
  }

  setLayout(mode) {
    const article = document.querySelector(".daf-page")
    if (article) {
      article.setAttribute("data-layout", mode)
    }
  }

  // Insert spacer divs into the aside to carve out center Gemara space.
  // The Gemara element sits in grid cell (2,2). We measure its height
  // and position, then insert left+right floated spacers into the aside
  // that match, so Tosafot text flows around the gap.
  insertSpacers() {
    const gemara = this.element.querySelector(".daf-gemara")
    const aside = this.element.querySelector(".daf-aside")
    if (!gemara || !aside) return

    // Wait for layout to settle
    requestAnimationFrame(() => {
      const gRect = gemara.getBoundingClientRect()
      const aRect = aside.getBoundingClientRect()

      // Height of the Gemara relative to the aside's top
      const topOffset = gRect.top - aRect.top
      const gHeight = gRect.height

      // Remove any existing spacers
      aside.querySelectorAll(".daf-spacer-right, .daf-spacer-left").forEach(s => s.remove())

      // Right spacer (pushes Tosafot away from center on the right/Rashi side)
      // This goes after the Rashi block
      const spacerR = document.createElement("div")
      spacerR.className = "daf-spacer-right"
      spacerR.style.height = `${topOffset + gHeight}px`

      // Left spacer (carves out center from Tosafot on the left side)
      const spacerL = document.createElement("div")
      spacerL.className = "daf-spacer-left"
      spacerL.style.height = `${topOffset + gHeight}px`

      // Insert spacers at the beginning of the Tosafot section
      const tosafot = aside.querySelector(".daf-tosafot-section")
      if (tosafot) {
        tosafot.prepend(spacerL)
      }

      // Insert right spacer after the Rashi block
      const rashi = aside.querySelector(".daf-rashi-block")
      if (rashi) {
        rashi.after(spacerR)
      }
    })
  }

  getCookie(name) {
    const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))
    return match ? decodeURIComponent(match[1]) : null
  }

  setCookie(name, value, days) {
    const expires = new Date(Date.now() + days * 24 * 60 * 60 * 1000).toUTCString()
    document.cookie = `${name}=${encodeURIComponent(value)}; expires=${expires}; path=/; samesite=lax`
  }
}
