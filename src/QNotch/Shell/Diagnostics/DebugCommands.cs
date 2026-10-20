using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;
using QNotch.Shell.GameMode;
using QNotch.Shell.Onboarding;

namespace QNotch.Shell.Diagnostics;

/// <summary>What the debug channel drives: the running shell's parts. <paramref name="Running"/> is live (late modules join after the first frame).</summary>
internal sealed record DebugHost(NotchWindow Window, ShellController Shell, Shortcuts Shortcuts, Registry<TabDescriptor> Tabs,
    Registry<SettingsSectionDescriptor> Sections, IReadOnlySet<string> BootDisabled, IReadOnlySet<string> Running, Action ShowTour, Action Quit);

/// <summary>
/// The debug channel's commands (spec/diagnostics.md, Debug channel table). UI thread only. Each answers once the UI has settled: the dispatcher
/// is idle, the panel's open or close animation has ended and, with motion on, no shell transition (mode or tab change, a command that changes
/// the UI) happened in the last 300 ms (700 ms while the welcome tour shows), bounded at 2 s.
/// </summary>
internal sealed class DebugCommands : IDisposable
{
    const double SettleMs = 2000, QuietMs = 300, TourQuietMs = 700;
    static readonly Brush Desk = Frozen(Color.FromRgb(0x4A, 0x52, 0x60));
    readonly DebugHost _h;
    long _changed = Stopwatch.GetTimestamp();

    public DebugCommands(DebugHost host)
    {
        _h = host;
        _h.Shell.ModeChanged += OnMode;
        _h.Shell.TabChanged += OnTab;
    }

    public Dispatcher Dispatcher => _h.Window.Dispatcher;

    void OnMode(ShellMode _) => Changed();
    void OnTab(string _) => Changed();
    void Changed() => _changed = Stopwatch.GetTimestamp();

    public void Dispose()
    {
        _h.Shell.ModeChanged -= OnMode;
        _h.Shell.TabChanged -= OnTab;
    }

