using Calc.Core;

namespace Calc.Documents;

public sealed record SheetDocument(int Version, Guid Id, string Source, bool Dark)
{
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public GeneratedUuidState? GeneratedUuids { get; init; }
}
public sealed record LoadResult(SheetDocument Document, bool Recovered, IReadOnlyList<FunctionReceipt>? FunctionReceipts = null);
public sealed class UnsupportedDocumentVersionException() : IOException("Unsupported document version; original preserved");

/// <summary>One-sheet P0 store. Same-directory atomic replacement with last-good backup.
/// Exclusive session ownership prevents concurrent writers from overwriting one another.</summary>
public sealed class SheetStore : IDisposable
{
    public const int MaxCharacters = 200_000;
    public const int MaxDocumentBytes = 4_000_000;
    private readonly string path;
    private readonly FileStream sessionLock;
    private bool canSave;
    public SheetStore(string directory)
    {
        Directory.CreateDirectory(directory);
        path = Path.Combine(directory, "sheet.json");
        sessionLock = new FileStream(Path.Combine(directory, "session.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    public LoadResult Load()
    {
        canSave = false;
        if (!File.Exists(path) && !File.Exists(path + ".bak"))
        {
            canSave = true;
            return new(new(1, Guid.NewGuid(), "price = 120\ndiscount = 15%\nprice * discount\nprice * (1 - discount)", false), false);
        }
        var loaded = AtomicJson.Load<SheetDocument>(path, MaxDocumentBytes, Validate);
        canSave = true;
        return new(loaded.Value, loaded.Recovered);
    }
    internal static void Validate(SheetDocument doc)
    {
        if (doc.Version is not (1 or 2)) throw new UnsupportedDocumentVersionException();
        if (doc.Id == Guid.Empty || doc.Source is null || doc.Source.Length > MaxCharacters)
            throw new InvalidDataException("Unsupported or invalid document; original preserved");
        if (doc.Version == 1 && doc.GeneratedUuids is not null || doc.Version == 2 && doc.GeneratedUuids is null) throw new InvalidDataException("Invalid generated-value document version; original preserved");
        if (doc.GeneratedUuids is { } state) GeneratedUuidSession.Validate(doc.Source, state);
    }
    public void Save(SheetDocument doc)
    {
        if (!canSave) throw new InvalidOperationException("Load must succeed before saving");
        Validate(doc);
        AtomicJson.Write(path, doc);
    }
    public void Dispose() => sessionLock.Dispose();
}
