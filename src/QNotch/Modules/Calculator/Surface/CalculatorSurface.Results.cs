using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Calc.Core;
using Calc.Documents;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private const double BaseGutterWidth = 220;
    private SourceLineMap sourceLines = new("");
    private readonly Dictionary<int, (Button Button, LineResult Answer)> resultControls = [];
    private DispatcherOperation? gutterUpdate;
    private readonly RectangleGeometry gutterClip = new();
    private int timestampWidthAnchor = -1;
    private double timestampGutterWidth = BaseGutterWidth;

    // Measure the same tabular-numeral TextBlock as the result template; proportional FormattedText
    // underestimates IP ranges. Bound the cache, and invalidate it for font or DPI changes.
    private readonly Dictionary<string, double> completeResultWidths = [];
    private FontFamily? measuredResultFamily;
    private double measuredResultFontSize, measuredResultDpi;
    private double CompleteResultWidth(string text)
    {
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        if (!ReferenceEquals(measuredResultFamily, Editor.FontFamily) || measuredResultFontSize != Editor.FontSize || measuredResultDpi != dpi)
        {
            completeResultWidths.Clear(); measuredResultFamily = Editor.FontFamily;
            measuredResultFontSize = Editor.FontSize; measuredResultDpi = dpi;
        }
        if (completeResultWidths.TryGetValue(text, out var cached)) return cached;
        var probe = new TextBlock { Text = text, FontFamily = Editor.FontFamily, FontSize = Editor.FontSize,
            FontStyle = FontStyles.Normal, FontWeight = FontWeights.SemiBold, FontStretch = FontStretches.Normal };
        System.Windows.Documents.Typography.SetNumeralAlignment(probe, FontNumeralAlignment.Tabular);
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        // Canvas right margin (10), surface inset/border (16), and the transient copy tick/margin (21).
        var width = Math.Ceiling(probe.DesiredSize.Width) + 48;
        if (completeResultWidths.Count >= 128) completeResultWidths.Clear();
        completeResultWidths[text] = width; return width;
    }

    // The editor runs under the gutter, so its padding keeps source text clear of the results.
    private void SetResultColumn(double width)
    {
        ResultColumn.Width = new GridLength(width);
        Editor.Padding = new Thickness(0, 8, width + 24, 8);
    }
    private void UpdatePlaceholder() => Placeholder.Visibility = Editor.Document.TextLength == 0 ? Visibility.Visible : Visibility.Collapsed;
    private void RequestGutterLayout()
    {
        if (gutterUpdate?.Status == DispatcherOperationStatus.Pending) return;
        gutterUpdate = Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => { gutterUpdate = null; DrawResults(); });
    }
    private void ClearResults()
    {
        var focused = resultControls.Values.Any(c => c.Button.IsKeyboardFocusWithin);
        resultControls.Clear(); Results.Children.Clear();
        timestampWidthAnchor = -1; timestampGutterWidth = BaseGutterWidth;
        if (focused) Editor.Focus();
    }
    private void DrawResults()
    {
        if (!ready) return;
        if (answers.Count == 0) { ClearResults(); return; }
        var top = Editor.Padding.Top;
        var bottom = Math.Max(top, Editor.ActualHeight - Editor.Padding.Bottom);
        gutterClip.Rect = new Rect(0, top, Results.ActualWidth, Math.Max(0, bottom - top));
        Results.Clip = gutterClip;
        if (sourceLines.Source != Editor.Text) sourceLines = new(Editor.Text);
        // Hit-test the viewport instead of asking WPF to enumerate all wrapped visual rows.
        var x = Editor.ActualWidth / 2;
        var firstCharacter = Editor.GetCharacterIndexFromPoint(new Point(x, 1), true);
        var lastCharacter = Editor.GetCharacterIndexFromPoint(new Point(x, Math.Max(1, Editor.ActualHeight - 1)), true);
        if (firstCharacter < 0 || lastCharacter < 0) { ClearResults(); return; }
        var first = Math.Max(0, sourceLines.LineAt(firstCharacter) - 1);
        var last = Math.Min(sourceLines.Count - 1, sourceLines.LineAt(lastCharacter) + 1);
        // Full timestamps and subnet/address endpoints are part of the value. Widen the existing gutter,
        // bounded to leave an editable source area; ordinary results retain the established density.
        var timestampWidth = BaseGutterWidth;
        for (var i = first; i <= last && i < answers.Count; i++)
            if (answers[i].Value?.Kind is SheetValueKind.LocalTimestamp or SheetValueKind.ZonedMoment || answers[i].Value is { Kind: SheetValueKind.Network } network && network.Network.Form is NetworkForm.Subnet or NetworkForm.Address)
                timestampWidth = Math.Max(timestampWidth, CompleteResultWidth(Shown(answers[i])));
        // Keep width stable while reflowing the same logical viewport; a bottom row must not
        // alternate between visible/wide and offscreen/narrow on consecutive layout passes.
        if (timestampWidthAnchor != first) { timestampWidthAnchor = first; timestampGutterWidth = BaseGutterWidth; }
        timestampGutterWidth = Math.Max(timestampGutterWidth, timestampWidth);
        timestampWidth = Math.Min(timestampGutterWidth, Math.Max(BaseGutterWidth, ResultGrid.ActualWidth - 240));
        if (Math.Abs(ResultColumn.Width.Value - timestampWidth) > .5)
        { SetResultColumn(timestampWidth); RequestGutterLayout(); return; }
        var desired = new HashSet<int>();
        for (var i = first; i <= last && i < answers.Count; i++)
        {
            var answer = answers[i];
            if (answer.Display.Length == 0) continue;
            var rect = Editor.GetRectFromCharacterIndex(sourceLines.Start(i));
            // Results anchor to the first visual row of their logical source line.
            if (rect.IsEmpty || rect.Bottom <= top + .01 || rect.Top >= bottom) continue;
            desired.Add(i);
            if (!resultControls.TryGetValue(i, out var control) || !ReferenceEquals(control.Answer, answer))
            {
                var focused = control.Button?.IsKeyboardFocusWithin == true;
                if (control.Button is not null) Results.Children.Remove(control.Button);
                var button = CreateResultButton(i, answer);
                control = (button, answer); resultControls[i] = control; Results.Children.Add(button);
                if (focused) button.Focus();
            }
            control.Button.Width = Results.ActualWidth;
            control.Button.Height = rect.Height; Canvas.SetTop(control.Button, rect.Top);
        }
        foreach (var i in resultControls.Keys.Where(i => !desired.Contains(i)).ToArray())
        {
            var button = resultControls[i].Button; var focused = button.IsKeyboardFocusWithin;
            Results.Children.Remove(button); resultControls.Remove(i);
            if (focused) Editor.Focus();
        }
    }
    private Button CreateResultButton(int line, LineResult answer)
    {
        var card = HoverCard(answer);
        var button = new Button
        {
            Content = Shown(answer), ContentTemplate = (DataTemplate)FindResource("ResultTemplate"),
            Style = (Style)FindResource("SheetResult"),
            FontFamily = Editor.FontFamily, FontSize = answer.Error is null ? Editor.FontSize : 13,
            // An unrolled dice line's range is a muted hint, not a value.
            FontWeight = answer.Error is null && answer.Pending is null ? FontWeights.SemiBold : FontWeights.Normal,
            Opacity = line == rollingLine ? 0 : 1,
            Cursor = answer.Value is null ? Cursors.Arrow : Cursors.Hand,
            Tag = answer.Error is null && card is not null ? "Explained" : null
        };
        if (card is not null)
        {
            var tip = new ToolTip { Content = card, Style = (Style)FindResource("ResultCardTip"),
                Placement = PlacementMode.Custom, CustomPopupPlacementCallback = CardBelowRightEdge };
            tip.Opened += (_, _) => card.Open(key => TryFindResource(key), QNotch.Theme.ThemeManager.IsDark, SystemParameters.HighContrast);
            button.ToolTip = tip;
        }
        button.SetResourceReference(ForegroundProperty, answer.Error is null && answer.Pending is null ? "AccentBrush" : "TextSecondaryBrush");
        System.Windows.Automation.AutomationProperties.SetName(button, answer.Pending is not null ? T.Format("diceRange", line + 1, Shown(answer))
            : T.Format(answer.Error is null ? "resultNameCopy" : "resultName", line + 1, Shown(answer)));
        if (answer.Value is not null)
        {
            System.Windows.Automation.AutomationProperties.SetHelpText(button, Explain(answer) + "\n" + T["resultHelp"]);
            var explain = new MenuItem { Header = T["explainMenu"], InputGestureText = "F1" };
            explain.Click += (_, _) => ShowExplanation(answer);
            var menu = HeldMenu(); menu.Items.Add(explain); button.ContextMenu = menu;
            button.KeyDown += (_, e) => { if (e.Key == Key.F1) { ShowExplanation(answer); e.Handled = true; } };
        }
        button.Click += (_, _) =>
        {
            if (answer.Value is null) return;
            try { SheetClipboard.SetText(QNotch.Modules.Calculator.SheetDisplay.Present(answer, answer.Value.Value, resultFormat).Copy); ConfirmCopy(button); }
            catch (System.Runtime.InteropServices.COMException) { SaveState.Text = T["clipboardUnavailable"]; }
            // A mouse copy must not strand typing on the result; keyboard users stay where they are.
            if (InputManager.Current.MostRecentInputDevice is MouseDevice) Editor.Focus();
        };
        return button;
    }
    private ResultCard? HoverCard(LineResult answer)
    {
        var family = FontFamily;
        if (answer.Error is { } error) return ResultCard.Problem(error, family);
        var (note, sources) = SummaryParts(answer);
        string? headline = null;
        // A default-currency result names the amount the line actually holds.
        if (answer.Shown is not null && answer.Value is { } held) headline = ResultFormatter.Format(held, resultFormat);
        // A complete ordered band code is needed to identify the component even when the row is ellipsized.
        // A rounded or compound row keeps its exact value one hover away.
        if (headline is null && answer.Value is not null && ResultFormatter.Format(answer, resultFormat) is var exact && exact != Shown(answer)) headline = exact;
        if (answer.Value is { Kind: SheetValueKind.Resistor } marking && marking.Resistor.ShowColors) headline = marking.Display;
        if (answer.Value is { Kind: SheetValueKind.Text } textual && note.Length == 0 && sources.Length == 0 &&
            (textual.Text.Display != textual.Text.Value || CompleteResultWidth(textual.Display) > ResultColumn.Width.Value))
        { headline = textual.Text.Display; note = textual.Text.Value.Length > 96 ? T["copyKeepsText"] : ""; }
        var breakdown = answer.Explanation.LastOrDefault(step => step.Payroll is not null)?.Payroll is { } payroll ? PayrollBreakdownText.Rows(payroll) : null;
        return ResultCard.Explain(headline, note, breakdown, sources, family);
    }
    // The card's right edge lines up with the value; it opens above when there is no room below.
    private static CustomPopupPlacement[] CardBelowRightEdge(Size popup, Size target, Point offset)
    {
        var x = target.Width - popup.Width + ResultCard.ShadowSpace.Right;
        return [new(new Point(x, target.Height - ResultCard.ShadowSpace.Top), PopupPrimaryAxis.Horizontal),
            new(new Point(x, ResultCard.ShadowSpace.Bottom - popup.Height), PopupPrimaryAxis.Horizontal)];
    }
    // Results sit at the window's right edge: keep the popup inside it, right-aligned with the value.
    private static CustomPopupPlacement[] BelowRightEdge(Size popup, Size target, Point offset) =>
        [new(new Point(target.Width - popup.Width, target.Height), PopupPrimaryAxis.Horizontal)];
    // Feedback lands where the user clicked. It appears at once, then leaves quickly so the result stays the focus.
    private static void ConfirmCopy(Button button)
    {
        if (button.Template.FindName("CopiedMark", button) is UIElement mark)
        {
            var hold = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(700)); var end = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(880));
            var fade = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.Stop };
            fade.KeyFrames.Add(new DiscreteDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            fade.KeyFrames.Add(new DiscreteDoubleKeyFrame(1, hold));
            fade.KeyFrames.Add(SheetMotion.Enabled ? new LinearDoubleKeyFrame(0, end) : new DiscreteDoubleKeyFrame(0, end));
            fade.Completed += (_, _) => mark.Visibility = Visibility.Collapsed;
            mark.Visibility = Visibility.Visible; mark.BeginAnimation(OpacityProperty, fade);
        }
        UIElementAutomationPeer.CreatePeerForElement(button)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.ImportantMostRecent, T["copied"], "calc-result-copied");
    }
}
