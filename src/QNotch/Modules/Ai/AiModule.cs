using System.Diagnostics;
using System.Net.Http;
using System.Windows.Input;
using System.Windows.Media;
using CommunityToolkit.Mvvm.Input;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Ai;

/// <summary>
/// AI apps (detect, icons, Alt+1..6 launch) and AI usage (per-provider readings).
/// Idle cost while collapsed: one 10 minute one-shot timer. All I/O runs on the thread pool or a short-lived STA thread and is posted back through the bus.
/// </summary>
public sealed class AiModule : INotchModule, ICadenceAware
{
    sealed record AppsScanned(List<DetectedApp> Apps);
    sealed record ProviderResult(string Id, UsageResult Result);
    sealed record RefreshDone(DateTime At);
    sealed record IconLoaded(string Id, ImageSource? Icon);

    ModuleContext _ctx = null!;
    AiSettings _s = null!;
    readonly AiState St = new();
    IUsageProvider[] _providers = [];
    readonly Dictionary<string, AiProviderItem> _items = new();
    readonly HashSet<int> _registered = new();
    Timer? _startTimer, _usageTimer;
    bool _refreshing, _refreshAgain, _scanning;

    /// <summary>Raised (UI thread) when apps, slots or conflicts change, so an open settings section can rebuild.</summary>
    internal event Action? Changed;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _s = ctx.Settings.Get<AiSettings>("ai");
        _s.Normalize();

        St.RefreshCommand = new RelayCommand(RefreshUsage);
        St.LaunchCommand = new RelayCommand<AiAppItem>(Launch);
        St.RescanCommand = new RelayCommand(Rescan);
        St.OpenSettingsCommand = new RelayCommand(() => ctx.Shell.OpenSettings("ai"));

        _providers = [new ClaudeCodeProvider(), new CodexProvider()];
        foreach (var p in _providers) _items[p.Id] = new AiProviderItem(p.Id, p.Name);
        ApplyProviderSelection();
        UpdateAppFlags();
        St.AppsEmptyText = "Looking for AI apps...";

