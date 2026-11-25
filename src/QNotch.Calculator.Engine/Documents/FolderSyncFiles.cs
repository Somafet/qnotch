using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Calc.Documents;

/// <summary>One sheet in the sync folder, stored as {SheetId:N}.calcsheet. Every write gets a new Revision;
/// Ancestors lists the revisions it superseded (newest first, bounded) so a reader can tell a descendant from a divergent write.
/// A tombstone (Deleted) records a deletion made in Calc. Hash covers name, source and generated values and detects truncation.</summary>
public sealed record SyncSheetFile(int Format, Guid SheetId, Guid Revision, Guid[] Ancestors, string Device, DateTimeOffset SavedAt,
    bool Deleted, string Name, string Source, string Hash)
{
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public GeneratedUuidState? GeneratedUuids { get; init; }
}

public enum SyncFileState { Ready, Placeholder, Incomplete, Unsupported, Locked }

/// <summary>A file found in the sync folder. Only Ready entries have contents; others are never imported or overwritten.</summary>
public sealed record SyncFolderEntry(Guid SheetId, string Path, SyncFileState State, SyncSheetFile? File, long Length, long Ticks, string? Problem);

/// <summary>Immutable folder scan, safe to take on a background thread. Canonical holds {id}.calcsheet files;
/// Duplicates holds valid sheet files under other names (provider conflict copies such as "id (1).calcsheet").</summary>
public sealed record SyncFolderSnapshot(string Folder, bool Available, IReadOnlyDictionary<Guid, SyncFolderEntry> Canonical,
    IReadOnlyList<SyncFolderEntry> Duplicates, IReadOnlyList<string> StaleTemporaries, int Skipped);

public static class SyncFolderFiles
{
    public const string Extension = ".calcsheet";
    public const string TemporaryExtension = ".calcsheet-tmp";
    public const string DamagedExtension = ".calcsheet-damaged";
    public const int Format = 1;
    public const int MaxAncestors = 32;
    public const int MaxFiles = 1024;
    public const int MaxDeviceLength = 64;
    public const long MaxFileBytes = SheetStore.MaxDocumentBytes + 64_000;
    public static readonly TimeSpan StaleTemporaryAge = TimeSpan.FromHours(1);
    private const FileAttributes RecallOnOpen = (FileAttributes)0x40000;
    private const FileAttributes RecallOnDataAccess = (FileAttributes)0x400000;

    /// <summary>Cloud-provider placeholders (Files On-Demand and similar) whose bytes are not on this computer.
    /// Opening them would start a download, so the scan never reads them.</summary>
    public static bool IsPlaceholder(FileAttributes attributes) => (attributes & (FileAttributes.Offline | RecallOnOpen | RecallOnDataAccess)) != 0;

    public static string CanonicalPath(string folder, Guid id) => Path.Combine(folder, id.ToString("N") + Extension);

    public static string ContentHash(string name, string source, GeneratedUuidState? uuids)
    {
        var text = new StringBuilder().Append(name.Length).Append(':').Append(name).Append(source.Length).Append(':').Append(source);
        if (uuids is not null)
        {
            text.Append('|').Append(uuids.Statements.Length);
            foreach (var statement in uuids.Statements) text.Append(':').Append(statement.ToString("N"));
            text.Append('|').Append(uuids.Bindings.Length);
            foreach (var binding in uuids.Bindings)
                text.Append(':').Append(binding.Statement.ToString("N")).Append(':').Append(binding.Site.Length).Append(':').Append(binding.Site).Append(binding.Value.ToString("N"));
            // UUID-only state keeps its earlier hash; rolls extend it.
            if (uuids.Dice is { Length: > 0 } rolls)
            {
                text.Append("|dice").Append(rolls.Length);
                foreach (var roll in rolls)
                    text.Append(':').Append(roll.Statement.ToString("N")).Append(':').Append(roll.Formula.Length).Append(':').Append(roll.Formula).Append('=').Append(string.Join(',', roll.Faces));
            }
        }
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
    }

