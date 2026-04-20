import { Controller } from "@hotwired/stimulus"

// Type-ahead scope picker for the search filter drawer.
// Searches works, books, and authors via /search/completions.
export default class extends Controller {
  static targets = ["input", "results"]

  search() {
    const query = this.inputTarget.value.trim()
    if (query.length < 2) {
      this.resultsTarget.classList.add("hidden")
      return
    }

    clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this._fetch(query), 200)
  }

  navigate(event) {
    const items = this.resultsTarget.querySelectorAll("[data-scope-item]")
    if (!items.length) return

    const current = this.resultsTarget.querySelector(".bg-\\[var\\(--color-rule\\)\\]")
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
      this.resultsTarget.classList.add("hidden")
    }
  }

  async _fetch(query) {
    try {
      const response = await fetch(`/search/completions?q=${encodeURIComponent(query)}`)
      const results = await response.json()
      this._render(results)
    } catch (e) {
      // Silently fail on network errors
    }
  }

  _render(results) {
    if (!results.length) {
      this.resultsTarget.classList.add("hidden")
      return
    }

    const icons = { book: "\u{1F4D7}", work: "\u{1F4D6}", author: "\u{1F464}" }

    this.resultsTarget.innerHTML = results.map((r, i) =>
      `<a href="#" data-scope-item
          data-type="${r.type}" data-slug="${r.slug}" data-label="${r.label}"
          class="flex items-center gap-2 px-3 py-2 text-sm font-serif
                 text-[var(--color-ink)] hover:bg-[var(--color-rule)]
                 cursor-pointer transition-colors"
          onclick="event.preventDefault(); this.closest('[data-controller=search-scope]').querySelector('[data-search-scope-target=input]').dispatchEvent(new CustomEvent('select-scope', { detail: { type: '${r.type}', slug: '${r.slug}', label: '${r.label}' } }))">
        <span class="text-xs">${icons[r.type] || ""}</span>
        <span class="flex-1">${r.label}</span>
        <span class="text-[10px] font-mono text-[var(--color-ink-soft)]">${r.badge || ""}</span>
      </a>`
    ).join("")

    this.resultsTarget.classList.remove("hidden")
  }

  _highlight(items, index) {
    items.forEach(item => item.classList.remove("bg-[var(--color-rule)]"))
    if (items[index]) items[index].classList.add("bg-[var(--color-rule)]")
  }

  // Called when a completion is selected
  connect() {
    this.inputTarget.addEventListener("select-scope", (event) => {
      const { type, slug, label } = event.detail
      this._applyScope(type, slug)
    })
  }

  _applyScope(type, slug) {
    const form = document.getElementById("search-form")
    if (!form) return

    // Remove existing hidden field for this type if any
    const paramName = type === "book" ? "book" : "work"
    const existing = form.querySelector(`input[name="${paramName}"]`)
    if (existing) existing.remove()

    // Add hidden field
    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = paramName
    hidden.value = slug
    form.appendChild(hidden)

    // Clear and hide results
    this.inputTarget.value = ""
    this.resultsTarget.classList.add("hidden")

    // Submit the form
    form.requestSubmit()
  }
}
