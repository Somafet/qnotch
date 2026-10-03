using System.Diagnostics;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using QNotch.Core;

namespace QNotch.Modules.Notifications;

/// <summary>
/// Notifications that any app or script can post: <c>QNotch.exe notify</c>, a named pipe or local HTTP (see <see cref="NotifyServer"/>).
/// A notification toasts in the glance strip, counts as unread in the pill and the game bar, and stays in the history (Home card, tab)
/// for the retention period. A request can wait for the user's answer. The servers run on the thread pool and are idle until a
/// sender connects; the module itself has no timer except the one-shot that ends a toast.
/// </summary>
public sealed class NotificationsModule : INotchModule, ICadenceAware
{
    internal const string TabId = "notifications";
    const string SettingsFile = "notifications", HistoryFile = "notifications.history";
    const int MaxItems = 500, MaxTitle = 80, MaxBody = 300, MaxApp = 40, MaxLabel = 24, MaxId = 64, MaxActions = 3;
    /// <summary>Links a button may open. Nothing here can run a program or a file.</summary>
    static readonly string[] Schemes = ["http", "https", "vscode", "vscode-insiders", "cursor", "claude"];

    ModuleContext _ctx = null!;
    NotificationSettings _cfg = null!;
    readonly NotificationsState _st = new();
    readonly Dictionary<string, long> _lastToast = new(StringComparer.OrdinalIgnoreCase);
    NotifyServer? _server;
    CaptureWatch? _micWatch; // only while Quiet during calls is on
    DispatcherTimer? _toastTimer, _ageTimer;
    FrameworkElement? _glance;
    Note? _transient;       // the toast that is on its timer; waiting notifications show without one
    volatile string _token = "";
    bool _fast, _autoOpened, _saveQueued, _inCall;

    internal NotificationSettings Config => _cfg;
    internal string Token => _token;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _cfg = ctx.Settings.Get<NotificationSettings>(SettingsFile);