        ctx.Cards.Register(new CardDescriptor("ai-usage", "AI usage", 40, () => new AiUsageCard { DataContext = St }));
        ctx.Cards.Register(new CardDescriptor("ai-apps", "AI apps", 70, () => new AiAppsCard { DataContext = St }));
        ctx.Tabs.Register(new TabDescriptor("ai", "AI", Glyphs.Chat, 30, () => new AiTab { DataContext = St }));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("ai", "AI", Glyphs.Chat, 40, () => AiSettingsSection.Create(this, _ctx)));

        ctx.Bus.Subscribe<AppsScanned>(OnScanned);
        ctx.Bus.Subscribe<ProviderResult>(OnProviderResult);
        ctx.Bus.Subscribe<RefreshDone>(OnRefreshDone);
        ctx.Bus.Subscribe<IconLoaded>(e => St.Apps.FirstOrDefault(a => a.Id == e.Id)?.Icon = e.Icon);

        // Both start after the shell is up and idle; nothing runs on a steady cadence except the usage timer.
        _startTimer = new Timer(_ => ctx.Bus.Run(Rescan), null, 1500, Timeout.Infinite);
        _usageTimer = new Timer(_ => ctx.Bus.Run(RefreshUsage), null, 4000, Timeout.Infinite);
    }

    /// <summary>Panel opened: relative "resets in" texts are recomputed (cheap, set-if-changed).</summary>
    public void SetCadence(Cadence cadence)
    {
        if (cadence != Cadence.Fast) return;
        foreach (var i in _items.Values) i.RefreshTexts();
    }

    // ---------- settings API (UI thread) ----------

    internal IReadOnlyList<IUsageProvider> Providers => _providers;
    internal bool IsProviderEnabled(string id) => _s.IsEnabled(id);
    internal IReadOnlyList<CustomApp> CustomApps => _s.Custom;
    internal IReadOnlyList<string> Slots => _s.Slots;
    internal AiState State => St;

    internal int RefreshMinutes
    {
        get => _s.RefreshMinutes;
        set { _s.RefreshMinutes = value; Save(); ArmUsageTimer(); }
    }

    internal void SetProviderEnabled(string id, bool on)
    {
        _s.Providers[id] = on;
        Save();
        ApplyProviderSelection();
        if (on) RefreshUsage(); else ArmUsageTimer();
    }

    internal void SetSlot(int index, string appId)
    {
        for (var j = 0; j < _s.Slots.Count; j++) if (appId.Length > 0 && _s.Slots[j] == appId) _s.Slots[j] = "";
        _s.Slots[index] = appId;
        if (appId.Length > 0 && !_s.AutoPlaced.Contains(appId)) _s.AutoPlaced.Add(appId);
        Save();
        ApplySlots();
    }

    internal void AddCustom(string path)
    {
        var c = new CustomApp { Id = "custom:" + Guid.NewGuid().ToString("N")[..8], Name = Path.GetFileNameWithoutExtension(path), Path = path };
        _s.Custom.Add(c);
        var item = new AiAppItem(c.Id, c.Name, c.Path, true);
        St.Apps.Add(item);
        UpdateAppFlags();
        AutoPlace();
        ApplySlots();
        ShellIcons.LoadAsync(path).ContinueWith(t => _ctx.Bus.Post(new IconLoaded(c.Id, t.Result)));
    }

    internal void RenameCustom(string id, string name)
    {
        name = name.Trim();
        if (name.Length == 0 || _s.Custom.FirstOrDefault(c => c.Id == id) is not { } c || c.Name == name) return;
        c.Name = name;
        if (St.Apps.FirstOrDefault(a => a.Id == id) is { } a) a.Name = name;
        Save();
        Changed?.Invoke();
    }

    internal void RemoveCustom(string id)
    {
        _s.Custom.RemoveAll(c => c.Id == id);
        for (var j = 0; j < _s.Slots.Count; j++) if (_s.Slots[j] == id) _s.Slots[j] = "";
        if (St.Apps.FirstOrDefault(a => a.Id == id) is { } a) St.Apps.Remove(a);
        UpdateAppFlags();
        Save();
        ApplySlots();
    }

    void Save() => _ctx.Settings.Save("ai", _s);

    // ---------- apps ----------

    void Rescan()
    {
        if (_scanning) return;
        _scanning = true;
        St.IsScanning = true;
        if (!St.HasApps) St.AppsEmptyText = "Looking for AI apps...";
        Changed?.Invoke();
        AppDetector.ScanAsync(_s.Custom.ToList()).ContinueWith(t => _ctx.Bus.Post(new AppsScanned(t.Result)));
    }

    void OnScanned(AppsScanned e)
    {
        _scanning = false;
        St.IsScanning = false;
        // Reuse items for unchanged apps so icons and tiles do not flicker on a rescan.
        var existing = St.Apps.ToDictionary(a => a.Id);
        St.Apps.Clear();
        foreach (var d in e.Apps)
        {
            if (!existing.TryGetValue(d.Id, out var item) || item.Target != d.Target) item = new AiAppItem(d.Id, d.Name, d.Target, d.IsCustom);
            if (d.Icon is not null) item.Icon = d.Icon;
            St.Apps.Add(item);
        }
        St.AppsEmptyText = "No AI apps found.\nAdd your own in Settings.";
        UpdateAppFlags();
        AutoPlace();
        ApplySlots();
    }

    void UpdateAppFlags()
    {
        St.HasApps = St.Apps.Count > 0;
        St.NoApps = !St.HasApps;
    }

    /// <summary>Each app is offered a free slot exactly once; clearing a slot later sticks.</summary>
    void AutoPlace()
    {
        var changed = false;
        foreach (var a in St.Apps)
        {
            if (_s.AutoPlaced.Contains(a.Id)) continue;
            _s.AutoPlaced.Add(a.Id);
            changed = true;
            var free = _s.Slots.FindIndex(x => x.Length == 0);
            if (free >= 0) _s.Slots[free] = a.Id;
        }
        if (changed) Save();
    }

    /// <summary>Applies slot ids to items and registers Alt+N lazily: only slots that hold an app own a hotkey.</summary>
    void ApplySlots()
    {
        foreach (var a in St.Apps) { a.Slot = 0; a.HotkeyConflict = false; }
        var slotted = new List<AiAppItem>();
        var conflicts = new List<string>();
        for (var i = 0; i < AiSettings.SlotCount; i++)
        {
            var app = _s.Slots[i].Length > 0 ? St.Apps.FirstOrDefault(a => a.Id == _s.Slots[i] && a.Slot == 0) : null;
            var key = Key.D1 + i;
            if (app is null)
            {
                if (_registered.Remove(i)) _ctx.Hotkeys.Unregister(ModifierKeys.Alt, key);
                continue;
            }
            app.Slot = i + 1;
            slotted.Add(app);
            if (_registered.Contains(i)) continue;
            var slot = i + 1;
            if (_ctx.Hotkeys.Register(ModifierKeys.Alt, key, () => LaunchSlot(slot))) _registered.Add(i);
            else { app.HotkeyConflict = true; conflicts.Add($"Alt+{slot}"); }
        }
        if (!St.Slotted.SequenceEqual(slotted))
        {
            St.Slotted.Clear();
            foreach (var a in slotted) St.Slotted.Add(a);
        }
        St.HotkeyWarning = conflicts.Count == 0 ? "" : $"{string.Join(", ", conflicts)} taken by another app, so {(conflicts.Count == 1 ? "it" : "they")} will not launch anything.";
        Changed?.Invoke();
    }

    void LaunchSlot(int slot) => Launch(St.Apps.FirstOrDefault(a => a.Slot == slot));

    void Launch(AiAppItem? app)
    {
        if (app is null) return;
        app.Error = "";
        var target = app.Target;
        // ShellExecute can take tens of ms (and runs AppX activation), so keep it off the UI thread.
        Task.Run(() =>
        {
            try
            {
                var psi = new ProcessStartInfo(target) { UseShellExecute = true };
                if (target.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && Path.GetDirectoryName(target) is { Length: > 0 } dir) psi.WorkingDirectory = dir;
                Process.Start(psi)?.Dispose();
            }
            catch (Exception ex)
            {
                Log.Warn($"Launching '{app.Name}' failed", ex);
                _ctx.Bus.Run(() => app.Error = "Could not launch: " + ex.Message);
            }
        });
        if (!_ctx.Shell.IsPinned) _ctx.Shell.ClosePanel();
    }

    // ---------- usage ----------

    void ApplyProviderSelection()
    {
        St.Providers.Clear();
        foreach (var p in _providers) if (_s.IsEnabled(p.Id)) St.Providers.Add(_items[p.Id]);
        St.HasProviders = St.Providers.Count > 0;
        St.NoProviders = !St.HasProviders;
        if (!St.HasProviders) St.LastUpdatedText = "";
    }

    void RefreshUsage()
    {
        var enabled = _providers.Where(p => _s.IsEnabled(p.Id)).ToList();
        if (enabled.Count == 0) { ArmUsageTimer(); return; }
        if (_refreshing) { _refreshAgain = true; return; }
        _refreshing = true;
        St.IsRefreshing = true;
        _usageTimer?.Change(Timeout.Infinite, Timeout.Infinite);

        var bus = _ctx.Bus;
        Task.Run(async () =>
        {
            // Every provider runs in parallel with its own timeout and try/catch; one failing never affects another.
            await Task.WhenAll(enabled.Select(async p =>
            {
                UsageResult r;
                try
                {
                    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(25));
                    r = await p.FetchAsync(cts.Token).WaitAsync(cts.Token);
                }
                catch (OperationCanceledException) { r = UsageResult.Unavailable("Timed out. Will retry on the next refresh."); }
                catch (HttpRequestException) { r = UsageResult.Unavailable("Network unavailable. Will retry on the next refresh."); }
                catch (Exception ex) { Log.Warn($"Usage provider {p.Id} failed", ex); r = UsageResult.Unavailable("Unexpected error. See the log for details."); }
                bus.Post(new ProviderResult(p.Id, r));
            }));
            bus.Post(new RefreshDone(DateTime.Now));
        });
    }

    void OnProviderResult(ProviderResult e)
    {
        if (_items.TryGetValue(e.Id, out var item)) item.Apply(e.Result);
    }

    void OnRefreshDone(RefreshDone e)
    {
        _refreshing = false;
        St.IsRefreshing = false;
        St.LastUpdatedText = "Checked " + AiFormat.When(e.At);
        if (_refreshAgain) { _refreshAgain = false; RefreshUsage(); }
        else ArmUsageTimer();
    }

    void ArmUsageTimer()
    {
        if (_usageTimer is null || _refreshing) return;
        var any = _providers.Any(p => _s.IsEnabled(p.Id));
        _usageTimer.Change(any ? TimeSpan.FromMinutes(_s.RefreshMinutes) : Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }
}
