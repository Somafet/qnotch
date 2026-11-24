// .NET oracle for the Swift documents port (Sources/CalculatorEngine/Documents). Dev tool, never shipped.
// Mac and Windows share data and sync folders, so every file the Swift port writes must be byte-identical to what the
// C# engine writes for the same state, and the Swift port must read everything C# writes. This tool records both:
//
//   json/<case>.json      System.Text.Json's bytes for fixed document values (Swift rebuilds the same values by name).
//   workspace/            a data folder written by the real C# WorkspaceStore (catalog, bodies, receipts, functions,
//                         preferences, version history, sync state), as Windows leaves it.
//   sync/                 the sync folder FolderSync wrote for that workspace (sheets, a tombstone).
//   legacy/               a one-sheet SheetStore folder (sheet.json) for the migration path.
//   manifest.json         what the folders above hold, for the Swift reader tests.
//
// Regenerate from the repository root with:
//   dotnet run -c Release --project src/QNotch.Mac/Calculator/Tools/DocumentsOracle -- tests/fixtures/calculator/documents
// The workspace and sync folders contain fresh random identities on every run; commit them together with manifest.json.
//
// The reverse check reads a Mac-written workspace and sync folder with the C# stores:
//   CALC_WRITE_MAC_DOCUMENTS=/tmp/mac-documents swift test --filter DocumentCompatibilityTests   (writes data/ and sync/)
//   dotnet run -c Release --project src/QNotch.Mac/Calculator/Tools/DocumentsOracle -- verify /tmp/mac-documents/data /tmp/mac-documents/sync
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Calc.Core;
using Calc.Documents;

if (args.Length == 3 && args[0] == "verify") return Verify(args[1], args[2]);
if (args.Length != 1) { Console.Error.WriteLine("usage: DocumentsOracle <output folder> | DocumentsOracle verify <data folder> <sync folder>"); return 1; }
var output = Path.GetFullPath(args[0]);
if (Directory.Exists(output)) Directory.Delete(output, true);
Directory.CreateDirectory(output);

