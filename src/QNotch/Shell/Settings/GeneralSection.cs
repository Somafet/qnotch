using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

public static class GeneralSection
{
    public static FrameworkElement Create(GeneralSettings gs, SettingsStore store, IReadOnlyList<SetupCode.Section> share, Action restart, Action resetSpots,
        Action<NotchPositionMode> setNotchPosition)
    {
        var page = UiKit.Page("General");

        var combo = new ComboBox { Width = 260 };
        var mons = Monitors.List();
        for (var i = 0; i < mons.Count; i++) combo.Items.Add(mons[i].Label(i));
        combo.SelectedIndex = Math.Clamp(gs.MonitorIndex, 0, Math.Max(0, mons.Count - 1));
        combo.SelectionChanged += (_, _) => { if (combo.IsKeyboardFocusWithin) { QNotch.Core.Analytics.Track("settings", "change", target: "display"); }  if (combo.SelectedIndex >= 0) gs.MonitorIndex = combo.SelectedIndex; };
        page.Children.Add(UiKit.Row("Monitor", "The display that hosts the notch. You can also drag the pill onto another display. Follows resolution and DPI changes live.", combo));

        // spec/notch-position.md: one spot for every app, or a spot per app; Reset centers it (and forgets the app spots).
        var position = new ComboBox { Width = 200, Items = { "Same for every app", "Each app has its own" },
            SelectedIndex = gs.NotchPosition == NotchPositionMode.PerApp ? 1 : 0 };
        System.Windows.Automation.AutomationProperties.SetAutomationId(position, "notch-position");
        var reset = new Button { Content = "Reset", Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 0, 0) };
        reset.Click += (_, _) => { QNotch.Core.Analytics.Track("settings", "reset_positions", "ui"); resetSpots(); };
        var positionControls = new StackPanel { Orientation = Orientation.Horizontal, Children = { position, reset } };
        var positionRow = UiKit.Row("Notch position", "", positionControls);
        page.Children.Add(positionRow);
        void ShowPosition(bool perApp) => UiKit.SetRowHint(positionRow, perApp
            ? "Drag the pill sideways to move it out of the way, or onto another display. Each app keeps its own spot, and the pill moves there when that app comes to the front. Double-click it to center it again."
            : "Drag the pill sideways to move it out of the way, or onto another display. It stays there whatever app is in front. Double-click it to center it again.");
        ShowPosition(position.SelectedIndex == 1);
        position.SelectionChanged += (_, _) =>
        {
            Analytics.Track("settings", "change", target: "notch_position");
            var perApp = position.SelectedIndex == 1;
            setNotchPosition(perApp ? NotchPositionMode.PerApp : NotchPositionMode.Everywhere);
            ShowPosition(perApp);
        };

        var openOn = new ComboBox { Width = 160, Items = { "Hover", "Click" }, SelectedIndex = gs.OpenOn == PanelOpenTrigger.Click ? 1 : 0 };
        System.Windows.Automation.AutomationProperties.SetAutomationId(openOn, "open-on");
        page.Children.Add(UiKit.Row("Open on", "Hover opens the panel when the pointer rests on the pill. Click opens it only when you click the pill, so heading for tabs near the top edge never pops it open; a click outside, Esc or the hotkey closes it.", openOn));
        var hoverDelay = UiKit.Row("Hover delay", "",
            SliderBox(0, 600, 10, gs.HoverDwellMs, v => { Analytics.Track("settings", "change", target: "hover_delay"); gs.HoverDwellMs = v; }, "ms"));
        page.Children.Add(hoverDelay);
        // Click mode shows only what it uses: a dragged file still waits for the hover delay, and a click outside closes the panel.
        var closeDelay = UiKit.Row("Close delay", "Grace period after the pointer leaves before the panel closes.",
            SliderBox(100, 1500, 50, gs.LeaveDelayMs, v => { Analytics.Track("settings", "change", target: "close_delay"); gs.LeaveDelayMs = v; }, "ms"));
        page.Children.Add(closeDelay);
        void ShowTrigger(bool click)
        {
            UiKit.SetRowHint(hoverDelay, click
                ? "How long files dragged onto the pill rest there before the panel opens."
                : "How long the pointer must rest on the pill before the panel opens.");
            closeDelay.Visibility = click ? Visibility.Collapsed : Visibility.Visible;
        }
        ShowTrigger(gs.OpenOn == PanelOpenTrigger.Click);
        openOn.SelectionChanged += (_, _) =>
        {
            Analytics.Track("settings", "change", target: "open_on");
            gs.OpenOn = openOn.SelectedIndex == 1 ? PanelOpenTrigger.Click : PanelOpenTrigger.Hover;
            ShowTrigger(gs.OpenOn == PanelOpenTrigger.Click);
        };