    /// <summary>Runs <paramref name="cmd"/>; the action, when set, runs after the response was written (quit).</summary>
    public async Task<(JsonNode Result, Action? After)> Run(string cmd, JsonElement args)
    {
        var a = new Args(args);
        switch (cmd)
        {
            case "ping": return (Ping(), null);
            case "state": await Settle(); return (State(), null);
            case "outline":
            {
                await Settle();
                var (el, crop, _) = Target(a.Str("window"));
                return (new JsonObject { ["text"] = Outline.Of(el, crop) }, null);
            }
            case "snapshot":
            {
                var path = a.Need("path");
                if (!Path.IsPathFullyQualified(path) || !path.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                    throw new DebugException("path must be absolute and end in .png");
                await Settle();
                var (el, crop, bg) = Target(a.Str("window"));
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                Render.Save(el, crop, path, bg ?? (Brush)el.FindResource("WindowBrush"));
                return (new JsonObject { ["path"] = path }, null);
            }
            case "quit": return (new JsonObject(), () => Dispatcher.BeginInvoke(_h.Quit));
        }
        Action act = cmd switch
        {
            "open" => () => Open(a.Str("tab")),
            "close" => _h.Shell.ClosePanel,
            "select-tab" => () => SelectTab(a.Need("id")),
            "settings" => () => Settings(a.Str("section"), a.Flag("close")),
            "onboarding" => () => { if (a.Flag("close")) Tour()?.Close(); else _h.ShowTour(); },
            "press" => () => Press(a.Need("id")),
            "type" => () => Type(a.Str("text") ?? throw new DebugException("missing arg text"), a.Str("id")),
            "key" => () => SendKey(a.Need("name"), a.Str("modifiers")),
            "hotkey" => () => Hotkey(a.Need("action")),
            "game-mode" => () => _h.Shell.GameMode.Override = a.Need("mode") switch
            {
                "auto" => GameModeOverride.Auto, "on" => GameModeOverride.ForceOn, "off" => GameModeOverride.ForceOff,
                var m => throw new DebugException($"unknown mode {m}: use auto, on or off"),
            },
            _ => throw new DebugException($"unknown command {cmd}"),
        };
        Changed();
        act();
        Changed();
        await Settle();
        return (new JsonObject(), null);
    }

    async Task Settle()
    {
        var t0 = Stopwatch.GetTimestamp();
        while (true)
        {
            await Dispatcher.InvokeAsync(static () => { }, DispatcherPriority.ApplicationIdle);
            if (Stopwatch.GetElapsedTime(t0).TotalMilliseconds >= SettleMs) return;
            var quiet = !Motion.Enabled || Stopwatch.GetElapsedTime(_changed).TotalMilliseconds >= (Tour() is null ? QuietMs : TourQuietMs);
            if (quiet && !_h.Window.IsAnimating) return;
            await Task.Delay(20);
        }
    }

    // ---------- reading ----------

    static JsonObject Ping()
    {
        var v = typeof(DebugCommands).Assembly.GetName().Version ?? new Version(0, 0, 0);
        return new JsonObject
        {
            ["platform"] = "Windows", ["app_version"] = v.ToString(v.Revision > 0 ? 4 : 3), ["pid"] = Environment.ProcessId, ["data_dir"] = Paths.DataDir,
        };
    }

    JsonObject State()
    {
        var s = _h.Shell;
        var w = _h.Window;
        var modules = new JsonArray();
        foreach (var m in ModuleList.All)
            modules.Add(new JsonObject { ["id"] = m.Id, ["enabled"] = !_h.BootDisabled.Contains(m.Id), ["running"] = _h.Running.Contains(m.Id) });
        var windows = new JsonArray
        {
            Entry("pill", w.IsVisible && s.Mode == ShellMode.Collapsed, ElementFrame(w.Surface)),
            Entry("panel", s.Mode == ShellMode.Expanded && w.PanelLayer.IsVisible, ElementFrame(w.PanelLayer)),
        };
        if (s.Mode == ShellMode.GameBar) windows.Add(Entry("gamebar", w.IsVisible, ElementFrame(w.Surface)));
        if (SettingsWindow.Current is { } sw) windows.Add(Entry("settings", sw.IsVisible && sw.WindowState != WindowState.Minimized, WindowFrame(sw)));
        if (Tour() is { } t) windows.Add(Entry("onboarding", t.IsVisible && t.WindowState != WindowState.Minimized, WindowFrame(t)));
        return new JsonObject
        {
            ["panel"] = s.Mode == ShellMode.Expanded ? "open" : "collapsed",
            ["tab"] = s.ActiveTab,
            ["keyboard"] = w.HasKeyboard,
            ["edit_mode"] = s.IsEditMode,
            ["pinned"] = s.IsPinned,
            ["game_mode"] = s.GameMode.Override switch { GameModeOverride.ForceOn => "on", GameModeOverride.ForceOff => "off", _ => "auto" },
            ["game_bar"] = s.Mode == ShellMode.GameBar,
            ["modules"] = modules,
            ["windows"] = windows,
        };
    }

    static JsonObject Entry(string id, bool visible, Rect frame) => new()
    {
        ["id"] = id, ["visible"] = visible,
        ["frame"] = new JsonObject { ["x"] = R(frame.X), ["y"] = R(frame.Y), ["width"] = R(frame.Width), ["height"] = R(frame.Height) },
    };

    static double R(double v) => Math.Round(v, 2);

    // Frames in DIPs from the primary display's top left: the window's device-pixel position (virtual screen, primary at 0,0) divided by the DPI
    // scale of the monitor the window is on, plus the element's offset inside the window in DIPs. Exact on the primary display and wherever every
    // display has the same scale; on a display with another scale the position is that display's pixels over its own scale (sizes stay exact).

    static Rect ElementFrame(FrameworkElement el)
    {
        var win = Window.GetWindow(el);
        if (win is null || !GetWindowRect(new WindowInteropHelper(win).Handle, out var r)) return Rect.Empty;
        var scale = VisualTreeHelper.GetDpi(win).DpiScaleX;
        Rect b;
        try { b = el.TransformToAncestor(win).TransformBounds(new Rect(el.RenderSize)); }
        catch (InvalidOperationException) { return Rect.Empty; }
        return new Rect(r.Left / scale + b.X, r.Top / scale + b.Y, b.Width, b.Height);
    }

    /// <summary>The visible frame (DWM extended frame bounds, without the invisible resize border).</summary>
    static Rect WindowFrame(Window win)
    {
        var hwnd = new WindowInteropHelper(win).Handle;
        if (DwmGetWindowAttribute(hwnd, 9, out var r, Marshal.SizeOf<RECT>()) != 0 && !GetWindowRect(hwnd, out r)) return Rect.Empty;
        var scale = VisualTreeHelper.GetDpi(win).DpiScaleX;
        return new Rect(r.Left / scale, r.Top / scale, r.Width / scale, r.Height / scale);
    }

    /// <summary>The element and crop for outline and snapshot, plus the background (null: the element's WindowBrush).</summary>
    (FrameworkElement El, Rect Crop, Brush? Background) Target(string? window)
    {
        var w = _h.Window;
        switch (window ?? "panel")
        {
            case "panel":
                if (_h.Shell.Mode != ShellMode.Expanded) throw new DebugException("the panel is not open (use open or select-tab)");
                return (w.RootElement, new Rect(0, 0, NotchWindow.WinW, NotchWindow.PanelH + 8), Desk);
            case "pill":
                if (_h.Shell.Mode == ShellMode.Expanded) throw new DebugException("the pill is hidden while the panel is open (use close)");
                return (w.RootElement, new Rect(0, 0, NotchWindow.WinW, 84), Desk);
            case "settings":
                if (SettingsWindow.Current is not { IsVisible: true, Content: FrameworkElement sc }) throw new DebugException("Settings is not open (use settings)");
                return (sc, new Rect(0, 0, sc.ActualWidth, sc.ActualHeight), null);
            case "onboarding":
                if (Tour() is not { IsVisible: true, Content: FrameworkElement tc }) throw new DebugException("the welcome tour is not open (use onboarding)");
                return (tc, new Rect(0, 0, tc.ActualWidth, tc.ActualHeight), null);
            default: throw new DebugException($"unknown window {window}: use panel, pill, settings or onboarding");
        }
    }

    static TourWindow? Tour() => Application.Current.Windows.OfType<TourWindow>().FirstOrDefault();

    // ---------- shell ----------

    void Open(string? tab)
    {
        if (tab is not null) tab = TabId(tab);
        if (!_h.Shell.OpenPanelWithKeyboard(tab)) throw new DebugException("the panel cannot open while the game bar shows (use game-mode --mode off)");
        if (tab is not null) _h.Shell.SelectTab(tab); // opening falls back to Home when the tab has nothing to show
    }

    void SelectTab(string id)
    {
        id = TabId(id);
        if (_h.Shell.Mode != ShellMode.Expanded) Open(id);
        else _h.Shell.SelectTab(id);
    }

    string TabId(string id)
    {
        if (_h.Tabs.Find(id) is not null) return id;
        if (id.StartsWith("tab-", StringComparison.Ordinal) && _h.Tabs.Find(id[4..]) is not null) return id[4..];
        throw new DebugException($"no tab with id {id} (tabs: {string.Join(", ", _h.Tabs.Items.Select(t => t.Id))})");
    }

    void Settings(string? section, bool close)
    {
        if (close) { SettingsWindow.Current?.Close(); return; }
        if (section is not null && _h.Sections.Find(section) is null)
        {
            var bare = section.StartsWith("settings-nav-", StringComparison.Ordinal) ? section[13..] : section.StartsWith("module.", StringComparison.Ordinal) ? section[7..] : section;
            section = _h.Sections.Find(bare) is not null ? bare
                : throw new DebugException($"no settings section {section} (sections: {string.Join(", ", _h.Sections.Items.Select(s => s.Id))})");
        }
        _h.Shell.OpenSettings(section);
    }

    void Hotkey(string action)
    {
        var id = action switch
        {
            "toggle" => "toggle", "search" => "search", "game-mode" => "gamemode",
            _ => throw new DebugException($"unknown hotkey action {action}: use toggle, search or game-mode"),
        };
        var s = _h.Shortcuts.Find(id) ?? throw new DebugException($"no {action} hotkey (is its feature turned on?)");
        s.Action();
    }

    // ---------- controls ----------

    /// <summary>The windows <c>press</c> and <c>type</c> search, in order: the tour, the notch, Settings.</summary>
    IEnumerable<Window> Windows()
    {
        if (Tour() is { IsVisible: true } t) yield return t;
        if (_h.Window.IsVisible) yield return _h.Window;
        if (SettingsWindow.Current is { IsVisible: true } s) yield return s;
    }

    /// <summary>The visible element with AutomationId <paramref name="id"/>, an enabled one when there is one.</summary>
    FrameworkElement Find(string id)
    {
        FrameworkElement? disabled = null;
        foreach (var w in Windows())
            if (Walk(w) is { } hit) return hit;
        throw new DebugException(disabled is null ? $"no visible control with id {id}" : $"control {id} is disabled");

        FrameworkElement? Walk(DependencyObject o)
        {
            if (o is UIElement { IsVisible: false }) return null;
            if (o is FrameworkElement fe && AutomationProperties.GetAutomationId(fe) == id)
            {
                if (fe.IsEnabled) return fe;
                disabled ??= fe;
            }
            for (int i = 0, n = VisualTreeHelper.GetChildrenCount(o); i < n; i++)
                if (Walk(VisualTreeHelper.GetChild(o, i)) is { } hit) return hit;
            return null;
        }
    }

    void Press(string id)
    {
        var el = Find(id);
        var peer = UIElementAutomationPeer.CreatePeerForElement(el);
        switch (peer)
        {
            case not null when peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider p: p.Invoke(); break;
            case not null when peer.GetPattern(PatternInterface.Toggle) is IToggleProvider p: p.Toggle(); break;
            case not null when peer.GetPattern(PatternInterface.SelectionItem) is ISelectionItemProvider p: p.Select(); break;
            default: throw new DebugException($"control {id} cannot be pressed (no Invoke, Toggle or SelectionItem pattern)");
        }
    }

    void Type(string text, string? id)
    {
        UIElement field;
        if (id is { Length: > 0 })
        {
            field = Find(id);
            if (field is not (TextBox { IsReadOnly: false } or PasswordBox)) throw new DebugException($"control {id} is not a text field");
            Focus(field);
        }
        else
        {
            field = KeyTarget().Target;
            if (field is not (TextBox { IsReadOnly: false } or PasswordBox)) throw new DebugException("no text field has the focus (pass --id)");
        }
        Insert(field, text);
    }

    /// <summary>Focuses <paramref name="el"/>; a field in the panel first takes the keyboard (as a click does), so the panel stays open.</summary>
    void Focus(UIElement el)
    {
        if (Window.GetWindow(el) is NotchWindow) _h.Shell.RequestKeyboardFocus();
        el.Focus();
        FocusManager.SetFocusedElement(FocusManager.GetFocusScope(el), el);
    }

    static void Insert(UIElement field, string text)
    {
        if (field is PasswordBox pb) { pb.Password += text; return; }
        var tb = (TextBox)field;
        tb.SelectedText = text;
        tb.Select(tb.SelectionStart + text.Length, 0);
    }

    /// <summary>QNotch's key window and its focused element: the active QNotch window, else the tour, else the open panel, else Settings.</summary>
    (Window Window, UIElement Target) KeyTarget()
    {
        var w = Windows().FirstOrDefault(x => x.IsActive)
            ?? (Tour() is { IsVisible: true } t ? t : null)
            ?? (_h.Shell.Mode == ShellMode.Expanded ? _h.Window : null)
            ?? (SettingsWindow.Current is { IsVisible: true } s ? s : null)
            ?? (Window)_h.Window;
        if (Keyboard.FocusedElement is UIElement f && Window.GetWindow(f) == w) return (w, f);
        if (FocusManager.GetFocusedElement(w) is UIElement { IsVisible: true } lf) return (w, lf);
        return (w, w);
    }

    void SendKey(string name, string? modifiers)
    {
        var mods = (modifiers ?? "").Split([',', '+', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(m => m.ToLowerInvariant() switch
            {
                "ctrl" or "control" => ModifierKeys.Control, "alt" => ModifierKeys.Alt, "shift" => ModifierKeys.Shift, "cmd" or "win" => ModifierKeys.Windows,
                _ => throw new DebugException($"unknown modifier {m}: use ctrl, alt, shift or cmd"),
            }).Aggregate(ModifierKeys.None, (x, y) => x | y);
        char? ch = name.Length == 1 ? name[0] : null;
        var key = name switch
        {
            "Escape" => System.Windows.Input.Key.Escape, "Return" or "Enter" => System.Windows.Input.Key.Return, "Tab" => System.Windows.Input.Key.Tab,
            "Space" => System.Windows.Input.Key.Space, "Up" => System.Windows.Input.Key.Up, "Down" => System.Windows.Input.Key.Down,
            "Left" => System.Windows.Input.Key.Left, "Right" => System.Windows.Input.Key.Right, "Delete" => System.Windows.Input.Key.Delete,
            _ when ch is { } c => VkKeyScanW(c) is var vk && vk != -1 ? KeyInterop.KeyFromVirtualKey(vk & 0xFF) : System.Windows.Input.Key.None,
            _ => throw new DebugException($"unknown key {name}: use Escape, Return, Tab, Space, Up, Down, Left, Right, Delete or one character"),
        };
        if (ch is { } upper && char.IsUpper(upper)) mods |= ModifierKeys.Shift;
        var (w, target) = KeyTarget();
        var src = PresentationSource.FromVisual(w) ?? throw new DebugException("the key window is not shown");
        using (new HeldModifiers(mods))
        {
            var handled = Raise(target, src, key, down: true);
            if (!handled && key == System.Windows.Input.Key.Tab)
                target.MoveFocus(new TraversalRequest(mods.HasFlag(ModifierKeys.Shift) ? FocusNavigationDirection.Previous : FocusNavigationDirection.Next));
            else if (!handled && ch is { } c && (mods & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) == 0)
            {
                if (target is TextBox { IsReadOnly: false } or PasswordBox) Insert(target, c.ToString());
                else TextCompositionManager.StartComposition(new TextComposition(InputManager.Current, target, c.ToString()));
            }
            Raise(target, src, key, down: false);
        }
    }

    /// <summary>Preview then bubbling key event on <paramref name="target"/>; true when a handler took it.</summary>
    static bool Raise(UIElement target, PresentationSource src, Key key, bool down)
    {
        if (key == System.Windows.Input.Key.None) return false;
        var preview = new KeyEventArgs(Keyboard.PrimaryDevice, src, Environment.TickCount, key) { RoutedEvent = down ? Keyboard.PreviewKeyDownEvent : Keyboard.PreviewKeyUpEvent };
        target.RaiseEvent(preview);
        if (preview.Handled) return true;
        var e = new KeyEventArgs(Keyboard.PrimaryDevice, src, Environment.TickCount, key) { RoutedEvent = down ? Keyboard.KeyDownEvent : Keyboard.KeyUpEvent };
        target.RaiseEvent(e);
        return e.Handled;
    }

    /// <summary>Modifier keys held for this thread only (SetKeyboardState: what GetKeyState and so Keyboard.Modifiers read), restored on dispose.
    /// Nothing reaches other apps.</summary>
    sealed class HeldModifiers : IDisposable
    {
        readonly byte[]? _saved;

        public HeldModifiers(ModifierKeys mods)
        {
            if (mods == ModifierKeys.None) return;
            var saved = new byte[256];
            if (!GetKeyboardState(saved)) return;
            var s = (byte[])saved.Clone();
            void Down(params int[] vks) { foreach (var vk in vks) s[vk] |= 0x80; }
            if (mods.HasFlag(ModifierKeys.Control)) Down(0x11, 0xA2);
            if (mods.HasFlag(ModifierKeys.Alt)) Down(0x12, 0xA4);
            if (mods.HasFlag(ModifierKeys.Shift)) Down(0x10, 0xA0);
            if (mods.HasFlag(ModifierKeys.Windows)) Down(0x5B);
            if (SetKeyboardState(s)) _saved = saved;
        }

        public void Dispose() { if (_saved is not null) SetKeyboardState(_saved); }
    }

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] static extern bool GetWindowRect(nint hwnd, out RECT rect);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out RECT value, int size);

    /// <summary>A request's <c>args</c>. Values may be strings, numbers or booleans: the CLI sends strings, so flags also read "true" and "false".</summary>
    readonly struct Args(JsonElement e)
    {
        public string? Str(string name) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) ? v.ValueKind switch
        {
            JsonValueKind.String => v.GetString(), JsonValueKind.Null => null, JsonValueKind.True => "true", JsonValueKind.False => "false", _ => v.GetRawText(),
        } : null;

        public string Need(string name) => Str(name) is { Length: > 0 } s ? s : throw new DebugException($"missing arg {name}");

        public bool Flag(string name) => Str(name)?.ToLowerInvariant() switch
        {
            null or "" or "false" or "0" or "no" => false,
            "true" or "1" or "yes" => true,
            var x => throw new DebugException($"{name} must be true or false, not {x}"),
        };
    }
}
