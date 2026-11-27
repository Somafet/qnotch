# Interface language

QNotch shows its interface in English or in a translated language. This file defines the setting and the catalog format. Windows implements it; macOS does not yet (see [Known gaps](#known-gaps)).

## Languages

| Code | Name shown | Catalog |
| --- | --- | --- |
| `en` | English | none: the English text in the source is the reference |
| `it` | Italiano | `src/QNotch/Localization/it.json` |

A language's name is always shown in that language, whatever the interface language is.

## Settings: Language

The first row of the General page.

| Row | Control | Shown | Description |
| --- | --- | --- | --- |
| Language | Pop-up with "System default", then every language by its own name; default System default; identifier `language` | Always | "The language of QNotch's menus and text. Applies after a restart." |

Behavior:

- System default picks the first supported language in the system display language's chain (`it-IT` → `it`), otherwise English.
- The choice is saved at once and applies after a restart. While the chosen language differs from the running one, a "Restart now" link button (identifier `language-restart`) shows next to the pop-up.
- Storage: Windows saves `Language` in `general.json`: `""` for System default, else the code. It is a local preference and never in setup codes.
- Numbers keep the English format in every language. Day and month names follow the interface language.
- The Calculator has its own language preference. Set to its default, it follows the interface language.

## Catalog

One JSON file per translated language, embedded in the app:

```json
{ "code": "it", "name": "Italiano", "strings": { "Restart now": "Riavvia ora", "{0} files": "{0} file" } }
```

- The key is the exact English text shown in the interface. A translation keeps the same `{0}` placeholders.
- A missing or empty translation shows the English text.
- Translated: everything a user reads or hears from assistive tech. Not translated: identifiers, saved values, analytics names, logs, CLI output, diagnostics reports, product names, user content and text from external services.
- `node scripts/ui-strings.mjs` checks every catalog against the source; `--sync` adds new texts with an empty translation and removes unused ones. `npm test` fails while a catalog is incomplete.

To add a language: copy `it.json` to `<code>.json`, set `code` and `name`, translate every value, and add the language to `L.Languages` in `src/QNotch/Core/Loc.cs`.

## Diagnostics

`--snapshot`, `--smoke-test` and `--measure` render in English so their checks see fixed text. `--language <code>` renders another language, for example `QNotch.exe --snapshot out --language it`.

## Known gaps

- macOS has no Language setting and shows English only.
