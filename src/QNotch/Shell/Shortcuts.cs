using QNotch.Core;

namespace QNotch.Shell;

/// <summary>hotkeys.json: shortcut id to gesture, only for shortcuts the user changed. An empty gesture means off.</summary>
public sealed class ShortcutSettings { public Dictionary<string, string> Keys { get; set; } = new(); }

/// <summary>One global hotkey the user can change in Settings, Hotkeys. Created with <see cref="Shortcuts.Add"/>.</summary>
public sealed class Shortcut
{
    internal Shortcut(string id, string title, string hint, string def, Action action, int order) =>
        (Id, Title, Hint, Default, Action, Order) = (id, title, hint, def, action, order);

    public string Id { get; }
    public string Title { get; }
    public string Hint { get; }
    public string Default { get; }
    public int Order { get; }
    internal Action Action { get; }

    /// <summary>The current gesture ("Ctrl+Alt+F"), empty when the user turned the shortcut off.</summary>
    public string Gesture { get; internal set; } = "";
    /// <summary>False while the owner has no use for it (an empty app slot): the key is then left to other apps.</summary>
    public bool Enabled { get; internal set; }
    /// <summary>Another app owns the gesture, so it does nothing here.</summary>
    public bool Taken { get; internal set; }
    internal string? Registered;
}

/// <summary>
/// The user-changeable global hotkeys of the shell and the modules: owns the saved gestures, the registration and what the
/// Settings, Hotkeys page lists. UI thread only. A snapshot run (read-only settings) registers nothing.
/// </summary>
public sealed class Shortcuts(HotkeyService hotkeys, SettingsStore store)
{
    const string File = "hotkeys";
    readonly List<Shortcut> _items = [];
    readonly ShortcutSettings _cfg = store.Get<ShortcutSettings>(File);
    bool _suspended;

    /// <summary>A gesture, an enabled flag or a taken flag changed, or a shortcut was added.</summary>
    public event Action? Changed;

    public IReadOnlyList<Shortcut> Items => _items.OrderBy(s => s.Order).ToList();
    public Shortcut? Find(string id) => _items.FirstOrDefault(s => s.Id == id);

    /// <summary>
    /// Declares a shortcut and registers it with the saved gesture, or <paramref name="defaultGesture"/> (KeyGestureConverter syntax).
    /// Call it once per id, in <c>Initialize</c>. <paramref name="action"/> runs on the UI thread.
    /// </summary>
    public Shortcut Add(string id, string title, string hint, string defaultGesture, Action action, int order = 100, bool enabled = true)
    {
        var s = new Shortcut(id, title, hint, defaultGesture, action, order)
        {
            Gesture = _cfg.Keys.TryGetValue(id, out var saved) ? saved : defaultGesture,
            Enabled = enabled,
        };
        _items.Add(s);
        Apply(s);
        Changed?.Invoke();
        return s;
    }

    public void Enable(Shortcut s, bool on)
    {
        if (s.Enabled == on) return;
        s.Enabled = on;
        Apply(s);
        Changed?.Invoke();
    }

    /// <summary>Changes and saves the gesture (empty turns it off). Returns the shortcut that already uses it, or null when done.</summary>
    public Shortcut? Set(Shortcut s, string gesture)
    {
        if (gesture.Length > 0 && _items.FirstOrDefault(x => x != s && Same(x.Gesture, gesture)) is { } other) return other;
        s.Gesture = gesture;
        if (gesture == s.Default) _cfg.Keys.Remove(s.Id); else _cfg.Keys[s.Id] = gesture;
        store.Save(File, _cfg);
        Apply(s);
        Changed?.Invoke();
        return null;
    }

    /// <summary>The Settings recorder is listening: registered hotkeys would swallow the keys it wants to read.</summary>
    public bool Suspended
    {
        get => _suspended;
        set
        {
            if (_suspended == value) return;
            _suspended = value;
            foreach (var s in _items) Apply(s);
            if (!value) Changed?.Invoke();
        }
    }

    void Apply(Shortcut s)
    {
        if (s.Registered is { } old) { hotkeys.Unregister(old); s.Registered = null; }
        s.Taken = false;
        if (_suspended || !s.Enabled || s.Gesture.Length == 0 || store.ReadOnly) return;
        // Two shortcuts with the same default: the first one keeps the key.
        if (!_items.Any(x => x != s && x.Registered is { } r && Same(r, s.Gesture)) && hotkeys.Register(s.Gesture, s.Action)) s.Registered = s.Gesture;
        else s.Taken = true;
    }

    static bool Same(string a, string b) =>
        HotkeyService.TryParse(a, out var ma, out var ka) && HotkeyService.TryParse(b, out var mb, out var kb) && ma == mb && ka == kb;
}
