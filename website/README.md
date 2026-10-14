# QNotch website

The static landing page, built with Astro. No framework, no runtime dependencies: the interactive demo is plain TypeScript in `src/scripts/demo.ts`, styled after the app's dark theme in `src/styles/demo.css`.

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # static site in dist/
```

| File | What it is |
| --- | --- |
| `src/pages/index.astro` | The page: hero, numbers, hotkeys, privacy, FAQ |
| `src/components/Demo.astro` + `src/scripts/demo.ts` | The notch itself (pill, panel, tabs, terminal, scenarios) |
| `src/scripts/desktop.ts` + `src/styles/desktop.css` | The fake Windows around it: windows, taskbar, Start, calendar, tray menu, Explorer, Music, browser upload |

Rule for the demo: anything that looks clickable must work. If a control can't be backed by real behavior, remove it.
| `src/components/Features.astro` | The feature grid |
| `src/components/OpenSource.astro` | Extensions, the five slots, contributing |
| `src/icons.ts` | Stroke icons used everywhere |
| `og/og.html` | Source of the social preview `src/assets/og.png`; rerender with `node og/render.mjs` (needs Edge or Chrome) |
| `src/layouts/Base.astro` | The head: title, description, canonical, Open Graph and Twitter tags. Pass `noindex` for pages search engines should skip |
| `src/pages/404.astro` | The not-found page (`noindex`, left out of the sitemap) |
| `public/robots.txt` | Points crawlers at `sitemap-index.xml`, which `@astrojs/sitemap` writes on every build |

Search engines read the structured data (JSON-LD) at the top of `index.astro`: the app, the site and the FAQ. The FAQ part is built from the same `faq` list the page shows, so the two stay in sync. Only real page headings should use `<h1>` to `<h6>`; titles inside the demo's mock UI use `.qn-h`.

Keep claims on the page in line with the repo README: numbers, hotkeys and privacy statements come from there.
