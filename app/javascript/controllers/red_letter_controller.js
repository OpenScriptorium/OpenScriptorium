import { Controller } from "@hotwired/stimulus"

// Red-letter / words-of-Christ toggle. On/off only — uses the site's
// garnet accent color (#9b2226 light / #c84849 dark).
//
// Sets/removes `data-red-letter` on the nearest `<article>` so the
// CSS `.rl` class takes effect. Persists choice in `red_letter`
// cookie. Instant — no page reload needed.
export default class extends Controller {
  connect() {
    const saved = this.getCookie("red_letter") === "on"
    const checkbox = this.element.querySelector("input[name='red_letter']")
    if (checkbox) checkbox.checked = saved
    this.setArticle(saved)
  }

  apply() {
    const checked = this.element.querySelector("input[name='red_letter']")?.checked || false
    this.setArticle(checked)
    this.setCookie("red_letter", checked ? "on" : "", 365)
  }

  setArticle(on) {
    const article = document.querySelector("article")
    if (!article) return
    if (on) {
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
