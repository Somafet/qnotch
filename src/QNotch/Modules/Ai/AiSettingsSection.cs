using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using QNotch.Theme;

namespace QNotch.Modules.Ai;

/// <summary>Settings page: provider toggles, refresh interval, slot bindings for Alt+1..6, custom shortcuts, rescan.</summary>
internal static class AiSettingsSection
{
    static readonly int[] Intervals = [5, 10, 15, 30, 60];

    public static FrameworkElement Create(AiModule m, ModuleContext ctx)
    {
        var st = m.State;
        var page = UiKit.Page("AI");

        // ----- usage -----
        page.Children.Add(Sub("Usage providers"));
        foreach (var p in m.Providers)
        {
            var hint = p is ClaudeCodeProvider ?"Reads your Claude Code sign-in and asks Anthropic for your plan limits."
                : "Reads the newest rate limit reading Codex stored locally. Nothing is sent anywhere.";
            var id = p.Id;
            page.Children.Add(UiKit.Row(p.Name, hint, UiKit.Toggle(m.IsProviderEnabled(id), on => m.SetProviderEnabled(id, on))));
        }

        if (m.ClaudeAccounts.Count > 1)
            foreach (var a in m.ClaudeAccounts)
            {
                var name = new TextBox { Text = a.Name, Width = 170 };
                void Commit() { m.RenameAccount(a, name.Text); name.Text = a.Name; }
                name.LostFocus += (_, _) => Commit();
                name.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) Commit(); };
                page.Children.Add(UiKit.Row("Claude account name", a.Dir, name));
            }

        var interval = new ComboBox { Width = 140 };
        foreach (var i in Intervals) interval.Items.Add($"{i} minutes");
        interval.SelectedIndex = Math.Max(0, Array.IndexOf(Intervals, m.RefreshMinutes));
        interval.SelectionChanged += (_, _) => { if (interval.SelectedIndex >= 0) m.RefreshMinutes = Intervals[interval.SelectedIndex]; };
        page.Children.Add(UiKit.Row("Refresh every", "How often usage is read in the background.", interval));

        var refresh = new Button { Content = "Refresh now", Padding = new Thickness(14, 6, 14, 6) };
        refresh.Click += (_, _) => st.RefreshCommand?.Execute(null);
        page.Children.Add(UiKit.Row("Usage readings", "Last check and per-tool status are on the AI tab.", refresh));

        // ----- slots -----
        page.Children.Add(Sub("App shortcuts"));
        page.Children.Add(UiKit.Text("Bind up to six apps to a slot. Each slot has a hotkey that works from anywhere; change the keys in Hotkeys.").Also(t => t.Margin = new Thickness(0, -6, 0, 16)));
        var slots = new StackPanel();
        page.Children.Add(slots);

        // ----- custom -----
        page.Children.Add(Sub("Custom apps"));
        var customs = new StackPanel();
        page.Children.Add(customs);
        var add = new Button { Content = "Add app...", Padding = new Thickness(14, 6, 14, 6), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 16) };
        add.Click += (_, _) =>
        {
            var dlg = new OpenFileDialog { Title = "Choose an app or shortcut", Filter = "Apps and shortcuts|*.exe;*.lnk;*.bat;*.cmd|All files|*.*" };
            using (ctx.Shell.HoldOpen())
                if (dlg.ShowDialog() == true) m.AddCustom(dlg.FileName);
        };
        page.Children.Add(add);

        // ----- detection -----
        page.Children.Add(Sub("Detection"));
        var status = new TextBlock { Style = (Style)Application.Current.FindResource("Muted"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        var rescan = new Button { Content = "Scan again", Padding = new Thickness(14, 6, 14, 6) };
        rescan.Click += (_, _) => st.RescanCommand?.Execute(null);
        var scanRow = new StackPanel { Orientation = Orientation.Horizontal };
        scanRow.Children.Add(status);
        scanRow.Children.Add(rescan);
        page.Children.Add(UiKit.Row("AI apps", "Checks the registry, Start menu, known folders and Store packages for ChatGPT, Claude, Cursor, Codex and Antigravity.", scanRow));

        bool building = false;
        void Rebuild()
        {
            building = true;
            status.Text = st.IsScanning ? "Scanning..." : $"{st.Apps.Count} found";

            slots.Children.Clear();
            for (var i = 0; i < AiSettings.SlotCount; i++)
            {
                var index = i;
                var combo = new ComboBox { Width = 200 };
                combo.Items.Add("None");
                foreach (var a in st.Apps) combo.Items.Add(a.Name);
                var current = st.Apps.ToList().FindIndex(a => a.Id == m.Slots[index]);
                combo.SelectedIndex = current + 1;
                combo.SelectionChanged += (_, _) =>
                {
                    if (building || combo.SelectedIndex < 0) return;
                    m.SetSlot(index, combo.SelectedIndex == 0 ? "" : st.Apps[combo.SelectedIndex - 1].Id);
                };
                var conflict = current >= 0 && st.Apps[current].HotkeyConflict;
                var key = ctx.Shortcuts.Find($"ai.slot{i + 1}")?.Gesture ?? "";
                slots.Children.Add(UiKit.Row($"Slot {i + 1}" + (key.Length > 0 ? $": {key}" : ""), conflict ? "Taken by another app. Pick a different slot or change the shortcut in Hotkeys." : null, combo));
            }

            customs.Children.Clear();
            if (m.CustomApps.Count == 0) customs.Children.Add(UiKit.Text("No custom apps yet.").Also(t => { t.Style = (Style)Application.Current.FindResource("Muted"); t.Margin = new Thickness(0, 0, 0, 8); }));
            foreach (var c in m.CustomApps.ToList()) customs.Children.Add(CustomRow(m, c));
            building = false;
        }

        // Subscribe only while the page is in the tree: the settings window is recreated on every open and must not be kept alive.
        void OnState(object? _, System.ComponentModel.PropertyChangedEventArgs e) { if (e.PropertyName == nameof(st.IsScanning)) Rebuild(); }
        page.Loaded += (_, _) => { m.Changed += Rebuild; st.PropertyChanged += OnState; Rebuild(); };
        page.Unloaded += (_, _) => { m.Changed -= Rebuild; st.PropertyChanged -= OnState; };
        Rebuild();
        return page;
    }

    static TextBlock Sub(string text) =>
        new() { Text = text, Style = (Style)Application.Current.FindResource("Title"), Margin = new Thickness(0, 8, 0, 14) };

    static FrameworkElement CustomRow(AiModule m, CustomApp c)
    {
        var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var name = new TextBox { Text = c.Name, VerticalAlignment = VerticalAlignment.Center };
        name.LostFocus += (_, _) => m.RenameCustom(c.Id, name.Text);
        name.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) m.RenameCustom(c.Id, name.Text); };

        var path = new TextBlock { Text = c.Path, Style = (Style)Application.Current.FindResource("Muted"), TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = c.Path, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 8, 0) };
        var remove = new Button { Style = (Style)Application.Current.FindResource("IconButton"), Content = Glyphs.Delete, ToolTip = "Remove" };
        remove.Click += (_, _) => m.RemoveCustom(c.Id);

        Grid.SetColumn(path, 1);
        Grid.SetColumn(remove, 2);
        g.Children.Add(name);
        g.Children.Add(path);
        g.Children.Add(remove);
        return g;
    }

    static T Also<T>(this T t, Action<T> f) { f(t); return t; }
}
