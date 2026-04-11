// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import dafRenderer from "daf-renderer"

export default class extends Controller {
  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"

    if (saved === "vilna") {
      document.fonts.ready.then(() => {
        setTimeout(() => this.renderVilna(), 100)
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
    const container = document.getElementById("daf-container")
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

  showVilna() {
    const container = document.getElementById("daf-container")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = ""
    if (simple) simple.style.display = "none"
  }

  showSimple() {
    const container = document.getElementById("daf-container")
    const simple = document.getElementById("daf-simple")
    if (container) container.style.display = "none"
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
