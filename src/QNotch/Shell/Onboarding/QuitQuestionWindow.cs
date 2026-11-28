using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Theme;

namespace QNotch.Shell.Onboarding;

/// <summary>
/// The first-week quit question (spec/analytics.md, Quit question): a small standalone, centered, dark window without a title bar, in the
/// welcome tour's look. One click on a reason picks it; Skip, Esc and closing the window pick <see cref="QuitQuestion.Skipped"/>. The
/// missing-feature answer first switches the window to a second step with one text box (What's missing); Send keeps the text, and every
/// other way out of that step keeps the answer without it. Every way out closes the window and the caller quits: there is no way to
/// cancel the quit. No timer, hook or animation. UI thread only.
/// App calls it from a method of its own, so a normal start never loads this type.
/// </summary>
internal sealed class QuitQuestionWindow : Window
{
    const double W = 420;

    bool _done;
    bool _missingStep;
    UIElement? _first;
    readonly StackPanel _stack;
    readonly Style _ring;
    readonly bool _styled;

    /// <summary>The chosen target (a <see cref="QuitQuestion.Answers"/> target or <see cref="QuitQuestion.Skipped"/>). Null only when the app was already shutting down.</summary>
    public string? Target { get; private set; }

    /// <summary>What the user typed and sent in the second step, uncleaned (Analytics cleans it). Null unless Send was used.</summary>
    public string? Missing { get; private set; }

    internal QuitQuestionWindow()
    {
        Title = "Before you go";
        // Always dark, like the welcome tour: the dark palette overrides the app's for everything in this window.
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Theme/Theme.Dark.xaml") });
        var styled = _styled = Motion.Enabled;
        if (styled) Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Shell/Onboarding/TourStyles.xaml") });
        Width = W;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        FontFamily = (System.Windows.Media.FontFamily)FindResource("UiFont");
        FontSize = 12;
        System.Windows.Media.TextOptions.SetTextFormattingMode(this, System.Windows.Media.TextFormattingMode.Ideal);
        SetResourceReference(BackgroundProperty, "WindowBrush");
        SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        try { Icon = AppIcon.Render(32); } catch { }
        System.Windows.Shell.WindowChrome.SetWindowChrome(this, new System.Windows.Shell.WindowChrome
        {
            CaptionHeight = 0, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0, 0, 0, 1), UseAeroCaptionButtons = false,
        });
        SourceInitialized += (_, _) => TourWindow.Frame(this);

        var ring = _ring = TourWindow.FocusRing();
        var root = new Grid { Width = W };
        root.SetResourceReference(Panel.BackgroundProperty, "WindowBrush");

