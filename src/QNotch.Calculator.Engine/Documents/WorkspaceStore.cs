namespace Calc.Documents;

public sealed record SheetEntry(Guid Id, string Name);
public sealed record WorkspaceDocument(int Version, Guid ActiveSheetId, bool Dark, SheetEntry[] Sheets);
public sealed record WorkspaceLoadResult(WorkspaceDocument Workspace, bool Recovered, bool Migrated);

/// <summary>A bounded metadata catalog; individual source files are read only when opened.
/// Source is committed before catalog creation and catalogs never refer to uncommitted new sheets.</summary>
public sealed partial class WorkspaceStore : IDisposable
{
    public const int MaxSheets = 256;
    public const int MaxNameLength = 80;
    public const int MaxCatalogBytes = 256_000;
    public const string StarterSource = "price = 120\ndiscount = 15%\nprice * discount\nprice * (1 - discount)";
    private readonly string catalogPath;
    private readonly string directory;
    private readonly string sheetsDirectory;
    private readonly FileStream sessionLock;
    private WorkspaceDocument? workspace;
    private readonly HashSet<Guid> loadedSheets = [];
    public WorkspaceStore(string directory)
    {
        this.directory = directory;
        Directory.CreateDirectory(directory);
        catalogPath = Path.Combine(directory, "workspace.json");
        sheetsDirectory = Path.Combine(directory, "sheets");
        sessionLock = new FileStream(Path.Combine(directory, "session.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    public WorkspaceLoadResult Load()
    {
        workspace = null; loadedSheets.Clear(); functionLibraryCache = null; newestVersions.Clear();
        if (File.Exists(catalogPath) || File.Exists(catalogPath + ".bak"))
        {
            var loaded = AtomicJson.Load<WorkspaceDocument>(catalogPath, MaxCatalogBytes, Validate);
            workspace = loaded.Value;
            RecoverFunctionSave(workspace);
            return new(Copy(workspace), loaded.Recovered, false);
        }
        var legacyPath = Path.Combine(directory, "sheet.json");
        SheetDocument initial;
        var migrated = File.Exists(legacyPath) || File.Exists(legacyPath + ".bak");
        var recovered = false;
        if (migrated)
        {
            var legacy = AtomicJson.Load<SheetDocument>(legacyPath, SheetStore.MaxDocumentBytes, SheetStore.Validate);
            initial = legacy.Value; recovered = legacy.Recovered;
        }
        else initial = new(1, Guid.NewGuid(), StarterSource, false);
        Directory.CreateDirectory(sheetsDirectory);
        // An interrupted migration can be retried. The legacy file and its backup stay untouched.
        AtomicJson.Write(SheetPath(initial.Id), initial);
        var created = new WorkspaceDocument(1, initial.Id, initial.Dark, [new(initial.Id, "Sheet")]);
        Commit(created);
        RecoverFunctionSave(created);
        return new(Copy(created), recovered, migrated);
    }
    public LoadResult Open(Guid id)
    {
        RequireSheet(id);
        loadedSheets.Remove(id);
        var loaded = AtomicJson.Load<SheetDocument>(SheetPath(id), SheetStore.MaxDocumentBytes, sheet =>
        {
            SheetStore.Validate(sheet);
            if (sheet.Id != id) throw new InvalidDataException("Sheet identity does not match catalog");
        });
        var receipts = ReadFunctionReceiptFile(id);
        loadedSheets.Add(id);
        return new(loaded.Value, loaded.Recovered || receipts.Recovered, Array.AsReadOnly(receipts.Document.Receipts));
    }
    public void Save(SheetDocument sheet)
    {
        RequireSheet(sheet.Id);
        if (!loadedSheets.Contains(sheet.Id)) throw new InvalidOperationException("Open must succeed before saving a sheet");
        SheetStore.Validate(sheet);
        AtomicJson.Write(SheetPath(sheet.Id), sheet);
    }
    public WorkspaceDocument Create(string name, string source = "")
    {
        var current = RequireWorkspace();
        if (current.Sheets.Length == MaxSheets) throw new InvalidDataException($"Maximum {MaxSheets} sheets");
        ValidateName(name);
        var sheet = new SheetDocument(1, Guid.NewGuid(), source, false);
        SheetStore.Validate(sheet);
        AtomicJson.Write(SheetPath(sheet.Id), sheet);
        var next = current with { ActiveSheetId = sheet.Id, Sheets = [.. current.Sheets, new(sheet.Id, name.Trim())] };
        try { Commit(next); }
        catch
        {
            // The catalog did not commit. Do not accumulate a body for every failed attempt.
            try { File.Delete(SheetPath(sheet.Id)); File.Delete(SheetPath(sheet.Id) + ".bak"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            throw;
        }
        loadedSheets.Add(sheet.Id);
        return Copy(next);
    }
    public WorkspaceDocument Rename(Guid id, string name)
    {
        RequireSheet(id); ValidateName(name);
        var current = RequireWorkspace();
        return CommitAndCopy(current with { Sheets = current.Sheets.Select(s => s.Id == id ? s with { Name = name.Trim() } : s).ToArray() });
    }
    public WorkspaceDocument Select(Guid id)
    {
        RequireSheet(id);
        return CommitAndCopy(RequireWorkspace() with { ActiveSheetId = id });
    }
    public WorkspaceDocument SetDark(bool dark) => CommitAndCopy(RequireWorkspace() with { Dark = dark });
    public WorkspaceDocument Delete(Guid id)
    {
        RequireSheet(id);
        var current = RequireWorkspace();
        if (current.Sheets.Length == 1) throw new InvalidOperationException("Keep at least one sheet");
        var remaining = current.Sheets.Where(s => s.Id != id).ToArray();
        var next = current with { Sheets = remaining, ActiveSheetId = current.ActiveSheetId == id ? remaining[0].Id : current.ActiveSheetId };
        Commit(next); loadedSheets.Remove(id);
        return Copy(next);
    }
    private WorkspaceDocument CommitAndCopy(WorkspaceDocument next) { Commit(next); return Copy(next); }
    private void Commit(WorkspaceDocument next)
    {
        Validate(next); AtomicJson.Write(catalogPath, next); workspace = next;
        // Keep bodies referenced by current/backup catalogs. Prune only files owned by Calc.
        // Failure here does not invalidate a committed user action; retry on the next metadata change.
        try
        {
            var retained = next.Sheets.Select(s => s.Id).ToHashSet();
            if (File.Exists(catalogPath + ".bak"))
                retained.UnionWith(AtomicJson.Read<WorkspaceDocument>(catalogPath + ".bak", MaxCatalogBytes, Validate).Sheets.Select(s => s.Id));
            foreach (var file in Directory.EnumerateFiles(sheetsDirectory))
            {
                var name = Path.GetFileName(file);
                if (name.EndsWith(".bak", StringComparison.Ordinal)) name = name[..^4];
                var suffix = name.EndsWith(".json", StringComparison.Ordinal) ? ".json" : name.EndsWith(".receipts", StringComparison.Ordinal) ? ".receipts" : null;
                if (suffix is null || !Guid.TryParseExact(name[..^suffix.Length], "N", out var id)) continue;
                if (!retained.Contains(id)) File.Delete(file);
            }
            PruneVersions(retained);
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
    }
    private string SheetPath(Guid id) => Path.Combine(sheetsDirectory, id.ToString("N") + ".json");
    private WorkspaceDocument RequireWorkspace()
    {
        var current = workspace ?? throw new InvalidOperationException("Load must succeed first");
        RecoverFunctionSave(current);
        return current;
    }
    private void RequireSheet(Guid id)
    {
        if (!RequireWorkspace().Sheets.Any(s => s.Id == id)) throw new InvalidDataException("Unknown sheet");
    }
    private static WorkspaceDocument Copy(WorkspaceDocument value) => value with { Sheets = value.Sheets.ToArray() };
    private static void ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > MaxNameLength || name.Any(char.IsControl))
            throw new InvalidDataException("Use a sheet name of 1–80 characters without control characters");
    }
    private static void Validate(WorkspaceDocument value)
    {
        if (value.Version != 1) throw new UnsupportedDocumentVersionException();
        if (value.Sheets is null || value.Sheets.Length is < 1 or > MaxSheets || value.Sheets.Any(s => s is null || s.Id == Guid.Empty) ||
            value.Sheets.Select(s => s.Id).Distinct().Count() != value.Sheets.Length || !value.Sheets.Any(s => s.Id == value.ActiveSheetId))
            throw new InvalidDataException("Invalid sheet catalog");
        foreach (var sheet in value.Sheets) ValidateName(sheet.Name);
    }
    public void Dispose() => sessionLock.Dispose();
}
