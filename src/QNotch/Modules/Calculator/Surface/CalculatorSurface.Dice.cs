using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Calc.Core;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    /// <summary>A roll waiting for its evaluation to be published, then shown.</summary>
    private (SheetEditor Editor, int Line, DiceBinding Roll)? rollShowing;
    /// <summary>The line whose result is held back while its dice are in the air.</summary>
    private int rollingLine = -1;

    private void RegisterDice(SheetEditor editor) => editor.RollRequested += (line, again) => RollDice(editor, line, again);

    private void RollDice(SheetEditor editor, int line, bool again)
    {
        if (!ready || !ReferenceEquals(editor, Editor) || compositionActive) return;
        var session = uuidSessions[editor].Session;
        if (session.Source != editor.Text) return;
        DiceBinding? roll;
        try { roll = session.Roll(line, again); }
        catch (ArithmeticException e) { SaveState.Text = e.Message; return; }
        if (roll is null) return;
        dirty = true; saveTimer.Stop(); saveTimer.Start();
        rollShowing = (editor, line, roll);
        pending = Evaluate();
    }

    /// <summary>Runs after an evaluation is published. Plays the toss for a fresh roll that is still the line's roll.</summary>
    private void ShowRoll()
    {
        if (rollShowing is not { } shown || !ReferenceEquals(shown.Editor, Editor)) return;
        rollShowing = null;
        var held = uuidSessions[Editor].Session.Rolled(shown.Line);
        if (held is null || !held.Faces.SequenceEqual(shown.Roll.Faces) || shown.Line >= answers.Count || answers[shown.Line].Value is not { } value) return;
        Announce(T.Format("rolled", value.Display));
        if (!SheetMotion.Enabled || DiceSyntax.TryParse(held.Formula) is not { } formula) return;
        if (sourceLines.Source != Editor.Text) sourceLines = new(Editor.Text);
        var end = Editor.GetRectFromCharacterIndex(sourceLines.ContentEnd(shown.Line));
        if (end.IsEmpty || end.Bottom < 0 || end.Top > Editor.ActualHeight) return;
        var origin = Editor.TranslatePoint(new Point(end.X, end.Top + end.Height / 2), DiceLayer);
        var line = shown.Line;
        DiceLayer.Clear();
        rollingLine = line; HoldRollingResult();
        // Filled in the result colour, printed in the sheet colour, so dice follow the palette and high contrast.
        DiceLayer.Play(DiceSyntax.Faces(formula, held.Faces), origin, Math.Round(Editor.FontSize * 3.4),
            ColorOf("AccentBrush", Colors.Teal), ColorOf("CardBrush", Colors.White), Editor.FontFamily,
            () => { rollingLine = -1; RevealResult(line); });
    }
    private Color ColorOf(string key, Color fallback) => TryFindResource(key) is SolidColorBrush brush ? brush.Color : fallback;

    /// <summary>Settled dice stay on the sheet until the next action: a key, click, wheel, scroll, edit, resize or sheet switch.
    /// Pointer movement alone keeps them.</summary>
    private void RegisterDiceDismissal() => DiceDismissal.Attach(this, DiceLayer);

    /// <summary>Keeps the rolled line's result hidden until the dice arrive.</summary>
    private void HoldRollingResult()
    {
        if (rollingLine >= 0 && resultControls.TryGetValue(rollingLine, out var control)) control.Button.Opacity = 0;
    }
    private void RevealResult(int line)
    {
        if (!resultControls.TryGetValue(line, out var control)) return;
        control.Button.Opacity = 1;
        control.Button.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)) { FillBehavior = FillBehavior.Stop });
    }
    private void Announce(string message)
    {
        UIElementAutomationPeer.CreatePeerForElement(Editor)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.ImportantMostRecent, message, "calc-dice-rolled");
    }
}
