using System.Windows.Input;

namespace QNotch.Modules.Terminal;

internal static class TerminalInput
{
    internal static string? KeyText(Key key, ModifierKeys modifiers, bool applicationCursor)
    {
        var ctrl = modifiers.HasFlag(ModifierKeys.Control);
        var alt = modifiers.HasFlag(ModifierKeys.Alt);
        var shift = modifiers.HasFlag(ModifierKeys.Shift);
        // Windows reports AltGr as Ctrl+Alt. Leave printable/composed input to TextInput for the active layout.
        if (ctrl && !alt && key >= Key.A && key <= Key.Z) return ((char)(key - Key.A + 1)).ToString();
        if (ctrl && !alt && key == Key.Space) return "\0";
        if (ctrl && !alt && key == Key.OemOpenBrackets) return "\u001b";
        if (ctrl && !alt && key == Key.OemBackslash) return "\u001c";
        if (ctrl && !alt && key == Key.OemCloseBrackets) return "\u001d";
        var mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
        string Cursor(char final) => mod > 1 ? $"\u001b[1;{mod}{final}" : "\u001b" + (applicationCursor ? "O" : "[") + final;
        string Number(int n) => mod > 1 ? $"\u001b[{n};{mod}~" : $"\u001b[{n}~";
        var value = key switch
        {
            Key.Up => Cursor('A'), Key.Down => Cursor('B'), Key.Right => Cursor('C'), Key.Left => Cursor('D'),
            Key.Home => Cursor('H'), Key.End => Cursor('F'), Key.Insert => Number(2), Key.Delete => Number(3),
            Key.PageUp => Number(5), Key.PageDown => Number(6), Key.Enter => "\r", Key.Back => ctrl ? "\u0017" : "\u007f",
            Key.Tab => shift ? "\u001b[Z" : "\t", Key.Escape => "\u001b",
            Key.F1 => "\u001bOP", Key.F2 => "\u001bOQ", Key.F3 => "\u001bOR", Key.F4 => "\u001bOS",
            Key.F5 => Number(15), Key.F6 => Number(17), Key.F7 => Number(18), Key.F8 => Number(19),
            Key.F9 => Number(20), Key.F10 => Number(21), Key.F11 => Number(23), Key.F12 => Number(24), _ => null,
        };
        return alt && value is { Length: 1 } ? "\u001b" + value : value;
    }
}
