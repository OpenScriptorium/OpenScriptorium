// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import dafRenderer from "daf-renderer"

export default class extends Controller {
  static targets = ["headerLabel", "marginsLabel"]

  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"

    const marginsSaved = this.getCookie("daf_margins") === "on"
    const marginsCheckbox = this.element.querySelector("input[name='daf_margins']")
    if (marginsCheckbox) marginsCheckbox.checked = marginsSaved

    if (saved === "vilna") {
      document.fonts.ready.then(() => {
        setTimeout(() => this.renderVilna(), 100)
      })
      if (marginsSaved) this.showMargins()
    } else {
      this.showSimple()
    }
  }

  toggle() {
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    const mode = checkbox?.checked ? "vilna" : "simple"
    this.setCookie("daf_layout", mode, 365)

    if (mode === "vilna") {
      if (!this.rendered) {
        this.renderVilna()
      }
      this.showVilna()
    } else {
      this.showSimple()
    }
  }

  renderVilna() {
    const dataEl = document.getElementById("daf-data")
    const container = document.getElementById("daf-vilna-wrapper")
    if (!dataEl || !container) return

    const data = JSON.parse(dataEl.textContent)

    try {
      const renderer = dafRenderer("#daf-container")
      setTimeout(() => {
        renderer.render(data.gemara, data.rashi, data.tosafot, "a")
        this.rendered = true
        this.showVilna()
      }, 50)
    } catch (e) {
      console.error("daf-renderer error:", e)
      this.showSimple()
    }
  }

  toggleMargins() {
    const checkbox = this.element.querySelector("input[name='daf_margins']")
    const on = checkbox?.checked
    this.setCookie("daf_margins", on ? "on" : "", 365)
    if (on) {
      this.showMargins()
    } else {
      this.hideMargins()
    }
  }

  showMargins() {
    document.querySelectorAll(".daf-margin-strip").forEach(el => el.style.display = "")
  }

  hideMargins() {
    document.querySelectorAll(".daf-margin-strip").forEach(el => el.style.display = "none")
  }

  showVilna() {
    const container = document.getElementById("daf-vilna-wrapper")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = ""
    if (simple) simple.style.display = "none"
    if (this.hasHeaderLabelTarget) {
      this.headerLabelTarget.textContent = this.headerLabelTarget.dataset.vilnaLabel
    }
    if (this.hasMarginsLabelTarget) {
      this.marginsLabelTarget.hidden = false
    }
    // Restore margins if cookie says on
    if (this.getCookie("daf_margins") === "on") this.showMargins()
  }

  showSimple() {
    const container = document.getElementById("daf-vilna-wrapper")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = "none"
    if (simple) simple.style.display = ""
    if (this.hasHeaderLabelTarget) {
      this.headerLabelTarget.textContent = this.headerLabelTarget.dataset.simpleLabel
    }
    if (this.hasMarginsLabelTarget) {
      this.marginsLabelTarget.hidden = true
    }
    this.hideMargins()
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