// ---- Fixed values ----
// Strings exercise the default encoder: HTML-sensitive ASCII, controls, DEL, Latin-1, BMP and astral characters.
const string Awkward = "price = 120 \"q\" \\ / <b>&amp;</b> 'a'+`b` \u0001\u001f\u007f é € 日本 😀\ttab\r\nnext";
Guid G(string text) => Guid.Parse(text);
var sheetId = G("0f8c2d6e-1a3b-4c5d-8e9f-a0b1c2d3e4f5");
var other = G("ffeeddcc-bbaa-4998-8776-655443322110");
var statement1 = G("11111111-2222-4333-8444-555555555555");
var statement2 = G("aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee");
var value1 = G("12345678-9abc-4def-8123-456789abcdef");
var revision = G("01020304-0506-4708-890a-0b0c0d0e0f10");
var ancestor = G("f1e2d3c4-b5a6-4978-8a9b-acbdcedfe0f1");
var uuids = new GeneratedUuidState(1, [statement1, statement2], [new(statement1, "uuid/0", value1), new(statement2, "f/1/uuid/0", value1)]);
var dice = new GeneratedUuidState(2, [statement1, statement2], [new(statement1, "uuid/0", value1)]) { Dice = [new(statement2, "2d6+3", [4, 6])] };
var definitions = new FunctionDefinition[] { new("f", ["x"], "x+1"), new("area", ["w", "h"], "w*h"), new("constant", [], "7 €") };
var receipts = new FunctionReceipt[] { new(new string('A', 64), 1), new("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", 2) };
var captured = new DateTimeOffset(2026, 10, 31, 12, 0, 0, TimeSpan.Zero);
var cases = new (string Name, object Value)[]
{
    ("sheet-v1", new SheetDocument(1, sheetId, Awkward, false)),
    ("sheet-v1-dark-empty", new SheetDocument(1, other, "", true)),
    ("sheet-v2-uuids", new SheetDocument(2, sheetId, "uuid\nf(1)", false) { GeneratedUuids = uuids }),
    ("sheet-v2-dice", new SheetDocument(2, sheetId, "uuid\n2d6+3", true) { GeneratedUuids = dice }),
    ("workspace", new WorkspaceDocument(1, other, true, [new(sheetId, "Sheet"), new(other, "Reise 日本 😀 <&>")])),
    ("functions", new FunctionCatalog(3, definitions)),
    ("functions-empty", new FunctionCatalog(1, [])),
    ("receipts", new FunctionReceiptDocument(1, sheetId, receipts)),
    ("receipts-empty", new FunctionReceiptDocument(1, other, [])),
    ("function-save", new FunctionSaveTransaction(1, new SheetDocument(2, sheetId, "saved()=uuid", false) { GeneratedUuids = new(1, [statement1], []) },
        new FunctionCatalog(2, [new("saved", [], "uuid")]), new FunctionReceiptDocument(1, sheetId, [receipts[0]]))),
    ("preferences-v1", new PreferencesDocument(1, null)),
    ("preferences-v1-region", new PreferencesDocument(1, "DE") { AutoCurrencyRates = true }),
    ("preferences-v2", new PreferencesDocument(2, "WEEKDAYS")
    {
        AutoCurrencyRates = true, FontSize = 40, DecimalPlaces = 20, NumberStyle = "apostrophe", Language = "zh-Hans", AlwaysOnTop = true,
        Window = new(-1_000_000, -20, 900, 700, true), DefaultCurrency = "HUF",
    }),
    ("preferences-v2-sparse", new PreferencesDocument(2, null) { FontSize = 12 }),
    ("version", new SheetVersion(1, sheetId, captured, new string('B', 64), new SheetDocument(1, sheetId, "a + b", false), receipts)),
    ("version-fraction", new SheetVersion(1, sheetId, captured.AddTicks(1_234_500), "C0FFEE".PadRight(64, '0'), new SheetDocument(2, sheetId, "uuid", false) { GeneratedUuids = uuids }, [])),
    ("version-max", new SheetVersion(1, sheetId, DateTimeOffset.MaxValue, new string('D', 64), new SheetDocument(1, sheetId, "", false), [])),
    ("sync-state", new SyncStateDocument(1, "/Users/someone/Library/CloudStorage/Drop box/Sync \"QNotch\" 日本", [
        new(sheetId, revision, new string('E', 64), "Sheet", 639_000_000_000_000_001, 1234),
        new(other, ancestor, new string('F', 64), "Reise 😀", 0, 0)])),
    ("sync-state-off", new SyncStateDocument(1, null, [])),
    ("calcsheet", new SyncSheetFile(1, sheetId, revision, [ancestor, statement1], "MacBook “Pro” 😀", captured.AddTicks(1).ToOffset(TimeSpan.FromHours(2)),
        false, "Reise 日本", Awkward, SyncFolderFiles.ContentHash("Reise 日本", Awkward, null))),
    ("calcsheet-uuids", new SyncSheetFile(1, sheetId, revision, [], "Computer", captured.ToOffset(TimeSpan.FromMinutes(-330)), false, "Sheet", "uuid\n2d6+3",
        SyncFolderFiles.ContentHash("Sheet", "uuid\n2d6+3", dice)) { GeneratedUuids = dice }),
    ("calcsheet-tombstone", new SyncSheetFile(1, other, ancestor, [revision], "C", captured.AddDays(-200), true, "", "", SyncFolderFiles.ContentHash("", "", null))),
};
var json = Path.Combine(output, "json");
Directory.CreateDirectory(json);
foreach (var (name, value) in cases) File.WriteAllBytes(Path.Combine(json, name + ".json"), JsonSerializer.SerializeToUtf8Bytes(value, value.GetType()));

// ---- Content hashes (SyncFolderFiles.ContentHash is the sync file integrity hash) ----
var hashes = new JsonArray();
foreach (var (name, source, state) in new (string, string, GeneratedUuidState?)[]
    { ("", "", null), ("Sheet", WorkspaceStore.StarterSource, null), ("Reise 日本", Awkward, null), ("Sheet", "uuid\nf(1)", uuids), ("Sheet", "uuid\n2d6+3", dice),
      ("S", "x", new(1, [statement1], [])) })
    hashes.Add(new JsonObject { ["name"] = name, ["source"] = source, ["case"] = state is null ? null : state == uuids ? "uuids" : state == dice ? "dice" : "statement",
        ["hash"] = SyncFolderFiles.ContentHash(name, source, state) });

