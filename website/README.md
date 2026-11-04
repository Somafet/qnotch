# QNotch website

The site and interactive demo describe both released apps. A switch in the hero picks Windows or Mac; `Base.astro` preselects the visitor's OS before the first paint (a `?os=mac` or `?os=windows` link overrides it, and the choice lasts for the tab). Content for one platform carries the `os-win` or `os-mac` class, and scripts listen for the `qnotch:os` event (`src/scripts/platform.ts`). The same page is also built at `/windows/` and `/mac/` for people searching for one platform ("notch for Windows", "MacBook notch app"). Those two have their own title, description, headline, an intro with the platform's facts, and only that platform's FAQ; their switch links to the other page instead of switching in place, and `?os=` doesn't apply. Describe each platform by what its app actually does: the [Mac README](../docs/macos/README.md) and [parity table](../docs/macos/parity.md) say what differs.

The Mac download link is resolved at build time from the newest stable `macos-v*` release on GitHub (set `GITHUB_TOKEN` to avoid rate limits), never from `/releases/latest`, which is Windows. If GitHub can't be reached, the build falls back to the release pinned in `src/lib/releases.ts`, which runs these checks once for every page. Rebuild the site after a Mac release to point at it. See [release compatibility](../docs/releases.md).

**Other ways to install** (`src/components/InstallDialog.astro`, Windows only) always offers the direct downloads. winget, Scoop and Chocolatey appear only when the build finds QNotch in `microsoft/winget-pkgs`, in `Somafet/scoop-bucket` and among the approved packages of the Chocolatey community feed, so the page never shows a command that fails. Rebuild the site once a channel goes live; [docs/releases.md](../docs/releases.md#winget-scoop-and-chocolatey) describes how releases reach them.

Use Node.js 24 or newer. CI installs from `website/package-lock.json` and runs `npm run build` independently of root repository tooling.

The static landing page, built with Astro. No framework, no runtime dependencies: the interactive demo is plain TypeScript in `src/scripts/demo.ts`, styled after the app's dark theme in `src/styles/demo.css`.

```bash
npm ci
npm run dev      # http://localhost:4321
npm run build    # static site in dist/
```

| File | What it is |
| --- | --- |
| `src/pages/[...platform].astro` | The page, built at `/` (both platforms), `/windows/` and `/mac/`: hero, platform intro, numbers, hotkeys, privacy, FAQ |
| `src/lib/releases.ts` | Build-time checks for the Mac download and the winget, Scoop and Chocolatey listings |
| `src/components/Demo.astro` + `src/scripts/demo.ts` | The notch itself (pill, panel, tabs, terminal, scenarios) |
| `src/scripts/desktop.ts` + `src/styles/desktop.css` | The fake desktop around it: windows, taskbar, Start, calendar, tray menu, Explorer, Music, browser upload |
| `src/styles/mac.css` | The Mac version of that desktop: menu bar, Dock, traffic lights, and the notch's wings around the camera housing |
| `src/components/OsSwitch.astro` + `src/scripts/platform.ts` | The Windows/Mac switch and the shared platform state |
| `src/components/Features.astro` | The feature grid |
| `src/components/OpenSource.astro` | Extensions, the five slots, contributing |
| `src/icons.ts` | Stroke icons used everywhere |
| `og/og.html` | Source of the social preview `src/assets/og.png`; rerender with `node og/render.mjs` (needs Edge or Chrome) |
| `src/layouts/Base.astro` | The head: title, description, canonical, Open Graph and Twitter tags. Pass `noindex` for pages search engines should skip |
| `src/pages/404.astro` | The not-found page (`noindex`, left out of the sitemap) |
| `src/pages/llms.txt.ts` | `/llms.txt`, a plain summary for AI assistants, built from the same release checks. Keep its claims in line with the page |
| `public/robots.txt` | Points crawlers at `sitemap-index.xml`, which `@astrojs/sitemap` writes on every build |

Rule for the demo: anything that looks clickable must work. If a control can't be backed by real behavior, remove it.

Search engines read the structured data (JSON-LD) at the top of `[...platform].astro`: the app, the site, the page on `/windows/` and `/mac/`, and the FAQ that page shows. The FAQ part is built from the same `faq` list the page shows, so the two stay in sync. Only real page headings should use `<h1>` to `<h6>`; titles inside the demo's mock UI use `.qn-h`.

Keep claims on the page in line with the repo README: numbers, hotkeys and privacy statements come from there.
