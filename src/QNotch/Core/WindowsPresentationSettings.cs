namespace QNotch.Core;

/// <summary>Windows-local presentation choices. Never exported in portable setup codes.</summary>
public sealed class WindowsPresentationSettings
{
    public Dictionary<string, bool> Tabs { get; set; } = new();
    public Dictionary<string, bool> Segments { get; set; } = new();
    public event Action? Changed;
    public bool TabVisible(string id) => id == "home" || !Tabs.TryGetValue(id, out var show) || show;
    public bool SegmentVisible(string id) => !Segments.TryGetValue(id, out var show) || show;
    public void SetTab(string id, bool show)
    {
        if (id == "home" || TabVisible(id) == show) return;
        Tabs[id] = show;
        Changed?.Invoke();
    }
    public void SetSegments(IEnumerable<string> ids, bool show)
    {
        foreach (var id in ids) Segments[id] = show;
        Changed?.Invoke();
    }
}
