import { Controller } from "@hotwired/stimulus"

// Autocomplete suggestions on the main search input.
// Shows lemma transliterations (type "aga" → ἀγάπη) and
// passage aliases (type "prodig" → Prodigal Son).
export default class extends Controller {
  static targets = ["input", "dropdown"]

  connect() {
    // Close on click outside
    document.addEventListener("click", (e) => {
      if (!this.element.contains(e.target)) {
        this.dropdownTarget.classList.add("hidden")
      }
    })
  }

  suggest() {
    const q = this.inputTarget.value.trim()
    if (q.length < 2) {
      this.dropdownTarget.classList.add("hidden")
      return
    }

    clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this._fetch(q), 250)
  }

  navigate(event) {
    const items = this.dropdownTarget.querySelectorAll("[data-suggest-item]")
    if (!items.length) return

    const current = this.dropdownTarget.querySelector(".bg-\\[var\\(--color-rule\\)\\]")
    let index = Array.from(items).indexOf(current)

    if (event.key === "ArrowDown") {
      event.preventDefault()
      index = Math.min(index + 1, items.length - 1)
      this._highlight(items, index)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      index = Math.max(index - 1, 0)
      this._highlight(items, index)
    } else if (event.key === "Enter" && index >= 0) {
      event.preventDefault()
      items[index].click()
    } else if (event.key === "Escape") {
      this.dropdownTarget.classList.add("hidden")
    }
  }

  async _fetch(query) {
    try {
      const response = await fetch(`/search/completions?q=${encodeURIComponent(query)}`)
      const results = await response.json()
      // Only show lemma and alias suggestions (not book/work/author)
      const relevant = results.filter(r => r.type === "lemma" || r.type === "alias")
      this._render(relevant)
    } catch (e) {
      // Silently fail
    }
  }

  _render(results) {
    if (!results.length) {
      this.dropdownTarget.classList.add("hidden")
      return
    }

    this.dropdownTarget.innerHTML = results.map(r => {
      const icon = r.type === "lemma" ? "&#x1F524;" : "&#x1F4D6;"
      const badgeColor = r.badge === "HE" ? "text-blue-600" : r.badge === "GR" ? "text-green-600" : "text-[var(--color-ink-soft)]"
      return `<a href="#" data-suggest-item
          class="flex items-center gap-2 px-3 py-2 text-sm
                 text-[var(--color-ink)] hover:bg-[var(--color-rule)]
                 cursor-pointer transition-colors border-b border-[var(--color-rule)] last:border-b-0"
          data-query="${this._escapeHtml(r.query || r.label)}">
        <span class="text-xs opacity-60">${icon}</span>
        <span class="flex-1 font-serif">${this._escapeHtml(r.label)}</span>
        <span class="text-xs text-[var(--color-ink-soft)]">${this._escapeHtml(r.detail || "")}</span>
        <span class="text-[10px] font-mono ${badgeColor}">${r.badge || ""}</span>
      </a>`
    }).join("")

    // Bind click handlers
    this.dropdownTarget.querySelectorAll("[data-suggest-item]").forEach(item => {
      item.addEventListener("click", (e) => {
        e.preventDefault()
        const query = item.getAttribute("data-query")
        this.inputTarget.value = query
        this.dropdownTarget.classList.add("hidden")
        this.inputTarget.form.requestSubmit()
      })
    })

    this.dropdownTarget.classList.remove("hidden")
  }

  _highlight(items, index) {
    items.forEach(item => item.classList.remove("bg-[var(--color-rule)]"))
    if (items[index]) items[index].classList.add("bg-[var(--color-rule)]")
  }

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str || ""
    return div.innerHTML
  }
}
