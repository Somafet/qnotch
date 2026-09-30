using System.Windows;
using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell;

/// <summary>Builds a segment element from its descriptor, inside try/catch. Each builder calls it once per segment (segments are read once).</summary>
internal static class SegmentHost
{
    public static FrameworkElement? Build(SegmentDescriptor d)
    {
        try { return d.Factory(); }
        catch (Exception ex)
        {
            Log.Error($"Segment '{d.Id}' failed to build", ex);
            return null;
        }
    }
}