// ---- A real workspace, sync folder and legacy sheet, written by the C# stores ----
// Stores write under a fixed scratch path so sync.json names no personal folder; the result is copied into the output.
const string Scratch = "/tmp/qnotch-documents-oracle";
if (Directory.Exists(Scratch)) Directory.Delete(Scratch, true);
var workspaceFolder = Path.Combine(Scratch, "workspace");
var syncFolder = Path.Combine(Scratch, "sync");
Directory.CreateDirectory(syncFolder);
var manifest = new JsonObject { ["format"] = "Written by Tools/DocumentsOracle with the C# engine; regenerate, do not edit.", ["hashes"] = hashes };
var clockAt = new DateTimeOffset(2026, 11, 1, 9, 30, 15, TimeSpan.FromHours(1)).AddTicks(7_654_321);
using (var store = new WorkspaceStore(workspaceFolder))
{
    var first = store.Load().Workspace.ActiveSheetId;
    var second = store.Create("Reise 日本 😀 <&>", "fuel = 40\nfuel * 3 \"q\" 'a'").ActiveSheetId;
    var third = store.Create("Scratch", "1+1").ActiveSheetId;
    // Functions: a definition saved through the journal, so functions.json and a .receipts file exist.
    var opened = store.Open(first).Document with { Source = "f(x)=x+1\nf(2)\n" + Awkward };
    store.SaveWithFunctions(opened, FunctionUpdate.Prepare(opened.Source, store.LoadFunctions(), store.LoadFunctionReceipts(first)));
    // Generated UUIDs: version 2 body.
    var withUuids = store.Open(second).Document with { Version = 2, Source = "uuid\nid = uuid", GeneratedUuids = new(1, [statement1, statement2], [new(statement1, "uuid/0", value1)]) };
    store.Save(withUuids);
    // History: two captures of the first sheet, one with a fractional time.
    store.CaptureVersion(first, captured);
    var edited = store.Open(first).Document with { Source = "f(2) * 10" };
    store.SaveWithFunctions(edited, FunctionUpdate.Prepare(edited.Source, store.LoadFunctions(), store.LoadFunctionReceipts(first)));
    store.CaptureVersion(first, captured.AddHours(1).AddTicks(42));
    store.UpdatePreferences(current => current with
    {
        WorkdayRegion = "DE", AutoCurrencyRates = true, FontSize = 18, DecimalPlaces = 2, NumberStyle = "comma", Language = "de", AlwaysOnTop = true,
        Window = new(10, 20, 810, 620, false), DefaultCurrency = "EUR",
    });
    store.SetDark(true);
    store.Select(second);
    // Sync: publish everything, then delete Scratch so the folder holds a tombstone.
    FolderSync.SetFolder(workspaceFolder, syncFolder);
    var sync = new FolderSync(store, "Oracle PC 😀", () => clockAt);
    var report = sync.Synchronize(sync.Scan(syncFolder));
    if (report.Failed > 0 || report.Published != 3) throw new InvalidOperationException("Unexpected sync report " + report);
    store.Delete(third);
    clockAt = clockAt.AddMinutes(1);
    report = sync.Synchronize(sync.Scan(syncFolder));
    if (report.Failed > 0) throw new InvalidOperationException("Unexpected sync report " + report);

    var workspace = store.Load().Workspace;
    var sheets = new JsonArray();
    foreach (var entry in workspace.Sheets)
    {
        var loaded = store.Open(entry.Id);
        var versions = new JsonArray();
        foreach (var version in store.LoadVersions(entry.Id).Versions)
            versions.Add(new JsonObject { ["hash"] = version.Hash, ["ticks"] = version.CapturedAt.UtcTicks, ["source"] = version.Sheet.Source, ["receipts"] = version.Receipts.Length });
        sheets.Add(new JsonObject
        {
            ["id"] = entry.Id.ToString("N"), ["name"] = entry.Name, ["version"] = loaded.Document.Version, ["source"] = loaded.Document.Source,
            ["receipts"] = loaded.FunctionReceipts!.Count, ["versions"] = versions,
        });
    }
    var files = new JsonArray();
    foreach (var entry in sync.Scan(syncFolder).Canonical.Values.OrderBy(e => e.SheetId))
        files.Add(new JsonObject
        {
            ["sheet"] = entry.SheetId.ToString("N"), ["revision"] = entry.File!.Revision.ToString("N"), ["deleted"] = entry.File.Deleted,
            ["name"] = entry.File.Name, ["source"] = entry.File.Source, ["hash"] = entry.File.Hash, ["ancestors"] = entry.File.Ancestors.Length,
        });
    manifest["workspace"] = new JsonObject
    {
        ["active"] = workspace.ActiveSheetId.ToString("N"), ["dark"] = workspace.Dark, ["sheets"] = sheets, ["deleted"] = third.ToString("N"),
        ["functions"] = new JsonArray(store.LoadFunctions().Definitions.Select(d => (JsonNode)new JsonObject { ["name"] = d.Name, ["body"] = d.Body }).ToArray()),
        ["functionsVersion"] = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(workspaceFolder, "functions.json"))).RootElement.GetProperty("Version").GetInt32(),
        ["sync"] = files,
    };
}
File.Delete(Path.Combine(workspaceFolder, "session.lock"));
// The configured folder is this machine's absolute path; the Swift test rewrites it after copying.
manifest["syncFolder"] = syncFolder;