        page.Children.Add(UiKit.Row("Keep panel open", "Pinned: the panel stays open when the pointer leaves.", BoundToggle(gs, nameof(GeneralSettings.Pinned))));
        page.Children.Add(UiKit.Row("Start with Windows", "Adds QNotch to your sign-in items.", BoundToggle(gs, nameof(GeneralSettings.StartWithWindows))));
        Share(page, store, share, restart);
        var usage = BoundToggle(gs, nameof(GeneralSettings.ShareUsageData));
        usage.IsEnabled = Analytics.EnvironmentAllows;
        if (!Analytics.EnvironmentAllows) { usage.ClearValue(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty); usage.IsChecked = false; }
        page.Children.Add(UiKit.Row("Share usage data", "Usage actions. No personal content." + (Analytics.EnvironmentAllows ? "" : " Disabled by QNOTCH_TELEMETRY_ENABLED."), usage));
        return page;
    }

    /// <summary>Copy and apply a setup code (see <see cref="SetupCode"/>). Applying is two steps: Check shows what changes, then Apply and restart.</summary>
    static void Share(StackPanel page, SettingsStore store, IReadOnlyList<SetupCode.Section> share, Action restart)
    {
        page.Children.Add(new TextBlock { Text = "Share your setup", Style = (Style)Application.Current.FindResource("Title"), Margin = new Thickness(0, 8, 0, 14) });

        var copied = UiKit.Text("", "Muted");
        copied.Margin = new Thickness(0, -6, 0, 16);
        copied.Visibility = Visibility.Collapsed;
        var copy = new Button { Content = "Copy code", Padding = new Thickness(14, 6, 14, 6) };
        copy.Click += (_, _) =>
        { QNotch.Core.Analytics.Track("settings", "setup_export", "ui");
            try { System.Windows.Clipboard.SetText(SetupCode.Export(store, share)); copied.Text = "Copied. Paste it on another PC, or into an issue."; }
            catch (Exception ex) { Log.Warn("Copying the setup code failed", ex); copied.Text = "Could not reach the clipboard. Try again."; }
            copied.Visibility = Visibility.Visible;
        };
        page.Children.Add(UiKit.Row("Copy setup code", "Your look, features, card layout, hotkeys, Game mode and a few feature preferences as one line of text. Leaves out your name, monitor, game lists, history, app paths and tokens.", copy));
        page.Children.Add(copied);

        var box = new TextBox { Width = 260 };
        var check = new Button { Content = "Check", Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 0, 0) };
        var input = new StackPanel { Orientation = Orientation.Horizontal };
        input.Children.Add(box);
        input.Children.Add(check);
        page.Children.Add(UiKit.Row("Apply a setup code", "Paste a code to see what it changes before anything is applied.", input));

        var status = UiKit.Text("", "Caption");
        status.VerticalAlignment = VerticalAlignment.Center;
        var apply = new Button { Content = "Apply and restart", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(16, 0, 0, 0), Visibility = Visibility.Collapsed };
        var result = new Grid { Margin = new Thickness(0, -6, 0, 16), Visibility = Visibility.Collapsed };
        result.ColumnDefinitions.Add(new ColumnDefinition());
        result.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(apply, 1);
        result.Children.Add(status);
        result.Children.Add(apply);
        page.Children.Add(result);

        SetupCode.Plan? plan = null;
        void Check()
        {
            QNotch.Core.Analytics.Track("settings", "setup_check");
            plan = SetupCode.Read(box.Text, store, share, out var error);
            status.Text = plan is null ? error : $"Replaces your settings for {string.Join(", ", plan.Titles)}."
                + (plan.TurnsOn.Count > 0 ? $" Turns on {string.Join(", ", plan.TurnsOn)}." : "") + " QNotch restarts to apply them.";
            status.SetResourceReference(TextBlock.ForegroundProperty, plan is null ? "DangerBrush" : "TextPrimaryBrush");
            apply.Visibility = plan is null ? Visibility.Collapsed : Visibility.Visible;
            result.Visibility = Visibility.Visible;
        }
        check.Click += (_, _) => {  Check(); };
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Check(); };
        box.TextChanged += (_, _) => { plan = null; result.Visibility = Visibility.Collapsed; };
        apply.Click += (_, _) =>
        { QNotch.Core.Analytics.Track("settings", "setup_apply", "ui");
            // Read again: a setting changed since Check (the pin, a hotkey) must not be written back with its old value.
            if (plan is null || SetupCode.Read(box.Text, store, share, out _) is not { } fresh) { Check(); return; }
            apply.Visibility = Visibility.Collapsed;
            var saved = store.Replace(fresh.Files);
            Log.Info($"Applied a setup code: {string.Join(", ", fresh.Files.Keys)}{(saved ? "" : " (some files failed)")}");
            if (!saved) { status.Text = "Some settings could not be saved, see the log. Restart QNotch to load what was saved."; return; }
            try { restart(); }
            catch (Exception ex) { Log.Warn("Restart after a setup code failed", ex); status.Text = "Applied. Restart QNotch to finish."; }
        };
    }

    /// <summary>Two-way bound, so a change made elsewhere (the pin button in the panel header) shows up on an open page.</summary>
    static CheckBox BoundToggle(GeneralSettings gs, string prop)
    {
        var t = UiKit.Toggle();
        t.Click += (_, _) => { Analytics.Track("settings", "change", target: prop switch { nameof(GeneralSettings.Pinned) => "pinned", nameof(GeneralSettings.StartWithWindows) => "login", _ => "telemetry" }, enabled: t.IsChecked); };
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