        ctx.Tabs.Register(new TabDescriptor(TabId, "Notifications", NotifyIcons.Bell, 50, () => new NotificationsTab(this, _st), () => _st.IsEmpty));
        ctx.Cards.Register(new CardDescriptor("notifications", "Notifications", 60, () => new NotificationsCard(_st, ctx.Shell)));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("notifications", "Notifications", NotifyIcons.Bell, 60, () => NotificationsSettingsSection.Create(this, _st)));
        ctx.Segments.Register(new SegmentDescriptor("notifications.pill", SegmentSlot.PillRight, 5, () => NotificationSegments.Unread(_st)));
        ctx.Segments.Register(new SegmentDescriptor("notifications.glance", SegmentSlot.Glance, 20, () => _glance = NotificationSegments.Glance(_st)));
        ctx.Segments.Register(new SegmentDescriptor("notifications.game", SegmentSlot.GameBar, 15, () => NotificationSegments.Unread(_st),
            "Notifications", "Unread count, only while something is unread."));
        ctx.Search.Register(new SearchSource("notifications", "Notifications", NotifyIcons.Bell, 40, q => _st.Items
            .Where(n => n.Title.Contains(q, StringComparison.OrdinalIgnoreCase) || n.Body.Contains(q, StringComparison.OrdinalIgnoreCase) || n.App.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(n => new SearchHit(n.Title, n.Meta, () => ctx.Shell.SelectTab(TabId)))));
        ctx.Shell.TabChanged += _ => MarkReadIfVisible();

        if (ctx.Settings.ReadOnly) { Seed(); return; } // snapshot run: demo data, no servers
        // Early module: the pill needs only the registrations. History and servers wait for the first idle moment.
        ctx.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, Start);
    }

    void Start()
    {
        Load();
        ApplyQuiet();
        _server = new NotifyServer(HandleAsync, () => _token,
            s => _ctx.Bus.Run(() => _st.PipeStatus = s), s => _ctx.Bus.Run(() => _st.HttpStatus = s));
        _server.StartPipe();
        Task.Run(() =>
        {
            _token = NotifyToken.Get();
            _server.SetHttp(_cfg.HttpEnabled, _cfg.HttpPort);
        });
    }

    public void SetCadence(Cadence cadence)
    {
        var opened = cadence == Cadence.Fast && !_fast;
        _fast = cadence == Cadence.Fast;
        if (!_fast) _autoOpened = false;
        // Relative times only move while the panel is open.
        if (_fast)
        {
            if (_ageTimer is null)
            {
                _ageTimer = new DispatcherTimer(DispatcherPriority.Background, _ctx.Dispatcher) { Interval = TimeSpan.FromSeconds(30) };
                _ageTimer.Tick += (_, _) => RefreshAges();
            }
            if (opened) RefreshAges();
            _ageTimer.Start();
        }
        else _ageTimer?.Stop();
        // The panel opened because the pointer rested on the toast: show what the toast was about.
        if (opened && _glance?.IsMouseOver == true) _ctx.Shell.SelectTab(TabId);
        MarkReadIfVisible();
    }

    // ---------- requests (thread pool) ----------

    /// <summary>Validates a request and hands it to the UI thread. A waiting request returns when it is answered, dismissed, timed out or its sender left.</summary>
    async Task<Reply> HandleAsync(NotifyRequest r, Func<Task> gone)
    {
        if (string.Equals(r.Op, "dismiss", StringComparison.OrdinalIgnoreCase))
        {
            var target = Clean(r.Id, MaxId);
            if (target.Length == 0) throw new NotifyException("dismiss needs an id.");
            _ctx.Bus.Run(() => { if (Find(target) is { } n) Dismiss(n); });
            return Reply.Ok(target);
        }
        if (!string.IsNullOrEmpty(r.Op) && !string.Equals(r.Op, "notify", StringComparison.OrdinalIgnoreCase)) throw new NotifyException($"Unknown op '{r.Op}'.");

        var title = Clean(r.Title, MaxTitle);
        if (title.Length == 0) throw new NotifyException("title is required.");
        if (r.Actions?.Count > MaxActions) throw new NotifyException($"At most {MaxActions} actions.");
        var level = NoteLevel.Info;
        if (!string.IsNullOrWhiteSpace(r.Level) && !Enum.TryParse(r.Level.Trim(), true, out level)) throw new NotifyException("level must be info, success, warning or error.");
        var id = Clean(r.Id, MaxId);
        var app = Clean(r.App, MaxApp);
        var icon = r.Icon?.Trim();
        var note = new Note
        {
            Id = id.Length > 0 ? id : Guid.NewGuid().ToString("N")[..12],
            App = app.Length > 0 ? app : "QNotch",
            Title = title,
            Body = Clean(r.Body, MaxBody, multiline: true),
            Level = level,
            IconSpec = string.IsNullOrEmpty(icon) ? null : icon,
            Glyph = icon is not null && NotifyIcons.Glyphs.TryGetValue(icon, out var g) ? g : NotifyIcons.LevelGlyph(level),
        };

        var actions = new List<NoteAction>();
        foreach (var a in r.Actions ?? [])
        {
            var label = Clean(a.Label, MaxLabel);
            if (label.Length == 0) throw new NotifyException("Every action needs a label.");
            string? url = null;
            nint hwnd = 0;
            if (!string.IsNullOrWhiteSpace(a.Url))
            {
                if (!Uri.TryCreate(a.Url.Trim(), UriKind.Absolute, out var u) || !Schemes.Contains(u.Scheme))
                    throw new NotifyException($"Action '{label}': only {string.Join(", ", Schemes)} links are allowed.");
                url = u.AbsoluteUri;
            }
            else if (a.FocusPid is { } pid)
            {
                // Resolved now: the sender (a hook, a script) is usually gone by the time the button is clicked.
                hwnd = WindowFinder.Find(pid);
                if (hwnd == 0) continue; // nothing to bring forward: no button
            }
            else if (!r.Wait) throw new NotifyException($"Action '{label}' needs a url or a focusPid, or the request must wait.");
            var actionId = Clean(a.Id, MaxId);
            actions.Add(new NoteAction { Owner = note, Id = actionId.Length > 0 ? actionId : label, Label = label, Url = url, Hwnd = hwnd });
        }
        note.Actions = actions;
        note.Icon = await NotifyIcons.LoadAsync(note.IconSpec);

        TaskCompletionSource<WaitResult>? waiter = null;
        if (r.Wait)
        {
            waiter = note.Waiter = new(TaskCreationOptions.RunContinuationsAsynchronously);
            note.Pending = true;
            note.Status = "Waiting for your answer";
        }
        var ttl = r.Ttl;
        _ctx.Bus.Run(() => Post(note, ttl));
        if (waiter is null) return Reply.Ok(note.Id);

        using var cts = new CancellationTokenSource();
        var left = gone();
        var seconds = r.Timeout is > 0 ? Math.Min(r.Timeout.Value, 86400) : 0;
        var timeout = Task.Delay(seconds > 0 ? TimeSpan.FromSeconds(seconds) : Timeout.InfiniteTimeSpan, cts.Token);
        var first = await Task.WhenAny(waiter.Task, left, timeout);
        cts.Cancel();
        if (first != waiter.Task)
        {
            var status = first == left ? "Sender stopped waiting" : "Timed out";
            waiter.TrySetResult(new WaitResult("timeout"));
            _ctx.Bus.Run(() => Close(note, status));
        }
        var result = await waiter.Task;
        return Reply.Ok(note.Id, result.Result, result.Action);
    }

    /// <summary>Trimmed, capped and free of control characters, so a sender cannot break the layout.</summary>
    static string Clean(string? s, int max, bool multiline = false)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        s = s.Trim();
        var sb = new StringBuilder(Math.Min(s.Length, max));
        foreach (var c in s)
        {
            if (sb.Length == max) { sb[^1] = '…'; break; }
            if (c == '\r') continue;
            sb.Append(c == '\n' && multiline ? '\n' : char.IsControl(c) ? ' ' : c);
        }
        return sb.ToString();
    }

    // ---------- history (UI thread) ----------

    Note? Find(string id) => _st.Items.FirstOrDefault(n => n.Id == id);
    bool IsMuted(string app) => _cfg.MutedApps.Contains(app, StringComparer.OrdinalIgnoreCase);
    bool TabVisible => _fast && _ctx.Shell.ActiveTab == TabId;

    void Post(Note n, double? ttl)
    {
        if (Find(n.Id) is { } old)
        {
            Close(old, "", new WaitResult("dismissed"));
            _st.Items.Remove(old);
            if (_transient == old) _transient = null;
        }
        var muted = IsMuted(n.App);
        n.Read = muted || (TabVisible && !_autoOpened);
        _st.Items.Insert(0, n);
        Prune();
        Changed();
        var quiet = muted || _inCall;
        if (!quiet) Toast(n, ttl);
        UpdateToast();
        if (quiet || n.Level != NoteLevel.Error || !_cfg.OpenOnError || _fast) return;
        // An error opens the panel (never in game mode, never over what the user is doing in an open panel). It stays unread
        // until the pointer reaches the list, so an error nobody saw still shows in the pill after the panel closes again.
        _autoOpened = true;
        if (!_ctx.Shell.TryOpenPanel(TabId, (int)(Math.Clamp(ttl ?? _cfg.ToastSeconds, 5, 60) * 1000))) _autoOpened = false;
    }

    void Toast(Note n, double? ttl)
    {
        if (n.Pending) { _transient = null; _toastTimer?.Stop(); return; } // stays up until answered: UpdateToast picks it
        var seconds = Math.Clamp(ttl ?? _cfg.ToastSeconds, 0, 60);
        var now = Environment.TickCount64;
        // One toast per app per second; the rest of a burst goes straight to the history. An update of the shown toast always passes.
        if (seconds <= 0 || (_lastToast.TryGetValue(n.App, out var last) && now - last < 1000 && _st.Toast?.Id != n.Id)) return;
        if (_lastToast.Count > 64) _lastToast.Clear();
        _lastToast[n.App] = now;
        _transient = n;
        if (_toastTimer is null)
        {
            _toastTimer = new DispatcherTimer(DispatcherPriority.Background, _ctx.Dispatcher);
            _toastTimer.Tick += (_, _) => { _toastTimer.Stop(); _transient = null; UpdateToast(); };
        }
        _toastTimer.Stop();
        _toastTimer.Interval = TimeSpan.FromSeconds(seconds);
        _toastTimer.Start();
    }

    void RefreshAges()
    {
        foreach (var n in _st.Items) n.RefreshMeta();
    }

    /// <summary>A notification waiting for an answer shows even during a call: someone is blocked on it.</summary>
    void UpdateToast() => _st.Toast = _transient ?? _st.Items.FirstOrDefault(n => n.Pending && !IsMuted(n.App));

    /// <summary>Starts or stops watching the microphone to match the Quiet during calls setting.</summary>
    internal void ApplyQuiet()
    {
        if (_cfg.QuietDuringCalls)
        {
            if (_micWatch is not null) return;
            CaptureWatch w = null!;
            // A late report from a watcher that was turned off in the meantime is ignored.
            w = _micWatch = new CaptureWatch(CaptureWatch.Microphone, apps => _ctx.Bus.Run(() => { if (_micWatch == w) SetCall(apps); }));
        }
        else
        {
            _micWatch?.Dispose();
            _micWatch = null;
            SetCall([]);
        }
    }

    void SetCall(IReadOnlyList<string> apps)
    {
        _inCall = apps.Count > 0;
        _st.QuietStatus = _inCall ? $"Quiet now: {string.Join(", ", apps)} {(apps.Count == 1 ? "is" : "are")} using the microphone." : "";
        if (_inCall) { _transient = null; _toastTimer?.Stop(); }
        UpdateToast();
    }

    /// <summary>Ends a wait: the sender gets <paramref name="result"/> (unless it already left) and the answer-only buttons go away.</summary>
    void Close(Note n, string status, WaitResult? result = null)
    {
        if (!n.Pending) return;
        var delivered = result is null || n.Waiter?.TrySetResult(result) == true;
        n.Waiter = null;
        n.Pending = false;
        n.Status = delivered ? status : "Expired";
        n.Actions = n.Actions.Where(a => !a.AnswersOnly).ToList();
        Changed();
        UpdateToast();
    }

    internal void Invoke(NoteAction a)
    {
        var n = a.Owner;
        if (a.Url is { } url)
            Task.Run(() =>
            {
                try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
                catch (Exception ex) { Log.Warn($"Opening '{url}' failed", ex); }
            });
        else if (a.Hwnd != 0) WindowFinder.Focus(a.Hwnd);
        Close(n, $"Answered: {a.Label}", new WaitResult("clicked", a.Id));
        n.Read = true;
        if (_transient == n) _transient = null;
        Changed();
        UpdateToast();
        if (!a.AnswersOnly) _ctx.Shell.ClosePanel();
    }

    internal void Dismiss(Note n)
    {
        Close(n, "", new WaitResult("dismissed"));
        _st.Items.Remove(n);
        if (_transient == n) _transient = null;
        Changed();
        UpdateToast();
    }

    /// <summary>Clears the history. Notifications that still wait for an answer stay.</summary>
    internal void Clear()
    {
        for (var i = _st.Items.Count - 1; i >= 0; i--) if (!_st.Items[i].Pending) _st.Items.RemoveAt(i);
        _transient = null;
        Changed();
        UpdateToast();
    }

    /// <summary>The pointer reached the list: whatever an automatic open showed has now been seen.</summary>
    internal void Seen()
    {
        _autoOpened = false;
        MarkReadIfVisible();
    }

    void MarkReadIfVisible()
    {
        if (!TabVisible || _autoOpened || !_st.HasUnread) return;
        foreach (var n in _st.Items) n.Read = true;
        Changed();
    }

    /// <summary>Drops what is older than the retention period, then the oldest beyond the cap. Waiting notifications stay.</summary>
    void Prune()
    {
        var items = _st.Items;
        var cutoff = DateTime.Now.AddDays(-Math.Max(1, _cfg.RetentionDays));
        var extra = items.Count - MaxItems;
        for (var i = items.Count - 1; i >= 0; i--)
        {
            if (items[i].Pending || (items[i].Created >= cutoff && extra <= 0)) continue;
            items.RemoveAt(i);
            extra--;
        }
    }

    void Changed()
    {
        _st.Recount();
        if (_saveQueued || _ctx.Settings.ReadOnly) return;
        _saveQueued = true; // one write per burst
        _ctx.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            _saveQueued = false;
            _ctx.Settings.Save(HistoryFile, new NotificationHistory { Items = _st.Items.Select(Saved).ToList() });
        });
    }

    static SavedNote Saved(Note n) => new()
    {
        Id = n.Id, App = n.App, Title = n.Title, Body = n.Body, Icon = n.IconSpec, Level = n.Level, Created = n.Created, Read = n.Read,
        Status = n.Status, Pending = n.Pending,
        Actions = n.Actions.Where(a => a.Url is not null).Select(a => new NotifyAction { Id = a.Id, Label = a.Label, Url = a.Url }).ToList(),
    };

    void Load()
    {
        foreach (var s in _ctx.Settings.Get<NotificationHistory>(HistoryFile).Items)
        {
            if (string.IsNullOrEmpty(s.Id) || string.IsNullOrEmpty(s.Title)) continue;
            var note = new Note
            {
                Id = s.Id, App = s.App, Title = s.Title, Body = s.Body ?? "", Level = s.Level, Created = s.Created, IconSpec = s.Icon,
                Glyph = s.Icon is not null && NotifyIcons.Glyphs.TryGetValue(s.Icon, out var g) ? g : NotifyIcons.LevelGlyph(s.Level),
                Read = s.Read,
                Status = s.Pending ? "Expired" : s.Status ?? "", // its sender did not survive the restart
            };
            note.Actions = (s.Actions ?? []).Where(a => a.Url is not null && a.Label is not null)
                .Select(a => new NoteAction { Owner = note, Id = a.Id ?? a.Label!, Label = a.Label!, Url = a.Url }).ToList();
            _st.Items.Add(note);
        }
        Prune();
        _st.Recount();

        var byIcon = _st.Items.Where(n => n.IconSpec is not null).GroupBy(n => n.IconSpec!).Select(g => g.ToList()).ToList();
        if (byIcon.Count == 0) return;
        Task.Run(async () =>
        {
            foreach (var notes in byIcon)
                if (await NotifyIcons.LoadAsync(notes[0].IconSpec) is { } img) _ctx.Bus.Run(() => { foreach (var n in notes) n.Icon = img; });
        });
    }

    // ---------- settings (UI thread) ----------

    internal void SaveSettings()
    {
        _ctx.Settings.Save(SettingsFile, _cfg);
        Prune();
        Changed();
        UpdateToast();
    }

    internal void ApplyHttp()
    {
        _ctx.Settings.Save(SettingsFile, _cfg);
        _server?.SetHttp(_cfg.HttpEnabled, _cfg.HttpPort);
    }

    /// <summary>A new token: everything that posts over HTTP needs it from now on.</summary>
    internal void RenewToken() => _token = NotifyToken.Get(renew: true);

    internal void SendTest() => Post(new Note { Id = "qnotch-test", App = "QNotch", Title = "Test notification", Body = "This is what a notification looks like.", Glyph = NotifyIcons.Bell }, null);

    // ---------- snapshot demo data ----------

    void Seed()
    {
        _st.PipeStatus = $@"Listening on \\.\pipe\{Wire.PipeName}";
        _st.HttpStatus = $"Listening on http://127.0.0.1:{_cfg.HttpPort}";
        _token = "0123456789abcdef0123456789abcdef0123456789abcdef";
        var deploy = new Note { Id = "demo-3", App = "Deploy", Title = "Deploy to production failed", Body = "Health check timed out after 60 s.", Level = NoteLevel.Error, Glyph = NotifyIcons.LevelGlyph(NoteLevel.Error), Created = DateTime.Today.AddHours(9).AddMinutes(12), Read = true };
        var build = new Note { Id = "demo-2", App = "Build", Title = "Build finished", Body = "142 tests passed in 38 s.", Level = NoteLevel.Success, Glyph = NotifyIcons.LevelGlyph(NoteLevel.Success), Created = DateTime.Today.AddHours(9).AddMinutes(35) };
        build.Actions = [new NoteAction { Owner = build, Id = "open", Label = "Open report", Url = "https://example.com/" }];
        var ask = new Note { Id = "demo-1", App = "Claude Code", Title = "Permission needed", Body = "Run the test suite in F:\\Code\\app?", Glyph = NotifyIcons.Glyphs["chat"], Created = DateTime.Today.AddHours(9).AddMinutes(41), Pending = true, Status = "Waiting for your answer" };
        ask.Actions = [new NoteAction { Owner = ask, Id = "approve", Label = "Approve" }, new NoteAction { Owner = ask, Id = "deny", Label = "Deny" }];
        foreach (var n in new[] { ask, build, deploy }) _st.Items.Add(n);
        _st.Recount();
        UpdateToast();
    }
}
