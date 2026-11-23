using System.IO;
using System.Windows;
using ICSharpCode.AvalonEdit.Editing;
using QNotch.Modules;

namespace Calc.Windows;

/// <summary>The sheet's focused element. Being exclusive input keeps module hotkeys from firing while the user types a calculation.</summary>
internal sealed class SheetTextArea : TextArea, IExclusiveKeyboardInput
{
    public string Text => Document?.Text ?? "";
    public void InsertText(string text) => Selection.ReplaceSelectionWithText(text);
}

/// <summary>Clipboard writes from the sheet. A debug-channel test run can send them to a file, so a test never touches the real clipboard.</summary>
internal static class SheetClipboard
{
    static readonly string? Sink = Environment.GetCommandLineArgs().Contains("--debug-control")
        ? Environment.GetEnvironmentVariable("QNOTCH_CALCULATOR_CLIPBOARD") : null;

    internal static void SetText(string text)
    {
        if (Sink is { } path) File.WriteAllText(path, text);
        else Clipboard.SetText(text);
    }

    internal static void SetDataObject(DataObject data)
    {
        if (Sink is { } path) File.WriteAllText(path, data.GetData(DataFormats.UnicodeText) as string ?? "[image]");
        else Clipboard.SetDataObject(data, true);
    }
}

/// <summary>Whether the sheet may animate: QNotch's reduce-motion setting together with the system's.</summary>
internal static class SheetMotion
{
    internal static bool Enabled => QNotch.Core.Motion.Enabled;
}
