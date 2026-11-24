namespace Calc.Documents;

/// <summary>What this computer last agreed with the folder about one sheet. Body stamp avoids rereading unchanged sheets.</summary>
public sealed record SyncBase(Guid SheetId, Guid Revision, string Hash, string Name, long BodyTicks, long BodyLength);
/// <summary>Local-only sync settings and bases, stored in sync.json beside the workspace. Folder null means off.</summary>
public sealed record SyncStateDocument(int Version, string? Folder, SyncBase[] Bases);

public enum SyncStatus { Off, FolderUnavailable, Synchronized, Waiting, Failed }

public sealed record SyncReport(SyncStatus Status, WorkspaceDocument? Workspace, IReadOnlySet<Guid> ChangedSheets)
{
    public int Published { get; init; }
    public int Imported { get; init; }
    public int Updated { get; init; }
    public int Deleted { get; init; }
    public int Conflicts { get; init; }
    public int Restored { get; init; }
    public int Waiting { get; init; }
    public int Damaged { get; init; }
    public int Failed { get; init; }
    /// <summary>A locked file or a concurrent folder change deferred work; one bounded retry is worthwhile.</summary>
    public bool RetrySoon { get; init; }
    /// <summary>An incomplete file is being given time to finish downloading; a pass after this delay can set it aside.</summary>
    public TimeSpan? RecheckAfter { get; init; }
    public string? Problem { get; init; }
}

/// <summary>Three-way sheet synchronization through a user-selected folder. One pass reconciles a folder snapshot with the
/// local workspace: fast-forward when the folder descends from this computer's base, publish local edits on top of the base,
/// and otherwise keep the local sheet and import the other revision as a conflict copy. Nothing is deleted locally unless a
/// Calc tombstone descends from an unchanged base; a file removed outside Calc is restored from the local copy.
/// Placeholders, incomplete, locked and future-format files are never read into sheets or overwritten.
/// Not thread-safe: call <see cref="Synchronize"/> on the thread that owns the store.</summary>
public sealed class FolderSync
{
    public const string StateFile = "sync.json";
    public const int MaxBases = WorkspaceStore.MaxSheets * 2;
    public static readonly TimeSpan IncompleteGrace = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan TombstoneLifetime = TimeSpan.FromDays(180);
    private static readonly TimeSpan TrustedStampAge = TimeSpan.FromSeconds(2);
    private readonly WorkspaceStore store;
    private readonly string device;
    private readonly Func<DateTimeOffset> clock;
    private readonly Dictionary<Guid, (long Ticks, long Length, DateTimeOffset Since)> incomplete = [];

