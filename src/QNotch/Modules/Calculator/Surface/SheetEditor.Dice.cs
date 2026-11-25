using System.Windows.Input;

namespace Calc.Windows;

public sealed partial class SheetEditor
{
    /// <summary>A dice line was submitted: Enter on it (<c>again</c> false) or Ctrl+Enter (<c>again</c> true). The index is 0-based.</summary>
    internal event Action<int, bool>? RollRequested;

    /// <summary>Enter (and Shift+Enter) arrive as a typed line break once the editor has inserted it; the line the caret just left,
    /// holding the text that was before the caret, is submitted. Ctrl+Enter rolls the caret's line again without inserting a line.
    /// Neither handler changes what the keys do to the text.</summary>
    private void RegisterDiceKeys()
    {
        TextArea.TextEntered += (_, e) =>
        {
            if (e.Text is not ("\n" or "\r" or "\r\n") || TextArea.Caret.Line < 2) return;
            RollRequested?.Invoke(TextArea.Caret.Line - 2, false);
        };
        TextArea.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || Keyboard.Modifiers != ModifierKeys.Control) return;
            e.Handled = true;
            RollRequested?.Invoke(TextArea.Caret.Line - 1, true);
        };
    }
}
