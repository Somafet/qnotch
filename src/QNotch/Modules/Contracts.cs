using System.Windows;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Shell;

namespace QNotch.Modules;

/// <summary>How often a module should refresh. The SHELL decides: Fast while the panel is open, Slow otherwise (collapsed or game bar).</summary>
public enum Cadence { Fast, Slow }

public interface INotchModule
{
    /// <summary>Stable id, also the settings file name (media.json) if the module stores settings.</summary>
    string Id { get; }

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
/// A small view the shell hosts outside the panel. Factory: called once, UI thread; it sets its own DataContext (or binds with Source).
/// The element owns its Visibility for data availability ("no battery" collapses the battery). The shell owns Margin and, in the game bar,
/// the per-segment user toggle. Segments never set their own outer Margin. Ids are unique across slots (module.slot.name); game bar ids
/// are persisted keys. Title and Hint: game bar only (Settings, Game mode, Segments).
/// </summary>
public sealed record SegmentDescriptor(string Id, SegmentSlot Slot, int Order, Func<FrameworkElement> Factory,
    string Title = "", string? Hint = null) : IRegistryItem;

/// <summary>One entry of <see cref="ModuleList.All"/>. Create is called only when the module is enabled. Early: registers pill or glance segments, so it initializes before the first frame.</summary>
public sealed record ModuleInfo(string Id, string Title, string Description, Func<INotchModule> Create, bool Early = false);

/// <summary>A panel tab. Glyph is a Segoe Fluent Icons string (see Theme/Glyphs.cs). Factory is called once, lazily.</summary>
public sealed record TabDescriptor(string Id, string Title, string Glyph, int Order, Func<FrameworkElement> Factory) : IRegistryItem;

/// <summary>A section in the Settings window left nav. Factory is called once, lazily.</summary>
public sealed record SettingsSectionDescriptor(string Id, string Title, string Glyph, int Order, Func<FrameworkElement> Factory) : IRegistryItem;

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
    public required HotkeyService Hotkeys { get; init; }
    public required IShell Shell { get; init; }
    public required Dispatcher Dispatcher { get; init; }
    public required Registry<CardDescriptor> Cards { get; init; }
    public required Registry<TabDescriptor> Tabs { get; init; }
    public required Registry<SettingsSectionDescriptor> SettingsSections { get; init; }
    /// <summary>Small views hosted by the shell outside the panel: pill clusters, glance strip, game bar.</summary>
    public required Registry<SegmentDescriptor> Segments { get; init; }
}
