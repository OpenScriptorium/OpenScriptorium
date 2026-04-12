// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import vilna5Render from "vilna5-renderer"

export default class extends Controller {
  static targets = ["headerLabel", "marginsLabel", "dafLabel"]

  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"

    if (saved === "vilna") {
      document.fonts.ready.then(() => {
        setTimeout(() => this.renderVilna(), 150)
      })
    } else {
      this.showSimple()
    }
  }

  toggle() {
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    const mode = checkbox?.checked ? "vilna" : "simple"
    this.setCookie("daf_layout", mode, 365)

    if (mode === "vilna") {
      // Immediately hide simple view while Vilna renders
      const simple = document.getElementById("daf-simple")
      if (simple) simple.style.display = "none"

      if (!this.rendered) {
        // Show container BEFORE rendering — daf-renderer needs visible
        // elements to measure text areas for spacer calculations
        const container = document.getElementById("daf-container")
        if (container) container.style.display = ""
        document.fonts.ready.then(() => {
          setTimeout(() => { this.renderVilna() }, 150)
        })
      } else {
        this.showVilna()
      }
    } else {
      this.showSimple()
    }
  }

  renderVilna() {
    const dataEl = document.getElementById("daf-data")
    const container = document.getElementById("daf-container")
    if (!dataEl || !container) return

    const data = JSON.parse(dataEl.textContent)

    try {
      this.vilna = vilna5Render(container, {
        gemara: data.gemara,
        rashi: data.rashi,
        tosafot: data.tosafot,
        einMishpat: data.ein_mishpat || '',
        otherCommentaries: data.other_commentaries || ''
      })
      this.rendered = true
      this.showVilna()
    } catch (e) {
      console.error("vilna5 render error:", e)
      this.showSimple()
    }
  }

  toggleXrefs() {
    const checkbox = this.element.querySelector("input[name='daf_xrefs']")
    const on = checkbox?.checked
    this.setCookie("daf_xrefs", on ? "on" : "off", 365)
    const el = document.getElementById("daf-xrefs")
    if (el) el.style.display = on ? "" : "none"
  }

  toggleMesoret() {
    const checkbox = this.element.querySelector("input[name='daf_mesoret']")
    const on = checkbox?.checked
    this.setCookie("daf_mesoret", on ? "on" : "off", 365)
    const el = document.getElementById("daf-mesoret")
    if (el) el.style.display = on ? "" : "none"
  }

  showVilna() {
    const container = document.getElementById("daf-container")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = ""
    if (simple) simple.style.display = "none"
    if (this.hasHeaderLabelTarget) {
      this.headerLabelTarget.textContent = this.headerLabelTarget.dataset.vilnaLabel
    }
    if (this.hasDafLabelTarget) {
      this.dafLabelTarget.textContent = this.dafLabelTarget.dataset.vilnaLabel
    }
    if (this.hasMarginsLabelTarget) {
      this.marginsLabelTarget.hidden = false
    }
  }

  showSimple() {
    const container = document.getElementById("daf-container")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = "none"
    if (simple) simple.style.display = ""
    if (this.hasHeaderLabelTarget) {
      this.headerLabelTarget.textContent = this.headerLabelTarget.dataset.simpleLabel
    }
    if (this.hasDafLabelTarget) {
      this.dafLabelTarget.textContent = this.dafLabelTarget.dataset.simpleLabel
    }
    if (this.hasMarginsLabelTarget) {
      this.marginsLabelTarget.hidden = true
    }
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
