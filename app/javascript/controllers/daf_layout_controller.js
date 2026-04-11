// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Toggles Vilna (with commentary) vs Simple (Gemara only).
export default class extends Controller {
  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = document.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"
    this.apply(saved)
  }

  toggle() {
    const checkbox = document.querySelector("input[name='daf_layout']")
    const mode = checkbox?.checked ? "vilna" : "simple"
    this.setCookie("daf_layout", mode, 365)
    this.apply(mode)
  }

  apply(mode) {
    document.querySelectorAll(".daf-rashi, .daf-tosafot").forEach(el => {
      el.style.display = mode === "vilna" ? "" : "none"
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
// @license-end
