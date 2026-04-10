import { Controller } from "@hotwired/stimulus"

// Red-letter / words-of-Christ toggle with optional accessibility
// underline. Cookie values: "" (off), "on" (color only), "accessible"
// (color + underline). The CSS uses [data-red-letter] for color and
// [data-red-letter="accessible"] for the underline addition.
export default class extends Controller {
  static targets = ["underlineLabel"]

  connect() {
    const saved = this.getCookie("red_letter")
    const main = this.element.querySelector("input[name='red_letter']")
    const underline = this.element.querySelector("input[name='red_letter_underline']")
    if (main) main.checked = saved === "on" || saved === "accessible"
    if (underline) underline.checked = saved === "accessible"
    this.setArticle(saved)
    this.showUnderlineOption(main?.checked)
  }

  apply() {
    const main = this.element.querySelector("input[name='red_letter']")?.checked || false
    const underline = this.element.querySelector("input[name='red_letter_underline']")?.checked || false
    const mode = main ? (underline ? "accessible" : "on") : ""
    this.setArticle(mode)
    this.setCookie("red_letter", mode, 365)
    this.showUnderlineOption(main)
  }

  toggleUnderline() {
    const underline = this.element.querySelector("input[name='red_letter_underline']")?.checked || false
    const mode = underline ? "accessible" : "on"
    this.setArticle(mode)
    this.setCookie("red_letter", mode, 365)
  }

  showUnderlineOption(visible) {
    if (this.hasUnderlineLabelTarget) {
      this.underlineLabelTarget.classList.toggle("hidden", !visible)
    }
  }

  setArticle(mode) {
    const article = document.querySelector("article")
    if (!article) return
    if (mode === "accessible") {
      article.setAttribute("data-red-letter", "accessible")
    } else if (mode === "on") {
      article.setAttribute("data-red-letter", "")
    } else {
      article.removeAttribute("data-red-letter")
    }
  }

  getCookie(name) {
    const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))
    return match ? decodeURIComponent(match[1]) : ""
  }

  setCookie(name, value, days) {
    const expires = new Date(Date.now() + days * 24 * 60 * 60 * 1000).toUTCString()
    document.cookie = `${name}=${encodeURIComponent(value)}; expires=${expires}; path=/; samesite=lax`
  }
}
