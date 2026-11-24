# Porting the C# calculator engine to Swift

The Swift engine in `Sources/CalculatorEngine` is a line-by-line port of `src/QNotch.Calculator.Engine` (C#).
For every input it must produce the same values, displays, errors and explanations as C#. The C# code and the
shared fixtures in `tests/fixtures/calculator/` are the contract; when in doubt, run the C# engine.

## Layout

- One Swift file per C# file, same base name, same folder (`Documents/`, `Rates/`, `Tabs/`). The core lives in
  `Core/`; .NET-compatible helpers in `Support/`; areas not ported yet in `Stubs/` (see `Stubs/README.md`).
  A port of an area deletes its stub file and adds the real files.
- Tests: `Tests/CalculatorEngineTests/<C# folder>/<C# test class>.swift`, one XCTest class per C# test class,
  one test method per C# `[Fact]`/`[Theory]` (same name, `test` prefix). Theory rows go through `theory(rows) { … }`
  (TestSupport.swift) so case counts can be compared with C#. Fixture-driven tests read the same files with
  `Fixtures.url/data/text(…)` and keep the C# case names; call `CaseCounter.record(file: #filePath, count:)` once per fixture case.
- Port hardcoded C# assertions as-is. Never weaken an assertion to make a port pass; fix the port.

## Running

From the repository root: `source scripts/macos/toolchain.sh && xcrun swift test --package-path src/QNotch.Mac/Calculator --filter <Class>`.
Use debug builds while iterating; before committing run the full suite once with `-c release -Xswiftc -warnings-as-errors`.
The .NET 10 SDK (`dotnet`) is installed: `dotnet test tests/QNotch.CalculatorTests --filter <Class>` runs the C# tests,
and a throwaway console project referencing `src/QNotch.Calculator.Engine` (kept outside the repo, or under
`Tools/` if it generates committed data) is the fastest way to see what C# returns for an input. The .NET engine is a
dev-time oracle only: nothing in the app may call or bundle it.

## Translation rules

- **Errors.** C# exception types map to `CalcError`: FormatException → `.format(msg)`, ArithmeticException (incl.
  DivideByZero/Overflow) → `.arithmetic(msg)`, ArgumentException → `.argument(msg)`, SheetComputationLimitException →
  `.computationLimit`, InvalidDataException → `.invalidData`, IOException → `.io`. Messages are copied verbatim.
  `catch (Exception e) when (e is FormatException or ArithmeticException)` → `catch let e as CalcError where e.isFormatOrArithmetic`.
  Anything that can throw in C# is `throws` in Swift; properties that throw in C# (`Display`, `Scalar`, typed `SheetValue`
  accessors) are `get throws`. When C# lets a .NET runtime message reach a line (e.g. `(int)big` overflow), use the same text
  (`CalcError.overflowInt32Message` etc.).
- **Numbers.** `BigInteger` → `BigInt` (C# semantics, including truncating `(double)` conversion); `Rational`, `ExactNumber`,
  `ExactArithmetic` mirror C#. Never use `Double` where C# uses exact values. `double` stays `Double`, with
  `NetMath.round*` for Math.Round and `NetFormat.double/integer` for .NET formatting (`Support/DotNetNumbers.swift`).
  `decimal` (German payroll only) must reproduce System.Decimal results; verify against the oracle.
- **Strings are UTF-16.** C# indexes, lengths and limits count UTF-16 code units. Use `netLength`, `units` ([UInt16]),
  `netSubstring`, `netSplit`, `netTrim`, `netLower/netUpper` (invariant simple case mapping), `equalsIgnoreCase`,
  `NetChar.isLetter/isDigit/isWhiteSpace/category` (Support/NetString.swift). In scanning loops convert once to `[UInt16]`;
  never index `String.utf16` repeatedly or split it as a view (that is quadratic). Swift's `==` and `Hashable` on
  `String` use canonical Unicode equivalence, C# compares code units: use `ordinalEquals`, `OrdinalString` keys, or
  `NetDictionary`/`NetHashSet` (which key strings by code units) wherever decomposed and composed text must differ.
- **Ordering.** C# `Dictionary`/`HashSet` enumerate in insertion order (with freed slots reused); use `NetDictionary`/`NetHashSet`
  wherever order can reach output or control flow, and `.ignoringCase()` for `StringComparer.OrdinalIgnoreCase`.
  LINQ `OrderBy` is stable: use `stableSorted`. `StringComparer.Ordinal` ordering is `String.ordinalCompare`.
  `Enum.TryParse` accepts integers and lists (`DayOfWeek.netTryParse`).
- **JSON.** Read with `JSONNode` (JsonDocument semantics: ordered properties, raw number text). `JsonSerializer.Serialize(string)`
  is `NetJSONText.quote`. Anything written to disk must match System.Text.Json's output byte for byte (escaping, indentation,
  property order), because Mac and Windows share folders.
- **Dates.** `DateOnly`, `TimeOnly`, `NetDateTime` (DateTime ticks), `Instant` (NodaTime, Unix ticks), `ZoneRules`
  (`Support/NetTime.swift`). Never use Foundation `Date`/`Calendar`/`TimeZone` for engine semantics.
- **Records.** C# records → Swift structs, or final classes with value `==` when shared by reference; `with { … }` →
  a copy helper. Expression nodes are final classes conforming to `Expression` and list their operands in `children`
  (same order as C# `ExpressionEvaluation.Children`).
- **Resources.** The engine's JSON catalogs are copied byte for byte into `Sources/CalculatorEngine/Resources/`
  (`ResourceTests` checks they match the C# originals). Load with `CalculatorEngine.resource(name)`.
- No new package dependencies. No network access from tests.
