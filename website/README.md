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

Keep claims on the page in line with the repo README: numbers, hotkeys and privacy statements come from there.
