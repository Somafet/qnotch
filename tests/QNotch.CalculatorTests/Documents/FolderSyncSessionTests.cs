using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class FolderSyncSessionTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "Calc-sync-session", Guid.NewGuid().ToString("N"));
    private string Data => Path.Combine(root, "data");
    private string Shared => Path.Combine(root, "shared");
    private readonly object storeGate = new();
    private readonly WorkspaceStore store;
    private readonly List<SyncReport> reports = [];
    private readonly SemaphoreSlim completedSignal = new(0);
    public FolderSyncSessionTests()
    {
        Directory.CreateDirectory(Shared);
        store = new WorkspaceStore(Data); store.Load();
    }
    private FolderSyncSession Session(Func<bool>? canApply = null) => new(store, Data, "A",
        action => { lock (storeGate) action(); }, canApply ?? (() => true),
        report => { lock (reports) reports.Add(report); completedSignal.Release(); });
    private async Task<SyncReport> NextReport()
    {
        Assert.True(await completedSignal.WaitAsync(TimeSpan.FromSeconds(20)), "No sync pass completed");
        lock (reports) return reports[^1];
    }

    [Fact]
    public async Task OffCreatesNoWatcherTimerOrPass()
    {
        using var session = Session();
        session.Start(); session.Request();
        Assert.Null(session.Folder);
        Assert.False(session.Watching); Assert.False(session.TimerExists);
        await Task.Delay(FolderSyncSession.Debounce * 2);
        Assert.Equal(0, session.Passes);
        Assert.Empty(Directory.EnumerateFileSystemEntries(Shared));
    }

    [Fact]
    public async Task EnablingWatchesAndReactsToFolderChangesThenClearingStopsEverything()
    {
        using var session = Session();
        session.SetFolder(Shared);
        Assert.True(session.Watching);
        var first = await NextReport();
        Assert.Equal(SyncStatus.Synchronized, first.Status); Assert.Equal(1, first.Published);

        // Another computer publishes a sheet; the watcher alone must bring it in.
        var other = Path.Combine(root, "other");
        using (var otherStore = new WorkspaceStore(other))
        {
            otherStore.Load(); FolderSync.SetFolder(other, Shared);
            otherStore.Create("Remote", "7*6");
            var engine = new FolderSync(otherStore, "B");
            engine.Synchronize(engine.Scan(Shared));
        }
        SyncReport report;
        do report = await NextReport(); while (report.Imported == 0);
        lock (storeGate) Assert.Contains(store.Load().Workspace.Sheets, s => s.Name == "Remote");

        session.SetFolder(null);
        Assert.False(session.Watching); Assert.False(session.TimerExists); Assert.Null(session.Folder);
        var passes = session.Passes;
        File.WriteAllText(Path.Combine(Shared, Guid.NewGuid().ToString("N") + ".calcsheet"), "{}");
        await Task.Delay(FolderSyncSession.Debounce * 3);
        Assert.Equal(passes, session.Passes);
    }

    [Fact]
    public async Task BurstsOfRequestsAreCoalesced()
    {
        using var session = Session();
        session.SetFolder(Shared);
        await NextReport();
        await Task.Delay(FolderSyncSession.Debounce * 3);
        while (completedSignal.CurrentCount > 0) await completedSignal.WaitAsync();
        var before = session.Passes;
        for (var i = 0; i < 40; i++) { session.Request(); await Task.Delay(10); }
        await NextReport();
        await Task.Delay(FolderSyncSession.Debounce * 3);
        Assert.InRange(session.Passes - before, 1, 2);
    }

    [Fact]
    public async Task DeferredPassIsRetriedNotDropped()
    {
        var allow = false;
        using var session = Session(() => Volatile.Read(ref allow));
        session.SetFolder(Shared);
        await Task.Delay(FolderSyncSession.Debounce * 2);
        Assert.Equal(0, session.Passes);
        Volatile.Write(ref allow, true);
        var report = await NextReport(); // One-shot retry after RetryDelay.
        Assert.Equal(1, report.Published);
    }

    [Fact]
    public void DisposeStopsWatcher()
    {
        var session = Session();
        session.SetFolder(Shared);
        Assert.True(session.Watching);
        session.Dispose();
        Assert.False(session.Watching); Assert.False(session.TimerExists);
        session.Request();
        Assert.False(session.TimerExists);
    }

    public void Dispose()
    {
        store.Dispose();
        try { Directory.Delete(root, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
