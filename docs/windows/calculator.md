# Windows Calculator

The Calculator module is a port of the Calc notepad calculator, hosted as a panel tab.

## Layout

| Path | Content |
| --- | --- |
| `src/QNotch.Calculator.Engine/` | UI-free assembly, loaded on first use. The root holds `Calc.Core` unchanged apart from `NumericValue.IsDuration`. `Documents/` is `Calc.Documents`, `Rates/` the rate clients, `Tabs/` the tab close and undo state, `Assets/` what Calc shipped beside its exe |
| `src/QNotch/Modules/Calculator/` | The module, its lazy tab host, Search answers and the workspace session |
| `src/QNotch/Modules/Calculator/Surface/` | Calc's Windows UI as a control. The `Calc.Windows` namespace and file split are kept so the files stay diffable against Calc |

## Lifecycle

Nothing loads at startup. The engine and the workspace load the first time the Calculator tab or its Settings page shows, and the engine alone when Search first sees a calculation. Search uses saved functions only when the workspace is already open. While hidden the view keeps no timers, except the one-shot undo window after a close. Sheets are saved in `calculator\`. Help, the third-party notices and the static share viewer are embedded and written there when first used, so `QNotch.exe` stays a single file.

## Results

Every edit is evaluated off the UI thread with no debounce; a newer edit cancels the older run. Until the new results arrive, `CalculatorSurface.CarryResults` keeps the last results for the lines before and after the edited block (`Calc.Documents.CarriedResults`, shifted by lines added or removed), and the edited lines show none, so the column never blinks empty while typing. Share, export and share links use only results evaluated for exactly the current text. A failed evaluation or a sheet switch carries nothing over.

## Tabs

`SheetTabList` is the UI-free state, checked by `tests/QNotch.CalculatorTests`. A closed sheet leaves the strip at once and stays in the store until its undo window ends, or until QNotch quits, so a crash in that window loses nothing. It keeps its name and counts toward the 256 sheet limit until then. All waiting closes share one deadline, moved on by each close and undo.

The strip creates only the tabs in view. Tabs share the width between 92 and 150 DIPs; past that the row scrolls with the wheel, chevrons and the all-sheets list.

| Input | Action |
| --- | --- |
| Middle-click, or the tab's close mark | Close that tab, without activating it |
| Ctrl+W | Close the active tab |
| Ctrl+Tab, Ctrl+Shift+Tab | Next or previous sheet |
| Ctrl+N, Ctrl+O | New sheet, import |
| F2 | Rename the variable at the caret, otherwise the sheet |
| F1 | Help, or the explanation of a focused result |
| Ctrl+Shift+L, Ctrl+P | Copy a share link, print |

## Testing

`tests/QNotch.CalculatorTests` holds every calculator check, run with `dotnet test`: the tab list, and the engine's arithmetic, units, dates, finance, payroll, documents and rate providers against the fixtures in its `fixtures/` folder. Cooking densities come from USDA FoodData Central; its `ingredient-usda-sr-legacy-2018.csv` extract pins every catalog value.

A `--debug-control` run can send the sheet's clipboard writes to a file by setting `QNOTCH_CALCULATOR_CLIPBOARD`, so a test leaves the real clipboard alone. `debug press --id calculator-tab-1 --button middle` runs a tab's middle-click.
