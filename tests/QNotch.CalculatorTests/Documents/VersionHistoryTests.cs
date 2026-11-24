using System.Text.Json;
using Calc.Core;
using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class VersionHistoryTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    private static readonly DateTimeOffset Start = new(2026, 10, 31, 12, 0, 0, TimeSpan.Zero);
    private string Folder(Guid id) => Path.Combine(directory, "versions", id.ToString("N"));
    private string Body(Guid id) => Path.Combine(directory, "sheets", id.ToString("N") + ".json");
    private string[] VersionFiles(Guid id) => Directory.Exists(Folder(id)) ? Directory.GetFiles(Folder(id), "*.json") : [];
    private (WorkspaceStore Store, Guid Id) Open()
    {
        var store = new WorkspaceStore(directory); var id = store.Load().Workspace.ActiveSheetId; store.Open(id);
        return (store, id);
    }
    private static void Edit(WorkspaceStore store, Guid id, string source) => store.Save(store.Open(id).Document with { Source = source });
    private static void EditWithFunctions(WorkspaceStore store, Guid id, string source)
    {
        var sheet = store.Open(id).Document with { Source = source };
        store.SaveWithFunctions(sheet, FunctionUpdate.Prepare(source, store.LoadFunctions(), store.LoadFunctionReceipts(id)));
    }
    private static string[] Sources(WorkspaceStore store, Guid id) => store.LoadVersions(id).Versions.Select(version => version.Sheet.Source).ToArray();
    private static SheetVersion Version(WorkspaceStore store, Guid id, string source) => store.LoadVersions(id).Versions.Single(version => version.Sheet.Source == source);
    private static string Run(WorkspaceStore store, string line) => new SheetEvaluationSession().EvaluateWithFunctions(line, store.LoadFunctions(), []).Results[0].Display;

    [Fact]
    public void CapturesOnlyWhenSavedContentDiffersAndFiveMinutesPassed()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a");
        Assert.True(store.CaptureVersion(id, Start));
        Edit(store, id, "b");
        Assert.False(store.CaptureVersion(id, Start.AddMinutes(5).AddTicks(-1)));
        Assert.Equal(["a"], Sources(store, id));
        Assert.True(store.CaptureVersion(id, Start.AddMinutes(5)));
        Assert.Equal(["b", "a"], Sources(store, id));
    }
    [Fact]
    public void ForcedCaptureSkipsTheIntervalButNeverStoresIdenticalContent()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a"); store.CaptureVersion(id, Start);
        Assert.True(store.CaptureVersion(id, Start.AddSeconds(1), true));
        Assert.True(store.CaptureVersion(id, Start.AddHours(1)));
        Assert.Single(VersionFiles(id));
        Edit(store, id, "b"); Assert.True(store.CaptureVersion(id, Start.AddHours(1).AddSeconds(1), true));
        Assert.Equal(["b", "a"], Sources(store, id));
    }
    [Fact]
    public void RepeatedContentReturnsToTheTopInsteadOfBeingStoredTwice()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a"); store.CaptureVersion(id, Start);
        Edit(store, id, "b"); store.CaptureVersion(id, Start.AddHours(1));
        Edit(store, id, "a"); store.CaptureVersion(id, Start.AddHours(2));
        Assert.Equal(["a", "b"], Sources(store, id));
        Assert.Equal(2, VersionFiles(id).Length);
        Assert.Equal(Start.AddHours(2), store.LoadVersions(id).Versions[0].CapturedAt);
    }
    [Fact]
    public void AnEmptySheetWithoutHistoryHasNothingToPreserve()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "");
        Assert.True(store.CaptureVersion(id, Start, true));
        Assert.False(Directory.Exists(Folder(id)));
        Assert.Empty(store.LoadVersions(id).Versions);
    }
    [Fact]
    public void TimestampsComeFromTheCallerAndStayOrderedWhenTheClockMovesBack()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a"); store.CaptureVersion(id, Start);
        Edit(store, id, "b");
        Assert.False(store.CaptureVersion(id, Start.AddDays(-1)));
        Assert.True(store.CaptureVersion(id, Start.AddDays(-1), true));
        var versions = store.LoadVersions(id).Versions;
        Assert.Equal(["b", "a"], versions.Select(version => version.Sheet.Source));
        Assert.Equal(Start.AddTicks(1), versions[0].CapturedAt);
        Assert.Equal(64, versions[0].Hash.Length);
    }
    [Fact]
    public void CountBoundDropsTheOldestWhenEveryDayHoldsOneVersion()
    {
        var (store, id) = Open(); using var _ = store;
        for (var day = 0; day < WorkspaceStore.MaxVersions + 1; day++)
        { Edit(store, id, "day " + day); store.CaptureVersion(id, Start.AddDays(day)); }
        var sources = Sources(store, id);
        Assert.Equal(WorkspaceStore.MaxVersions, sources.Length);
        Assert.Equal("day 64", sources[0]); Assert.Equal("day 1", sources[^1]);
    }
    [Fact]
    public void CountBoundThinsOlderDaysBeforeDroppingAnyDayEntirely()
    {
        var (store, id) = Open(); using var _ = store;
        // 40 versions on the first day, then 40 on the next: 16 over the bound, all from the older day.
        for (var i = 0; i < 40; i++) { Edit(store, id, "first " + i); store.CaptureVersion(id, Start.AddMinutes(5 * i)); }
        for (var i = 0; i < 40; i++) { Edit(store, id, "second " + i); store.CaptureVersion(id, Start.AddDays(1).AddMinutes(5 * i)); }
        var sources = Sources(store, id);
        Assert.Equal(WorkspaceStore.MaxVersions, sources.Length);
        Assert.Equal(Enumerable.Range(0, 40).Reverse().Select(i => "second " + i), sources.Take(40));
        Assert.Equal(Enumerable.Range(16, 24).Reverse().Select(i => "first " + i), sources.Skip(40));
    }
    [Fact]
    public void ByteBoundKeepsTheNewestAndStaysWithinEightMebibytes()
    {
        var (store, id) = Open(); using var _ = store;
        // Non-ASCII source is escaped to six JSON bytes per character, so each copy takes about 1.1 MB.
        for (var i = 0; i < 12; i++)
        { Edit(store, id, i + new string('é', 190_000)); store.CaptureVersion(id, Start.AddDays(i)); }
        var bytes = VersionFiles(id).Sum(path => new FileInfo(path).Length);
        Assert.InRange(bytes, 1, WorkspaceStore.MaxVersionBytes);
        Assert.InRange(VersionFiles(id).Length, 2, 11);
        Assert.StartsWith("11", store.LoadVersions(id).Versions[0].Sheet.Source);
    }
    [Fact]
    public void RestoreCapturesCurrentContentFirstAndCanBeUndoneByRestoringAgain()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "old"); store.CaptureVersion(id, Start);
        Edit(store, id, "current");
        var target = store.LoadVersions(id).Versions.Single();
        Assert.Equal("current", store.Open(id).Document.Source); // Listing a version changes nothing.
        var restored = store.RestoreVersion(id, target.Hash, Start.AddMinutes(1));
        Assert.Equal("old", restored.Document.Source); Assert.Equal("old", store.Open(id).Document.Source);
        Assert.Equal(["current", "old"], Sources(store, id));
        var back = store.RestoreVersion(id, Version(store, id, "current").Hash, Start.AddMinutes(2));
        Assert.Equal("current", back.Document.Source); Assert.Equal("current", store.Open(id).Document.Source);
        Assert.Contains("old", Sources(store, id));
        Assert.Throws<InvalidDataException>(() => store.RestoreVersion(id, new string('0', 64), Start.AddMinutes(3)));
    }
    [Fact]
    public void RestoreSurvivesRestartAndKeepsWorkspaceSchemaUntouched()
    {
        Guid id; string catalog;
        var (store, sheet) = Open(); id = sheet;
        using (store)
        {
            catalog = File.ReadAllText(Path.Combine(directory, "workspace.json"));
            Edit(store, id, "old"); store.CaptureVersion(id, Start);
            Edit(store, id, "current");
            store.RestoreVersion(id, Version(store, id, "old").Hash, Start.AddMinutes(1));
        }
        Assert.Equal(catalog, File.ReadAllText(Path.Combine(directory, "workspace.json")));
        var (reopened, _) = Open(); using var _2 = reopened;
        Assert.Equal("old", reopened.Open(id).Document.Source);
        Assert.Equal(["current", "old"], Sources(reopened, id));
    }
    [Fact]
    public void VersionsKeepTheCompleteDocumentIncludingUuidBindings()
    {
        var (store, id) = Open(); using var _ = store;
        var session = new GeneratedUuidSession("id=uuid\nid"); session.Enable();
        var engine = new SheetEvaluationSession(); var context = new EvaluationContext { Uuids = session.Context };
        session.Supply(engine.EvaluateWithFunctions(session.Source, FunctionLibrary.Empty, [], context: context).UuidRequests, context.Uuids!);
        var document = store.Open(id).Document with { Version = 2, Source = session.Source, GeneratedUuids = session.Snapshot };
        store.Save(document); store.CaptureVersion(id, Start);
        store.Save(new(1, id, "plain", false));
        var restored = store.RestoreVersion(id, store.LoadVersions(id).Versions[^1].Hash, Start.AddMinutes(1)).Document;
        Assert.Equal(2, restored.Version); Assert.NotEmpty(restored.GeneratedUuids!.Bindings);
        Assert.Equal(document.GeneratedUuids!.Statements, restored.GeneratedUuids.Statements);
        Assert.Equal(document.GeneratedUuids.Bindings, restored.GeneratedUuids.Bindings);
        Assert.Equal(restored.GeneratedUuids.Bindings, store.Open(id).Document.GeneratedUuids!.Bindings);
    }
    [Fact]
    public void ContentThatDiffersOnlyInUuidBindingsIsADistinctVersion()
    {
        var (store, id) = Open(); using var _ = store;
        GeneratedUuidState Bound() => new(1, [Guid.NewGuid()], []);
        var document = store.Open(id).Document with { Version = 2, Source = "uuid" };
        store.Save(document with { GeneratedUuids = Bound() }); store.CaptureVersion(id, Start);
        store.Save(document with { GeneratedUuids = Bound() }); store.CaptureVersion(id, Start.AddMinutes(5));
        Assert.Equal(2, VersionFiles(id).Length);
    }
    [Fact]
    public void RestoringARemovedDefinitionDoesNotOverrideANewerOne()
    {
        var (store, id) = Open(); using var _ = store;
        EditWithFunctions(store, id, "f(x)=x+1"); store.CaptureVersion(id, Start);
        var other = store.Create("Other").ActiveSheetId;
        EditWithFunctions(store, other, "f(x)=x+2");
        EditWithFunctions(store, id, "1+1");
        Assert.Empty(store.LoadFunctionReceipts(id));
        var fingerprint = store.LoadFunctions().Fingerprint;
        var restored = store.RestoreVersion(id, Version(store, id, "f(x)=x+1").Hash, Start.AddMinutes(1));
        Assert.Equal("f(x)=x+1", restored.Document.Source);
        Assert.Equal(fingerprint, store.LoadFunctions().Fingerprint);
        Assert.False(FunctionUpdate.Prepare(restored.Document.Source, store.LoadFunctions(), store.LoadFunctionReceipts(id)).HasChanges);
        Assert.True(FunctionUpdate.Prepare(restored.Document.Source, store.LoadFunctions(), []).HasChanges); // Without the receipt this source would re-apply.
        Assert.Equal("12", Run(store, "f(10)"));
    }
    [Fact]
    public void RestoringARemovedForgetDoesNotDeleteALaterDefinition()
    {
        var (store, id) = Open(); using var _ = store;
        var other = store.Create("Other").ActiveSheetId;
        EditWithFunctions(store, other, "f(x)=x+1");
        EditWithFunctions(store, id, "forget f"); store.CaptureVersion(id, Start);
        EditWithFunctions(store, id, "1+1");
        EditWithFunctions(store, other, "f(x)=x+5");
        var restored = store.RestoreVersion(id, Version(store, id, "forget f").Hash, Start.AddMinutes(1));
        Assert.False(FunctionUpdate.Prepare(restored.Document.Source, store.LoadFunctions(), restored.FunctionReceipts!).HasChanges);
        Assert.Equal("15", Run(store, "f(10)"));
    }
    [Fact]
    public void RestoringAroundADefinitionNeitherLosesNorReappliesIt()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "plain"); store.CaptureVersion(id, Start);
        EditWithFunctions(store, id, "g(x)=x+1");
        store.RestoreVersion(id, Version(store, id, "plain").Hash, Start.AddMinutes(1));
        Assert.Equal("2", Run(store, "g(1)")); // Removing a directive never removes its function.
        Assert.Empty(store.LoadFunctionReceipts(id));
        var other = store.Create("Other").ActiveSheetId;
        EditWithFunctions(store, other, "g(x)=x+9");
        var back = store.RestoreVersion(id, Version(store, id, "g(x)=x+1").Hash, Start.AddMinutes(2));
        Assert.Single(back.FunctionReceipts!);
        Assert.False(FunctionUpdate.Prepare(back.Document.Source, store.LoadFunctions(), store.LoadFunctionReceipts(id)).HasChanges);
        Assert.Equal("10", Run(store, "g(1)"));
    }
    [Fact]
    public void ADirectiveNeverAppliedAtCaptureStaysPendingAfterRestore()
    {
        var (store, id) = Open(); using var _ = store;
        const string blocked = "h(x)=missing(x)";
        EditWithFunctions(store, id, blocked); store.CaptureVersion(id, Start);
        Edit(store, id, "1+1");
        var restored = store.RestoreVersion(id, Version(store, id, blocked).Hash, Start.AddMinutes(1));
        Assert.Empty(restored.FunctionReceipts!);
        Assert.False(store.LoadFunctions().Definitions.Any());
    }
    [Theory]
    [InlineData("{bad")]
    [InlineData("")]
    [InlineData("{\"Version\":2}")]
    [InlineData("null")]
    public void UnreadableVersionsAreSkippedAndReportedWithoutTouchingTheSheet(string corruption)
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a"); store.CaptureVersion(id, Start);
        Edit(store, id, "b"); store.CaptureVersion(id, Start.AddHours(1));
        Edit(store, id, "current");
        var oldest = VersionFiles(id).Order(StringComparer.Ordinal).First();
        var hash = Version(store, id, "a").Hash;
        File.WriteAllText(oldest, corruption);
        var history = store.LoadVersions(id);
        Assert.Equal(1, history.Skipped); Assert.Equal("b", history.Versions.Single().Sheet.Source);
        var refused = Assert.ThrowsAny<Exception>(() => store.RestoreVersion(id, hash, Start.AddHours(2)));
        Assert.True(refused is IOException or InvalidDataException or JsonException, refused.GetType().Name); // Failures the host reports in its save state.
        Assert.Equal("current", store.Open(id).Document.Source);
        Assert.Equal("b", store.LoadVersions(id).Versions[0].Sheet.Source); // A refused restore captures nothing.
    }
    [Fact]
    public void AlteredOrMisfiledContentIsNeverTrusted()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "secret"); store.CaptureVersion(id, Start);
        var file = VersionFiles(id).Single();
        File.WriteAllText(file, File.ReadAllText(file).Replace("secret", "edited"));
        Assert.Equal(1, store.LoadVersions(id).Skipped);
        var other = store.Create("Other").ActiveSheetId;
        Edit(store, other, "theirs"); store.CaptureVersion(other, Start);
        Directory.CreateDirectory(Folder(id));
        File.Copy(VersionFiles(other).Single(), Path.Combine(Folder(id), Path.GetFileName(VersionFiles(other).Single())));
        Assert.Equal(2, store.LoadVersions(id).Skipped);
    }
    [Fact]
    public void InterruptedWritesAndForeignFilesAreIgnored()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a"); store.CaptureVersion(id, Start);
        var file = VersionFiles(id).Single();
        File.WriteAllText(file + ".0123.tmp", "{partial"); File.WriteAllText(Path.Combine(Folder(id), "notes.json"), "mine");
        var history = store.LoadVersions(id);
        Assert.Equal(0, history.Skipped); Assert.Single(history.Versions);
    }
    [Fact]
    public void DeletionRemovesVersionsOnlyAfterTheBackupCatalogForgetsTheSheet()
    {
        var (store, keep) = Open(); using var _ = store;
        var doomed = store.Create("Doomed").ActiveSheetId;
        Edit(store, doomed, "a"); store.CaptureVersion(doomed, Start);
        Edit(store, keep, "kept"); store.CaptureVersion(keep, Start);
        File.WriteAllText(VersionFiles(doomed).Single() + ".0123.tmp", "{partial");
        var foreign = Path.Combine(directory, "versions", "not-a-sheet"); Directory.CreateDirectory(foreign); File.WriteAllText(Path.Combine(foreign, "keep.txt"), "x");
        store.Delete(doomed);
        Assert.True(Directory.Exists(Folder(doomed))); // workspace.json.bak still names it, and its body survives for recovery.
        Assert.True(File.Exists(Body(doomed)));
        store.Rename(keep, "Still here");
        Assert.False(Directory.Exists(Folder(doomed))); Assert.False(File.Exists(Body(doomed)));
        Assert.Single(VersionFiles(keep));
        Assert.True(File.Exists(Path.Combine(foreign, "keep.txt")));
    }
    [Fact]
    public void DeletionLeavesFilesItDoesNotOwn()
    {
        var (store, keep) = Open(); using var _ = store;
        var doomed = store.Create("Doomed").ActiveSheetId;
        Edit(store, doomed, "a"); store.CaptureVersion(doomed, Start);
        var note = Path.Combine(Folder(doomed), "note.txt"); File.WriteAllText(note, "mine");
        store.Delete(doomed); store.Rename(keep, "Next");
        Assert.True(File.Exists(note)); Assert.Empty(VersionFiles(doomed));
    }
    [Fact]
    public void RecoveringTheBackupCatalogStillFindsADeletedSheetsHistory()
    {
        Guid doomed;
        var (store, keep) = Open();
        using (store)
        {
            doomed = store.Create("Doomed").ActiveSheetId;
            Edit(store, doomed, "a"); store.CaptureVersion(doomed, Start);
            store.Delete(doomed);
        }
        File.WriteAllText(Path.Combine(directory, "workspace.json"), "{bad");
        using var reopened = new WorkspaceStore(directory);
        Assert.True(reopened.Load().Recovered);
        reopened.Open(doomed);
        Assert.Equal(["a"], Sources(reopened, doomed));
        Assert.Equal(keep, reopened.Load().Workspace.Sheets[0].Id);
    }
    [Fact]
    public void UnwritableHistoryFailsVisiblyAndLeavesSavingIntact()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a");
        Directory.CreateDirectory(Path.Combine(directory, "versions"));
        File.WriteAllText(Folder(id), "blocks the folder");
        Assert.ThrowsAny<IOException>(() => store.CaptureVersion(id, Start));
        Edit(store, id, "b");
        Assert.Equal("b", store.Open(id).Document.Source);
    }
    [Fact]
    public void FailedCaptureRefusesTheRestoreSoNothingIsLost()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "old"); store.CaptureVersion(id, Start);
        var hash = Version(store, id, "old").Hash;
        Edit(store, id, "current");
        using (new FileStream(VersionFiles(id).Single(), FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.ThrowsAny<IOException>(() => store.RestoreVersion(id, hash, Start.AddMinutes(1)));
        Assert.Equal("current", store.Open(id).Document.Source);
        Assert.False(File.Exists(Path.Combine(directory, "function-save.json")));
    }
    [Fact]
    public void LockedBodyAbandonsTheRestoreAndKeepsTheCurrentSheetAndReceipts()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "old"); store.CaptureVersion(id, Start);
        EditWithFunctions(store, id, "f(x)=x+1");
        var hash = Version(store, id, "old").Hash; var receipts = store.LoadFunctionReceipts(id);
        using (new FileStream(Body(id), FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.ThrowsAny<IOException>(() => store.RestoreVersion(id, hash, Start.AddMinutes(1)));
        Assert.Equal("f(x)=x+1", store.Open(id).Document.Source);
        Assert.Equal(receipts, store.LoadFunctionReceipts(id));
        Assert.False(File.Exists(Path.Combine(directory, "function-save.json")));
        Assert.Contains("f(x)=x+1", Sources(store, id)); // The attempted restore already preserved the current content.
    }
    [Fact]
    public void ReadOnlyBodyAbandonsTheRestore()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "old"); store.CaptureVersion(id, Start);
        Edit(store, id, "current");
        var hash = Version(store, id, "old").Hash;
        File.SetAttributes(Body(id), FileAttributes.ReadOnly);
        try
        {
            var refused = Assert.ThrowsAny<Exception>(() => store.RestoreVersion(id, hash, Start.AddMinutes(1)));
            Assert.True(refused is IOException or UnauthorizedAccessException, refused.GetType().Name);
            Assert.Equal("current", store.Open(id).Document.Source);
        }
        finally { File.SetAttributes(Body(id), FileAttributes.Normal); }
        Edit(store, id, "still saves");
        Assert.Equal("still saves", store.Open(id).Document.Source);
    }
    [Fact]
    public void LoadOpenSaveAndSelectReadNoHistory()
    {
        Guid id, other;
        var (store, sheet) = Open(); id = sheet;
        using (store)
        {
            Edit(store, id, "a"); store.CaptureVersion(id, Start);
            other = store.Create("Other").ActiveSheetId;
        }
        File.WriteAllText(Directory.GetFiles(Folder(id), "*.json").Single(), "{bad");
        using var reopened = new WorkspaceStore(directory);
        reopened.Load(); reopened.LoadFunctions();
        reopened.Open(other); reopened.Select(other); reopened.Open(id); reopened.Select(id);
        Assert.Equal("a", reopened.Open(id).Document.Source);
        reopened.Save(reopened.Open(id).Document with { Source = "b" });
        Assert.Equal(0, reopened.VersionScans);
    }
    [Fact]
    public void UnchangedIntervalNeedsNoFolderScan()
    {
        var (store, id) = Open(); using var _ = store;
        Edit(store, id, "a"); store.CaptureVersion(id, Start);
        var scans = store.VersionScans;
        for (var i = 1; i < 20; i++) { Edit(store, id, "a" + i); Assert.False(store.CaptureVersion(id, Start.AddSeconds(i))); }
        Assert.Equal(scans, store.VersionScans);
    }
    [Fact]
    public void ExistingFoldersWithoutHistoryKeepWorking()
    {
        var (store, id) = Open(); using var _ = store;
        Assert.False(Directory.Exists(Path.Combine(directory, "versions")));
        Assert.Equal(new VersionHistory([], 0).Skipped, store.LoadVersions(id).Skipped);
        Assert.Empty(store.LoadVersions(id).Versions);
        Assert.False(Directory.Exists(Path.Combine(directory, "versions")));
    }
    [Fact]
    public void CaptureRequiresAnOpenedSheet()
    {
        Guid id;
        var (store, sheet) = Open(); id = sheet;
        store.Dispose();
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        Assert.Throws<InvalidOperationException>(() => reopened.CaptureVersion(id, Start));
        Assert.Throws<InvalidOperationException>(() => reopened.RestoreVersion(id, new string('0', 64), Start));
    }
    [Fact]
    public void StoredVersionIsPlainJsonWithReceiptsAndUtcTimestamp()
    {
        var (store, id) = Open(); using var _ = store;
        EditWithFunctions(store, id, "f(x)=x"); store.CaptureVersion(id, Start.ToOffset(TimeSpan.FromHours(2)));
        using var json = JsonDocument.Parse(File.ReadAllBytes(VersionFiles(id).Single()));
        Assert.Equal(1, json.RootElement.GetProperty("Version").GetInt32());
        Assert.Equal(TimeSpan.Zero, json.RootElement.GetProperty("CapturedAt").GetDateTimeOffset().Offset);
        Assert.Equal(1, json.RootElement.GetProperty("Receipts").GetArrayLength());
        Assert.Equal("f(x)=x", json.RootElement.GetProperty("Sheet").GetProperty("Source").GetString());
    }
    public void Dispose() { try { Directory.Delete(directory, true); } catch (IOException) { } }
}
