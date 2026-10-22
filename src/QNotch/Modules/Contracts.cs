using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Shell;

namespace QNotch.Modules;

/// <summary>How often a module should refresh. The SHELL decides: Fast while the panel is open, Slow otherwise (collapsed or game bar).</summary>
public enum Cadence { Fast, Slow }

public interface INotchModule
{
    /// <summary>Called once on the UI thread at startup, after the window handle exists. Register cards/tabs/sections and start providers here. Exceptions are caught and logged.</summary>
    void Initialize(ModuleContext ctx);
}

/// <summary>Optional. Called on the UI thread whenever the shell mode changes the refresh cadence, and once after startup.</summary>
public interface ICadenceAware
{
    void SetCadence(Cadence cadence);
}

public interface IRegistryItem { string Id { get; } int Order { get; } }

/// <summary>A card on the Home grid. The card body comes from Factory (called once, lazily, on the UI thread); CardHost draws title and order badge.</summary>
public sealed record CardDescriptor(string Id, string Title, int DefaultOrder, Func<FrameworkElement> Factory,
    bool DefaultVisible = true, int ColumnSpan = 1, int RowSpan = 1) : IRegistryItem
{
    public int Order => DefaultOrder;
}

/// <summary>Where a segment is hosted: the pill (left or right cluster), the glance strip under the collapsed pill, or the game bar.</summary>
public enum SegmentSlot { PillLeft, PillRight, Glance, GameBar }

/// <summary>
/// A small view the shell hosts outside the panel. Segments are read once: pill and glance segments at startup, game bar segments on the
/// first entry into game mode, so register them in <c>Initialize</c> of an Early module (pill, glance) or any module (game bar) and never
/// later. Factory: called once, UI thread; it sets its own DataContext (or binds with Source).
/// The element owns its Visibility for data availability ("no battery" collapses the battery). The shell owns Margin and, in the game bar,
/// the per-segment user toggle. Segments never set their own outer Margin. Ids are unique across slots (module.slot.name); game bar ids
/// are persisted keys. Title and Hint: game bar only (Settings, Game mode, Segments).
/// </summary>
public sealed record SegmentDescriptor(string Id, SegmentSlot Slot, int Order, Func<FrameworkElement> Factory,
    string Title = "", string? Hint = null, Func<bool>? Presented = null, Action<bool>? SetPresented = null) : IRegistryItem;

/// <summary>One entry of <see cref="ModuleList.All"/>. Create is called only when the module is enabled. Early: registers pill or glance segments, so it initializes before the first frame.
/// Shared: the fields of the module's settings file (named Id) that a setup code carries, or null for none.
/// Glyph: its icon in the welcome tour's feature tiles (Segoe Fluent Icons).
/// Setup: optional static factory for the tour's Connect step (see <see cref="SetupContext"/>); null when there is nothing to set up right now.
/// Tip: optional one-line tip for the tour's last step, with real gestures; null for none.</summary>
public sealed record ModuleInfo(string Id, string Title, string Description, Func<INotchModule> Create, bool Early = false, SharedSettings? Shared = null,
    string Glyph = "", Func<SetupContext, SetupRow?>? Setup = null, Func<SetupContext, string?>? Tip = null);

/// <summary>
/// What a setup row (<see cref="ModuleInfo.Setup"/>) and a tip may use. The welcome tour builds rows before the module exists, so a row
/// uses only static helpers, these settings and the credential store: no providers, bus, shell or timers. The running module picks up what
/// a row saved when it starts; a module that is already running learns about it through its own static event. UI thread only.
/// </summary>
public sealed class SetupContext
{
    public required SettingsStore Settings { get; init; }
    /// <summary>Gestures by shortcut id, also for modules that are not created yet (saved gesture or the given default).</summary>
    public required Shortcuts Shortcuts { get; init; }
    /// <summary>Snapshot run: show demo values (a connected account, a chosen place), never write files or go online.</summary>
    public bool Demo => Settings.ReadOnly;
}

/// <summary>
/// One row of the tour's Connect step. The module keeps Status current (text and foreground brush): "Not connected", "Connected as @login".
/// Action sits on the right (buttons, a box). Detail, if any, shows under the row (a sign-in code, search results) and the module collapses it
/// while it has nothing to show. Work a row starts (GitHub polling) must stop when its elements unload.
/// </summary>
public sealed record SetupRow(string Title, string Glyph, TextBlock Status, FrameworkElement Action, FrameworkElement? Detail = null)
{
    /// <summary>Raised by <see cref="Success"/>; the tour plays its success moment (a check spring, the hero card).</summary>
    public event Action? Succeeded;

    /// <summary>Call when the row just connected something (signed in, picked a place), not for a state that was already there.</summary>
    public void Success() => Succeeded?.Invoke();
}

/// <summary>
/// Settings fields a setup code may carry (Settings, General, Share your setup). A field is its property name, with "Name:min..max" for a
/// number. Only plain preferences: never personal data, paths, history, or anything that starts a program or opens a port.
/// </summary>
public sealed record SharedSettings(Type Type, params string[] Fields);

