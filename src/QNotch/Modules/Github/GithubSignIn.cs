using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Github;

/// <summary>
/// The Sign in with GitHub button and the device flow panel under it (Settings, GitHub and the welcome tour). The panel shows the user code
/// large with Copy code and open GitHub, then waits. Polling runs only while the panel is visible: Cancel, hiding or unloading it stops it.
/// </summary>
internal sealed class GithubSignIn
{
    /// <summary>Demo code for snapshots: shows the waiting state without a client id or a request.</summary>
    const string DemoCode = "WDJB-MJHT";

    readonly Func<string, Task<(bool Ok, string Message)>> _save;
    readonly TextBlock _code, _message;
    readonly Ellipse _dot;
    readonly Button _open, _cancel, _retry;
    CancellationTokenSource? _run;
    GithubOAuth.DeviceCode? _device;
    Window? _window;
    bool _waiting, _demo;

    /// <summary>Accent button that starts the flow.</summary>
    public Button Button { get; }
    /// <summary>Code, progress and errors. Collapsed until the flow starts.</summary>
    public Border Panel { get; }

    /// <summary>The token was saved and checked: the message is "Connected as @login.".</summary>
    public event Action<string>? Connected;

    /// <param name="save">Stores the token (Credential Manager, same entry as a pasted one) and checks it with the existing request.</param>
    public GithubSignIn(Func<string, Task<(bool Ok, string Message)>> save)
    {
        _save = save;
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        var glyph = new TextBlock { Text = Glyphs.Github, Style = (Style)Application.Current.FindResource("Glyph"), FontSize = 13, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        glyph.SetResourceReference(TextBlock.ForegroundProperty, "OnAccentBrush");
        label.Children.Add(glyph);
        label.Children.Add(new TextBlock { Text = "Sign in with GitHub", VerticalAlignment = VerticalAlignment.Center });
        Button = new Button { Content = label, Style = (Style)Application.Current.FindResource("AccentButton") };
        AutomationProperties.SetName(Button, "Sign in with GitHub");
        Button.Click += (_, _) => Start();

        _code = new TextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 26, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 0, 2),
        };
        AutomationProperties.SetName(_code, "Your code");
        _message = new TextBlock { FontSize = 11.5, TextWrapping = TextWrapping.Wrap };
        // While polling, a soft pulsing dot next to "Waiting for you…" shows it is alive. It runs only while it can be seen.
        _dot = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(1, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        _dot.SetResourceReference(Shape.FillProperty, "AccentBrush");
        _open = new Button { Content = "Copy code and open GitHub", Style = (Style)Application.Current.FindResource("AccentButton") };
        _cancel = new Button { Content = "Cancel", Margin = new Thickness(8, 0, 0, 0) };
        _retry = new Button { Content = "Try again", Margin = new Thickness(8, 0, 0, 0) };
        _open.Click += (_, _) => CopyAndOpen();
        _cancel.Click += (_, _) => Stop();
        _retry.Click += (_, _) => Start();

        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(_dot);
        line.Children.Add(_message);
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(_code);
        left.Children.Add(line);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
        buttons.Children.Add(_open);
        buttons.Children.Add(_retry);
        buttons.Children.Add(_cancel);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(left);
        grid.Children.Add(buttons);
        Panel = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 10, 10, 10), BorderThickness = new Thickness(1), Child = grid, Visibility = Visibility.Collapsed };
        Panel.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        Panel.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        // Polling only while the panel can be seen: switching sections, leaving the tour step or closing the window stops it.
        Panel.IsVisibleChanged += (_, e) => { if (!(bool)e.NewValue) Stop(collapse: false); };
        Panel.Unloaded += (_, _) => { Stop(collapse: false); Hook(null); };
        Panel.Loaded += (_, _) => Hook(Window.GetWindow(Panel));
    }

    /// <summary>Snapshot: the waiting state with a made-up code, settled (no reveal, no pulse) and no request.</summary>
    public void ShowDemo()
    {
        _demo = true;
        _device = new GithubOAuth.DeviceCode("", DemoCode, "https://github.com/login/device", 900, 5);
        Show(DemoCode, "Waiting for you to approve QNotch on GitHub…", "TextSecondaryBrush", open: true, retry: false, waiting: true);
    }

    async void Start()
    {
        if (_demo) return; // snapshot run: no requests
        Stop(collapse: false);
        var run = _run = new CancellationTokenSource();
        Show("", "Asking GitHub for a code…", "TextSecondaryBrush", open: false, retry: false);
        using var http = GithubOAuth.Client();
        try
        {
            var device = _device = await GithubOAuth.RequestCodeAsync(http, run.Token);
            if (run.IsCancellationRequested) return;
            Show(device.User, "Waiting for you to approve QNotch on GitHub…", "TextSecondaryBrush", open: true, retry: false, waiting: true);
            var r = await GithubOAuth.WaitForTokenAsync(device, ct => GithubOAuth.PollOnceAsync(http, device, ct), Task.Delay, run.Token);
            if (run.IsCancellationRequested) return;
            if (r.Kind != GithubOAuth.PollKind.Success) { Show("", r.Message, "DangerBrush", open: false, retry: true); return; }
            Show(device.User, "Approved. Checking the account…", "TextSecondaryBrush", open: false, retry: false);
            var (ok, message) = await _save(r.Token);
            if (run.IsCancellationRequested && !ok) return;
            if (!ok) { Show("", message, "DangerBrush", open: false, retry: true); return; }
            Panel.Visibility = Visibility.Collapsed;
            Connected?.Invoke(message);
        }
        catch (OperationCanceledException) { }
        catch (GithubException ex) { if (!run.IsCancellationRequested) Show("", ex.Message, "DangerBrush", open: false, retry: true); }
        catch (Exception ex)
        {
            Log.Warn("GitHub sign-in failed", ex); // the exception text never holds the token or codes
            if (!run.IsCancellationRequested) Show("", "Something went wrong. See the log.", "DangerBrush", open: false, retry: true);
        }
        finally { if (_run == run) _run = null; run.Dispose(); }
    }

    void Show(string code, string message, string brush, bool open, bool retry, bool waiting = false)
    {
        _code.Text = code;
        _code.Visibility = code.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _message.Text = message;
        _message.SetResourceReference(TextBlock.ForegroundProperty, brush);
        _open.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        _retry.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
        _retry.Margin = new Thickness(open ? 8 : 0, 0, 0, 0);
        _waiting = waiting;
        _dot.Visibility = waiting ? Visibility.Visible : Visibility.Collapsed;
        Pulse(waiting);
        var shown = Panel.Visibility == Visibility.Visible;
        Panel.Visibility = Visibility.Visible;
        if (shown) return;
        // In a scrolling page or tour step the code may open below the fold: scroll it into view once.
        Panel.Dispatcher.BeginInvoke(() => Panel.BringIntoView(), System.Windows.Threading.DispatcherPriority.Loaded);
        // Reveal: one unfold from the top with a fade (a render transform, never a height loop).
        if (!Motion.Enabled || _demo) return;
        var unfold = new ScaleTransform();
        Panel.RenderTransformOrigin = new Point(0.5, 0);
        Panel.RenderTransform = unfold;
        var d = TimeSpan.FromMilliseconds(220);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        unfold.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.86, 1, d) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        Panel.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, d) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
    }

    void Stop(bool collapse = true)
    {
        try { _run?.Cancel(); } catch (ObjectDisposedException) { }
        _run = null;
        _waiting = false;
        Pulse(false);
        if (collapse) Panel.Visibility = Visibility.Collapsed;
    }

    /// <summary>A minimized window stops the pulse; restoring it starts it again while still waiting.</summary>
    void Hook(Window? w)
    {
        if (_window is not null) _window.StateChanged -= OnWindowState;
        _window = w;
        if (w is not null) w.StateChanged += OnWindowState;
    }

    void OnWindowState(object? sender, EventArgs e) => Pulse(_waiting);

    /// <summary>The waiting dot's loop: only while polling, the panel is visible and its window is not minimized; removed otherwise.</summary>
    void Pulse(bool on)
    {
        if (on && Motion.Enabled && !_demo && _window?.WindowState != WindowState.Minimized)
        {
            var a = new DoubleAnimation(1, 0.25, TimeSpan.FromMilliseconds(700))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            };
            Timeline.SetDesiredFrameRate(a, 30);
            _dot.BeginAnimation(UIElement.OpacityProperty, a);
        }
        else _dot.BeginAnimation(UIElement.OpacityProperty, null);
    }

    void CopyAndOpen()
    {
        if (_device is not { } d) return;
        try { System.Windows.Clipboard.SetText(d.User); }
        catch (Exception ex) { Log.Warn("Copying the GitHub code failed", ex); }
        if (string.IsNullOrEmpty(d.Device)) return; // demo
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(d.VerificationUri) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn("Opening GitHub failed", ex); }
    }
}
