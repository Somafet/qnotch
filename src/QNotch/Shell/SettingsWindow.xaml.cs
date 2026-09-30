using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;
using QNotch.Theme;

namespace QNotch.Shell;

/// <summary>Normal activatable window. Left nav lists every registered settings section; section views are created lazily, once.</summary>
public partial class SettingsWindow : Window
{
    static SettingsWindow? _instance;
    readonly Dictionary<string, FrameworkElement> _views = new();
    readonly Dictionary<string, RadioButton> _buttons = new();
    readonly Registry<SettingsSectionDescriptor> _sections;

    SettingsWindow(Registry<SettingsSectionDescriptor> sections)
    {
        _sections = sections;
        InitializeComponent();
        Icon = AppIcon.Render(32);
        foreach (var s in sections.Items)
        {
            var id = s.Id;
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            var glyph = UiKit.Glyph(s.Glyph, 15, "TextSecondaryBrush");
            glyph.Margin = new Thickness(0, 0, 10, 0);
            row.Children.Add(glyph);
            row.Children.Add(new TextBlock { Text = s.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
            var rb = new RadioButton { Style = (Style)FindResource("NavButton"), Content = row, GroupName = "nav", Margin = new Thickness(0, 0, 0, 2) };
            rb.Checked += (_, _) => Select(id);
            Nav.Children.Add(rb);
            _buttons[id] = rb;
        }
        SourceInitialized += (_, _) => DarkTitleBar();
    }

    /// <summary>Shows the single settings window (creating it on first use) and optionally jumps to a section.</summary>
    public static void Show(Registry<SettingsSectionDescriptor> sections, GeneralSettings gs, string? sectionId)
    {
        if (_instance is null)
        {
            _instance = new SettingsWindow(sections);
            _instance.Closed += (_, _) => _instance = null;
        }
        var w = _instance;
        ((Window)w).Show();
        w.WindowState = WindowState.Normal;
        w.Activate();
        var first = sectionId is not null && w._buttons.ContainsKey(sectionId) ? sectionId : w._sections.Items.FirstOrDefault()?.Id;
        if (first is not null) w._buttons[first].IsChecked = true;
    }

    void Select(string id)
    {
        if (!_views.TryGetValue(id, out var v))
        {
            var d = _sections.Find(id)!;
            try { v = d.Factory(); }
            catch (Exception ex)
            {
                Log.Error($"Settings section '{id}' failed", ex);
                v = Placeholder.Create(Glyphs.Warning, d.Title, "This section failed to load. See logs.");
            }
            _views[id] = v;
        }
        Scroll.Content = v;
        Scroll.ScrollToTop();
    }

    void DarkTitleBar()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        int dark = ThemeManager.IsDark ? 1 : 0;
        Native.DwmSetWindowAttribute(hwnd, 20, ref dark, 4); // DWMWA_USE_IMMERSIVE_DARK_MODE
        if (FindResource("WindowBrush") is SolidColorBrush b)
        {
            int bgr = b.Color.R | (b.Color.G << 8) | (b.Color.B << 16);
            Native.DwmSetWindowAttribute(hwnd, 35, ref bgr, 4); // caption color
            Native.DwmSetWindowAttribute(hwnd, 34, ref bgr, 4); // border color
        }
    }
}
