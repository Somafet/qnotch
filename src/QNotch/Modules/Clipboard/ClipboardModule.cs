using System.Buffers.Binary;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Clipboard;

public sealed class ClipboardSettings
{
    /// <summary>Off by default: persisting clipboard text to disk can store secrets.</summary>
    public bool Persist { get; set; }
    public List<SavedClip> Items { get; set; } = new();
}

public sealed class SavedClip
{
    public string Text { get; set; } = "";
    public bool Pinned { get; set; }
    public DateTime Created { get; set; }
}

internal sealed record ClipReady(ClipEntry Entry);

/// <summary>
/// Clipboard history. Event-driven: WM_CLIPBOARDUPDATE and the sequence-number check stay on the UI thread; the clipboard read
/// (which can wait on a delayed-rendering owner such as Excel), classification and image conversion run on one STA worker thread.
/// No timers run while idle.
/// </summary>
public sealed class ClipboardModule : INotchModule, ICadenceAware
{
    const int MaxEntries = 40;
    const long ImageBudget = 8 << 20;  // total PNG bytes kept, so 40 big screenshots can never blow the memory target
    const int MaxPersistChars = 20_000;

    ModuleContext _ctx = null!;
    readonly ClipboardState _st = new();
    ClipboardSettings _cfg = null!;
    HwndSourceHook? _hook;
    DispatcherTimer? _capTimer, _ageTimer;
    readonly AutoResetEvent _wake = new(false);
    Thread? _worker;
    int _pending; // latest clipboard sequence number waiting for the worker (0 = none); bursts coalesce
    uint _selfSeq, _lastSeq;
    bool _fast;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _cfg = ctx.Settings.Get<ClipboardSettings>("clipboard");

