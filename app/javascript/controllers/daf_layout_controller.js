// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import vilna5Render from "vilna5-renderer"

export default class extends Controller {
  static targets = ["headerLabel", "marginsLabel"]

  connect() {
    // Vilna layout temporarily disabled while being rebuilt
    const saved = "simple"
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    if (checkbox) {
      checkbox.checked = false
      checkbox.disabled = true
    }
    this.showSimple()
  }

  toggle() {
    const checkbox = this.element.querySelector("input[name='daf_layout']")
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
    const dataEl = document.getElementById("daf-data")
    const container = document.getElementById("daf-container")
    if (!dataEl || !container) return

    const data = JSON.parse(dataEl.textContent)

    try {
      vilna5Render(container, {
        gemara: data.gemara,
        rashi: data.rashi,
        tosafot: data.tosafot,
        marginInner: data.margin_inner || '',
        marginOuter: data.margin_outer || ''
      })
      this.rendered = true
      this.showVilna()
    } catch (e) {
      console.error("vilna5 render error:", e)
      this.showSimple()
    }
  }

  showVilna() {
    const container = document.getElementById("daf-container")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = ""
    if (simple) simple.style.display = "none"
    if (this.hasHeaderLabelTarget) {
      this.headerLabelTarget.textContent = this.headerLabelTarget.dataset.vilnaLabel
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
