using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Github;

/// <summary>Settings section: enter, test and clear the GitHub token (stored in Windows Credential Manager).</summary>
internal static class GithubSection
{
    /// <param name="demo">Snapshot run: the sign-in panel shows a made-up code, even without a client id.</param>
    public static FrameworkElement Create(GithubState s, GithubService svc, bool demo)
    {
        var page = UiKit.Page("GitHub");

        var status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxWidth = 280, TextAlignment = TextAlignment.Right };
        page.Children.Add(UiKit.Row("Status", null, status));

        // Sign in with GitHub: only with a client id (or a demo); otherwise the token box is the way in.
        var signedIn = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -8, 0, 16), Visibility = Visibility.Collapsed };
        if (GithubOAuth.ShowSignIn(GithubOAuth.ClientId, demo))
        {
            var signIn = new GithubSignIn(async t =>
            {
                if (!await svc.SaveTokenAsync(t)) return (false, "Windows refused to store the token.");
                return await GithubService.TestAsync(t);
            });
            signIn.Connected += msg => { signedIn.Text = msg; signedIn.SetResourceReference(TextBlock.ForegroundProperty, "SuccessBrush"); signedIn.Visibility = Visibility.Visible; };
            signIn.Panel.Margin = new Thickness(0, -6, 0, 16);
            page.Children.Add(UiKit.Row("Sign in with GitHub", "Opens GitHub in your browser, where you approve QNotch. Asks only to read your public profile and activity (read:user).", signIn.Button));
            page.Children.Add(signIn.Panel);
            page.Children.Add(signedIn);
            if (demo) signIn.ShowDemo();
        }

        var box = new PasswordBox { Width = 200, MaxLength = 255, ToolTip = "Paste a personal access token" };
        var save = new Button { Content = "Save", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(8, 0, 0, 0) };
        var tokenRow = new StackPanel { Orientation = Orientation.Horizontal };
        tokenRow.Children.Add(box);
        tokenRow.Children.Add(save);
        page.Children.Add(UiKit.Row(GithubOAuth.ShowSignIn(GithubOAuth.ClientId, demo) ? "Or use a token" : "Personal access token",
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
        { QNotch.Core.Analytics.Track("github", "save", "ui");
            var t = box.Password.Trim();
            if (t.Length == 0) { Show("Paste a token first.", "WarningBrush"); return; }
            if (await svc.SaveTokenAsync(t)) { box.Clear(); Show("Token saved to Credential Manager.", "SuccessBrush"); }
            else Show("Windows refused to store the token.", "DangerBrush");
        };
        test.Click += async (_, _) =>
        { QNotch.Core.Analytics.Track("github", "test_connection", "ui");
            test.IsEnabled = false;
            Show("Testing", "TextSecondaryBrush");
            var t = box.Password.Trim();
            if (t.Length == 0 && !demo) t = await Task.Run(CredentialStore.Read) ?? "";
            if (demo) Show("Connected as @octocat.", "SuccessBrush"); // a snapshot run never reads the credential store or goes online
            else if (t.Length == 0) Show("No token to test.", "WarningBrush");
            else { var (ok, msg) = await GithubService.TestAsync(t); Show(msg, ok ? "SuccessBrush" : "DangerBrush"); }
            test.IsEnabled = true;
        };
        clear.Click += async (_, _) =>
        { QNotch.Core.Analytics.Track("github", "disconnect", "ui");
            await svc.ClearTokenAsync();
            box.Clear();
            Show("Token and cached activity removed.", "TextSecondaryBrush");
        };
        refresh.Click += (_, _) => { QNotch.Core.Analytics.Track("github", "refresh", "ui"); _ = svc.RefreshAsync(); };
        return page;
    }
}
