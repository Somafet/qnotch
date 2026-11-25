using System.Windows;

namespace QNotch.Theme;

/// <summary>
/// Panel geometry shared by the tabs (DIPs). A surface that fills a tab (a card, a drop zone, the Home grid) reaches the panel's
/// rounded bottom corners, so it follows the concentric-corners rule in spec/ui-conventions.md: the same gap to the panel's sides and
/// bottom, and a radius of the panel's radius minus that gap. Captions and headers above it keep the page's text inset.
/// </summary>
public static class PanelMetrics
{
    /// <summary>Bottom corner radius of the open panel.</summary>
    public const double Radius = 26;
    /// <summary>Gap from a tab's filling surface to the panel's sides and bottom, and between Home cards.</summary>
    public const double Gap = 12;
    /// <summary>Radius of a surface that sits in the panel's bottom corners, and of every Home card.</summary>
    public const double CardRadius = Radius - Gap;
    /// <summary>The panel's tab host already insets each side by this much.</summary>
    public const double TabHostInset = 4;
    /// <summary>Where a tab's captions and header text start, from the panel's edge.</summary>
    public const double TextInset = 23;

    public static readonly CornerRadius Card = new(CardRadius);
    /// <summary>Margin of a tab whose content fills it: <see cref="Gap"/> from the panel's sides and bottom.</summary>
    public static readonly Thickness Page = new(Gap - TabHostInset, 0, Gap - TabHostInset, Gap);
    /// <summary>Side margin that brings a caption or header inside a <see cref="Page"/> back to <see cref="TextInset"/>.</summary>
    public static readonly Thickness Caption = new(TextInset - Gap, 0, TextInset - Gap, 0);
}
