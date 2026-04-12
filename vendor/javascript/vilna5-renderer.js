// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
//
// Vilna Talmud page renderer.
// Uses the stock daf-renderer (MIT, TalmudLab) for the center 3 columns
// (Gemara + Rashi + Tosafot). Margin references and other commentaries
// are displayed in collapsible sections below.
//
import dafRenderer from "daf-renderer"

export default function vilna5Render(container, {
  gemara, rashi, tosafot,
  einMishpat = '',
  mesoretHaShas = '',
  otherCommentaries = '',
  amud = 'a'
}) {
  container.innerHTML = ''

  // Center 3-column layout via daf-renderer
  const dafEl = document.createElement('div')
  dafEl.style.cssText = 'position:relative;max-width:660px;margin:0 auto;'
  container.appendChild(dafEl)

  const daf = dafRenderer(dafEl, { contentWidth: '660px' })
  daf.render(gemara, rashi, tosafot, amud)

  // Margin references + other commentaries below
  const extras = document.createElement('div')
  extras.style.cssText = 'max-width:660px;margin:1rem auto 0;direction:rtl;'
  container.appendChild(extras)

  // Mesoret HaShas — cross-references, always visible (not collapsible)
  if (mesoretHaShas) {
    const mesDiv = document.createElement('div')
    mesDiv.style.cssText = 'border-top:1px solid var(--color-rule,#ccc);padding:0.5rem 0;font-size:11px;font-family:Rashi,serif;line-height:1.6;'
    mesDiv.innerHTML = '<span style="font-family:serif;color:var(--color-ink-soft,#666);font-size:10px;">מסורת הש״ס: </span>' + mesoretHaShas
    extras.appendChild(mesDiv)
  }

  // Collapsible sections
  const sections = []
  if (einMishpat) sections.push({ title: 'עין משפט / נר מצוה', content: einMishpat, font: 'Rashi', size: '10px' })
  if (otherCommentaries) sections.push({ title: 'Other Commentaries', content: otherCommentaries, font: 'Rashi', size: '11px' })

  // Read persisted open/closed state from cookie
  const openSections = new Set(
    (document.cookie.match(/(?:^|; )daf_sections=([^;]*)/)?.[1] || '')
      .split(',').filter(Boolean)
  )

  function saveOpenSections() {
    const open = []
    extras.querySelectorAll('details[data-section]').forEach(d => {
      if (d.open) open.push(d.dataset.section)
    })
    const expires = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toUTCString()
    document.cookie = `daf_sections=${open.join(',')};expires=${expires};path=/;samesite=lax`
  }

  sections.forEach(sec => {
    const key = sec.title.replace(/[^a-zA-Z\u0590-\u05FF]/g, '').substring(0, 20)
    const details = document.createElement('details')
    details.style.cssText = 'border-top:1px solid var(--color-rule,#ccc);padding:0.5rem 0;'
    details.dataset.section = key
    if (openSections.has(key)) details.open = true
    details.addEventListener('toggle', saveOpenSections)

    const summary = document.createElement('summary')
    summary.style.cssText = 'cursor:pointer;font-size:12px;color:var(--color-ink-soft,#666);font-family:serif;'
    summary.textContent = sec.title
    details.appendChild(summary)

    const body = document.createElement('div')
    body.style.cssText = `font-family:${sec.font};font-size:${sec.size};line-height:1.5;text-align:justify;padding-top:0.5rem;`
    body.innerHTML = sec.content
    details.appendChild(body)

    extras.appendChild(details)
  })

  return { dafEl, extras }
}
// @license-end
