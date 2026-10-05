using System.Windows;
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
    string Title = "", string? Hint = null) : IRegistryItem;

/// <summary>One entry of <see cref="ModuleList.All"/>. Create is called only when the module is enabled. Early: registers pill or glance segments, so it initializes before the first frame.
/// Shared: the fields of the module's settings file (named Id) that a setup code carries, or null for none.</summary>
public sealed record ModuleInfo(string Id, string Title, string Description, Func<INotchModule> Create, bool Early = false, SharedSettings? Shared = null);

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
    IReadOnlyList<T>? _sorted;

    /// <summary>Raised (UI thread) after any registration.</summary>
    public event Action? Changed;

    /// <summary>Registering an existing Id replaces it.</summary>
    public void Register(T item)
    {
        _items.RemoveAll(i => i.Id == item.Id);
        _items.Add(item);
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
}
