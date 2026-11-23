using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Calc.Core;

namespace Calc.Documents;

/// <summary>One restorable copy of a sheet. Receipts travel with the source so restoring never re-runs or loses a define/forget.</summary>
public sealed record SheetVersion(int Version, Guid SheetId, DateTimeOffset CapturedAt, string Hash, SheetDocument Sheet, FunctionReceipt[] Receipts);
public sealed record VersionHistory(IReadOnlyList<SheetVersion> Versions, int Skipped);

/// <summary>Versions live in versions/{sheet}/{ticks}-{hash}.json, one atomic file each, and are read only while history is open.
/// Capture time is supplied by the host. Load, Open and Save never touch this folder.</summary>
public sealed partial class WorkspaceStore
{
    public const int MaxVersions = 64;
    public const long MaxVersionBytes = 8 * 1024 * 1024;
    public static readonly TimeSpan VersionInterval = TimeSpan.FromMinutes(5);
    private const int MaxVersionFileBytes = SheetStore.MaxDocumentBytes + 100_000;
    private const int VersionStemLength = 19 + 1 + 64;
    private readonly Dictionary<Guid, DateTimeOffset> newestVersions = [];
    /// <summary>Folder scans so far, so tests and diagnostics can prove startup and switching load no history.</summary>
    public int VersionScans { get; private set; }
    private string VersionsDirectory => Path.Combine(directory, "versions");
    private string VersionFolder(Guid id) => Path.Combine(VersionsDirectory, id.ToString("N"));
    private sealed record VersionFile(string Path, long Ticks, string Hash, long Length)
    {
        internal DateTimeOffset At => new(Ticks, TimeSpan.Zero);
        internal DateOnly Day => DateOnly.FromDateTime(At.UtcDateTime);
    }

