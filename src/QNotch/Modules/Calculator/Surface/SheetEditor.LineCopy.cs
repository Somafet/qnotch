using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using ICSharpCode.AvalonEdit.Document;

namespace Calc.Windows;

public sealed partial class SheetEditor
{
    /// <summary>The marker Visual Studio and AvalonEdit put beside text copied from an empty selection.</summary>
    internal const string WholeLineFormat = "MSDEVLineSelect";

    /// <summary>The last whole line copied from any sheet. Clipboard sync (Remote Desktop, WSLg) can re-publish text without the marker;
    /// matching text then still pastes as a line, as VS Code does.</summary>
    private static string? lastWholeLine;

    /// <summary>Ctrl+C with no selection copies the caret's whole line; pasting such a copy with no selection inserts it as a line
    /// above the caret's line, so copy then paste duplicates the line. Ctrl+X with no selection copies the line the same way and removes it.</summary>
    private void RegisterLineCopy()
    {
        // Options.CutCopyWholeLine stays off (this handler owns the behaviour), which makes the editor report Copy/Cut as
        // unavailable without a selection. Key gestures check availability first, so Ctrl+C/Ctrl+X would never arrive here.
        CommandManager.AddPreviewCanExecuteHandler(TextArea, (_, e) =>
        {
            if (SelectionLength != 0) return;
            if (e.Command == ApplicationCommands.Copy || e.Command == ApplicationCommands.Cut && !IsReadOnly)
            { e.CanExecute = true; e.Handled = true; }
        });
        CommandManager.AddPreviewExecutedHandler(TextArea, (_, e) =>
        {
            var cut = e.Command == ApplicationCommands.Cut;
            if ((e.Command == ApplicationCommands.Copy || cut) && SelectionLength == 0)
            {
                e.Handled = true;
                if (cut && IsReadOnly) return;
                // Clipboard history or another process may hold the clipboard for a moment; retry briefly before giving up.
                var data = CopyWholeLine(); var copied = false;
                for (var attempt = 0; attempt < 5 && !copied; attempt++)
                {
                    try { SheetClipboard.SetDataObject(data); copied = true; }
                    catch (COMException) { Thread.Sleep(10); }
                }
                // A line is removed only once it is safely on the clipboard.
                if (cut && copied) RemoveCaretLine();
            }
            else if (e.Command == ApplicationCommands.Paste && SelectionLength == 0 && !IsReadOnly)
            {
                for (var attempt = 0; attempt < 5; attempt++)
                {
                    try
                    {
                        if (System.Windows.Clipboard.GetDataObject() is not { } data) break;
                        // A whole-line copy is never empty; empty text means another process is rewriting the clipboard.
                        if (data.GetData(DataFormats.UnicodeText) is not string { Length: > 0 } text)
                        {
                            if (data.GetDataPresent(WholeLineFormat)) { Thread.Sleep(20); continue; }
                            break;
                        }
                        var snapshot = new DataObject(DataFormats.UnicodeText, text);
                        if (data.GetDataPresent(WholeLineFormat)) snapshot.SetData(WholeLineFormat, true);
                        e.Handled = PasteWholeLine(snapshot);
                        break;
                    }
                    catch (COMException) { Thread.Sleep(10); }
                }
            }
        });
    }

    /// <summary>The caret line with a line ending, marked as a whole line.</summary>
    internal DataObject CopyWholeLine()
    {
        var line = Document.GetLineByNumber(TextArea.Caret.Line);
        var text = Document.GetText(line.Offset, line.Length) + "\r\n";
        var data = new DataObject(DataFormats.UnicodeText, text);
        data.SetData(WholeLineFormat, new System.IO.MemoryStream([1]));
        lastWholeLine = text;
        return data;
    }

    /// <summary>Deletes the caret line with its line break (the preceding one for the last line), keeping the caret's column where it fits.</summary>
    internal void RemoveCaretLine()
    {
        var line = Document.GetLineByNumber(TextArea.Caret.Line);
        var column = TextArea.Caret.Column;
        var start = line.Offset; var end = line.EndOffset + line.DelimiterLength;
        if (line.DelimiterLength == 0 && line.PreviousLine is { } previous) start = previous.EndOffset;
        Document.Remove(start, end - start);
        // The caret now sits on the following line, or on the previous one when the last line was removed.
        var target = Document.GetLineByOffset(start);
        CaretOffset = target.Offset + Math.Min(column - 1, target.Length);
    }

    /// <summary>Inserts a whole-line copy at the start of the caret line; false when the data is not a whole line.</summary>
    internal bool PasteWholeLine(IDataObject data)
    {
        if (data.GetData(DataFormats.UnicodeText) is not string { Length: > 0 } text || text.Length > MaximumCharacters * 2) return false;
        if (!data.GetDataPresent(WholeLineFormat) && !SameText(text, lastWholeLine)) return false;
        var newline = TextUtilities.GetNewLineFromDocument(Document, TextArea.Caret.Line);
        text = TextUtilities.NormalizeNewLines(Calc.Core.TableSyntax.TryNormalizePaste(text), newline);
        if (!text.EndsWith(newline, StringComparison.Ordinal)) text += newline;
        if (Document.TextLength + text.Length > MaximumCharacters) return true; // Refused like any oversized paste.
        Document.Insert(Document.GetLineByNumber(TextArea.Caret.Line).Offset, text);
        ScrollTo(TextArea.Caret.Line, TextArea.Caret.Column);
        return true;
    }
    private static bool SameText(string text, string? line) =>
        line is not null && TextUtilities.NormalizeNewLines(text, "\n") == TextUtilities.NormalizeNewLines(line, "\n");
}
