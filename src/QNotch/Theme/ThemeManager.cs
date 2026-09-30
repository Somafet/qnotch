using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using QNotch.Core;

namespace QNotch.Theme;

/// <summary>Swaps the dark/light dictionary and (re)creates the accent brushes. All styles use DynamicResource so the swap is live.</summary>
public static class ThemeManager
{
    static bool? _dark;
    public static bool IsDark => _dark ?? true;

    public static void Apply(GeneralSettings gs)
    {
        var res = Application.Current.Resources;
        var dark = gs.Theme switch { ThemeChoice.Dark => true, ThemeChoice.Light => false, _ => !SystemUsesLightTheme() };
        if (_dark != dark)
        {
            _dark = dark;
            var uri = new Uri($"pack://application:,,,/Theme/Theme.{(dark ? "Dark" : "Light")}.xaml");
            var dict = new ResourceDictionary { Source = uri };
            if (res.MergedDictionaries.Count > 0 && res.MergedDictionaries[0].Source?.OriginalString.Contains("Theme.") == true)
                res.MergedDictionaries[0] = dict;
            else res.MergedDictionaries.Insert(0, dict);
        }

        Color accent;
        try { accent = (Color)ColorConverter.ConvertFromString(gs.AccentColor); }
        catch { accent = Color.FromRgb(0x5B, 0x9D, 0xFF); }
        var lum = (0.299 * accent.R + 0.587 * accent.G + 0.114 * accent.B) / 255;
        res["AccentBrush"] = Frozen(accent);
        res["AccentHoverBrush"] = Frozen(Blend(accent, dark ? Colors.White : Colors.Black, 0.18));
        res["AccentSoftBrush"] = Frozen(Color.FromArgb(0x38, accent.R, accent.G, accent.B));
        res["OnAccentBrush"] = Frozen(lum > 0.55 ? Color.FromRgb(0x0B, 0x0B, 0x0D) : Colors.White);
    }

    static SolidColorBrush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    static Color Blend(Color a, Color b, double t) => Color.FromRgb(
        (byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));

    static bool SystemUsesLightTheme()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v != 0;
        }
        catch { return false; }
    }
}
