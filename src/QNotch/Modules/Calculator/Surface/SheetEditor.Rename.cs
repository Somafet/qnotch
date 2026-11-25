using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Calc.Core;

namespace Calc.Windows;

public sealed partial class SheetEditor
{
    private Popup? renameBox;
    private Action<bool>? closeRename;
    private FrameworkElement? inlineRenameBox;
    /// <summary>When set, the box is shown by this host inside the panel instead of a popup: <c>null</c> removes it. A popup over a
    /// no-activate layered window would not get the keyboard reliably.</summary>
    internal Action<FrameworkElement?, Rect>? InlineRenameHost { get; set; }
    internal bool RenamingVariable => renameBox?.IsOpen == true || inlineRenameBox is not null;
    internal Popup? RenameBox => renameBox;

    /// <summary>Opens an inline box below the variable at the caret or selection; commits every occurrence as one undo step.
    /// Returns false when the caret is not on a sheet variable.</summary>
    internal bool BeginVariableRename()
    {
        if (IsReadOnly || RenamingVariable || VariableRename.Find(Text, SelectionStart, SelectionLength) is not { } target) return false;
        var rect = GetRectFromCharacterIndex(target.Span.Start);
        if (rect.IsEmpty) return false;
        var input = new TextBox
        {
            Text = Document.GetText(target.Span.Start, target.Span.Length), MinWidth = 160, MaxLength = 128,
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI"), FontSize = 14, Padding = new Thickness(4, 2, 4, 2),
        };
        // The popup stays outside the window's logical tree (and its shortcuts), so it takes the current theme brushes directly.
        Brush? Theme(string key) => TryFindResource(key) as Brush;
        input.Background = Theme("SurfaceRaisedBrush"); input.Foreground = input.CaretBrush = Theme("TextPrimaryBrush");
        input.BorderBrush = Theme("AccentBrush");
        AutomationProperties.SetName(input, UiText.Current["renameVariable"]);
        var problem = new TextBlock { Visibility = Visibility.Collapsed, FontSize = 12, Margin = new Thickness(4, 2, 4, 2), TextWrapping = TextWrapping.Wrap, MaxWidth = 280 };
        problem.Foreground = Theme("WarningBrush");
        AutomationProperties.SetLiveSetting(problem, AutomationLiveSetting.Assertive);
        var panel = new StackPanel(); panel.Children.Add(input); panel.Children.Add(problem);
        var host = new Border { Child = panel, CornerRadius = new CornerRadius(4), Background = Theme("SurfaceRaisedBrush") };
        AutomationProperties.SetAutomationId(input, "calculator-rename-variable");
        var inline = InlineRenameHost;
        var popup = inline is not null ? null : renameBox = new Popup
        {
            Child = host, PlacementTarget = this, Placement = PlacementMode.Relative, StaysOpen = false, AllowsTransparency = true,
            HorizontalOffset = rect.X, VerticalOffset = rect.Bottom,
        };
        var done = false;
        void Close(bool commit)
        {
            if (done) return;
            if (commit)
            {
                var source = Text;
                var issue = VariableRename.Check(source, target.Name, input.Text);
                if (issue != VariableRename.Problem.None)
                {
                    problem.Text = issue == VariableRename.Problem.Taken ? UiText.Current["variableNameTaken"] : UiText.Current["invalidVariableName"];
                    problem.Visibility = Visibility.Visible; input.SelectAll(); return;
                }
                RenameOccurrences(source, target.Name, target.Span, input.Text);
            }
            done = true; closeRename = null;
            if (popup is not null) { popup.IsOpen = false; renameBox = null; }
            else { inlineRenameBox = null; inline!(null, default); }
            TextArea.Focus();
        }
        closeRename = Close;
        input.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { Close(true); e.Handled = true; }
            else if (e.Key == Key.Escape) { Close(false); e.Handled = true; }
        };
        input.TextChanged += (_, _) => problem.Visibility = Visibility.Collapsed;
        if (popup is null)
        {
            inlineRenameBox = host;
            inline!(host, rect);
            input.Loaded += (_, _) => { input.Focus(); Keyboard.Focus(input); input.SelectAll(); };
            // Like a popup that does not stay open: clicking elsewhere cancels.
            input.LostKeyboardFocus += (_, e) => { if (!done && e.NewFocus is not null && !host.IsAncestorOf((DependencyObject)e.NewFocus)) Close(false); };
            return true;
        }
        popup.Closed += (_, _) => { done = true; renameBox = null; closeRename = null; };
        popup.Opened += (_, _) => { input.Focus(); Keyboard.Focus(input); input.SelectAll(); };
        popup.IsOpen = true;
        return true;
    }

    /// <summary>Enter (commit) or Escape on the open box; an invalid name keeps it open with its reason.</summary>
    internal void CompleteVariableRename(bool commit) => closeRename?.Invoke(commit);

    /// <summary>Replaces every occurrence in one document update, keeping the caret inside the renamed name.</summary>
    internal void RenameOccurrences(string source, string name, SourceSpan target, string newName)
    {
        var replacement = VariableRename.Normalize(newName);
        var spans = VariableRename.Occurrences(source, name);
        if (spans.Count == 0) return;
        var caret = Math.Clamp(CaretOffset - target.Start, 0, target.Length);
        var shift = spans.TakeWhile(span => span.Start < target.Start).Sum(span => replacement.Length - span.Length);
        if (Document.TextLength + spans.Sum(span => replacement.Length - span.Length) > MaximumCharacters) return;
        Document.BeginUpdate();
        try { foreach (var span in spans.Reverse()) Document.Replace(span.Start, span.Length, replacement); }
        finally { Document.EndUpdate(); }
        CaretOffset = target.Start + shift + Math.Min(caret, replacement.Length);
    }
}
