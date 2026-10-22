using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Theme;

namespace QNotch.Modules.Notifications;

/// <summary>Settings page: toast time, error behaviour, retention, the HTTP endpoint with its token, and per-app mute.</summary>
internal static class NotificationsSettingsSection
{
    static readonly int[] ToastSeconds = [0, 4, 6, 10, 15, 30];
    static readonly int[] RetentionDays = [1, 3, 7, 14, 30];

    public static FrameworkElement Create(NotificationsModule m, NotificationsState st)
    {
        var cfg = m.Config;
        var page = UiKit.Page("Notifications");
        page.Children.Add(UiKit.SettingsIntro("Choose when notifications can interrupt you. History and replies stay available when alerts are muted."));
        var behavior = new List<FrameworkElement>();
        behavior.Add(UiKit.SettingsRow("Mute notifications", "Until you unmute, including after a restart. Saved on this PC.", NotificationMuteViews.Button(m, st)));

        behavior.Add(UiKit.SettingsRow("Show a toast for", "How long an alert stays under the pill. A sender can set its own time.",
            Choice(ToastSeconds, cfg.ToastSeconds, s => s == 0 ? "Off" : $"{s} seconds", v => { cfg.ToastSeconds = v; m.SaveSettings(); })));
        behavior.Add(UiKit.SettingsRow("Play a sound", "Choose the sound in Settings, Sounds.",
            UiKit.Toggle(cfg.Sound, on => { cfg.Sound = on; m.SaveSettings(); })));
        behavior.Add(UiKit.SettingsRow("Open the panel on errors", "Open Notifications automatically. Never while a game is running.",
            UiKit.Toggle(cfg.OpenOnError, on => { cfg.OpenOnError = on; m.SaveSettings(); })));
        behavior.Add(UiKit.SettingsRow("Quiet during calls", "While the microphone is in use, only questions awaiting a reply can show a toast. The panel stays closed.",
            UiKit.Toggle(cfg.QuietDuringCalls, on => { cfg.QuietDuringCalls = on; m.SaveSettings(); m.ApplyQuiet(); })));
        var alerts = UiKit.SettingsGroup(behavior, "Alerts");
        var quietStatus = UiKit.BindVisible(Status(st, nameof(NotificationsState.QuietStatus)), st, nameof(NotificationsState.IsQuiet));
        quietStatus.Margin = new Thickness(4, 8, 4, 0);
        alerts.Children.Add(quietStatus);
        page.Children.Add(alerts);

        var history = new List<FrameworkElement>();
        history.Add(UiKit.SettingsRow("Keep history for", "Keep up to 500 notifications. Older entries are removed.",
            Choice(RetentionDays, cfg.RetentionDays, d => d == 1 ? "1 day" : $"{d} days", v => { cfg.RetentionDays = v; m.SaveSettings(); })));
        var test = new Button { Content = "Send test", Padding = new Thickness(14, 6, 14, 6) };
        test.Click += (_, _) => m.SendTest();
        history.Add(UiKit.SettingsRow("Try it", "Send a sample notification using your current alert settings.", test));
        page.Children.Add(UiKit.SettingsGroup(history, "History and testing"));

        // ----- senders -----
        var cli = new StackPanel { Margin = new Thickness(16, 12, 16, 12) };
        cli.Children.Add(Note("Run QNotch.exe notify \"Title\" \"Text\" from a script. Use QNotch.exe notify --help for options. Apps can also send JSON to the current-user named pipe."));
        var pipeStatus = Status(st, nameof(NotificationsState.PipeStatus));
        pipeStatus.Margin = new Thickness(0, 8, 0, 0);
        cli.Children.Add(pipeStatus);
        page.Children.Add(UiKit.SettingsGroup([cli], "Command line and pipe"));

        var http = new List<FrameworkElement>();
        http.Add(UiKit.SettingsRow("Accept HTTP requests", "On this computer only. Requires the token below; web pages are refused.",
            UiKit.Toggle(cfg.HttpEnabled, on => { cfg.HttpEnabled = on; m.ApplyHttp(); })));
        var port = new TextBox { Text = cfg.HttpPort.ToString(), Width = 80, MaxLength = 5 };
        void ApplyPort()
        {
            if (!int.TryParse(port.Text, out var p) || p == cfg.HttpPort) { port.Text = cfg.HttpPort.ToString(); return; }
            cfg.HttpPort = p;
            m.ApplyHttp();
        }
        port.LostFocus += (_, _) => ApplyPort();
        port.KeyDown += (_, e) => { if (e.Key == Key.Enter) ApplyPort(); };
        http.Add(UiKit.SettingsRow("Port", "1024 to 65535. Press Enter to apply.", port));

        var shown = new TextBlock { Style = (Style)Application.Current.FindResource("Muted"), FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        void ShowToken() => shown.Text = m.Token.Length > 6 ? m.Token[..6] + "..." : "not ready";
        ShowToken();
        var copy = new Button { Content = "Copy", Padding = new Thickness(14, 6, 14, 6) };
        copy.Click += (_, _) => { if (m.Token.Length > 0) System.Windows.Clipboard.SetText(m.Token); };
        var renew = new Button { Content = "New token", Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 0, 0), ToolTip = "Replaces the token: senders using the old one are refused" };
        renew.Click += (_, _) => { m.RenewToken(); ShowToken(); };
        var tokenRow = new StackPanel { Orientation = Orientation.Horizontal };
        tokenRow.Children.Add(shown);
        tokenRow.Children.Add(copy);
        tokenRow.Children.Add(renew);
        http.Add(UiKit.SettingsRow("Token", "Authorization: Bearer <token>. Stored in Windows Credential Manager.", tokenRow));
        var local = UiKit.SettingsGroup(http, "Local HTTP");
        var httpStatus = Status(st, nameof(NotificationsState.HttpStatus));
        httpStatus.Margin = new Thickness(4, 8, 4, 0);
        local.Children.Add(httpStatus);
        page.Children.Add(local);

        // ----- per-app mute -----
        var appRows = new List<FrameworkElement>();
        var apps = st.Items.Select(n => n.App).Concat(cfg.MutedApps).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(a => a, StringComparer.OrdinalIgnoreCase).ToList();
        if (apps.Count == 0) appRows.Add(new Border { Padding = new Thickness(16, 12, 16, 12), Child = Note("Apps appear here after their first notification.") });
        foreach (var app in apps)
            appRows.Add(UiKit.SettingsRow(app, null, UiKit.Toggle(!cfg.MutedApps.Contains(app, StringComparer.OrdinalIgnoreCase), on =>
            {
                cfg.MutedApps.RemoveAll(a => string.Equals(a, app, StringComparison.OrdinalIgnoreCase));
                if (!on) cfg.MutedApps.Add(app);
                m.SaveSettings();
            })));
        page.Children.Add(UiKit.SettingsGroup(appRows, "Apps", "Turn an app off to silence its alerts and unread count. Its notifications still go into history."));
        return page;
    }

    static ComboBox Choice(int[] values, int current, Func<int, string> label, Action<int> set)
    {
        var c = new ComboBox { Width = 140 };
        foreach (var v in values) c.Items.Add(label(v));
        // A hand-edited value that is not in the list shows as the nearest choice until the user picks one.
        c.SelectedIndex = Array.IndexOf(values, values.MinBy(v => Math.Abs(v - current)));
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) set(values[c.SelectedIndex]); };
        return c;
    }

    static TextBlock Note(string text)
    {
        var t = UiKit.Text(text);
        t.FontSize = 12;
        return t;
    }

    static TextBlock Status(NotificationsState st, string path)
    {
        var t = UiKit.Text("", "Caption");
        t.FontSize = 12;
        return UiKit.Bind(t, TextBlock.TextProperty, st, path);
    }
}
