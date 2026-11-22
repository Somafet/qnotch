using QNotch.Core;

namespace QNotch.Shell;

/// <summary>hotkeys.json: shortcut id to gesture, only for shortcuts the user changed. An empty gesture means off.</summary>
public sealed class ShortcutSettings { public Dictionary<string, string> Keys { get; set; } = new(); }

/// <summary>A titled block of rows on the Settings, Hotkeys page.</summary>
public sealed record ShortcutGroup(string Title, string Hint);

/// <summary>One global hotkey the user can change in Settings, Hotkeys. Created with <see cref="Shortcuts.Add"/>.</summary>
public sealed class Shortcut
{
    internal Shortcut(string id, string title, string hint, string def, Action action, int order) =>
        (Id, Title, Hint, Default, Action, Order) = (id, title, hint, def, action, order);

    public string Id { get; }
    public string Title { get; }
    public string Hint { get; }
    public string Default { get; }
    public int Order { get; internal set; }
    public ShortcutGroup? Group { get; init; }
    internal bool AllowDuringInput { get; init; }
    internal Action Action { get; }

    /// <summary>The current gesture ("Ctrl+Alt+F"), empty when the user turned the shortcut off.</summary>
    public string Gesture { get; internal set; } = "";
    /// <summary>False while the owner has no use for it (an empty app slot): the key is then left to other apps.</summary>
    public bool Enabled { get; internal set; }
    /// <summary>Another app or <see cref="UsedBy"/> owns the gesture, so it does nothing here.</summary>
    public bool Taken { get; internal set; }
    /// <summary>The QNotch shortcut with a lower order that holds this gesture.</summary>
    public Shortcut? UsedBy { get; internal set; }
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
    bool _inputCaptured;
    public bool InputCaptured
    {
        get => _inputCaptured;
        set { if (_inputCaptured == value) return; _inputCaptured = value; ApplyInOrder(_items); Changed?.Invoke(); }
    }

    /// <summary>A gesture, an enabled flag or a taken flag changed, or a shortcut was added.</summary>
    public event Action? Changed;

    public IReadOnlyList<Shortcut> Items => _items.OrderBy(s => s.Order).ToList();
    public Shortcut? Find(string id) => _items.FirstOrDefault(s => s.Id == id);

    /// <summary>The gesture of <paramref name="id"/> even before its owner declared it (welcome tour tips): the declared one, else the saved
    /// one, else <paramref name="defaultGesture"/>. Empty when the user turned it off.</summary>
    public string GestureOf(string id, string defaultGesture) =>
        Find(id)?.Gesture ?? (_cfg.Keys.TryGetValue(id, out var saved) ? saved : defaultGesture);

    /// <summary>
    /// Declares a shortcut and registers it with the saved gesture, or <paramref name="defaultGesture"/> (KeyGestureConverter syntax).
    /// Call it once per id, in <c>Initialize</c>. <paramref name="action"/> runs on the UI thread.
    /// </summary>
    public Shortcut Add(string id, string title, string hint, string defaultGesture, Action action, int order = 100, bool enabled = true, bool allowDuringInput = false, ShortcutGroup? group = null)
    {
        var s = new Shortcut(id, title, hint, defaultGesture, action, order)
        {
            Gesture = _cfg.Keys.TryGetValue(id, out var saved) ? saved : defaultGesture,
            Enabled = enabled,
            AllowDuringInput = allowDuringInput,
            Group = group,
        };
        _items.Add(s);
        ApplyKey(s.Gesture);
        Changed?.Invoke();
        return s;
    }

    public void Enable(Shortcut s, bool on)
    {
        if (s.Enabled == on) return;
        s.Enabled = on;
        ApplyKey(s.Gesture);
        Changed?.Invoke();
    }

    /// <summary>Moves a shortcut in the Settings list and in who keeps a shared key.</summary>
    internal void SetOrder(Shortcut s, int order)
    {
        if (s.Order == order) return;
        s.Order = order;
        ApplyKey(s.Gesture);
        Changed?.Invoke();
    }

    /// <summary>Changes and saves the gesture (empty turns it off). Returns the enabled shortcut that already uses it, or null when done.
    /// A disabled shortcut holds no key, so its gesture can be reused; when it is enabled again, the lower order keeps the key.</summary>
    public Shortcut? Set(Shortcut s, string gesture)
    {
        if (gesture.Length > 0 && _items.FirstOrDefault(x => x != s && x.Enabled && Same(x.Gesture, gesture)) is { } other) return other;
        var old = s.Gesture;
        s.Gesture = gesture;
        if (gesture == s.Default) _cfg.Keys.Remove(s.Id); else _cfg.Keys[s.Id] = gesture;
        store.Save(File, _cfg);
        Apply(s);
        ApplyKey(old);
        ApplyKey(gesture);
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
            ApplyInOrder(_items);
            if (!value) Changed?.Invoke();
        }
    }

    void ApplyKey(string gesture)
    {
        if (gesture.Length > 0) ApplyInOrder(_items.Where(x => Same(x.Gesture, gesture)));
    }

    /// <summary>Releases these shortcuts, then registers them lowest order first, so that one keeps a key they share.</summary>
    void ApplyInOrder(IEnumerable<Shortcut> items)
    {
        var ordered = items.OrderBy(x => x.Order).ToList();
        foreach (var x in ordered) Release(x);
        foreach (var x in ordered) Apply(x);
    }

    void Release(Shortcut s)
    {
        if (s.Registered is not { } old) return;
        hotkeys.Unregister(old);
        s.Registered = null;
    }

    void Apply(Shortcut s)
    {
        Release(s);
        s.Taken = false;
        s.UsedBy = null;
        if (_suspended || (_inputCaptured && !s.AllowDuringInput) || !s.Enabled || s.Gesture.Length == 0 || store.ReadOnly) return;
        if (_items.FirstOrDefault(x => x != s && x.Registered is { } r && Same(r, s.Gesture)) is { } holder) { s.Taken = true; s.UsedBy = holder; return; }
        if (hotkeys.Register(s.Gesture, () => { using (Analytics.Surface("hotkey")) { s.Action(); } })) s.Registered = s.Gesture;
        else s.Taken = true;
    }

    static bool Same(string a, string b) =>
        HotkeyService.TryParse(a, out var ma, out var ka) && HotkeyService.TryParse(b, out var mb, out var kb) && ma == mb && ka == kb;
}
