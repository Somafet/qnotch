using System.Windows;
using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell;

/// <summary>Builds segment elements from descriptors. A factory runs once per id (the element, or null after a failure, is cached), inside try/catch.</summary>
internal sealed class SegmentHost
{
    readonly Dictionary<string, FrameworkElement?> _cache = new();

    public FrameworkElement? Get(SegmentDescriptor d)
    {
        if (_cache.TryGetValue(d.Id, out var el)) return el;
        try { el = d.Factory(); }
        catch (Exception ex)
        {
            Log.Error($"Segment '{d.Id}' failed to build", ex);
            el = null;
        }
        _cache[d.Id] = el;
        return el;
    }
}
