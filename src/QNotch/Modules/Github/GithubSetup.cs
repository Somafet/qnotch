using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Theme;

namespace QNotch.Modules.Github;

/// <summary>
/// The GitHub row of the welcome tour's Connect step. Works before the module exists: Credential Manager and the static check request only.
/// Sign in with GitHub (device flow) when there is a client id, with Use a token instead; otherwise the token paste box.
/// </summary>
internal static class GithubSetup
{
    /// <summary>A token was saved from the tour. A running GitHub module fetches with it (UI thread).</summary>
    public static event Action? TokenSaved;

    const string TokenPage = "https://github.com/settings/tokens/new?description=QNotch&scopes=read:user";

    public static SetupRow Create(SetupContext ctx)
    {
        var status = new TextBlock();
        var done = UiKit.Glyph(Glyphs.Accept, 14, "SuccessBrush");
        done.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(done, "Connected");
        var controls = new StackPanel { Orientation = Orientation.Horizontal };
        var action = new Grid();
        action.Children.Add(controls);
        action.Children.Add(done);
        var detail = new StackPanel();
        SetupRow? row = null;

        void Status(string text, string brush)
        {
            status.Text = text;
            status.SetResourceReference(TextBlock.ForegroundProperty, brush);
        }
        void Connected(string message)
        {
            Status(message.TrimEnd('.'), "SuccessBrush");
            controls.Visibility = Visibility.Collapsed;
            detail.Visibility = Visibility.Collapsed;
            done.Visibility = Visibility.Visible;
            row?.Success(); // null while the demo state is set up
        }
        async Task<(bool Ok, string Message)> Save(string token)
        {
            if (ctx.Demo) return (true, "Connected as @octocat.");
            if (!await Task.Run(() => CredentialStore.Write(token))) return (false, "Windows refused to store the token.");
            TokenSaved?.Invoke();
            return await GithubService.TestAsync(token);
        }

        // Paste box: the fallback, or the only way in while there is no client id.
        var box = new PasswordBox { Width = 170, MaxLength = 255, ToolTip = "Paste a personal access token" };
        AutomationProperties.SetName(box, "GitHub token");
        var save = new Button { Content = "Save", Margin = new Thickness(8, 0, 0, 0) };
        var tokenRow = new StackPanel { Orientation = Orientation.Horizontal };
        tokenRow.Children.Add(box);
        tokenRow.Children.Add(save);
        async void SaveBox()
        {
            var t = box.Password.Trim();
            if (t.Length == 0) { Status("Paste a token first.", "WarningBrush"); return; }
            save.IsEnabled = false;
            Status("Checking the token…", "TextSecondaryBrush");
            var (ok, message) = await Save(t);
            save.IsEnabled = true;
            if (ok) { box.Clear(); Connected(message); }
            else Status(message, "DangerBrush");
        }
        save.Click += (_, _) => SaveBox();
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; SaveBox(); } };

        if (GithubOAuth.ShowSignIn(GithubOAuth.ClientId, ctx.Demo))
        {
            var signIn = new GithubSignIn(Save);
            signIn.Connected += Connected;
            var useToken = new Button { Content = "Use a token instead", Style = (Style)Application.Current.FindResource("LinkButton"), Margin = new Thickness(0, 0, 12, 0) };
            controls.Children.Add(useToken);
            controls.Children.Add(signIn.Button);
            tokenRow.Margin = new Thickness(0, 10, 0, 0);
            tokenRow.HorizontalAlignment = HorizontalAlignment.Right;
            tokenRow.Visibility = Visibility.Collapsed;
            signIn.Panel.Margin = new Thickness(0, 10, 0, 0);
            detail.Children.Add(signIn.Panel);
            detail.Children.Add(tokenRow);
            useToken.Click += (_, _) =>
            {
                useToken.Visibility = Visibility.Collapsed;
                tokenRow.Visibility = Visibility.Visible;
                box.Focus();
            };
        }
        else
        {
            var get = new Button { Content = "Get a token", Style = (Style)Application.Current.FindResource("LinkButton"), Margin = new Thickness(0, 0, 12, 0), ToolTip = "Opens GitHub's token page with read:user picked" };
            get.Click += (_, _) =>
            {
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(TokenPage) { UseShellExecute = true }); }
                catch (Exception ex) { Core.Log.Warn("Opening GitHub failed", ex); }
            };
            controls.Children.Add(get);
            controls.Children.Add(tokenRow);
        }

        if (ctx.Demo) Connected("Connected as @octocat.");
        else
        {
            Status("Not connected", "TextTertiaryBrush");
            // A token from an earlier install: say so without a request (the tour itself never goes online).
            _ = Task.Run(CredentialStore.Read).ContinueWith(t =>
            {
                if (t.Result is { Length: > 0 } && controls.Visibility == Visibility.Visible) Status("A token is saved", "SuccessBrush");
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }
        return row = new SetupRow("GitHub", Glyphs.Github, status, action, detail);
    }
}
