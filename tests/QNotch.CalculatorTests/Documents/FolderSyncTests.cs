using System.Text.Json;
using Calc.Documents;

namespace Calc.Documents.Tests;

/// <summary>Each Computer has its own data folder and store; they meet only through one shared sync folder,
/// as two PCs do through OneDrive/Dropbox. Provider behaviour (overwrites, duplicates, placeholders, truncation) is simulated on disk.</summary>
public sealed class FolderSyncTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "Calc-sync-tests", Guid.NewGuid().ToString("N"));
    private string Shared => Path.Combine(root, "shared");
    private readonly List<Computer> computers = [];
    public FolderSyncTests() => Directory.CreateDirectory(Shared);

    internal sealed class Computer : IDisposable
    {
        public readonly string Data;
        public readonly WorkspaceStore Store;
        public readonly FolderSync Sync;
        public DateTimeOffset Now = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
        public Computer(string data, string device)
        {
            Data = data; Store = new WorkspaceStore(data); Store.Load();
            Sync = new FolderSync(Store, device, () => Now);
        }
        public WorkspaceDocument Workspace => Store.Load().Workspace;
        public SyncReport Run(string folder) => Sync.Synchronize(Sync.Scan(folder));
        public string Source(Guid id) => Store.Open(id).Document.Source;
        public void Edit(Guid id, string source) { var doc = Store.Open(id).Document; Store.Save(doc with { Source = source }); }
        public Guid Add(string name, string source) => Store.Create(name, source).ActiveSheetId;
        public Dictionary<Guid, (string Name, string Source)> Sheets() => Workspace.Sheets.ToDictionary(s => s.Id, s => (s.Name, Source(s.Id)));
        public void Dispose() => Store.Dispose();
    }
    private Computer Machine(string device, bool connect = true)
    {
        var computer = new Computer(Path.Combine(root, device), device);
        computers.Add(computer);
        if (connect) FolderSync.SetFolder(computer.Data, Shared);
        return computer;
    }
    private string Canonical(Guid id) => SyncFolderFiles.CanonicalPath(Shared, id);
    private SyncSheetFile ReadFile(Guid id) => JsonSerializer.Deserialize<SyncSheetFile>(File.ReadAllBytes(Canonical(id)))!;
    private static void Quiesce(params Computer[] all)
    {
        for (var round = 0; round < 6; round++)
        {
            var writes = 0;
            foreach (var c in all) { var r = c.Run(SharedOf(c)); writes += r.Published + r.Imported + r.Updated + r.Conflicts + r.Deleted; Assert.Equal(0, r.Failed); }
            if (writes == 0) return;
        }
        throw new Xunit.Sdk.XunitException("Sync did not converge");
    }
    private static string SharedOf(Computer c) => FolderSync.ConfiguredFolder(c.Data)!;

    [Fact]
    public void OffByDefaultReadsAndWritesNothing()
    {
        var a = Machine("A", connect: false);
        Assert.Null(FolderSync.ConfiguredFolder(a.Data));
        Assert.False(File.Exists(FolderSync.StatePath(a.Data)));
        FolderSync.SetFolder(a.Data, null); // Clearing an unset folder creates no state file.
        Assert.False(File.Exists(FolderSync.StatePath(a.Data)));
        var report = a.Run(Shared);
        Assert.Equal(SyncStatus.Off, report.Status);
        Assert.Empty(Directory.EnumerateFileSystemEntries(Shared));
    }

    [Fact]
    public void FolderSelectionIsValidated()
    {
        var a = Machine("A", connect: false);
        Assert.Throws<InvalidDataException>(() => FolderSync.SetFolder(a.Data, "relative\\folder"));
        Assert.Throws<InvalidDataException>(() => FolderSync.SetFolder(a.Data, a.Data));
        Assert.Throws<InvalidDataException>(() => FolderSync.SetFolder(a.Data, Path.Combine(a.Data, "sheets")));
        Assert.Throws<InvalidDataException>(() => FolderSync.SetFolder(a.Data, root));
        Assert.Throws<DirectoryNotFoundException>(() => FolderSync.SetFolder(a.Data, Path.Combine(root, "missing")));
        FolderSync.SetFolder(a.Data, Shared + Path.DirectorySeparatorChar);
        Assert.Equal(Shared, FolderSync.ConfiguredFolder(a.Data));
    }

    [Fact]
    public void FirstConnectMergesBothComputersByStableIdentity()
    {
        var a = Machine("A"); var b = Machine("B");
        var travel = a.Add("Travel", "fuel = 40\nfuel * 3");
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
        Assert.Equal(3, a.Sheets().Count); // Two starter sheets plus Travel.
        Assert.Equal("fuel = 40\nfuel * 3", b.Source(travel));
        Assert.Equal("Travel", b.Workspace.Sheets.Single(s => s.Id == travel).Name);
        Assert.True(File.Exists(Canonical(travel)));
    }

    [Fact]
    public void EditsPropagateWithNewRevisionsAndIdlePassesWriteNothing()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        var first = ReadFile(id);
        var stamp = File.GetLastWriteTimeUtc(Canonical(id));
        for (var i = 0; i < 3; i++) { var idle = a.Run(Shared); Assert.Equal(0, idle.Published); Assert.Equal(SyncStatus.Synchronized, idle.Status); }
        Assert.Equal(stamp, File.GetLastWriteTimeUtc(Canonical(id)));

        a.Edit(id, "2 + 2");
        Assert.Equal(1, a.Run(Shared).Published);
        var second = ReadFile(id);
        Assert.NotEqual(first.Revision, second.Revision);
        Assert.Equal(first.Revision, second.Ancestors[0]);
        Assert.Equal("A", second.Device);
        var update = b.Run(Shared);
        Assert.Equal(1, update.Updated); Assert.Contains(id, update.ChangedSheets);
        Assert.Equal("2 + 2", b.Source(id));
        Assert.Equal(second.Revision, ReadFile(id).Revision); // Fast-forward does not rewrite the file.

        b.Store.Rename(id, "Budget");
        b.Run(Shared); a.Run(Shared);
        Assert.Equal("Budget", a.Workspace.Sheets.Single(s => s.Id == id).Name);
    }

    [Fact]
    public void SameLengthEditWithinOneFileTimeTickIsStillPublished()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        var body = Path.Combine(a.Data, "sheets", id.ToString("N") + ".json");
        a.Edit(id, "aaaa"); a.Run(Shared);
        var stamp = File.GetLastWriteTimeUtc(body);
        a.Edit(id, "bbbb");
        File.SetLastWriteTimeUtc(body, stamp); // Coarse system time: both saves share one tick.
        Assert.Equal(1, a.Run(Shared).Published);
        Assert.Equal("bbbb", ReadFile(id).Source);
    }

    [Fact]
    public void FastForwardKeepsReplacedContentInVersionHistory()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        a.Edit(id, "replacement"); a.Run(Shared);
        b.Run(Shared);
        var history = b.Store.LoadVersions(id).Versions.Select(v => v.Sheet.Source);
        Assert.Contains(WorkspaceStore.StarterSource, history);
    }

    [Fact]
    public void ConcurrentEditsKeepBothAsConflictCopyOnEveryComputer()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        a.Edit(id, "edited on A"); b.Edit(id, "edited on B");
        a.Run(Shared);
        var conflict = b.Run(Shared);
        Assert.Equal(1, conflict.Conflicts);
        Assert.Equal("edited on B", b.Source(id)); // The computer that finds the conflict keeps its own text in place.
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
        var sources = a.Sheets().Values.Select(v => v.Source).ToArray();
        Assert.Contains("edited on A", sources); Assert.Contains("edited on B", sources);
        Assert.Contains(a.Sheets().Values, v => v.Name == "Sheet (conflict, A)" && v.Source == "edited on A");
    }

    [Fact]
    public void ProviderOverwriteOfAnUnseenRevisionIsDetectedByAncestry()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        var original = File.ReadAllBytes(Canonical(id));
        b.Edit(id, "from B"); b.Run(Shared);
        var fromB = File.ReadAllBytes(Canonical(id));
        File.WriteAllBytes(Canonical(id), original); // A has not yet received B's upload.
        a.Edit(id, "from A"); a.Run(Shared);
        File.WriteAllBytes(Canonical(id), fromB); // Provider: last writer wins, A's upload is silently replaced.
        var report = a.Run(Shared);
        Assert.Equal(1, report.Conflicts);
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
        var sources = a.Sheets().Values.Select(v => v.Source).ToArray();
        Assert.Contains("from A", sources); Assert.Contains("from B", sources);
    }

    [Theory]
    [InlineData("{0} (1).calcsheet")]
    [InlineData("{0}-DESKTOP-7Q2.calcsheet")]
    [InlineData("{0} (Someone's conflicted copy 2026-11-01).calcsheet")]
    public void ProviderDuplicateFilesBecomeConflictCopies(string pattern)
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        var stale = File.ReadAllBytes(Canonical(id));
        b.Edit(id, "kept by provider as duplicate"); b.Run(Shared);
        var duplicate = Path.Combine(Shared, string.Format(pattern, id.ToString("N")));
        File.Move(Canonical(id), duplicate); File.WriteAllBytes(Canonical(id), stale);
        var report = a.Run(Shared);
        Assert.Equal(1, report.Conflicts);
        Assert.False(File.Exists(duplicate));
        Assert.Contains(a.Sheets().Values, v => v.Source == "kept by provider as duplicate");
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
    }

    [Fact]
    public void IdenticalDuplicateIsRemovedWithoutACopy()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        var duplicate = Path.Combine(Shared, id.ToString("N") + " (1).calcsheet");
        File.Copy(Canonical(id), duplicate);
        var report = a.Run(Shared);
        Assert.Equal(0, report.Conflicts);
        Assert.False(File.Exists(duplicate));
        Assert.Single(a.Workspace.Sheets);
    }

    [Fact]
    public void FileDeletedOutsideCalcIsRestoredAndNeverDeletesLocalWork()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        var revision = ReadFile(id).Revision;
        File.Delete(Canonical(id));
        var report = a.Run(Shared);
        Assert.Equal(1, report.Restored);
        Assert.Equal(revision, ReadFile(id).Revision); // Unchanged content keeps its revision, so other computers see no change.
        Assert.Equal(WorkspaceStore.StarterSource, a.Source(id));

        File.Delete(Canonical(id)); a.Edit(id, "edited after external delete");
        a.Run(Shared);
        Assert.Equal(revision, ReadFile(id).Ancestors.Single());
    }

    [Fact]
    public void UnavailableFolderChangesNothing()
    {
        var a = Machine("A");
        a.Add("Second", "1");
        a.Run(Shared);
        Directory.Delete(Shared, true);
        var before = a.Sheets();
        var report = a.Run(Shared);
        Assert.Equal(SyncStatus.FolderUnavailable, report.Status);
        Assert.Equal(before, a.Sheets());
        Assert.False(Directory.Exists(Shared));
    }

    [Fact]
    public void EmptiedFolderIsRepopulatedNotPropagatedAsDeletes()
    {
        var a = Machine("A"); var b = Machine("B");
        Quiesce(a, b);
        var before = a.Sheets();
        foreach (var file in Directory.EnumerateFiles(Shared)) File.Delete(file);
        a.Run(Shared); b.Run(Shared);
        Assert.Equal(before, a.Sheets()); Assert.Equal(before, b.Sheets());
        Assert.Equal(before.Count, Directory.EnumerateFiles(Shared, "*.calcsheet").Count());
    }

    [Fact]
    public void DeletionInCalcPropagatesAsTombstone()
    {
        var a = Machine("A"); var b = Machine("B");
        var extra = a.Add("Scratch", "1+1");
        Quiesce(a, b);
        a.Store.Delete(extra);
        a.Run(Shared);
        Assert.True(ReadFile(extra).Deleted);
        var report = b.Run(Shared);
        Assert.Equal(1, report.Deleted);
        Assert.DoesNotContain(b.Workspace.Sheets, s => s.Id == extra);
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
    }

    [Fact]
    public void EditWinsOverDeleteInBothOrders()
    {
        var a = Machine("A"); var b = Machine("B");
        var first = a.Add("First", "1"); var second = a.Add("Second", "2");
        Quiesce(a, b);
        // A deletes and publishes first; B had edited it.
        a.Store.Delete(first); a.Run(Shared);
        b.Edit(first, "B kept editing");
        b.Run(Shared);
        Assert.Equal("B kept editing", b.Source(first));
        // B edits and publishes first; A deletes without having seen it.
        b.Edit(second, "B edited second"); b.Run(Shared);
        a.Store.Delete(second); a.Run(Shared);
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
        Assert.Equal("B kept editing", a.Source(first));
        Assert.Equal("B edited second", a.Source(second));
    }

    [Fact]
    public void RemoteDeleteOfTheLastLocalSheetKeepsIt()
    {
        var a = Machine("A"); var b = Machine("B", connect: false);
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        // B imports A's only sheet and deletes its own starter, so it has one sheet that A then deletes.
        FolderSync.SetFolder(b.Data, Shared); b.Run(Shared);
        b.Store.Delete(b.Workspace.Sheets.Single(s => s.Id != id).Id); b.Run(Shared);
        Assert.Single(b.Workspace.Sheets);
        // Another computer deletes it in Calc: a tombstone that descends from B's base.
        var current = ReadFile(id);
        var tombstone = new SyncSheetFile(SyncFolderFiles.Format, id, Guid.NewGuid(), [current.Revision], "C", b.Now, true, "", "", SyncFolderFiles.ContentHash("", "", null));
        File.WriteAllText(Canonical(id), JsonSerializer.Serialize(tombstone));
        var report = b.Run(Shared);
        Assert.Equal(0, report.Deleted); Assert.Equal(1, report.Published);
        Assert.Contains(b.Workspace.Sheets, s => s.Id == id);
        Assert.False(ReadFile(id).Deleted);
    }

    [Fact]
    public void PlaceholderIsNeitherReadNorOverwritten()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        b.Edit(id, "newer, still in the cloud"); b.Run(Shared);
        var bytes = File.ReadAllBytes(Canonical(id));
        a.Edit(id, "local edit");
        File.SetAttributes(Canonical(id), FileAttributes.Offline);
        var waiting = a.Run(Shared);
        Assert.Equal(SyncStatus.Waiting, waiting.Status);
        Assert.Equal(1, waiting.Waiting);
        Assert.Equal("Waiting for download", waiting.Problem);
        Assert.Equal(bytes, File.ReadAllBytes(Canonical(id)));
        Assert.Equal("local edit", a.Source(id));
        File.SetAttributes(Canonical(id), FileAttributes.Normal); // Download finished.
        Assert.Equal(1, a.Run(Shared).Conflicts);
        Quiesce(a, b);
        var sources = a.Sheets().Values.Select(v => v.Source).ToArray();
        Assert.Contains("local edit", sources); Assert.Contains("newer, still in the cloud", sources);
    }

    [Theory]
    [InlineData((FileAttributes)0x400000, true)] // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
    [InlineData((FileAttributes)0x40000, true)]  // FILE_ATTRIBUTE_RECALL_ON_OPEN
    [InlineData(FileAttributes.Offline, true)]
    [InlineData(FileAttributes.Archive | FileAttributes.ReadOnly, false)]
    [InlineData((FileAttributes)0x80000 | FileAttributes.Archive, false)] // Pinned, fully present
    public void PlaceholderAttributesAreRecognized(FileAttributes attributes, bool placeholder) =>
        Assert.Equal(placeholder, SyncFolderFiles.IsPlaceholder(attributes));

    [Fact]
    public void PartialDownloadWaitsThenIsSetAsideWithoutLoss()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        var bytes = File.ReadAllBytes(Canonical(id));
        var truncated = bytes[..(bytes.Length / 2)];
        File.WriteAllBytes(Canonical(id), truncated);
        a.Edit(id, "local while partial");
        var first = a.Run(Shared);
        Assert.Equal(1, first.Waiting);
        Assert.Equal(FolderSync.IncompleteGrace, first.RecheckAfter);
        Assert.Equal(truncated, File.ReadAllBytes(Canonical(id)));
        a.Now += TimeSpan.FromMinutes(5);
        Assert.Equal(TimeSpan.FromMinutes(5), a.Run(Shared).RecheckAfter);
        Assert.Equal(truncated, File.ReadAllBytes(Canonical(id)));
        a.Now += TimeSpan.FromMinutes(6);
        var aside = a.Run(Shared);
        Assert.Equal(1, aside.Damaged); Assert.Equal(1, aside.Published);
        var damaged = Assert.Single(Directory.EnumerateFiles(Shared, "*" + SyncFolderFiles.DamagedExtension));
        Assert.Equal(truncated, File.ReadAllBytes(damaged));
        Assert.Equal("local while partial", ReadFile(id).Source);
    }

    [Fact]
    public void GrowingDownloadRestartsTheGracePeriod()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        var bytes = File.ReadAllBytes(Canonical(id));
        File.WriteAllBytes(Canonical(id), bytes[..10]);
        a.Run(Shared);
        a.Now += TimeSpan.FromMinutes(9);
        File.WriteAllBytes(Canonical(id), bytes[..20]); // Still arriving.
        a.Now += TimeSpan.FromMinutes(9);
        Assert.Equal(0, a.Run(Shared).Damaged);
        File.WriteAllBytes(Canonical(id), bytes); // Complete.
        var done = a.Run(Shared);
        Assert.Equal(SyncStatus.Synchronized, done.Status);
        Assert.Empty(Directory.EnumerateFiles(Shared, "*" + SyncFolderFiles.DamagedExtension));
    }

    [Fact]
    public void ValidJsonWithMismatchedHashIsTreatedAsIncomplete()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        var tampered = ReadFile(id) with { Source = "half written" };
        File.WriteAllText(Canonical(id), JsonSerializer.Serialize(tampered));
        var report = a.Run(Shared);
        Assert.Equal(1, report.Waiting);
        Assert.Equal(WorkspaceStore.StarterSource, a.Source(id));
    }

    [Fact]
    public void FutureFormatIsNeverOverwrittenOrSetAside()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        var future = File.ReadAllText(Canonical(id)).Replace("\"Format\":1", "\"Format\":2");
        File.WriteAllText(Canonical(id), future);
        a.Edit(id, "local");
        a.Now += TimeSpan.FromDays(1);
        var report = a.Run(Shared);
        Assert.Equal(1, report.Waiting); Assert.Equal(0, report.Damaged);
        Assert.Equal(future, File.ReadAllText(Canonical(id)));
    }

    [Fact]
    public void LockedFileDefersWithRetry()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        a.Run(Shared);
        a.Edit(id, "while locked");
        using (new FileStream(Canonical(id), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var report = a.Run(Shared);
            Assert.True(report.RetrySoon); Assert.Equal(0, report.Published);
        }
        Assert.Equal(1, a.Run(Shared).Published);
        Assert.Equal("while locked", ReadFile(id).Source);
    }

    [Fact]
    public void ChangeBetweenScanAndApplyIsNotOverwritten()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        a.Edit(id, "A pending");
        var snapshot = a.Sync.Scan(Shared); // Taken on a background thread...
        b.Edit(id, "B landed meanwhile"); b.Run(Shared);
        var landed = ReadFile(id).Revision;
        var report = a.Sync.Synchronize(snapshot); // ...applied after B's write arrived.
        Assert.True(report.RetrySoon); Assert.Equal(0, report.Published);
        Assert.Equal(landed, ReadFile(id).Revision);
        Quiesce(a, b);
        var sources = a.Sheets().Values.Select(v => v.Source).ToArray();
        Assert.Contains("A pending", sources); Assert.Contains("B landed meanwhile", sources);
    }

    [Fact]
    public void WritesAreAtomicAndStaleTemporariesAreCleaned()
    {
        var a = Machine("A");
        var foreign = Path.Combine(Shared, ".0123.4567" + SyncFolderFiles.TemporaryExtension);
        var fresh = Path.Combine(Shared, ".89ab.cdef" + SyncFolderFiles.TemporaryExtension);
        File.WriteAllText(foreign, "{"); File.WriteAllText(fresh, "{");
        File.SetLastWriteTimeUtc(foreign, a.Now.UtcDateTime - TimeSpan.FromHours(2));
        File.SetLastWriteTimeUtc(fresh, a.Now.UtcDateTime);
        a.Run(Shared);
        Assert.False(File.Exists(foreign)); Assert.True(File.Exists(fresh));
        Assert.Single(Directory.EnumerateFiles(Shared, "*.calcsheet"));
    }

    [Fact]
    public void AncestryStaysBounded()
    {
        var a = Machine("A");
        var id = a.Workspace.ActiveSheetId;
        for (var i = 0; i < SyncFolderFiles.MaxAncestors + 8; i++) { a.Edit(id, $"v{i}"); a.Run(Shared); }
        Assert.Equal(SyncFolderFiles.MaxAncestors, ReadFile(id).Ancestors.Length);
    }

    [Fact]
    public void FolderScanIsBounded()
    {
        var a = Machine("A");
        for (var i = 0; i < SyncFolderFiles.MaxFiles + 5; i++) File.WriteAllText(Path.Combine(Shared, $"junk{i}.calcsheet"), "x");
        var snapshot = a.Sync.Scan(Shared);
        Assert.Equal(SyncFolderFiles.MaxFiles + 5, snapshot.Skipped);
        Assert.Empty(snapshot.Canonical);
    }

    [Fact]
    public void CorruptStateRecoversFromBackupWithoutLosingWork()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        Quiesce(a, b);
        a.Edit(id, "one"); a.Run(Shared);
        a.Edit(id, "two"); a.Run(Shared);
        File.WriteAllText(FolderSync.StatePath(a.Data), "{ broken");
        a.Edit(id, "three");
        Quiesce(a, b);
        Assert.Equal(a.Sheets(), b.Sheets());
        Assert.Contains(a.Sheets().Values, v => v.Source == "three");
    }

    [Fact]
    public void ClearingStopsSyncAndLeavesFolderFilesAlone()
    {
        var a = Machine("A");
        a.Run(Shared);
        var files = Directory.EnumerateFiles(Shared).Select(File.ReadAllBytes).ToArray();
        FolderSync.SetFolder(a.Data, null);
        Assert.Null(FolderSync.ConfiguredFolder(a.Data));
        a.Edit(a.Workspace.ActiveSheetId, "after clearing");
        Assert.Equal(SyncStatus.Off, a.Run(Shared).Status);
        Assert.Equal(files, Directory.EnumerateFiles(Shared).Select(File.ReadAllBytes).ToArray());
    }

    [Fact]
    public void GeneratedUuidsTravelWithTheSheet()
    {
        var a = Machine("A"); var b = Machine("B");
        var id = a.Workspace.ActiveSheetId;
        var statement = Guid.NewGuid(); var value = Guid.NewGuid();
        var doc = a.Store.Open(id).Document;
        a.Store.Save(doc with { Version = 2, Source = "uuid", GeneratedUuids = new(1, [statement], [new(statement, "0", value)]) });
        Quiesce(a, b);
        var received = b.Store.Open(id).Document;
        Assert.Equal(value, received.GeneratedUuids!.Bindings.Single().Value);
    }

    /// <summary>Random edits, deletes, adds and syncs on three computers, with scans applied late to model background delays.
    /// Oracle: every text that no user replaced or deleted still exists on every computer after quiescence, and all computers agree.</summary>
    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)] [InlineData(6)]
    public void RandomInterleavingsLoseNothingAndConverge(int seed)
    {
        var random = new Random(seed);
        var all = new[] { Machine("A"), Machine("B"), Machine("C") };
        var superseded = new HashSet<string>();
        var produced = new HashSet<string>(all.SelectMany(c => c.Sheets().Values.Select(v => v.Source)));
        var delayed = new Dictionary<Computer, SyncFolderSnapshot>();
        var counter = 0;
        for (var step = 0; step < 120; step++)
        {
            var c = all[random.Next(all.Length)];
            var sheets = c.Workspace.Sheets;
            switch (random.Next(10))
            {
                case 0 or 1 or 2:
                    {
                        var id = sheets[random.Next(sheets.Length)].Id;
                        superseded.Add(c.Source(id));
                        var text = $"text {++counter} by {c.Data[^1]}"; produced.Add(text); c.Edit(id, text); break;
                    }
                case 3 when sheets.Length < 8:
                    { var text = $"new {++counter}"; produced.Add(text); c.Add($"S{counter}", text); break; }
                case 4 when sheets.Length > 1:
                    { var id = sheets[random.Next(sheets.Length)].Id; superseded.Add(c.Source(id)); c.Store.Delete(id); break; }
                case 5:
                    delayed[c] = c.Sync.Scan(Shared); break;
                case 6 when delayed.Remove(c, out var old):
                    Assert.Equal(0, c.Sync.Synchronize(old).Failed); break;
                default:
                    Assert.Equal(0, c.Run(Shared).Failed); break;
            }
        }
        Quiesce(all);
        var reference = all[0].Sheets();
        foreach (var c in all) Assert.Equal(reference, c.Sheets());
        var finalSources = reference.Values.Select(v => v.Source).ToHashSet();
        foreach (var text in produced.Except(superseded)) Assert.Contains(text, finalSources);
    }

    public void Dispose()
    {
        foreach (var c in computers) c.Dispose();
        try { Directory.Delete(root, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