    /// <summary>Stores the saved content unless it matches the newest version; unforced calls also wait for the interval.
    /// True means history reflects the saved content; false means the interval deferred it.</summary>
    public bool CaptureVersion(Guid id, DateTimeOffset now, bool force = false)
    {
        RequireOpened(id);
        if (!force && newestVersions.TryGetValue(id, out var known) && now - known < VersionInterval) return false;
        var files = VersionFiles(id);
        var newest = files.FirstOrDefault();
        if (newest is not null) newestVersions[id] = newest.At;
        if (!force && newest is not null && now - newest.At < VersionInterval) return false;
        var sheet = ReadSaved(id);
        var hash = ContentHash(sheet);
        if (newest?.Hash == hash || newest is null && sheet.Source.Length == 0) return true;
        // Ticks keep increasing when the clock moves back, so names always sort oldest to newest.
        var at = new DateTimeOffset(Math.Max(now.UtcTicks, (newest?.Ticks ?? 0) + 1), TimeSpan.Zero);
        var folder = VersionFolder(id);
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, at.UtcTicks.ToString("D19", CultureInfo.InvariantCulture) + "-" + hash + ".json");
        AtomicJson.Write(path, new SheetVersion(1, id, at, hash, sheet, ReadFunctionReceiptFile(id).Document.Receipts));
        newestVersions[id] = at;
        files.Insert(0, new(path, at.UtcTicks, hash, new FileInfo(path).Length));
        // Bounds are retried by the next capture; a held file never fails the capture that just succeeded.
        try { MoveDuplicates(files); Thin(files); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return true;
    }
    public VersionHistory LoadVersions(Guid id)
    {
        RequireSheet(id);
        var versions = new List<SheetVersion>(); var skipped = 0;
        foreach (var file in VersionFiles(id).DistinctBy(file => file.Hash).Take(MaxVersions))
        {
            try { versions.Add(ReadVersion(id, file)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or JsonException) { skipped++; }
        }
        return new(versions, skipped);
    }
    /// <summary>Captures the current content, then replaces source, UUID bindings and receipts together through the function journal.
    /// The function library is never changed, so a restored directive neither re-applies nor undoes a later define/forget.</summary>
    public LoadResult RestoreVersion(Guid id, string hash, DateTimeOffset now)
    {
        RequireOpened(id);
        var file = VersionFiles(id).FirstOrDefault(file => file.Hash == hash) ?? throw new InvalidDataException("Version unavailable");
        var version = ReadVersion(id, file);
        var restored = version.Sheet with { Dark = ReadSaved(id).Dark };
        CaptureVersion(id, now, true);
        var library = LoadFunctions();
        var update = new FunctionUpdate(library, version.Receipts, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(restored.Source))), true) { BaseFingerprint = library.Fingerprint };
        try { SaveWithFunctions(restored, update); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { AbandonRestore(id, hash); throw; }
        return new(restored, false, Array.AsReadOnly(version.Receipts));
    }
    // Replay writes the body first, so an untouched body means nothing applied. A partial replay rolls forward instead.
    private void AbandonRestore(Guid id, string hash)
    {
        try { if (ContentHash(ReadSaved(id)) != hash) File.Delete(FunctionJournalPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or JsonException) { }
    }
    private void RequireOpened(Guid id)
    {
        RequireSheet(id);
        if (!loadedSheets.Contains(id)) throw new InvalidOperationException("Open must succeed before using sheet history");
    }
    private SheetDocument ReadSaved(Guid id) => AtomicJson.Read<SheetDocument>(SheetPath(id), SheetStore.MaxDocumentBytes, sheet =>
    {
        SheetStore.Validate(sheet);
        if (sheet.Id != id) throw new InvalidDataException("Sheet identity does not match catalog");
    });
    private SheetVersion ReadVersion(Guid id, VersionFile file) => AtomicJson.Read<SheetVersion>(file.Path, MaxVersionFileBytes, version =>
    {
        if (version.Version != 1) throw new UnsupportedDocumentVersionException();
        if (version.Sheet is null || version.SheetId != id || version.Sheet.Id != id || version.CapturedAt.UtcTicks != file.Ticks) throw new InvalidDataException("Invalid sheet version");
        SheetStore.Validate(version.Sheet);
        if (version.Hash != file.Hash || ContentHash(version.Sheet) != file.Hash) throw new InvalidDataException("Sheet version content does not match its hash");
        ValidateReceipts(new(1, id, version.Receipts), id);
    });
    /// <summary>Newest first. Names carry time and hash, so a scan reads no version body.</summary>
    private List<VersionFile> VersionFiles(Guid id)
    {
        VersionScans++;
        var folder = new DirectoryInfo(VersionFolder(id));
        if (!folder.Exists) return [];
        var files = new List<VersionFile>();
        foreach (var info in folder.EnumerateFiles("*.json").Take(MaxVersions * 4))
            if (TryVersionStem(Path.GetFileNameWithoutExtension(info.Name), out var ticks, out var hash)) files.Add(new(info.FullName, ticks, hash, info.Length));
        return files.OrderByDescending(file => file.Ticks).ToList();
    }
    private static bool TryVersionStem(string stem, out long ticks, out string hash)
    {
        ticks = 0; hash = "";
        if (stem.Length != VersionStemLength || stem[19] != '-' || !stem[20..].All(char.IsAsciiHexDigitUpper) ||
            !long.TryParse(stem.AsSpan(0, 19), NumberStyles.None, CultureInfo.InvariantCulture, out ticks) || ticks > DateTimeOffset.MaxValue.UtcTicks) return false;
        hash = stem[20..]; return true;
    }
    // Identical content keeps only its newest timestamp, so a repeated state returns to the top instead of being stored twice.
    private static void MoveDuplicates(List<VersionFile> newestFirst)
    {
        for (var i = newestFirst.Count - 1; i > 0; i--)
            if (newestFirst[i].Hash == newestFirst[0].Hash) { File.Delete(newestFirst[i].Path); newestFirst.RemoveAt(i); }
    }
    // Over a bound, delete the oldest version with a newer version on the same UTC day, or the oldest of all once every day holds one.
    private static void Thin(List<VersionFile> newestFirst)
    {
        var files = Enumerable.Reverse(newestFirst).ToList();
        var bytes = files.Sum(file => file.Length);
        while (files.Count > 1 && (files.Count > MaxVersions || bytes > MaxVersionBytes))
        {
            var victim = Enumerable.Range(0, files.Count - 1).FirstOrDefault(i => files[i].Day == files[i + 1].Day);
            File.Delete(files[victim].Path); bytes -= files[victim].Length; files.RemoveAt(victim);
        }
    }
    // Follows the same retained set as bodies, so a sheet the backup catalog still names keeps its history.
    private void PruneVersions(HashSet<Guid> retained)
    {
        if (!Directory.Exists(VersionsDirectory)) return;
        foreach (var folder in Directory.EnumerateDirectories(VersionsDirectory))
        {
            if (!Guid.TryParseExact(Path.GetFileName(folder), "N", out var id) || retained.Contains(id)) continue;
            foreach (var file in Directory.EnumerateFiles(folder).Where(OwnedVersionFile)) File.Delete(file);
            if (!Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder);
            newestVersions.Remove(id);
        }
    }
    private static bool OwnedVersionFile(string path)
    {
        var name = Path.GetFileName(path);
        return name.Length > VersionStemLength && TryVersionStem(name[..VersionStemLength], out _, out _) &&
            (name.EndsWith(".json", StringComparison.Ordinal) || name.EndsWith(".tmp", StringComparison.Ordinal));
    }
    // Dark is workspace presentation and never distinguishes content. The encoding stays explicit so hashes survive serializer changes.
    private static string ContentHash(SheetDocument sheet)
    {
        var text = new StringBuilder(sheet.Source);
        if (sheet.GeneratedUuids is { } uuids)
        {
            foreach (var statement in uuids.Statements) text.Append('\0').Append(statement.ToString("N"));
            foreach (var binding in uuids.Bindings) text.Append('\0').Append(binding.Statement.ToString("N")).Append('\0').Append(binding.Site).Append('\0').Append(binding.Value.ToString("N"));
            foreach (var roll in uuids.Dice ?? []) text.Append("\0dice\0").Append(roll.Statement.ToString("N")).Append('\0').Append(roll.Formula).Append('\0').Append(string.Join(',', roll.Faces));
        }
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
    }
}
