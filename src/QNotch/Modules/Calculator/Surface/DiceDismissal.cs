using System.Windows;

namespace Calc.Windows;

/// <summary>Settled dice stay on the sheet until the next action inside <c>root</c>: a key, a click or a wheel turn, or a resize of
/// the dice layer. Pointer movement alone keeps them. The host adds its own edit, scroll and sheet-switch triggers.</summary>
internal static class DiceDismissal
{
    internal static void Attach(UIElement root, DiceToss layer)
    {
        root.PreviewKeyDown += (_, _) => layer.Dismiss();
        root.PreviewMouseDown += (_, _) => layer.Dismiss();
        root.PreviewMouseWheel += (_, _) => layer.Dismiss();
        layer.SizeChanged += (_, _) => layer.Dismiss();
    }
}