    public static SyncFolderSnapshot Scan(string folder, DateTimeOffset now)
    {
        var canonical = new Dictionary<Guid, SyncFolderEntry>();
        var duplicates = new List<SyncFolderEntry>();
        var stale = new List<string>();
        var skipped = 0;
        DirectoryInfo directory;
        try
        {
            directory = new DirectoryInfo(folder);
            if (!directory.Exists) return new(folder, false, canonical, duplicates, stale, 0);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return new(folder, false, canonical, duplicates, stale, 0); }
        var options = new EnumerationOptions { RecurseSubdirectories = false, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Directory, MatchType = MatchType.Simple };
        IEnumerable<FileInfo> files;
        try { files = directory.EnumerateFiles("*", options).ToArray(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return new(folder, false, canonical, duplicates, stale, 0); }
        var seen = 0;
        foreach (var info in files)
        {
            if (info.Name.EndsWith(TemporaryExtension, StringComparison.OrdinalIgnoreCase))
            {
                if (info.Name.StartsWith('.') && now.UtcDateTime - info.LastWriteTimeUtc > StaleTemporaryAge) stale.Add(info.FullName);
                continue;
            }
            if (!info.Name.EndsWith(Extension, StringComparison.OrdinalIgnoreCase)) continue;
            if (++seen > MaxFiles) { skipped++; continue; }
            var stem = info.Name[..^Extension.Length];
            Guid? stemId = stem.Length == 32 && Guid.TryParseExact(stem, "N", out var parsed) ? parsed : null;
            var entry = Read(info, stemId ?? Guid.Empty);
            if (entry is null) continue;
            if (entry.State == SyncFileState.Ready && entry.File is { } file)
            {
                if (stemId == file.SheetId && stem == file.SheetId.ToString("N")) canonical[file.SheetId] = entry;
                else duplicates.Add(entry with { SheetId = file.SheetId });
            }
            else if (stemId is { } id && stem == id.ToString("N")) canonical[id] = entry;
            else skipped++; // Unreadable files under foreign names are revisited by the next event.
        }
        return new(folder, true, canonical, duplicates, stale, skipped);
    }

    /// <summary>Reads one file. Null means it disappeared. A placeholder is classified from attributes alone.</summary>
    public static SyncFolderEntry? Read(FileInfo info, Guid stemId)
    {
        try
        {
            info.Refresh();
            if (!info.Exists) return null;
            var ticks = info.LastWriteTimeUtc.Ticks; var length = info.Length;
            if (IsPlaceholder(info.Attributes)) return new(stemId, info.FullName, SyncFileState.Placeholder, null, length, ticks, "Not downloaded to this computer");
            if (length == 0) return new(stemId, info.FullName, SyncFileState.Incomplete, null, length, ticks, "Empty file");
            if (length > MaxFileBytes) return new(stemId, info.FullName, SyncFileState.Incomplete, null, length, ticks, "File too large");
            byte[] bytes;
            using (var stream = new FileStream(info.FullName, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
            {
                if (stream.Length > MaxFileBytes) return new(stemId, info.FullName, SyncFileState.Incomplete, null, stream.Length, ticks, "File too large");
                bytes = new byte[checked((int)stream.Length)];
                stream.ReadExactly(bytes);
                if (stream.ReadByte() != -1) return new(stemId, info.FullName, SyncFileState.Locked, null, length, ticks, "File changed while reading");
            }
            try
            {
                var file = JsonSerializer.Deserialize<SyncSheetFile>(bytes) ?? throw new InvalidDataException("Empty sync file");
                Validate(file);
                return new(file.SheetId, info.FullName, SyncFileState.Ready, file, length, ticks, null);
            }
            catch (UnsupportedDocumentVersionException e) { return new(stemId, info.FullName, SyncFileState.Unsupported, null, length, ticks, e.Message); }
            catch (Exception e) when (e is JsonException or InvalidDataException or ArgumentException or FormatException)
            { return new(stemId, info.FullName, SyncFileState.Incomplete, null, length, ticks, e.Message); }
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { _ = e; return null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { return new(stemId, info.FullName, SyncFileState.Locked, null, 0, 0, e.Message); }
    }

    internal static SyncFolderEntry? ReadCanonical(string folder, Guid id) => Read(new FileInfo(CanonicalPath(folder, id)), id);

    public static void Validate(SyncSheetFile file)
    {
        if (file.Format != Format) throw new UnsupportedDocumentVersionException();
        if (file.SheetId == Guid.Empty || file.Revision == Guid.Empty || file.Ancestors is null || file.Ancestors.Length > MaxAncestors ||
            file.Ancestors.Any(a => a == Guid.Empty || a == file.Revision) || file.Device is null || file.Device.Length > MaxDeviceLength ||
            file.Device.Any(char.IsControl) || file.Name is null || file.Source is null || file.Hash is null)
            throw new InvalidDataException("Invalid sync file");
        if (file.Deleted)
        {
            if (file.Name.Length != 0 || file.Source.Length != 0 || file.GeneratedUuids is not null) throw new InvalidDataException("Invalid sync tombstone");
        }
        else
        {
            WorkspaceStore.ValidateSheetName(file.Name);
            SheetStore.Validate(ToSheet(file, false));
        }
        if (file.Hash != ContentHash(file.Name, file.Source, file.GeneratedUuids)) throw new InvalidDataException("Sync file content does not match its hash (incomplete download?)");
    }

    internal static SheetDocument ToSheet(SyncSheetFile file, bool dark) =>
        new(file.GeneratedUuids is null ? 1 : 2, file.SheetId, file.Source, dark) { GeneratedUuids = file.GeneratedUuids };

    /// <summary>Same-folder temporary file, flushed, then renamed over the canonical name. Readers see the old or the new file, never a partial one.</summary>
    internal static void WriteAtomic(string folder, SyncSheetFile file)
    {
        Validate(file);
        var path = CanonicalPath(folder, file.SheetId);
        var temporary = Path.Combine(folder, "." + file.SheetId.ToString("N") + "." + Guid.NewGuid().ToString("N") + TemporaryExtension);
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { JsonSerializer.Serialize(stream, file); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
