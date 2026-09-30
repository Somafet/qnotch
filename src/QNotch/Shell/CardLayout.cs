using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell;

/// <summary>
/// Order and visibility of Home cards, persisted in general.json. The order list also contains hidden cards, so a card
/// re-enabled later returns to its old slot. HomeView renders from this and publishes the live hosts in <see cref="Hosts"/>.
/// </summary>
public sealed class CardLayout
{
    readonly Registry<CardDescriptor> _cards;
    readonly GeneralSettings _gs;
    List<CardDescriptor>? _ordered;

    public CardLayout(Registry<CardDescriptor> cards, GeneralSettings gs)
    {
        _cards = cards;
        _gs = gs;
        cards.Changed += () => { _ordered = null; Changed?.Invoke(); };
    }

    /// <summary>Raised after order or visibility changed (settings are already updated and will be saved).</summary>
    public event Action? Changed;
    /// <summary>Raised by HomeView after it rebuilt <see cref="Hosts"/>.</summary>
    public event Action? HostsChanged;

    /// <summary>Currently displayed cards in display order (visible only). Maintained by HomeView.</summary>
    public IReadOnlyList<CardHost> Hosts { get; private set; } = [];
    internal void SetHosts(IReadOnlyList<CardHost> hosts) { Hosts = hosts; HostsChanged?.Invoke(); }

    /// <summary>All registered cards (hidden included) in display order.</summary>
    public IReadOnlyList<CardDescriptor> Ordered => _ordered ??= Resolve();

    public IEnumerable<CardDescriptor> Visible => Ordered.Where(c => IsVisible(c.Id));

    public bool IsVisible(string id) =>
        _gs.CardVisible.TryGetValue(id, out var v) ? v : _cards.Find(id)?.DefaultVisible ?? false;

    public int OrderNumber(string id) => Ordered.ToList().FindIndex(c => c.Id == id) + 1;

    public void SetVisible(string id, bool visible)
    {
        _gs.CardVisible[id] = visible;
        Save();
    }

    /// <summary>Move card <paramref name="id"/> into the slot currently held by <paramref name="targetId"/>.</summary>
    public void Move(string id, string targetId)
    {
        var order = Ordered.Select(c => c.Id).ToList();
        var from = order.IndexOf(id);
        var to = order.IndexOf(targetId);
        if (from < 0 || to < 0 || from == to) return;
        order.RemoveAt(from);
        order.Insert(to, id);
        _gs.CardOrder = order;
        Save();
    }

    void Save()
    {
        _ordered = null;
        _gs.CardOrder = Ordered.Select(c => c.Id).ToList();
        Changed?.Invoke();
        // Persisted by the shell (it watches Changed and saves general.json).
    }

    List<CardDescriptor> Resolve()
    {
        var byId = _cards.Items.ToDictionary(c => c.Id);
        var result = new List<CardDescriptor>();
        foreach (var id in _gs.CardOrder)
            if (byId.Remove(id, out var c)) result.Add(c);
        result.AddRange(byId.Values.OrderBy(c => c.DefaultOrder));
        return result;
    }
}
