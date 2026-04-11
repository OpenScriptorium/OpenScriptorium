// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import dafRenderer from "daf-renderer"

// Uses the daf-renderer library (MIT, TalmudLab) to create proper
// Vilna-style page layout with CSS float spacers. The library handles
// the complex spacer math that makes text wrap correctly around the
// center Gemara block.
export default class extends Controller {
  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = document.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"

    if (saved === "vilna") {
      this.renderVilna()
      this.showVilna()
    } else {
      this.showSimple()
    }
  }

  toggle() {
    const checkbox = document.querySelector("input[name='daf_layout']")
    const mode = checkbox?.checked ? "vilna" : "simple"
    this.setCookie("daf_layout", mode, 365)

    if (mode === "vilna") {
      if (!this.rendered) this.renderVilna()
      this.showVilna()
    } else {
      this.showSimple()
    }
  }

  renderVilna() {
    const container = document.getElementById("daf-rendered")
    const gemaraSource = document.getElementById("daf-gemara-source")
    const rashiSource = document.getElementById("daf-rashi-source")
    const tosafotSource = document.getElementById("daf-tosafot-source")

    if (!container || !gemaraSource) return

    const mainHTML = gemaraSource.innerHTML
    const innerHTML = rashiSource ? rashiSource.innerHTML : ""
    const outerHTML = tosafotSource ? tosafotSource.innerHTML : ""

    try {
      const renderer = dafRenderer("#daf-rendered", {
        contentWidth: "900px",
        mainWidth: "42%",
        padding: { vertical: "12px", horizontal: "20px" },
        fontFamily: {
          inner: "'Ezra SIL', 'SBL Hebrew', serif",
          outer: "'Ezra SIL', 'SBL Hebrew', serif",
          main: "'Ezra SIL', 'SBL Hebrew', serif"
        },
        direction: "rtl",
        fontSize: { main: "18", side: "13" },
        lineHeight: { main: "32", side: "22" }
      })

      renderer.render(mainHTML, innerHTML, outerHTML, "b")
      this.rendered = true
    } catch (e) {
      console.error("daf-renderer error:", e)
      // Fall back to simple view
      this.showSimple()
    }
  }

  showVilna() {
    const rendered = document.getElementById("daf-rendered")
    const simple = document.getElementById("daf-simple")
    if (rendered) rendered.style.display = ""
    if (simple) simple.style.display = "none"
  }

  showSimple() {
    const rendered = document.getElementById("daf-rendered")
    const simple = document.getElementById("daf-simple")
    if (rendered) rendered.style.display = "none"
    if (simple) simple.style.display = ""
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
// @license-end