    public FolderSync(WorkspaceStore store, string device, Func<DateTimeOffset>? clock = null)
    {
        this.store = store;
        var clean = new string((device ?? "").Where(c => !char.IsControl(c)).ToArray()).Trim();
        this.device = clean.Length == 0 ? "Computer" : clean[..Math.Min(clean.Length, SyncFolderFiles.MaxDeviceLength)];
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public static string StatePath(string dataDirectory) => Path.Combine(dataDirectory, StateFile);

    /// <summary>Null when sync is off. A missing state file means off, so default startup reads nothing else.</summary>
    public static string? ConfiguredFolder(string dataDirectory)
    {
        var path = StatePath(dataDirectory);
        if (!File.Exists(path) && !File.Exists(path + ".bak")) return null;
        return LoadState(dataDirectory).Folder;
    }

    /// <summary>Selects or clears the folder. A new folder starts without bases, so the first pass merges both sides by identity.
    /// Clearing never touches files in the folder.</summary>
    public static void SetFolder(string dataDirectory, string? folder)
    {
        if (folder is not null)
        {
            folder = ValidateFolder(dataDirectory, folder);
            if (!Directory.Exists(folder)) throw new DirectoryNotFoundException("Sync folder not found");
        }
        var path = StatePath(dataDirectory);
        if (folder is null && !File.Exists(path) && !File.Exists(path + ".bak")) return;
        var current = File.Exists(path) || File.Exists(path + ".bak") ? TryLoadState(dataDirectory) : null;
        if (current?.Folder is { } existing && folder is not null && SameFolder(existing, folder)) return;
        AtomicJson.Write(path, new SyncStateDocument(1, folder, []));
    }

    public static string ValidateFolder(string dataDirectory, string folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Path.IsPathFullyQualified(folder)) throw new InvalidDataException("Choose a full folder path");
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        var data = Path.TrimEndingDirectorySeparator(Path.GetFullPath(dataDirectory));
        if (SameFolder(full, data) || Inside(full, data) || Inside(data, full)) throw new InvalidDataException("Choose a folder outside the calculator's own data folder");
        return full;
    }
    private static bool SameFolder(string a, string b) => string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)), StringComparison.OrdinalIgnoreCase);
    private static bool Inside(string child, string parent) => child.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    internal static SyncStateDocument LoadState(string dataDirectory)
    {
        var path = StatePath(dataDirectory);
        if (!File.Exists(path) && !File.Exists(path + ".bak")) return new(1, null, []);
        return AtomicJson.Load<SyncStateDocument>(path, 512_000, ValidateState).Value;
    }
    private static SyncStateDocument? TryLoadState(string dataDirectory)
    {
        try { return LoadState(dataDirectory); }
        catch (Exception e) when (e is IOException or InvalidDataException or System.Text.Json.JsonException or UnauthorizedAccessException) { return null; }
    }
    private static void ValidateState(SyncStateDocument state)
    {
        if (state.Version != 1) throw new UnsupportedDocumentVersionException();
        if (state.Bases is null || state.Bases.Length > MaxBases || state.Bases.Any(b => b is null || b.SheetId == Guid.Empty || b.Revision == Guid.Empty || b.Hash is null || b.Name is null) ||
            state.Bases.Select(b => b.SheetId).Distinct().Count() != state.Bases.Length || state.Folder is not null && !Path.IsPathFullyQualified(state.Folder))
            throw new InvalidDataException("Invalid sync state");
    }

    public SyncFolderSnapshot Scan(string folder) => SyncFolderFiles.Scan(folder, clock());

    public SyncReport Synchronize(SyncFolderSnapshot snapshot) => new Pass(this, snapshot).Run();

    private sealed class Pass(FolderSync owner, SyncFolderSnapshot snapshot)
    {
        private readonly WorkspaceStore store = owner.store;
        private readonly string folder = snapshot.Folder;
        private readonly DateTimeOffset now = owner.clock();
        private readonly HashSet<Guid> changed = [];
        private Dictionary<Guid, SyncBase> bases = [];
        private WorkspaceDocument workspace = null!;
        private bool workspaceChanged, basesChanged, retry;
        private int published, imported, updated, deleted, conflicts, restored, waiting, damaged, failed;
        private TimeSpan? recheck;
        private string? problem;

        internal SyncReport Run()
        {
            var state = LoadState(store.DataDirectory);
            if (state.Folder is null) return new(SyncStatus.Off, null, changed);
            if (!SameFolder(state.Folder, folder)) return new(SyncStatus.Off, null, changed) { RetrySoon = true };
            if (!snapshot.Available) return new(SyncStatus.FolderUnavailable, null, changed) { Problem = "Sync folder unavailable" };
            bases = state.Bases.ToDictionary(b => b.SheetId);
            workspace = store.CurrentWorkspace;
            var ids = workspace.Sheets.Select(s => s.Id).Concat(bases.Keys).Concat(snapshot.Canonical.Keys).Distinct().OrderBy(id => id).ToArray();
            foreach (var id in ids) Guarded(() => Reconcile(id));
            foreach (var duplicate in snapshot.Duplicates) Guarded(() => Duplicate(duplicate));
            Cleanup();
            foreach (var id in owner.incomplete.Keys.Where(id => !snapshot.Canonical.TryGetValue(id, out var e) || e.State != SyncFileState.Incomplete).ToArray()) owner.incomplete.Remove(id);
            if (basesChanged) AtomicJson.Write(StatePath(store.DataDirectory), new SyncStateDocument(1, state.Folder, bases.Values.OrderBy(b => b.SheetId).Take(MaxBases).ToArray()));
            var status = failed > 0 ? SyncStatus.Failed : waiting + damaged > 0 || retry ? SyncStatus.Waiting : SyncStatus.Synchronized;
            return new(status, workspaceChanged ? workspace : null, changed)
            {
                Published = published, Imported = imported, Updated = updated, Deleted = deleted, Conflicts = conflicts, Restored = restored,
                Waiting = waiting, Damaged = damaged, Failed = failed, RetrySoon = retry, RecheckAfter = recheck, Problem = problem,
            };
        }

        private void Guarded(Action action)
        {
            try { action(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or System.Text.Json.JsonException)
            { failed++; problem ??= e.Message; }
        }

        private void Reconcile(Guid id)
        {
            var hasLocal = workspace.Sheets.Any(s => s.Id == id);
            bases.TryGetValue(id, out var known);
            snapshot.Canonical.TryGetValue(id, out var entry);
            if (entry is not null && entry.State != SyncFileState.Ready)
            {
                if (!SetAsideIfAbandoned(id, entry)) return;
                entry = null;
            }
            var remote = entry?.File;
            if (!hasLocal)
            {
                if (known is null) { if (remote is { Deleted: false }) Import(remote); return; }
                if (remote is null || remote.Deleted) { Forget(id); return; }
                if (remote.Revision == known.Revision)
                {
                    if (Write(Next(id, Ancestry(remote.Revision, null, remote.Ancestors), deleted: true), remote.Revision)) Forget(id);
                    return;
                }
                Import(remote); // Edited elsewhere after this computer deleted it: the edit wins.
                return;
            }
            var local = Local(id, known);
            var localChanged = known is null || local.Hash != known.Hash;
            if (remote is null)
            {
                // Removed outside Calc (or never published). Restore from the local copy; an unchanged sheet keeps its revision.
                if (known is not null) restored++;
                var revision = known is not null && !localChanged ? known.Revision : Guid.NewGuid();
                Publish(local, revision, known is null || !localChanged ? [] : [known.Revision], expected: null);
                return;
            }
            if (remote.Deleted)
            {
                if (known is not null && !localChanged && (remote.Ancestors.Contains(known.Revision)) && workspace.Sheets.Length > 1)
                {
                    workspace = store.RemoveSyncedSheet(id); workspaceChanged = true; changed.Add(id); deleted++; Forget(id);
                    return;
                }
                // Edited here (or the last sheet): keep it and publish over the tombstone.
                Publish(local, Guid.NewGuid(), Ancestry(remote.Revision, known?.Revision, remote.Ancestors), remote.Revision);
                return;
            }
            if (known is not null && remote.Revision == known.Revision)
            {
                if (localChanged) Publish(local, Guid.NewGuid(), Ancestry(known.Revision, null, remote.Ancestors), remote.Revision);
                else if (local.Ticks != known.BodyTicks || local.Length != known.BodyLength) Remember(local, known.Revision); // Same content, newer stamp.
                return;
            }
            if (local.Hash == remote.Hash) { Remember(local, remote.Revision); return; }
            if (known is not null && !localChanged && remote.Ancestors.Contains(known.Revision))
            {
                var dark = store.ReadSheetForSync(id).Dark;
                workspace = store.ApplySyncedSheet(SyncFolderFiles.ToSheet(remote, dark), remote.Name, now); workspaceChanged = true;
                changed.Add(id); updated++;
                Remember(Local(id, null), remote.Revision);
                return;
            }
            // Both sides changed, or the folder holds a write that did not build on this computer's base.
            // Keep the local sheet, preserve the other revision as its own sheet, then publish local on top of both.
            if (!ConflictCopy(remote)) return;
            Publish(local, Guid.NewGuid(), Ancestry(remote.Revision, known?.Revision, remote.Ancestors), remote.Revision);
        }

        private void Duplicate(SyncFolderEntry entry)
        {
            var file = entry.File!;
            var redundant = file.Deleted || workspace.Sheets.Any(s => s.Id == file.Revision) ||
                snapshot.Canonical.TryGetValue(file.SheetId, out var canonical) && canonical.File?.Hash == file.Hash && canonical.File?.Deleted == false ||
                workspace.Sheets.Any(s => s.Id == file.SheetId) && Local(file.SheetId, bases.GetValueOrDefault(file.SheetId)).Hash == file.Hash;
            if (!redundant && !ConflictCopy(file)) return;
            File.Delete(entry.Path); // Its content is now an ordinary sheet (or already was).
        }

        /// <summary>The copy's identity is the other revision's ID, so computers resolving the same conflict produce the same sheet and file.</summary>
        private bool ConflictCopy(SyncSheetFile other)
        {
            var id = other.Revision;
            if (workspace.Sheets.Any(s => s.Id == id)) return true;
            if (workspace.Sheets.Length >= WorkspaceStore.MaxSheets) { failed++; problem ??= $"Conflict not resolved: maximum {WorkspaceStore.MaxSheets} sheets"; return false; }
            var suffix = $" (conflict, {other.Device})";
            var name = other.Name.Length + suffix.Length <= WorkspaceStore.MaxNameLength ? other.Name + suffix : other.Name[..Math.Max(1, WorkspaceStore.MaxNameLength - suffix.Length)] + suffix;
            if (name.Length > WorkspaceStore.MaxNameLength) name = name[..WorkspaceStore.MaxNameLength];
            var copy = other with { SheetId = id, Revision = id, Ancestors = [], Name = name, Hash = SyncFolderFiles.ContentHash(name, other.Source, other.GeneratedUuids) };
            workspace = store.ImportSyncedSheet(SyncFolderFiles.ToSheet(copy, workspace.Dark), name); workspaceChanged = true;
            changed.Add(id); conflicts++;
            var local = Local(id, null);
            if (SyncFolderFiles.ReadCanonical(folder, id) is null) Write(copy, null);
            Remember(local, id);
            return true;
        }

        private void Import(SyncSheetFile remote)
        {
            if (workspace.Sheets.Length >= WorkspaceStore.MaxSheets) { failed++; problem ??= $"Not imported: maximum {WorkspaceStore.MaxSheets} sheets"; return; }
            workspace = store.ImportSyncedSheet(SyncFolderFiles.ToSheet(remote, workspace.Dark), remote.Name); workspaceChanged = true;
            changed.Add(remote.SheetId); imported++;
            Remember(Local(remote.SheetId, null), remote.Revision);
        }

        private void Publish(LocalSheet local, Guid revision, Guid[] ancestors, Guid? expected)
        {
            var sheet = local.Sheet ?? store.ReadSheetForSync(local.Id);
            var file = new SyncSheetFile(SyncFolderFiles.Format, local.Id, revision, ancestors.Where(a => a != revision).Take(SyncFolderFiles.MaxAncestors).ToArray(),
                owner.device, now, false, local.Name, sheet.Source, local.Hash) { GeneratedUuids = sheet.GeneratedUuids };
            if (Write(file, expected)) { Remember(local, revision); published++; }
        }

        /// <summary>Compare-and-replace: the folder must still hold the revision this decision was based on.</summary>
        private bool Write(SyncSheetFile file, Guid? expected)
        {
            var current = SyncFolderFiles.ReadCanonical(folder, file.SheetId);
            var matches = expected is null ? current is null : current is { State: SyncFileState.Ready, File: { } f } && f.Revision == expected;
            if (!matches) { retry = true; return false; }
            SyncFolderFiles.WriteAtomic(folder, file);
            return true;
        }

        private SyncSheetFile Next(Guid id, Guid[] ancestors, bool deleted) =>
            new(SyncFolderFiles.Format, id, Guid.NewGuid(), ancestors.Take(SyncFolderFiles.MaxAncestors).ToArray(), owner.device, now, deleted, "", "", SyncFolderFiles.ContentHash("", "", null));

        private static Guid[] Ancestry(Guid first, Guid? second, Guid[] rest)
        {
            var list = new List<Guid> { first };
            if (second is { } s) list.Add(s);
            list.AddRange(rest);
            return list.Distinct().Take(SyncFolderFiles.MaxAncestors).ToArray();
        }

        /// <summary>An incomplete file that stays byte-identical past the grace period is moved aside (kept, never deleted)
        /// so local work can be published again. Placeholders, locked and future-format files are only waited on.</summary>
        private bool SetAsideIfAbandoned(Guid id, SyncFolderEntry entry)
        {
            if (entry.State == SyncFileState.Locked) { retry = true; waiting++; return false; }
            if (entry.State != SyncFileState.Incomplete) { waiting++; problem ??= entry.State == SyncFileState.Placeholder ? "Waiting for download" : "Sync file from a newer QNotch"; return false; }
            if (!owner.incomplete.TryGetValue(id, out var seen) || seen.Ticks != entry.Ticks || seen.Length != entry.Length)
                owner.incomplete[id] = seen = (entry.Ticks, entry.Length, now);
            if (now - seen.Since < IncompleteGrace)
            {
                waiting++; problem ??= "Waiting for a complete sync file";
                var left = IncompleteGrace - (now - seen.Since);
                recheck = recheck is { } r && r < left ? r : left;
                return false;
            }
            var aside = Path.Combine(folder, id.ToString("N") + "." + Guid.NewGuid().ToString("N") + SyncFolderFiles.DamagedExtension);
            File.Move(entry.Path, aside);
            owner.incomplete.Remove(id); damaged++; problem ??= "Damaged sync file set aside";
            return true;
        }

        private void Cleanup()
        {
            foreach (var path in snapshot.StaleTemporaries)
                try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            foreach (var entry in snapshot.Canonical.Values)
                if (entry.File is { Deleted: true } tombstone && !bases.ContainsKey(tombstone.SheetId) && now - tombstone.SavedAt > TombstoneLifetime &&
                    !workspace.Sheets.Any(s => s.Id == tombstone.SheetId))
                    try { if (SyncFolderFiles.ReadCanonical(folder, tombstone.SheetId)?.File?.Revision == tombstone.Revision) File.Delete(entry.Path); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }

        private sealed record LocalSheet(Guid Id, string Name, string Hash, long Ticks, long Length, SheetDocument? Sheet);
        private LocalSheet Local(Guid id, SyncBase? known)
        {
            var name = workspace.Sheets.Single(s => s.Id == id).Name;
            var stamp = store.SheetStamp(id) ?? throw new FileNotFoundException("Sheet body missing");
            if (known is not null && known.BodyTicks != 0 && known.Name == name && known.BodyTicks == stamp.Ticks && known.BodyLength == stamp.Length)
                return new(id, name, known.Hash, stamp.Ticks, stamp.Length, null);
            var sheet = store.ReadSheetForSync(id);
            var after = store.SheetStamp(id) ?? throw new FileNotFoundException("Sheet body missing");
            // File times advance in coarse ticks, so a stamp is only trusted once it was already old when observed:
            // any later save then necessarily carries a different time. A fresh stamp forces a reread next pass.
            var trusted = DateTime.UtcNow.Ticks - after.Ticks > TrustedStampAge.Ticks;
            return new(id, name, SyncFolderFiles.ContentHash(name, sheet.Source, sheet.GeneratedUuids), trusted ? after.Ticks : 0, after.Length, sheet);
        }
        private void Remember(LocalSheet local, Guid revision)
        {
            bases[local.Id] = new(local.Id, revision, local.Hash, local.Name, local.Ticks, local.Length); basesChanged = true;
        }
        private void Forget(Guid id) { if (bases.Remove(id)) basesChanged = true; }
    }
}