/// <summary>A panel tab. Glyph is a Segoe Fluent Icons string (see Theme/Glyphs.cs). Factory is called once, lazily.
/// IsEmpty: true while the tab has nothing to show; the panel then opens on Home instead of this tab.</summary>
public sealed record TabDescriptor(string Id, string Title, string Glyph, int Order, Func<FrameworkElement> Factory, Func<bool>? IsEmpty = null) : IRegistryItem;

/// <summary>A section in the Settings window left nav. Factory is called once, lazily.</summary>
public sealed record SettingsSectionDescriptor(string Id, string Title, string Glyph, int Order, Func<FrameworkElement> Factory) : IRegistryItem;

/// <summary>
/// A collapsed pill state a module shows with demo data in a snapshot run (spec/diagnostics.md, <c>pill-&lt;State&gt;.png</c>). State <c>idle</c>
/// hides what the module adds to the resting pill; any other (<c>running</c>, <c>capture</c>, <c>waiting</c>, <c>agent</c>) shows it. Show
/// applies the state and returns the action that undoes it. Register only when <c>Settings.ReadOnly</c>.
/// </summary>
public sealed record DemoState(string Id, string State, int Order, Func<Action> Show) : IRegistryItem;

/// <summary>One search result. Run (UI thread) does the whole action when the user picks it, including SelectTab or ClosePanel.</summary>
public sealed record SearchHit(string Title, string Subtitle, Action Run)
{
    /// <summary>One line of <paramref name="text"/> around the first match of <paramref name="query"/>, for a hit title.</summary>
    public static string Snippet(string text, string query, int max = 90)
    {
        var at = Math.Max(0, text.IndexOf(query, StringComparison.OrdinalIgnoreCase));
        var from = at > max / 3 ? at - max / 3 : 0;
        var s = text.AsSpan(from, Math.Min(max, text.Length - from)).ToString().ReplaceLineEndings(" ").Trim();
        return (from > 0 ? "…" : "") + s + (from + max < text.Length ? "…" : "");
    }
}

/// <summary>
/// What a module offers to the Search tab (the search module reads the registry; without it nobody does). Find runs on the UI thread on
/// every keystroke with the trimmed query (never empty): filter what is already in memory, case-insensitive, no I/O. The search module
/// caps the count and draws Glyph and Title next to each hit.
/// </summary>
public sealed record SearchSource(string Id, string Title, string Glyph, int Order, Func<string, IEnumerable<SearchHit>> Find) : IRegistryItem;

public sealed class Registry<T> where T : class, IRegistryItem
{
    readonly List<T> _items = new();
    readonly Dictionary<string, string> _owners = new();
    internal string RegistrationOwner { get; set; } = "";
    public string OwnerOf(string id) => _owners.GetValueOrDefault(id, "");
    IReadOnlyList<T>? _sorted;

    /// <summary>Raised (UI thread) after any registration.</summary>
    public event Action? Changed;

    /// <summary>Registering an existing Id replaces it.</summary>
    public void Register(T item)
    {
        _items.RemoveAll(i => i.Id == item.Id);
        _items.Add(item);
        _owners[item.Id] = RegistrationOwner;
        _sorted = null;
        Changed?.Invoke();
    }

    public IReadOnlyList<T> Items => _sorted ??= _items.OrderBy(i => i.Order).ToList();
    public T? Find(string id) => _items.FirstOrDefault(i => i.Id == id);
}

/// <summary>Everything a module may touch. Do not reach for App.Current or shell internals instead.</summary>
public sealed class ModuleContext
{
    public required EventBus Bus { get; init; }
    public required SettingsStore Settings { get; init; }
    /// <summary>Raw RegisterHotKey, for a key held only for a moment (Esc while picking a color). Anything lasting goes in <see cref="Shortcuts"/>.</summary>
    public required HotkeyService Hotkeys { get; init; }
    /// <summary>Global hotkeys the user can change in Settings, Hotkeys: declare each with <c>Shortcuts.Add</c> in <c>Initialize</c>.</summary>
    public required Shortcuts Shortcuts { get; init; }
    /// <summary>Sounds the user can replace with a file in Settings, Sounds: declare each with <c>Sounds.Add</c> in <c>Initialize</c>, play with <c>Sounds.Play</c>.</summary>
    public required Sounds Sounds { get; init; }
    public required IShell Shell { get; init; }
    public required Dispatcher Dispatcher { get; init; }
    public required Registry<CardDescriptor> Cards { get; init; }
    public required Registry<TabDescriptor> Tabs { get; init; }
    public required Registry<SettingsSectionDescriptor> SettingsSections { get; init; }
    /// <summary>Small views hosted by the shell outside the panel: pill clusters, glance strip, game bar. Read once, see <see cref="SegmentDescriptor"/>.</summary>
    public required Registry<SegmentDescriptor> Segments { get; init; }
    /// <summary>Content the Search tab can find, see <see cref="SearchSource"/>. Register in <c>Initialize</c>.</summary>
    public required Registry<SearchSource> Search { get; init; }
    /// <summary>Snapshot run only: pill states the snapshot shows one at a time, see <see cref="DemoState"/>.</summary>
    public Registry<DemoState> Demos { get; init; } = new();
}
