using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Github;

/// <summary>Settings section: enter, test and clear the GitHub token (stored in Windows Credential Manager).</summary>
internal static class GithubSection
{
    public static FrameworkElement Create(GithubState s, GithubService svc)
    {
        var page = UiKit.Page("GitHub");

        var status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxWidth = 280, TextAlignment = TextAlignment.Right };
        page.Children.Add(UiKit.Row("Status", null, status));

        var box = new PasswordBox { Width = 200, MaxLength = 255, ToolTip = "Paste a personal access token" };
        var save = new Button { Content = "Save", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(8, 0, 0, 0) };
        var tokenRow = new StackPanel { Orientation = Orientation.Horizontal };
        tokenRow.Children.Add(box);
        tokenRow.Children.Add(save);
        page.Children.Add(UiKit.Row("Personal access token",
            "Stored in Windows Credential Manager, never in a settings file. A classic token with read:user works; add repo to count private activity.", tokenRow));

        var test = new Button { Content = "Test" };
        var clear = new Button { Content = "Remove token", Margin = new Thickness(8, 0, 0, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(test);
        buttons.Children.Add(clear);
        var result = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -8, 0, 16), Visibility = Visibility.Collapsed };
        page.Children.Add(UiKit.Row("Connection", "Tests the token in the box, or the saved one if the box is empty.", buttons));
        page.Children.Add(result);

        var refresh = new Button { Content = "Refresh now" };
        page.Children.Add(UiKit.Row("Activity", "Refreshes every hour. The last result is kept on disk so the card works offline.", refresh));

        void Show(string text, string brushKey)
        {
            result.Text = text;
            result.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
            result.Visibility = Visibility.Visible;
        }

        void Sync()
        {
            var (text, brush) = !s.GithubHasToken ? ("No token saved", "TextTertiaryBrush")
                : s.GithubStatus switch
                {
                    GithubStatus.Ready when s.GithubStale => ($"Saved data for @{s.GithubLogin}. {s.GithubMessage}", "WarningBrush"),
                    GithubStatus.Ready => ($"Connected as @{s.GithubLogin}. {s.GithubUpdatedText}.", "SuccessBrush"),
                    GithubStatus.Error => (s.GithubMessage, "DangerBrush"),
                    _ => ("Token saved, fetching activity", "TextSecondaryBrush"),
                };
            status.Text = text;
            status.SetResourceReference(TextBlock.ForegroundProperty, brush);
            clear.IsEnabled = refresh.IsEnabled = s.GithubHasToken;
        }
        void OnState(object? _, System.ComponentModel.PropertyChangedEventArgs e) { if (e.PropertyName?.StartsWith("Github", StringComparison.Ordinal) == true) Sync(); }
        page.Loaded += (_, _) => { s.PropertyChanged += OnState; Sync(); }; // unsubscribed on Unloaded so a closed settings window can be collected
        page.Unloaded += (_, _) => s.PropertyChanged -= OnState;
        Sync();

        save.Click += async (_, _) =>
        {
            var t = box.Password.Trim();
            if (t.Length == 0) { Show("Paste a token first.", "WarningBrush"); return; }
            if (await svc.SaveTokenAsync(t)) { box.Clear(); Show("Token saved to Credential Manager.", "SuccessBrush"); }
            else Show("Windows refused to store the token.", "DangerBrush");
        };
        test.Click += async (_, _) =>
        {
            test.IsEnabled = false;
            Show("Testing", "TextSecondaryBrush");
            var t = box.Password.Trim();
            if (t.Length == 0) t = await Task.Run(CredentialStore.Read) ?? "";
            if (t.Length == 0) Show("No token to test.", "WarningBrush");
            else { var (ok, msg) = await GithubService.TestAsync(t); Show(msg, ok ? "SuccessBrush" : "DangerBrush"); }
            test.IsEnabled = true;
        };
        clear.Click += async (_, _) =>
        {
            await svc.ClearTokenAsync();
            box.Clear();
            Show("Token and cached activity removed.", "TextSecondaryBrush");
        };
        refresh.Click += (_, _) => _ = svc.RefreshAsync();
        return page;
    }
}
