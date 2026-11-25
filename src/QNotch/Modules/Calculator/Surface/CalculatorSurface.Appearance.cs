using System.Windows;
using System.Windows.Media;

namespace Calc.Windows;

/// <summary>Colors come from QNotch's theme resources, so light, dark and the accent switch live. Windows high contrast replaces them
/// with system colors for this view only.</summary>
public partial class CalculatorSurface
{
    private static readonly string[] ThemeKeys = ["CardBrush", "TextPrimaryBrush", "TextSecondaryBrush", "TextTertiaryBrush", "AccentBrush", "ControlHoverBrush",
        "ControlPressedBrush", "SurfaceRaisedBrush", "StrokeBrush", "StrokeStrongBrush", "WarningBrush", "AccentSoftBrush"];

    /// <summary>Follows a theme brush, so a light, dark or accent change repaints what the editor draws itself.</summary>
    private static readonly DependencyProperty ThemeProbeProperty = DependencyProperty.Register("ThemeProbe", typeof(object), typeof(CalculatorSurface),
        new PropertyMetadata(null, (sender, _) => ((CalculatorSurface)sender).ThemeChanged()));

    private void ThemeChanged()
    {
        if (!ready) return;
        foreach (var editor in editors.Values.Append(Editor).Distinct()) editor.TextArea.TextView.Redraw();
        ClearResults();
        RequestGutterLayout();
    }

    private void ApplyAppearance(bool? highContrastOverride = null)
    {
        var contrast = highContrastOverride ?? SystemParameters.HighContrast;
        if (contrast)
        {
            Resources["CardBrush"] = SystemColors.WindowBrush;
            Resources["TextPrimaryBrush"] = SystemColors.WindowTextBrush;
            Resources["TextSecondaryBrush"] = SystemColors.WindowTextBrush;
            Resources["TextTertiaryBrush"] = SystemColors.WindowTextBrush;
            Resources["AccentBrush"] = SystemColors.WindowTextBrush;
            Resources["ControlHoverBrush"] = SystemColors.ControlBrush;
            Resources["ControlPressedBrush"] = SystemColors.HighlightBrush;
            Resources["SurfaceRaisedBrush"] = SystemColors.WindowBrush;
            Resources["StrokeBrush"] = SystemColors.WindowTextBrush;
            Resources["StrokeStrongBrush"] = SystemColors.WindowTextBrush;
            Resources["WarningBrush"] = SystemColors.WindowTextBrush;
            Resources["AccentSoftBrush"] = SystemColors.ControlBrush;
        }
        else foreach (var key in ThemeKeys) Resources.Remove(key);
        // Recolor cached editors too, without replacing their source, undo history or selection.
        foreach (var editor in editors.Values.Append(Editor).Distinct()) ApplyEditorColors(editor, contrast);
    }

    private void ApplyEditorColors(SheetEditor editor, bool contrast)
    {
        if (contrast)
        {
            editor.TextArea.ClearValue(ICSharpCode.AvalonEdit.Editing.TextArea.SelectionBrushProperty);
            editor.TextArea.SelectionBrush = SystemColors.HighlightBrush;
            editor.TextArea.SelectionForeground = SystemColors.HighlightTextBrush;
        }
        else
        {
            editor.TextArea.SetResourceReference(ICSharpCode.AvalonEdit.Editing.TextArea.SelectionBrushProperty, "AccentSoftBrush");
            editor.TextArea.SelectionForeground = null;
        }
        editor.TextArea.TextView.Redraw();
    }
}
