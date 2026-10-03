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

        page.Children.Add(UiKit.Row("Show a toast for", "How long a notification stays under the pill. A sender can set its own time.",
            Choice(ToastSeconds, cfg.ToastSeconds, s => s == 0 ? "Off" : $"{s} seconds", v => { cfg.ToastSeconds = v; m.SaveSettings(); })));
        page.Children.Add(UiKit.Row("Open the panel on errors", "An error opens the Notifications tab by itself. Never while a game is running.",
            UiKit.Toggle(cfg.OpenOnError, on => { cfg.OpenOnError = on; m.SaveSettings(); })));
        page.Children.Add(UiKit.Row("Quiet during calls", "While an app uses the microphone, only questions waiting for your answer show a toast, and the panel never opens by itself. Everything still lands in the history.",
            UiKit.Toggle(cfg.QuietDuringCalls, on => { cfg.QuietDuringCalls = on; m.SaveSettings(); m.ApplyQuiet(); })));
        page.Children.Add(UiKit.BindVisible(Status(st, nameof(NotificationsState.QuietStatus)), st, nameof(NotificationsState.IsQuiet)));
        page.Children.Add(UiKit.Row("Keep history for", "Older notifications are removed. The history holds 500 at most.",
            Choice(RetentionDays, cfg.RetentionDays, d => d == 1 ? "1 day" : $"{d} days", v => { cfg.RetentionDays = v; m.SaveSettings(); })));
        var test = new Button { Content = "Send test", Padding = new Thickness(14, 6, 14, 6) };
        test.Click += (_, _) => m.SendTest();
        page.Children.Add(UiKit.Row("Try it", "Posts a sample notification.", test));

        // ----- senders -----
        page.Children.Add(Sub("Command line and pipe"));
        page.Children.Add(Note("Any script can run QNotch.exe notify \"Title\" \"Text\". QNotch.exe notify --help lists every option. Other programs can write one line of JSON to the named pipe, which only your Windows account can open."));
        page.Children.Add(Status(st, nameof(NotificationsState.PipeStatus)));

        page.Children.Add(Sub("Local HTTP"));
        page.Children.Add(UiKit.Row("Accept HTTP requests", "POST /notify on this computer only. Requests need the token below; web pages are refused.",
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
        page.Children.Add(UiKit.Row("Port", "1024 to 65535. Press Enter to apply.", port));

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
        page.Children.Add(UiKit.Row("Token", "Send it as the header Authorization: Bearer <token>. Kept in Windows Credential Manager.", tokenRow));
        page.Children.Add(Status(st, nameof(NotificationsState.HttpStatus)));

        // ----- per-app mute -----
        page.Children.Add(Sub("Apps"));
        var apps = st.Items.Select(n => n.App).Concat(cfg.MutedApps).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(a => a, StringComparer.OrdinalIgnoreCase).ToList();
        if (apps.Count == 0) page.Children.Add(Note("Apps show up here after their first notification, so you can mute them."));
        foreach (var app in apps)
            page.Children.Add(UiKit.Row(app, null, UiKit.Toggle(!cfg.MutedApps.Contains(app, StringComparer.OrdinalIgnoreCase), on =>
            {
                cfg.MutedApps.RemoveAll(a => string.Equals(a, app, StringComparison.OrdinalIgnoreCase));
                if (!on) cfg.MutedApps.Add(app);
                m.SaveSettings();
            })));
        if (apps.Count > 0) page.Children.Add(Note("A muted app still lands in the history, but shows no toast, no unread count and never opens the panel."));
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

    static TextBlock Sub(string text) =>
        new() { Text = text, Style = (Style)Application.Current.FindResource("Title"), Margin = new Thickness(0, 8, 0, 14) };

    static TextBlock Note(string text)
    {
        var t = UiKit.Text(text, "Muted");
        t.Margin = new Thickness(0, -6, 0, 16);
        return t;
    }

    static TextBlock Status(NotificationsState st, string path)
    {
        var t = UiKit.Text("", "Caption");
        t.Margin = new Thickness(0, -6, 0, 16);
        return UiKit.Bind(t, TextBlock.TextProperty, st, path);
    }
}