var legacyFolder = Path.Combine(Scratch, "legacy");
using (var legacy = new SheetStore(legacyFolder))
{
    var doc = legacy.Load().Document with { Source = "// 😀 日本語\n120*15%", Dark = true };
    legacy.Save(doc); legacy.Save(doc);
    manifest["legacy"] = new JsonObject { ["id"] = doc.Id.ToString("N"), ["source"] = doc.Source, ["dark"] = doc.Dark };
}
File.Delete(Path.Combine(legacyFolder, "session.lock"));

foreach (var folder in new[] { "workspace", "sync", "legacy" }) Copy(Path.Combine(Scratch, folder), Path.Combine(output, folder));
Directory.Delete(Scratch, true);
File.WriteAllText(Path.Combine(output, "manifest.json"),
    manifest.ToJsonString(new JsonSerializerOptions { WriteIndented = true, IndentSize = 1, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }).Replace("\r\n", "\n") + "\n", new UTF8Encoding(false));
Console.WriteLine($"Wrote {cases.Length} JSON cases, a workspace, a sync folder and a legacy sheet to {output}");
return 0;

// The reverse direction: the C# stores read a data folder and sync folder the Mac engine wrote (DocumentCompatibilityTests writes one
// when CALC_WRITE_MAC_DOCUMENTS names a folder). Prints what C# sees; any recovery, skipped version or unreadable sync file fails.
static int Verify(string data, string folder)
{
    var problems = new List<string>();
    using var store = new WorkspaceStore(data);
    var loaded = store.Load();
    if (loaded.Recovered || loaded.Migrated) problems.Add("catalog recovered or migrated");
    Console.WriteLine($"workspace: {loaded.Workspace.Sheets.Length} sheets, active {loaded.Workspace.ActiveSheetId:N}, dark {loaded.Workspace.Dark}");
    foreach (var entry in loaded.Workspace.Sheets)
    {
        var sheet = store.Open(entry.Id);
        if (sheet.Recovered) problems.Add("sheet recovered: " + entry.Name);
        var history = store.LoadVersions(entry.Id);
        if (history.Skipped > 0) problems.Add($"{history.Skipped} versions skipped: {entry.Name}");
        Console.WriteLine($"  {entry.Name}: v{sheet.Document.Version} {JsonSerializer.Serialize(sheet.Document.Source)}, {sheet.FunctionReceipts!.Count} receipts, " +
            $"{history.Versions.Count} versions [{string.Join(", ", history.Versions.Select(v => JsonSerializer.Serialize(v.Sheet.Source)))}]" +
            (sheet.Document.GeneratedUuids is { } u ? $", {u.Statements.Length} statements, {u.Bindings.Length} bindings, {u.Dice?.Length ?? 0} rolls" : ""));
    }
    var functions = store.LoadFunctions();
    if (store.FunctionsRecovered) problems.Add("functions recovered");
    Console.WriteLine("functions: " + string.Join(", ", functions.Definitions.Select(d => d.Name + "(" + string.Join(",", d.Parameters) + ")=" + d.Body)));
    var preferences = store.LoadPreferences();
    if (store.PreferencesRecovered) problems.Add("preferences recovered");
    Console.WriteLine("preferences: " + JsonSerializer.Serialize(preferences));
    var sync = new FolderSync(store, "Verifier");
    var snapshot = sync.Scan(folder);
    foreach (var entry in snapshot.Canonical.Values.OrderBy(e => e.SheetId))
    {
        if (entry.State != SyncFileState.Ready) problems.Add($"sync file {entry.SheetId:N} is {entry.State}: {entry.Problem}");
        Console.WriteLine($"sync {entry.SheetId:N}: {entry.State} {(entry.File is { } f ? (f.Deleted ? "tombstone" : JsonSerializer.Serialize(f.Name)) + " by " + f.Device + " at " + f.SavedAt.ToString("O") : "")}");
    }
    FolderSync.SetFolder(data, folder); // Same folder: keeps the Mac's bases.
    var report = sync.Synchronize(sync.Scan(folder));
    Console.WriteLine($"pass: {report.Status}, published {report.Published}, imported {report.Imported}, updated {report.Updated}, conflicts {report.Conflicts}, failed {report.Failed}");
    if (report.Status != SyncStatus.Synchronized || report.Published + report.Imported + report.Updated + report.Conflicts + report.Failed > 0) problems.Add("sync pass changed something");
    foreach (var problem in problems) Console.Error.WriteLine("PROBLEM: " + problem);
    return problems.Count == 0 ? 0 : 2;
}

static void Copy(string from, string to)
{
    Directory.CreateDirectory(to);
    foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
    foreach (var folder in Directory.GetDirectories(from)) Copy(folder, Path.Combine(to, Path.GetFileName(folder)));
}
