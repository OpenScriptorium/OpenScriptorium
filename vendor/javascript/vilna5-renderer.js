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
  dafEl.style.cssText = 'max-width:660px;margin:0 auto;'
  container.appendChild(dafEl)

  const daf = dafRenderer(dafEl, { contentWidth: '660px' })
  daf.render(gemara, rashi, tosafot, amud)

  // Margin references + other commentaries below
  const extras = document.createElement('div')
  extras.style.cssText = 'max-width:660px;margin:1rem auto 0;direction:rtl;'
  container.appendChild(extras)

  const sections = []
  if (einMishpat) sections.push({ title: 'עין משפט / נר מצוה', content: einMishpat, font: 'Rashi', size: '10px' })
  if (mesoretHaShas) sections.push({ title: 'מסורת הש״ס', content: mesoretHaShas, font: 'Rashi', size: '10px' })
  if (otherCommentaries) sections.push({ title: 'Other Commentaries', content: otherCommentaries, font: 'Rashi', size: '11px' })

  sections.forEach(sec => {
    const details = document.createElement('details')
    details.style.cssText = 'border-top:1px solid var(--color-rule,#ccc);padding:0.5rem 0;'

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
