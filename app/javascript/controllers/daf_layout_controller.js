// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import dafRenderer from "daf-renderer"

export default class extends Controller {
  connect() {
    // Wait for fonts to load before rendering — the spacer math
    // depends on accurate text measurements
    document.fonts.ready.then(() => this.render())
  }

  render() {
    const dataEl = document.getElementById("daf-data")
    if (!dataEl) return

    const data = JSON.parse(dataEl.textContent)
    const container = document.getElementById("daf-container")
    if (!container) return

    try {
      const renderer = dafRenderer("#daf-container", {
        contentWidth: "850px",
        mainWidth: "42%",
        padding: { vertical: "8px", horizontal: "14px" },
        fontFamily: { inner: "Rashi", outer: "Rashi", main: "Vilna" },
        direction: "rtl",
        fontSize: { main: "17", side: "12" },
        lineHeight: { main: "28", side: "19" }
      })

      setTimeout(() => {
        renderer.render(data.gemara, data.rashi, data.tosafot, "a")
      }, 50)
    } catch (e) {
      console.error("daf-renderer error:", e)
      // Fallback: just show the Gemara text
      container.innerHTML = `<div dir="rtl" style="font-family:Vilna,serif;font-size:17px;line-height:28px;">${data.gemara}</div>`
    }
  }

  getCookie(name) {
    const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))
    return match ? decodeURIComponent(match[1]) : null
  }
}
// @license-end
