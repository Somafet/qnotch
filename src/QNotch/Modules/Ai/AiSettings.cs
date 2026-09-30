namespace QNotch.Modules.Ai;

public sealed class CustomApp
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
}

/// <summary>ai.json. Slots holds app ids for Alt+1..6 (empty string = free).</summary>
public sealed class AiSettings
{
    public const int SlotCount = 6;

    public Dictionary<string, bool> Providers { get; set; } = new();
    public int RefreshMinutes { get; set; } = 10;
    public List<string> Slots { get; set; } = new();
    /// <summary>Apps already auto-placed into a slot once, so clearing a slot is never undone.</summary>
    public List<string> AutoPlaced { get; set; } = new();
    public List<CustomApp> Custom { get; set; } = new();

    public bool IsEnabled(string providerId) => !Providers.TryGetValue(providerId, out var on) || on;

    public void Normalize()
    {
        Slots ??= new(); AutoPlaced ??= new(); Custom ??= new(); Providers ??= new();
        while (Slots.Count < SlotCount) Slots.Add("");
        if (Slots.Count > SlotCount) Slots.RemoveRange(SlotCount, Slots.Count - SlotCount);
        for (var i = 0; i < Slots.Count; i++) Slots[i] ??= "";
        if (RefreshMinutes < 1) RefreshMinutes = 10;
    }
}
