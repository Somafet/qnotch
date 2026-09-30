using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
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
    bool _noAnim;

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
            glyph.Margin = new Thickness(0, 0, 12, 0);
            glyph.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(glyph);
            row.Children.Add(new TextBlock { Text = s.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
            var rb = new RadioButton { Style = (Style)FindResource("NavButton"), Content = row, GroupName = "nav", Margin = new Thickness(0, 0, 0, 2) };
            rb.Checked += (_, _) => Select(id);
            Nav.Children.Add(rb);
            _buttons[id] = rb;
        }
        SourceInitialized += (_, _) => ApplyTitleBar();
    }

    /// <summary>Shows the single settings window (creating it on first use) and optionally jumps to a section.</summary>
    public static void Show(Registry<SettingsSectionDescriptor> sections, GeneralSettings gs, string? sectionId)
    {
        if (_instance is null)
        {
            var w = new SettingsWindow(sections);
            PropertyChangedEventHandler onTheme = (_, e) => { if (e.PropertyName == nameof(GeneralSettings.Theme)) w.ApplyTitleBar(); };
            gs.PropertyChanged += onTheme;
            w.Closed += (_, _) => { gs.PropertyChanged -= onTheme; _instance = null; };
            _instance = w;
        }
        var win = _instance;
        ((Window)win).Show();
        win.WindowState = WindowState.Normal;
        win.Activate();
        var first = sectionId is not null && win._buttons.ContainsKey(sectionId) ? sectionId : win._sections.Items.FirstOrDefault()?.Id;
        if (first is not null) win._buttons[first].IsChecked = true;
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
        if (IsLoaded && Motion.Enabled && !_noAnim)
            v.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)) { FillBehavior = FillBehavior.Stop });
    }

    /// <summary>Dark or light caption matching the theme (also re-applied when the theme changes).</summary>
    void ApplyTitleBar()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == 0) return;
        int dark = ThemeManager.IsDark ? 1 : 0;
        Native.DwmSetWindowAttribute(hwnd, 20, ref dark, 4); // DWMWA_USE_IMMERSIVE_DARK_MODE
        if (FindResource("WindowBrush") is SolidColorBrush b)
        {
            int bgr = b.Color.R | (b.Color.G << 8) | (b.Color.B << 16);
            Native.DwmSetWindowAttribute(hwnd, 35, ref bgr, 4); // caption color
            Native.DwmSetWindowAttribute(hwnd, 34, ref bgr, 4); // border color
        }
    }

    /// <summary>Snapshot tool: renders every section off-screen through <paramref name="save"/>.</summary>
    internal static void Snapshot(Registry<SettingsSectionDescriptor> sections, Action<FrameworkElement, string> save)
    {
        var w = new SettingsWindow(sections) { WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = 0, ShowActivated = false, _noAnim = true };
        w.Show();
        foreach (var s in sections.Items)
        {
            w._buttons[s.Id].IsChecked = true;
            w.UpdateLayout();
            save((FrameworkElement)w.Content, s.Id);
            if (w.Scroll.ScrollableHeight <= 0) continue;
            w.Scroll.ScrollToEnd(); // tall pages (Game mode segments): a second shot of the bottom
            w.UpdateLayout();
            save((FrameworkElement)w.Content, s.Id + "-end");
            w.Scroll.ScrollToHome();
        }
        w.Close();
    }
}
