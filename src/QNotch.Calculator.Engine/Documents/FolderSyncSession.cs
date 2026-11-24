namespace Calc.Documents;

/// <summary>Event-driven lifecycle around <see cref="FolderSync"/>. Nothing exists until a folder is configured: no watcher,
/// timer or task. When on, folder notifications and host requests restart one debounce timer; a pass scans on the thread pool,
/// then applies through <c>post</c> on the store's thread. Retries are one-shot and bounded; there is no polling loop.</summary>
public sealed class FolderSyncSession : IDisposable
{
    public static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(750);
    public static readonly TimeSpan MaxDelay = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(5);
    public const int MaxRetries = 6;
    private static int liveWatchers;
    /// <summary>Process-wide count of folder watchers, so tests and diagnostics can prove an off setting creates none.</summary>
    public static int LiveWatchers => Volatile.Read(ref liveWatchers);

    private readonly object gate = new();
    private readonly WorkspaceStore store;
    private readonly string dataDirectory;
    private readonly FolderSync engine;
    private readonly Action<Action> post;
    private readonly Func<bool> canApply;
    private readonly Action<SyncReport> completed;
    private FileSystemWatcher? watcher;
    private Timer? timer;
    private DateTimeOffset? firstRequest;
    private bool running, again, disposed;
    private int retries;
    public string? Folder { get; private set; }
    public bool Watching { get { lock (gate) return watcher is not null; } }
    public bool TimerExists { get { lock (gate) return timer is not null; } }
    public int Passes { get; private set; }

    /// <param name="post">Runs an action on the thread that owns <paramref name="store"/>.</param>
    /// <param name="canApply">Called on that thread before applying; false (for example while composing or after a failed save) defers the pass.</param>
    public FolderSyncSession(WorkspaceStore store, string dataDirectory, string device, Action<Action> post, Func<bool> canApply, Action<SyncReport> completed, Func<DateTimeOffset>? clock = null)
    {
        this.store = store; this.dataDirectory = dataDirectory; this.post = post; this.canApply = canApply; this.completed = completed;
        engine = new FolderSync(store, device, clock);
    }

    /// <summary>Reads the configured folder and, only if one is set, starts watching and requests a first pass.</summary>
    public void Start() => Configure(FolderSync.ConfiguredFolder(dataDirectory));

    public void SetFolder(string? folder)
    {
        FolderSync.SetFolder(dataDirectory, folder);
        Configure(FolderSync.ConfiguredFolder(dataDirectory));
    }

    private void Configure(string? folder)
    {
        lock (gate)
        {
            if (disposed) return;
            StopLocked();
            Folder = folder;
            if (folder is null) return;
            WatchLocked(folder);
        }
        Request();
    }

    /// <summary>An unavailable folder gets no watcher; the next pass that finds it available installs one.</summary>
    private void WatchLocked(string folder)
    {
        try
        {
            watcher = new FileSystemWatcher(folder, "*" + SyncFolderFiles.Extension)
            {
                IncludeSubdirectories = false, InternalBufferSize = 16 * 1024,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.Attributes,
            };
            watcher.Changed += Notified; watcher.Created += Notified; watcher.Deleted += Notified; watcher.Renamed += Notified;
            watcher.Error += (_, _) => Request(); // Overflow: every pass rescans the whole folder anyway.
            watcher.EnableRaisingEvents = true;
            Interlocked.Increment(ref liveWatchers);
        }
        catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            watcher?.Dispose(); watcher = null; // Unavailable folder: report it; the next save or start retries.
        }
    }

    private void Notified(object sender, FileSystemEventArgs e) => Request();

    /// <summary>Coalesces requests: waits for a quiet <see cref="Debounce"/>, but never longer than <see cref="MaxDelay"/> after the first.</summary>
    public void Request() => Schedule(Debounce, request: true);

    /// <param name="request">A change request, coalesced under <see cref="MaxDelay"/>. A retry or recheck keeps its own delay.</param>
    private void Schedule(TimeSpan delay, bool request)
    {
        lock (gate)
        {
            if (disposed || Folder is null) return;
            if (request) retries = 0;
            if (running) { again = true; return; }
            var wait = delay;
            if (request)
            {
                var now = DateTimeOffset.UtcNow;
                firstRequest ??= now;
                var latest = firstRequest.Value + MaxDelay - now;
                if (latest < wait) wait = latest < TimeSpan.Zero ? TimeSpan.Zero : latest;
            }
            timer ??= new Timer(_ => Fire());
            timer.Change(wait, Timeout.InfiniteTimeSpan);
        }
    }

    private void Fire()
    {
        string folder;
        lock (gate)
        {
            if (disposed || Folder is null || running) return;
            running = true; again = false; firstRequest = null; folder = Folder;
        }
        SyncFolderSnapshot snapshot;
        try { snapshot = engine.Scan(folder); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { snapshot = new(folder, false, new Dictionary<Guid, SyncFolderEntry>(), [], [], 0); }
        post(() => Apply(snapshot));
    }

    private void Apply(SyncFolderSnapshot snapshot)
    {
        SyncReport? report = null;
        try
        {
            lock (gate) if (disposed) return;
            if (!canApply()) report = null;
            else
            {
                Passes++;
                try { report = engine.Synchronize(snapshot); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or System.Text.Json.JsonException)
                { report = new(SyncStatus.Failed, null, new HashSet<Guid>()) { Problem = e.Message }; }
                completed(report);
            }
        }
        finally
        {
            lock (gate)
            {
                running = false; var rerun = again; again = false; TimeSpan? delay = null;
                if (!disposed && watcher is null && Folder is not null && report is { Status: not (SyncStatus.FolderUnavailable or SyncStatus.Off) })
                    WatchLocked(Folder);
                if (!rerun && report is not null)
                {
                    if (report.RetrySoon && retries < MaxRetries) { retries++; delay = RetryDelay; }
                    else if (report.RecheckAfter is { } after) delay = after + TimeSpan.FromSeconds(1);
                }
                else if (!rerun && report is null && retries < MaxRetries) { retries++; delay = RetryDelay; }
                // Armed under the lock: a change request arriving after this replaces a long recheck, never the other way round.
                if (rerun) Request();
                else if (delay is { } d) Schedule(d, request: false);
            }
        }
    }

    private void StopLocked()
    {
        if (watcher is not null)
        {
            watcher.EnableRaisingEvents = false; watcher.Dispose(); watcher = null;
            Interlocked.Decrement(ref liveWatchers);
        }
        timer?.Dispose(); timer = null; firstRequest = null; again = false;
    }

    public void Dispose()
    {
        lock (gate) { if (disposed) return; disposed = true; StopLocked(); Folder = null; }
    }
}
