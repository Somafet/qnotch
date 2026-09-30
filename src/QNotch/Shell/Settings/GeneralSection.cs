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

        page.Children.Add(UiKit.Row("Toggle panel hotkey", "Click the box, then press the new shortcut. Esc cancels.",
            HotkeyBox(gs, () => gs.ToggleHotkey, v => gs.ToggleHotkey = v, nameof(GeneralSettings.ToggleHotkeyTaken))));
        page.Children.Add(UiKit.Row("Cycle Game mode hotkey", "Auto, Force on, Force off.",
            HotkeyBox(gs, () => gs.GameModeHotkey, v => gs.GameModeHotkey = v, nameof(GeneralSettings.GameModeHotkeyTaken))));
        return page;
    }

    /// <summary>Hotkey recorder: a read-only box that turns the next Ctrl/Alt chord into a gesture string. Global hotkeys are suspended while it has focus.</summary>
    static FrameworkElement HotkeyBox(GeneralSettings gs, Func<string> get, Action<string> set, string takenProp)
    {
        var box = new TextBox
        {
            Text = get(), Width = 150, IsReadOnly = true, IsReadOnlyCaretVisible = false, TextAlignment = TextAlignment.Center,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 12, Cursor = Cursors.Arrow, ToolTip = "Click, then press the new shortcut",
        };
        var note = new TextBlock { Text = "Taken by another app", Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
        note.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
        note.SetBinding(UIElement.VisibilityProperty, new Binding(takenProp) { Source = gs, Converter = (IValueConverter)Application.Current.FindResource("BoolToVis") });

        box.GotKeyboardFocus += (_, _) => { gs.RecordingHotkey = true; box.Text = "Press shortcut"; };
        box.LostKeyboardFocus += (_, _) => { gs.RecordingHotkey = false; box.Text = get(); };
        box.Unloaded += (_, _) => gs.RecordingHotkey = false;
        box.PreviewKeyDown += (_, e) =>
        {
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key is Key.None or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin
                or Key.DeadCharProcessed or Key.ImeProcessed) return;
            var mods = Keyboard.Modifiers;
            if (key == Key.Escape && mods == ModifierKeys.None) { Keyboard.ClearFocus(); return; }
            if ((mods & (ModifierKeys.Control | ModifierKeys.Alt)) == 0) { box.Text = "Add Ctrl or Alt"; return; }
            string gesture;
            try { gesture = new KeyGestureConverter().ConvertToInvariantString(new KeyGesture(key, mods)) ?? ""; }
            catch { box.Text = "Not supported"; return; }
            if (gesture.Length > 0 && gesture != get()) set(gesture);
            Keyboard.ClearFocus(); // LostKeyboardFocus re-registers the hotkeys and refreshes the "taken" note
        };

        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(note);
        p.Children.Add(box);
        return p;
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
