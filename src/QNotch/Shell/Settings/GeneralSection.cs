using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

public static class GeneralSection
{
    public static FrameworkElement Create(GeneralSettings gs)
    {
        var page = UiKit.Page("General");

        var combo = new ComboBox { Width = 260 };
        var mons = Monitors.List();
        for (var i = 0; i < mons.Count; i++) combo.Items.Add(mons[i].Label(i));
        combo.SelectedIndex = Math.Clamp(gs.MonitorIndex, 0, Math.Max(0, mons.Count - 1));
        combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) gs.MonitorIndex = combo.SelectedIndex; };
        page.Children.Add(UiKit.Row("Monitor", "The display that hosts the notch. Follows resolution and DPI changes live.", combo));

        page.Children.Add(UiKit.Row("Hover delay", "How long the pointer must rest on the pill before the panel opens.",
            SliderBox(0, 600, 10, gs.HoverDwellMs, v => gs.HoverDwellMs = v, "ms")));
        page.Children.Add(UiKit.Row("Close delay", "Grace period after the pointer leaves before the panel closes.",
            SliderBox(100, 1500, 50, gs.LeaveDelayMs, v => gs.LeaveDelayMs = v, "ms")));

        page.Children.Add(UiKit.Row("Keep panel open", "Pinned: the panel stays open when the pointer leaves.", BoundToggle(gs, nameof(GeneralSettings.Pinned))));
        page.Children.Add(UiKit.Row("Start with Windows", "Adds QNotch to your sign-in items.", BoundToggle(gs, nameof(GeneralSettings.StartWithWindows))));
        return page;
    }

    /// <summary>Two-way bound, so a change made elsewhere (the pin button in the panel header) shows up on an open page.</summary>
    static CheckBox BoundToggle(GeneralSettings gs, string prop)
    {
        var t = UiKit.Toggle();
        t.SetBinding(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty, new Binding(prop) { Source = gs, Mode = BindingMode.TwoWay });
        return t;
    }

    public static FrameworkElement SliderBox(int min, int max, int step, int value, Action<int> set, string unit)
    {
        var label = new TextBlock { Width = 64, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Text = $"{value} {unit}" };
        var s = new Slider { Minimum = min, Maximum = max, Value = value, Width = 180, SmallChange = step, LargeChange = step * 5, TickFrequency = step, IsSnapToTickEnabled = true };
        s.ValueChanged += (_, e) => { var v = (int)e.NewValue; label.Text = $"{v} {unit}"; set(v); };
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(s);
        p.Children.Add(label);
        return p;
    }
}