        var stack = _stack = new StackPanel { Margin = new Thickness(24, 22, 24, 18) };
        var heading = new TextBlock { Text = "Before you go", FontSize = 20, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 28, 0) };
        AutomationProperties.SetName(heading, "Before you go");
        stack.Children.Add(heading);
        var ask = new TextBlock { Text = "What is the main reason you are quitting?", Margin = new Thickness(0, 4, 0, 14), TextWrapping = TextWrapping.Wrap };
        ask.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        stack.Children.Add(ask);

        foreach (var (target, label) in QuitQuestion.Answers)
        {
            var b = new Button { Content = label, Padding = new Thickness(12, 9, 12, 9), Margin = new Thickness(0, 0, 0, 6), FocusVisualStyle = ring };
            if (styled) b.Style = (Style)FindResource("TourButton");
            AutomationProperties.SetName(b, label);
            AutomationProperties.SetAutomationId(b, "quit-reason-" + target.Replace("quit_", "").Replace('_', '-'));
            var chosen = target;
            b.Click += (_, _) => { if (chosen == QuitQuestion.MissingFeature) ShowMissingStep(); else Pick(chosen); };
            _first ??= b;
            stack.Children.Add(b);
        }

        var footer = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var fine = new TextBlock { Text = "Sends only the answer you pick, or that you skipped. No text.", FontSize = 11, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        fine.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        var skip = new Button { Content = "Skip", Padding = new Thickness(2, 4, 2, 4), FocusVisualStyle = ring, VerticalAlignment = VerticalAlignment.Center };
        skip.Style = (Style)FindResource(styled ? "TourLinkButton" : "LinkButton");
        AutomationProperties.SetName(skip, "Skip");
        AutomationProperties.SetAutomationId(skip, "quit-reason-skip");
        skip.Click += (_, _) => Pick(QuitQuestion.Skipped);
        Grid.SetColumn(skip, 1);
        footer.Children.Add(fine);
        footer.Children.Add(skip);
        stack.Children.Add(footer);
        root.Children.Add(stack);

        var close = new Button { Style = (Style)FindResource("IconButton"), Content = Glyphs.Close, ToolTip = "Close", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 10, 10, 0), FocusVisualStyle = ring };
        AutomationProperties.SetName(close, "Close");
        AutomationProperties.SetAutomationId(close, "quit-reason-close");
        close.Click += (_, _) => Leave();
        root.Children.Add(close);
        Content = root;

        root.MouseLeftButtonDown += (_, e) =>
        {
            if (_done || !IsLoaded || e.OriginalSource is DependencyObject d && IsButton(d)) return;
            try { DragMove(); } catch (InvalidOperationException) { }
        };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && !_done) { e.Handled = true; Leave(); } };
        Closing += OnClosing;
        Loaded += (_, _) => { Activate(); _first?.Focus(); };
    }

    static bool IsButton(DependencyObject d)
    {
        for (; d is not null; d = d is System.Windows.Media.Visual or System.Windows.Media.Media3D.Visual3D ? System.Windows.Media.VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d is System.Windows.Controls.Primitives.ButtonBase) return true;
        return false;
    }

    /// <summary>The second step (spec/analytics.md, What's missing): replaces the reasons with one text box, Skip and Send.</summary>
    void ShowMissingStep()
    {
        if (_done || _missingStep) return;
        _missingStep = true;
        _stack.Children.Clear();
        var heading = new TextBlock { Text = "What's missing?", FontSize = 20, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 28, 0) };
        AutomationProperties.SetName(heading, "What's missing?");
        _stack.Children.Add(heading);
        var ask = new TextBlock { Text = "What did you need QNotch to do?", Margin = new Thickness(0, 4, 0, 14), TextWrapping = TextWrapping.Wrap };
        ask.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        _stack.Children.Add(ask);

        var box = new TextBox { MaxLength = QuitQuestion.MissingMaxLength, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, AcceptsTab = false, VerticalContentAlignment = VerticalAlignment.Top };
        // Three lines tall from the font's line height, so the box never grows as the user types.
        box.Height = Math.Ceiling(FontSize * FontFamily.LineSpacing * 3) + 6 + 6 + 2;
        AutomationProperties.SetName(box, "What did you need QNotch to do?");
        AutomationProperties.SetAutomationId(box, "quit-reason-missing-text");
        _stack.Children.Add(box);

        var footer = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var fine = new TextBlock { Text = "Sends what you type with your answer. Leave out anything personal.", FontSize = 11, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        fine.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        var skip = new Button { Content = "Skip", Padding = new Thickness(2, 4, 2, 4), FocusVisualStyle = _ring, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        skip.Style = (Style)FindResource(_styled ? "TourLinkButton" : "LinkButton");
        AutomationProperties.SetName(skip, "Skip");
        AutomationProperties.SetAutomationId(skip, "quit-reason-missing-skip");
        skip.Click += (_, _) => Pick(QuitQuestion.MissingFeature);
        var send = new Button { Content = "Send", Padding = new Thickness(16, 7, 16, 7), FocusVisualStyle = _ring, VerticalAlignment = VerticalAlignment.Center, IsDefault = true, IsEnabled = false };
        send.Style = (Style)FindResource(_styled ? "TourAccentButton" : "AccentButton");
        AutomationProperties.SetName(send, "Send");
        AutomationProperties.SetAutomationId(send, "quit-reason-missing-send");
        send.Click += (_, _) => { if (QuitQuestion.CleanMissing(box.Text) is not null) Pick(QuitQuestion.MissingFeature, box.Text); };
        box.TextChanged += (_, _) => send.IsEnabled = QuitQuestion.CleanMissing(box.Text) is not null;
        Grid.SetColumn(skip, 1);
        Grid.SetColumn(send, 2);
        footer.Children.Add(fine);
        footer.Children.Add(skip);
        footer.Children.Add(send);
        _stack.Children.Add(footer);
        _first = box;
        if (IsLoaded) box.Focus();
    }

    /// <summary>Esc and the close button: Skip on the first step; on the second the answer stands, without text.</summary>
    void Leave() => Pick(_missingStep ? QuitQuestion.MissingFeature : QuitQuestion.Skipped);

    void Pick(string target, string? missing = null)
    {
        if (_done) return;
        _done = true;
        Target = target;
        Missing = missing;
        Close();
    }

    /// <summary>Any other close (Alt+F4, the taskbar) counts as Esc; when the app is already shutting down it records nothing.</summary>
    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_done) return;
        _done = true;
        Target = Dispatcher.HasShutdownStarted ? null : _missingStep ? QuitQuestion.MissingFeature : QuitQuestion.Skipped;
    }

    /// <summary>Shows the question modally and returns the chosen target (null when it could not be shown or the app was shutting down) and
    /// the sent what's-missing text. Never throws: a failure is logged and the caller quits as usual.</summary>
    internal static (string? Target, string? Missing) Ask()
    {
        QuitQuestionWindow? w = null;
        try
        {
            w = new QuitQuestionWindow();
            w.ShowDialog();
            return (w.Target, w.Missing);
        }
        catch (Exception ex)
        {
            Log.Error("Quit question failed", ex);
            try { w?.Close(); } catch { }
            return (null, null);
        }
    }

    /// <summary>Snapshot: renders the window (nothing activates, nothing is recorded) through <paramref name="save"/> as quit-question, then
    /// its second step as quit-question-missing.</summary>
    internal static void Snapshot(Action<FrameworkElement, string> save)
    {
        var w = new QuitQuestionWindow { WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = 0, ShowActivated = false, ShowInTaskbar = false, Topmost = false };
        w.Show();
        try
        {
            w.UpdateLayout();
            save((FrameworkElement)w.Content, "quit-question");
            w.ShowMissingStep();
            w.UpdateLayout();
            save((FrameworkElement)w.Content, "quit-question-missing");
        }
        finally { w._done = true; w.Close(); }
    }
}
