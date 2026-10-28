using System.Net.NetworkInformation;
using System.Windows.Threading;

namespace QNotch.Modules.Devices;

/// <summary>Main-thread coordinator; only changes, reconnects and bounded failed-work retries wake it.</summary>
sealed class DeviceSyncRuntime : IDisposable
{
    readonly ModuleContext ctx;
    readonly DevicesSettings settings;
    readonly Func<DeviceNode?> node;
    readonly string path;
    readonly object io = new();
    readonly HashSet<SharedTextSource> attached = [];
    readonly DispatcherTimer retry;
    DeviceSync state;
    bool loaded, failed, applying, working, again, disposed;
    string? lastNote;
    int attempts, saveVersion;
    public string Status { get; private set; } = "Sync is off for new devices. Enable it separately on both computers.";
    public event Action? Changed;
    public IReadOnlyList<NoteRevision> Conflicts => state.Notes.Count > 1 ? state.Notes : [];
    public DeviceSyncRuntime(ModuleContext ctx, DevicesSettings settings, Func<DeviceNode?> node)
    {
        this.ctx = ctx; this.settings = settings; this.node = node;
        path = Path.Combine(QNotch.Core.Paths.DataDir, "devices-sync.json");
        state = new(settings.Id, new());
        retry = new DispatcherTimer(DispatcherPriority.Background, ctx.Dispatcher);
        retry.Tick += async (_, _) => { retry.Stop(); await Pump(); };
        ctx.SharedText.Changed += Attach;
        if (ctx.Settings.ReadOnly) { loaded = true; return; }
        NetworkChange.NetworkAddressChanged += NetworkChanged;
        Attach();
        _ = Load();
    }
    async Task Load()
    {
        try
        {
            var journal = await Task.Run(() =>
            {
                if (!File.Exists(path)) return new SyncJournal();
                if (new FileInfo(path).Length > DeviceProtocol.MaxSync) throw new IOException("Sync journal is too large.");
                var result = DeviceProtocol.Decode<SyncJournal>(File.ReadAllBytes(path));
                DeviceSync.Merge(result.Notes, []);
                if (result.ActiveClock is null || result.ActiveClock.Count > DeviceSync.MaxAuthors || result.ClipboardCounter < 0) throw new IOException("Invalid sync journal.");
                return result;
            });
            if (disposed) return;
            state = new(settings.Id, journal); loaded = true; Configure();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or ArgumentException)
        { failed = true; Status = "Saved sync data could not be read. Sync is paused; your note and the journal have been preserved."; Changed?.Invoke(); }
    }
    void NetworkChanged(object? sender, EventArgs args) => ctx.Bus.Run(() => Schedule(1));
    void Attach()
    {
        foreach (var source in ctx.SharedText.Items)
            if (attached.Add(source)) source.Changed += text => LocalChanged(source.Id, text);
        Configure();
    }
    bool NotesOn => settings.Peers.Any(p => p.Receive && p.SyncNotes);
    bool ClipboardOn => settings.Peers.Any(p => p.Receive && p.SyncClipboard);
    SharedTextSource? Source(string id) => ctx.SharedText.Find(id);
    public void Configure()
    {
        if (!loaded || failed || disposed || ctx.Settings.ReadOnly) return;
        try
        {
            if (NotesOn && Source("note")?.Read() is { } current && lastNote != current)
            { if (lastNote is null) state.ReconcileEditor(current); else state.EditNote(current); lastNote = current; Persist(); }
            Schedule(1); Changed?.Invoke();
        }
        catch (IOException ex) { Status = ex.Message; Changed?.Invoke(); }
    }
    void LocalChanged(string source, string text)
    {
        if (!loaded || applying || failed || disposed || ctx.Settings.ReadOnly) return;
        try
        {
            if (source == "note" && NotesOn)
            {
                if (lastNote is null) state.ReconcileEditor(text);
                else if (lastNote != text) state.EditNote(text);
                else return;
                lastNote = text;
            }
            else if (source == "clipboard" && ClipboardOn) state.CopyText(text);
            else return;
            Persist(); attempts = 0; Schedule(1); Changed?.Invoke();
        }
        catch (IOException ex) { Status = ex.Message; Changed?.Invoke(); }
    }
    SyncBundle Bundle(DevicePeer peer) => state.Bundle(peer.SyncNotes && Source("note")?.Read() is not null, peer.SyncClipboard && Source("clipboard") is not null);
    string Fingerprint() => string.Join(',', state.Notes.Select(i => i.Id)) + ":" + state.Journal.ClipboardCounter + ":" + state.Journal.ClipboardAuthor;
    void Merge(DevicePeer peer, SyncBundle incoming)
    {
        var before = Fingerprint(); var candidate = state.Clone();
        string? note = null, clip = null;
        if (peer.SyncNotes && incoming.NotesEnabled && Source("note")?.Read() is not null) note = candidate.ReceiveNotes(incoming.Notes);
        if (peer.SyncClipboard && incoming.ClipboardEnabled && Source("clipboard") is not null) clip = candidate.ReceiveClipboard(incoming.Clipboard);
        applying = true;
        try
        {
            if (note is not null && Source("note") is { } noteSource && noteSource.Read() != note) { noteSource.Apply(note); lastNote = note; }
            if (clip is not null) Source("clipboard")?.Apply(clip);
            state = candidate;
        }
        finally { applying = false; }
        if (before != Fingerprint()) { Persist(); Schedule(1); }
        Status = state.Notes.Count > 1 ? "Note conflict: both versions are preserved. Choose a version below to resolve it." : "Sync is up to date.";
        Changed?.Invoke();
    }
    public async Task<byte[]> Exchange(string peerId, byte[] input)
    {
        var incoming = DeviceProtocol.Decode<SyncBundle>(input);
        return await ctx.Dispatcher.InvokeAsync(() =>
        {
            if (!loaded || failed || disposed || settings.Peers.FirstOrDefault(p => p.Id == peerId && p.Receive) is not { } peer) throw new IOException("Sync is unavailable.");
            Merge(peer, incoming); return DeviceProtocol.Encode(Bundle(peer));
        });
    }
    public void Resolve(string id)
    {
        if (!loaded || failed || ctx.Settings.ReadOnly || Source("note") is not { } source || state.Notes.FirstOrDefault(i => i.Id == id) is not { } selected) return;
        try
        {
            var candidate = state.Clone(); candidate.EditNote(selected.Text, resolveAll: true);
            applying = true;
            try { source.Apply(selected.Text); lastNote = selected.Text; state = candidate; } finally { applying = false; }
            Persist(); Status = "Note conflict resolved. The chosen version will sync."; Schedule(1); Changed?.Invoke();
        }
        catch (IOException ex) { Status = ex.Message; Changed?.Invoke(); }
    }
    void Schedule(int seconds)
    {
        if (disposed || failed || !loaded || ctx.Settings.ReadOnly || node()?.Port is not > 0 || !settings.Peers.Any(p => p.Receive && (p.SyncNotes || p.SyncClipboard))) return;
        if (working) { again = true; return; }
        retry.Stop(); retry.Interval = TimeSpan.FromSeconds(seconds); retry.Start();
    }
    async Task Pump()
    {
        var active = node(); if (working || disposed || failed || active?.Port is not > 0) return;
        working = true; again = false; var hadFailure = false;
        try
        {
            foreach (var peer in settings.Peers.Where(p => p.Receive && (p.SyncNotes || p.SyncClipboard)).ToArray())
            {
                if (disposed || node() != active) return;
                try
                {
                    var payload = DeviceProtocol.Encode(Bundle(peer));
                    var result = await Task.Run(() => active.Synchronize(peer.Id, payload));
                    if (node() == active && settings.Peers.FirstOrDefault(p => p.Id == peer.Id && p.Receive) is { } current) Merge(current, DeviceProtocol.Decode<SyncBundle>(result));
                }
                catch (Exception ex) when (ex is IOException or System.Net.Sockets.SocketException or OperationCanceledException or ObjectDisposedException or System.Security.Cryptography.CryptographicException or System.Text.Json.JsonException)
                { hadFailure = true; Status = "A device is offline or sync is unavailable. Notes are kept locally and will retry."; Changed?.Invoke(); }
            }
        }
        finally { working = false; }
        if (hadFailure) { attempts = Math.Min(attempts + 1, 6); Schedule(Math.Min(300, 5 * (1 << attempts))); }
        else { attempts = 0; if (again) Schedule(1); }
    }
    void Persist()
    {
        if (ctx.Settings.ReadOnly || failed || disposed) return;
        var snapshot = state.Clone().Journal; var version = Interlocked.Increment(ref saveVersion);
        _ = Task.Run(() => Write(snapshot, version));
    }
    void Write(SyncJournal journal, int version)
    {
        try
        {
            var bytes = DeviceProtocol.Encode(journal);
            lock (io)
            {
                if (version != Volatile.Read(ref saveVersion)) return;
                File.WriteAllBytes(path + ".tmp", bytes); File.Move(path + ".tmp", path, true);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { ctx.Bus.Run(() => { Status = "Sync changes could not be saved. Keep QNotch open and check its data folder."; Changed?.Invoke(); }); }
    }
    public void Dispose()
    {
        retry.Stop(); ctx.SharedText.Changed -= Attach;
        NetworkChange.NetworkAddressChanged -= NetworkChanged;
        if (loaded && !failed && !ctx.Settings.ReadOnly) Write(state.Clone().Journal, Interlocked.Increment(ref saveVersion));
        disposed = true;
    }
}
