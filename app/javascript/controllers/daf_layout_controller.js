import { Controller } from "@hotwired/stimulus"

// Toggles the daf view between Vilna (3-column) and Simple (Gemara only).
// Persisted in a `daf_layout` cookie. The CSS uses [data-layout="simple"]
// to hide Rashi/Tosafot columns.
export default class extends Controller {
  connect() {
    const saved = this.getCookie("daf_layout") || "vilna"
    const checkbox = this.element.querySelector("input[name='daf_layout']")
    if (checkbox) checkbox.checked = saved === "vilna"
    this.setLayout(saved)
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

  getCookie(name) {
    const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))
    return match ? decodeURIComponent(match[1]) : null
  }

  setCookie(name, value, days) {
    const expires = new Date(Date.now() + days * 24 * 60 * 60 * 1000).toUTCString()
    document.cookie = `${name}=${encodeURIComponent(value)}; expires=${expires}; path=/; samesite=lax`
  }
}
