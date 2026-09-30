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
    public required AppState State { get; init; }
    public required EventBus Bus { get; init; }
    public required SettingsStore Settings { get; init; }
    public required HotkeyService Hotkeys { get; init; }
    public required IShell Shell { get; init; }
    public required Dispatcher Dispatcher { get; init; }
    public required Registry<CardDescriptor> Cards { get; init; }
    public required Registry<TabDescriptor> Tabs { get; init; }
    public required Registry<SettingsSectionDescriptor> SettingsSections { get; init; }
    /// <summary>Card order/visibility and the live card hosts (for Edit mode).</summary>
    public required CardLayout CardLayout { get; init; }
}