        ctx.Tabs.Register(new TabDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 20, () => new ClipboardTab(this, _st), () => _st.Entries.Count == 0));
        ctx.Cards.Register(new CardDescriptor("clipboard", "Clipboard", 30, () => new ClipboardCard(this, _st)));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 30, BuildSettings));
        ctx.Search.Register(new SearchSource("clipboard", "Clipboard", Glyphs.Clipboard, 10, q => _st.Entries
            .Where(e => e.Text.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(e => new SearchHit(SearchHit.Snippet(e.Text, q), $"{e.Meta} · copies it", () => { CopyAgain(e); ctx.Shell.ClosePanel(); }))));
        ctx.Bus.Subscribe<ClipReady>(e => Add(e.Entry));
        ctx.Shell.TabChanged += _ => UpdateAgeTimer();

        if (ctx.Settings.ReadOnly) { Seed(); return; } // snapshot run: demo data, never touch the real clipboard
        LoadPersisted();
        _hook = Hook;
        ctx.Shell.AddHwndHook(_hook);
        _st.IsAvailable = ClipboardNative.AddClipboardFormatListener(ctx.Shell.Hwnd);
        if (!_st.IsAvailable) Log.Warn("AddClipboardFormatListener failed; clipboard history unavailable");
    }

    public void SetCadence(Cadence cadence)
    {
        _fast = cadence == Cadence.Fast;
        UpdateAgeTimer();
    }

    // ---------- capture ----------

    nint Hook(nint hwnd, int msg, nint w, nint l, ref bool handled)
    {
        if (msg == ClipboardNative.WM_CLIPBOARDUPDATE) Arm(30);
        return 0;
    }

    /// <summary>One-shot timer: coalesces bursts of updates (many apps set several formats).</summary>
    void Arm(int ms)
    {
        if (_capTimer is null)
        {
            _capTimer = new DispatcherTimer(DispatcherPriority.Normal, _ctx.Dispatcher);
            _capTimer.Tick += (_, _) => Capture();
        }
        _capTimer.Stop();
        _capTimer.Interval = TimeSpan.FromMilliseconds(ms);
        _capTimer.Start();
    }

    void Capture()
    {
        _capTimer?.Stop();
        uint seq = ClipboardNative.GetClipboardSequenceNumber();
        if (seq == _selfSeq || seq == _lastSeq) return; // our own copy, or already handled
        _lastSeq = seq;
        Volatile.Write(ref _pending, (int)seq);
        if (_worker is null)
        {
            _worker = new Thread(WorkerLoop) { IsBackground = true, Name = "QNotch.Clipboard" };
            _worker.SetApartmentState(ApartmentState.STA);
            _worker.Start();
        }
        _wake.Set();
    }

    // ---------- worker thread ----------

    void WorkerLoop()
    {
        while (true)
        {
            _wake.WaitOne();
            while (Interlocked.Exchange(ref _pending, 0) != 0)
            {
                try
                {
                    string? text = null; byte[]? dib = null;
                    var r = ReadResult.Busy;
                    for (int i = 1; i <= 6 && r == ReadResult.Busy; i++)
                    {
                        r = ClipboardNative.Read(0, out text, out dib); // may wait for a delayed-rendering owner: fine, this is not the UI thread
                        if (r == ReadResult.Busy) Thread.Sleep(40 * i);
                    }
                    if (r != ReadResult.Ok) continue;
                    var e = text is not null ? ClipProcessor.FromText(text) : ClipProcessor.FromDib(dib!);
                    dib = null;
                    if (e is not null) _ctx.Bus.Post(new ClipReady(e));
                }
                catch (Exception ex) { Log.Warn("Clipboard capture failed", ex); }
            }
        }
    }

    // ---------- history (UI thread) ----------

    int PinnedCount(ClipEntry? except = null) => _st.Entries.Count(e => e.Pinned && e != except);

    void Add(ClipEntry e)
    {
        var list = _st.Entries;
        var dup = list.FirstOrDefault(x => x.IsImage == e.IsImage && x.Key == e.Key);
        if (dup is not null) { dup.Created = DateTime.Now; Reposition(dup); Changed(); return; }
        e.Subtitle = Subtitle(e);
        Log.Info($"Clipboard captured: {e.Meta}");
        list.Insert(PinnedCount(), e);
        while (list.Count > MaxEntries)
        {
            int i = list.Count - 1;
            while (i > 0 && list[i].Pinned) i--;
            list.RemoveAt(i);
        }
        while (list.Sum(x => x.Png?.Length ?? 0) > ImageBudget && list.LastOrDefault(x => x.IsImage && !x.Pinned) is { } old) list.Remove(old);
        Changed();
        if (e.IsImage) MemoryTrim.AfterActivity(); // a 4K screenshot leaves ~100 MB of large-object garbage behind
    }

    void Reposition(ClipEntry e)
    {
        int to = e.Pinned ? 0 : PinnedCount(e);
        int from = _st.Entries.IndexOf(e);
        if (from >= 0 && from != to) _st.Entries.Move(from, to);
    }

    void Changed() { _st.Recount(); Persist(); }

    internal void Remove(ClipEntry e) { _st.Entries.Remove(e); Changed(); }

    /// <summary>Right-click menu for one entry. Keeps the notch open while the menu is showing.</summary>
    internal ContextMenu RowMenu(ClipEntry e)
    {
        IDisposable? hold = null;
        var delete = new MenuItem { Header = "Delete" };
        delete.Click += (_, _) => Remove(e);
        var menu = new ContextMenu();
        menu.Items.Add(delete);
        menu.Opened += (_, _) => hold ??= _ctx.Shell.HoldOpen();
        menu.Closed += (_, _) => { hold?.Dispose(); hold = null; };
        return menu;
    }

    /// <summary>Clears everything except pinned entries.</summary>
    internal void Clear()
    {
        for (int i = _st.Entries.Count - 1; i >= 0; i--) if (!_st.Entries[i].Pinned) _st.Entries.RemoveAt(i);
        Changed();
    }

    internal void TogglePin(ClipEntry e) { e.Pinned = !e.Pinned; Reposition(e); Changed(); }

    internal void CopyAgain(ClipEntry e)
    {
        if (e.IsImage && e.Png is { } png)
        {
            Task.Run(() =>
            {
                try { var dib = ClipProcessor.PngToDib(png); _ctx.Bus.Run(() => Written(e, ClipboardNative.WriteDib(_ctx.Shell.Hwnd, dib))); }
                catch (Exception ex) { Log.Warn("Copying image again failed", ex); }
            });
        }
        else Written(e, ClipboardNative.WriteText(_ctx.Shell.Hwnd, e.Text));
    }

    /// <summary>Remembers our own write so the resulting WM_CLIPBOARDUPDATE is ignored, and flashes a check mark.</summary>
    void Written(ClipEntry e, bool ok)
    {
        _selfSeq = ClipboardNative.GetClipboardSequenceNumber();
        if (!ok) return;
        e.JustCopied = true;
        _st.NotifyFlash();
        Task.Delay(1200).ContinueWith(_ => _ctx.Bus.Run(() => { e.JustCopied = false; _st.NotifyFlash(); }));
    }

    // ---------- relative time: a timer only while the clipboard tab is visible ----------

    void UpdateAgeTimer()
    {
        if (_fast && _ctx.Shell.ActiveTab == "clipboard")
        {
            UpdateAges();
            _ageTimer ??= CreateAgeTimer();
            _ageTimer.Start();
        }
        else _ageTimer?.Stop();
    }

    DispatcherTimer CreateAgeTimer()
    {
        var t = new DispatcherTimer(DispatcherPriority.Background, _ctx.Dispatcher) { Interval = TimeSpan.FromSeconds(30) };
        t.Tick += (_, _) => UpdateAges();
        return t;
    }

    void UpdateAges() { foreach (var e in _st.Entries) e.Subtitle = Subtitle(e); }

    static string Subtitle(ClipEntry e)
    {
        var d = DateTime.Now - e.Created;
        var age = d.TotalSeconds < 60 ? "Just now" : d.TotalMinutes < 60 ? $"{(int)d.TotalMinutes}m ago" : d.TotalHours < 24 ? $"{(int)d.TotalHours}h ago" : $"{(int)d.TotalDays}d ago";
        return $"{e.Meta} · {age}";
    }

    // ---------- persistence (text only, off by default) ----------

    void Persist()
    {
        if (!_cfg.Persist) return;
        _cfg.Items = _st.Entries.Where(e => !e.IsImage && e.Text.Length <= MaxPersistChars)
            .Select(e => new SavedClip { Text = e.Text, Pinned = e.Pinned, Created = e.Created }).ToList();
        _ctx.Settings.Save("clipboard", _cfg);
    }

    void SetPersist(bool on)
    {
        _cfg.Persist = on;
        if (on) Persist(); else { _cfg.Items = new(); _ctx.Settings.Save("clipboard", _cfg); }
    }

    void LoadPersisted()
    {
        if (!_cfg.Persist) return;
        foreach (var s in _cfg.Items.Take(MaxEntries))
            if (ClipProcessor.FromText(s.Text) is { } e)
            {
                e.Pinned = s.Pinned;
                e.Created = s.Created == default ? DateTime.Now : s.Created;
                e.Subtitle = Subtitle(e);
                _st.Entries.Add(e);
            }
        _st.Recount();
    }

    // ---------- settings section ----------

    FrameworkElement BuildSettings()
    {
        var page = UiKit.Page("Clipboard");
        var keep = UiKit.Toggle();
        keep.IsChecked = _cfg.Persist;
        keep.Checked += (_, _) => SetPersist(true);
        keep.Unchecked += (_, _) => SetPersist(false);
        page.Children.Add(UiKit.Row("Keep history between sessions",
            "Saves text entries (and pins) to clipboard.json as plain text. Images are never saved. Off by default, so secrets stay in memory only.", keep));

        var clear = new Button { Content = "Clear history", Padding = new Thickness(12, 5, 12, 5) };
        clear.SetBinding(UIElement.IsEnabledProperty, new System.Windows.Data.Binding(nameof(ClipboardState.HasUnpinned)) { Source = _st });
        clear.Click += (_, _) => Clear();
        page.Children.Add(UiKit.Row("Clear history", "Removes every entry that is not pinned. History holds the last 40 entries.", clear));

        page.Children.Add(UiKit.Text("Content that password managers flag as sensitive, and anything you copy again from QNotch, is never captured.", "Muted"));
        if (!_st.IsAvailable)
        {
            var w = UiKit.Text("Clipboard monitoring is unavailable: the system refused the clipboard listener.", "Muted");
            w.Margin = new Thickness(0, 8, 0, 0);
            page.Children.Add(w);
        }
        return page;
    }

    // ---------- snapshot demo data ----------

    void Seed()
    {
        string[] texts =
        [
            "https://github.com/dotnet/wpf/issues/1234",
            "public static int Fib(int n)\n{\n    return n < 2 ? n : Fib(n - 1) + Fib(n - 2);\n}",
            "Meeting notes: ship the clipboard module, then polish the settings page and run the idle CPU check on the build machine.",
            "SELECT id, name FROM users WHERE active = 1;",
        ];
        foreach (var t in texts) if (ClipProcessor.FromText(t) is { } e) { e.Created = DateTime.Now.AddMinutes(-3 * (_st.Entries.Count + 1)); e.Subtitle = Subtitle(e); _st.Entries.Add(e); }
        if (ClipProcessor.FromDib(DemoDib()) is { } img) { img.Created = DateTime.Now.AddMinutes(-9); img.Subtitle = Subtitle(img); _st.Entries.Insert(2, img); }
        _st.Entries[0].Pinned = true;
        _st.Recount();
    }

    static byte[] DemoDib()
    {
        const int w = 320, h = 180;
        var dib = new byte[40 + w * h * 4];
        BinaryPrimitives.WriteInt32LittleEndian(dib, 40);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(4), w);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(8), h);
        BinaryPrimitives.WriteInt16LittleEndian(dib.AsSpan(12), 1);
        BinaryPrimitives.WriteInt16LittleEndian(dib.AsSpan(14), 32);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int o = 40 + (y * w + x) * 4;
                dib[o] = (byte)(255 - y); dib[o + 1] = (byte)(x * 255 / w); dib[o + 2] = (byte)(90 + y / 2);
            }
        return dib;
    }
}
