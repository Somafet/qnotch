using System.Globalization;
using System.Text;

namespace QNotch.Modules.Terminal;

/// <summary>Bounded VT screen and scrollback. Consumes streaming UTF-8 decoded text; no I/O or WPF dependency.</summary>
internal sealed class TerminalBuffer
{
    internal const uint DefaultColor = uint.MaxValue;
    internal const int HistoryLimit = 500;
    internal readonly record struct Cell(string Text, uint Foreground, uint Background, bool Bold, bool Inverse = false);
    internal sealed record Frame(Cell[][] Lines, int CursorX, int CursorY, bool CursorVisible, int HistoryCount);
    readonly object _gate = new();
    readonly Queue<Cell[]> _history = new();
    readonly StringBuilder _sequence = new(64);
    Cell[][] _screen;
    Cell[][]? _normal;
    int _x, _y, _savedX, _savedY, _normalX, _normalY, _top, _bottom, _parse;
    bool _wrap, _autoWrap = true, _inverse, _bold, _insert;
    uint _fg = DefaultColor, _bg = DefaultColor;
    internal int Columns { get; private set; }
    internal int Rows { get; private set; }
    internal bool CursorVisible { get; private set; } = true;
    internal bool ApplicationCursor { get; private set; }
    internal bool BracketedPaste { get; private set; }
    Cell Blank => new(" ", _fg, _bg, false, _inverse);

    internal TerminalBuffer(int columns = 80, int rows = 16)
    {
        Columns = Math.Clamp(columns, 20, 240); Rows = Math.Clamp(rows, 2, 100);
        _bottom = Rows - 1;
        _screen = Screen();
    }
    Cell[] Line() => Enumerable.Repeat(Blank, Columns).ToArray();
    Cell[][] Screen() => Enumerable.Range(0, Rows).Select(_ => Line()).ToArray();

    internal void Resize(int columns, int rows)
    {
        lock (_gate)
        {
            columns = Math.Clamp(columns, 20, 240); rows = Math.Clamp(rows, 2, 100);
            if (columns == Columns && rows == Rows) return;
            Columns = columns; Rows = rows;
            Cell[][] Fit(Cell[][] old)
            {
                var next = Screen();
                for (var i = 0; i < Math.Min(rows, old.Length); i++) Array.Copy(old[i], next[i], Math.Min(columns, old[i].Length));
                return next;
            }
            _screen = Fit(_screen);
            if (_normal is not null) _normal = Fit(_normal);
            _x = Math.Clamp(_x, 0, Columns - 1); _y = Math.Clamp(_y, 0, Rows - 1);
            _top = 0; _bottom = Rows - 1; _wrap = false;
        }
    }

    internal Frame Capture(int scroll = 0)
    {
        lock (_gate)
        {
            var history = _normal is null ? _history.ToArray() : [];
            var offset = Math.Clamp(scroll, 0, history.Length);
            var all = history.Concat(_screen).ToArray();
            return new Frame(all.Skip(history.Length - offset).Take(Rows).Select(l => l.ToArray()).ToArray(), _x, _y + offset,
                CursorVisible && offset == 0, history.Length);
        }
    }

    internal void Feed(string text, Action<string>? reply = null)
    {
        lock (_gate)
            foreach (var rune in text.EnumerateRunes())
            {
                var c = rune.Value;
                switch (_parse)
                {
                    case 1:
                        _parse = 0;
                        switch (c)
                        {
                            case '[': _sequence.Clear(); _parse = 2; break;
                            case ']': case 'P': case '^': case '_': _parse = 3; break;
                            case '(': case ')': _parse = 5; break;
                            case '7': _savedX = _x; _savedY = _y; break;
                            case '8': Cursor(_savedX, _savedY); break;
                            case 'D': Down(); break;
                            case 'E': _x = 0; Down(); break;
                            case 'M': if (_y == _top) Scroll(-1); else _y = Math.Max(0, _y - 1); break;
                            case 'c': Reset(); break;
                        }
                        continue;
                    case 2:
                        if (c is >= 0x40 and <= 0x7e) { Csi((char)c, _sequence.ToString(), reply); _parse = 0; }
                        else if (c == 27) _parse = 1;
                        else if (_sequence.Length < 128 && c < 128) _sequence.Append((char)c);
                        continue;
                    case 3: if (c == 7) _parse = 0; else if (c == 27) _parse = 4; continue;
                    case 4: _parse = c == '\\' ? 0 : 3; continue;
                    case 5: _parse = 0; continue;
                }
                switch (c)
                {
                    case 27: _parse = 1; break;
                    case '\r': _x = 0; _wrap = false; break;
                    case '\n': _wrap = false; Down(); break;
                    case '\b': _x = Math.Max(0, _x - 1); _wrap = false; break;
                    case '\t': _x = Math.Min(Columns - 1, (_x / 8 + 1) * 8); _wrap = false; break;
                    default: if (c >= 32 && c != 127) Put(rune); break;
                }
            }
    }

    void Put(Rune rune)
    {
        if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark)
        {
            var at = Math.Max(0, _wrap ? _x : _x - 1);
            var cell = _screen[_y][at];
            if (cell.Text.Length < 16) _screen[_y][at] = cell with { Text = cell.Text + rune };
            return;
        }
        if (_wrap && _autoWrap) { _x = 0; Down(); }
        _wrap = false;
        var wide = IsWide(rune.Value);
        if (wide && _x == Columns - 1 && _autoWrap) { _x = 0; Down(); }
        if (_insert) Array.Copy(_screen[_y], _x, _screen[_y], _x + 1, Columns - _x - 1);
        _screen[_y][_x] = new(rune.ToString(), _fg, _bg, _bold, _inverse);
        if (wide && _x + 1 < Columns) _screen[_y][++_x] = new("", _fg, _bg, _bold, _inverse);
        if (_x == Columns - 1) _wrap = true; else _x++;
    }
    static bool IsWide(int c) => c is >= 0x1100 and <= 0x115f or >= 0x2e80 and <= 0xa4cf or >= 0xac00 and <= 0xd7a3
        or >= 0xf900 and <= 0xfaff or >= 0xfe10 and <= 0xfe6f or >= 0xff00 and <= 0xff60 or >= 0x1f300 and <= 0x1faff or >= 0x20000 and <= 0x3ffff;
    void Cursor(int x, int y) { _x = Math.Clamp(x, 0, Columns - 1); _y = Math.Clamp(y, 0, Rows - 1); _wrap = false; }
    void Down() { if (_y == _bottom) Scroll(1); else _y = Math.Min(Rows - 1, _y + 1); }
    void Scroll(int count)
    {
        for (var n = 0; n < Math.Min(Math.Abs(count), _bottom - _top + 1); n++)
        {
            if (count > 0)
            {
                if (_top == 0 && _bottom == Rows - 1 && _normal is null)
                {
                    _history.Enqueue(_screen[0]);
                    if (_history.Count > HistoryLimit) _history.Dequeue();
                }
                for (var i = _top; i < _bottom; i++) _screen[i] = _screen[i + 1];
                _screen[_bottom] = Line();
            }
            else
            {
                for (var i = _bottom; i > _top; i--) _screen[i] = _screen[i - 1];
                _screen[_top] = Line();
            }
        }
    }
    void Erase(int row, int from, int to) => Array.Fill(_screen[row], Blank, Math.Clamp(from, 0, Columns), Math.Max(0, Math.Min(to, Columns) - Math.Clamp(from, 0, Columns)));
    void Reset()
    {
        _fg = _bg = DefaultColor; _bold = _inverse = _insert = false; _autoWrap = CursorVisible = true;
        ApplicationCursor = BracketedPaste = false; _normal = null; _history.Clear(); _screen = Screen();
        _top = 0; _bottom = Rows - 1; Cursor(0, 0);
    }

    void Csi(char command, string raw, Action<string>? reply)
    {
        var privateMode = raw.StartsWith('?');
        var parts = raw.TrimStart('?', '>').Split(';');
        var p = parts.Select(s => int.TryParse(s.Trim(), out var v) ? Math.Clamp(v, 0, 32767) : 0).ToArray();
        int N(int i = 0, int fallback = 1) => i >= p.Length || p[i] == 0 ? fallback : p[i];
        if (command != 'm') _wrap = false;
        switch (command)
        {
            case 'A': Cursor(_x, _y - N()); break;
            case 'B': case 'e': Cursor(_x, _y + N()); break;
            case 'C': case 'a': Cursor(_x + N(), _y); break;
            case 'D': Cursor(_x - N(), _y); break;
            case 'E': Cursor(0, _y + N()); break;
            case 'F': Cursor(0, _y - N()); break;
            case 'G': case '`': Cursor(N() - 1, _y); break;
            case 'd': Cursor(_x, N() - 1); break;
            case 'H': case 'f': Cursor(N(1) - 1, N() - 1); break;
            case 's': _savedX = _x; _savedY = _y; break;
            case 'u': Cursor(_savedX, _savedY); break;
            case 'J':
                if (p[0] is 2 or 3) { for (var row = 0; row < Rows; row++) Erase(row, 0, Columns); if (p[0] == 3) _history.Clear(); }
                else if (p[0] == 0) { Erase(_y, _x, Columns); for (var row = _y + 1; row < Rows; row++) Erase(row, 0, Columns); }
                else if (p[0] == 1) { Erase(_y, 0, _x + 1); for (var row = 0; row < _y; row++) Erase(row, 0, Columns); }
                break;
            case 'K': Erase(_y, p[0] == 0 ? _x : 0, p[0] == 1 ? _x + 1 : Columns); break;
            case 'X': Erase(_y, _x, _x + N()); break;
            case 'P': { var n = Math.Min(N(), Columns - _x); Array.Copy(_screen[_y], _x + n, _screen[_y], _x, Columns - _x - n); Erase(_y, Columns - n, Columns); break; }
            case '@': { var n = Math.Min(N(), Columns - _x); Array.Copy(_screen[_y], _x, _screen[_y], _x + n, Columns - _x - n); Erase(_y, _x, _x + n); break; }
            case 'L': case 'M':
                if (_y >= _top && _y <= _bottom) { var top = _top; _top = _y; Scroll(command == 'L' ? -N() : N()); _top = top; }
                break;
            case 'S': Scroll(N()); break;
            case 'T': Scroll(-N()); break;
            case 'r':
                var first = N() - 1; var last = N(1, Rows) - 1;
                if (first < last && first >= 0 && last < Rows) { _top = first; _bottom = last; Cursor(0, 0); }
                break;
            case 'm': Sgr(p); break;
            case 'n': if (p[0] == 6) reply?.Invoke($"\u001b[{_y + 1};{_x + 1}R"); else if (p[0] == 5) reply?.Invoke("\u001b[0n"); break;
            case 'c': reply?.Invoke(raw.StartsWith('>') ? "\u001b[>0;1;0c" : "\u001b[?1;2c"); break;
            case 'h': case 'l':
                foreach (var mode in p)
                {
                    var on = command == 'h';
                    if (!privateMode) { if (mode == 4) _insert = on; continue; }
                    switch (mode)
                    {
                        case 1: ApplicationCursor = on; break;
                        case 7: _autoWrap = on; break;
                        case 25: CursorVisible = on; break;
                        case 2004: BracketedPaste = on; break;
                        case 1047: case 1049:
                            if (on && _normal is null) { _normal = _screen; _normalX = _x; _normalY = _y; _screen = Screen(); Cursor(0, 0); }
                            else if (!on && _normal is not null) { _screen = _normal; _normal = null; Cursor(_normalX, _normalY); }
                            _top = 0; _bottom = Rows - 1;
                            break;
                    }
                }
                break;
        }
    }
    void Sgr(int[] p)
    {
        for (var i = 0; i < p.Length; i++)
        {
            var n = p[i];
            if (n == 0) { _fg = _bg = DefaultColor; _bold = _inverse = false; }
            else if (n is 1 or 22) _bold = n == 1;
            else if (n is 7 or 27) _inverse = n == 7;
            else if (n == 39) _fg = DefaultColor;
            else if (n == 49) _bg = DefaultColor;
            else if (n is >= 30 and <= 37) _fg = Color(n - 30);
            else if (n is >= 40 and <= 47) _bg = Color(n - 40);
            else if (n is >= 90 and <= 97) _fg = Color(n - 90 + 8);
            else if (n is >= 100 and <= 107) _bg = Color(n - 100 + 8);
            else if (n is 38 or 48)
            {
                uint color;
                if (i + 2 < p.Length && p[i + 1] == 5) { color = Color(p[i + 2]); i += 2; }
                else if (i + 4 < p.Length && p[i + 1] == 2) { color = (uint)(Math.Min(p[i + 2], 255) << 16 | Math.Min(p[i + 3], 255) << 8 | Math.Min(p[i + 4], 255)); i += 4; }
                else continue;
                if (n == 38) _fg = color; else _bg = color;
            }
        }
    }
    static uint Color(int index)
    {
        index = Math.Clamp(index, 0, 255);
        if (index < 16) return Palette[index];
        if (index >= 232) { var gray = (uint)(8 + (index - 232) * 10); return gray << 16 | gray << 8 | gray; }
        index -= 16;
        uint Component(int value) => (uint)(value == 0 ? 0 : value * 40 + 55);
        return Component(index / 36) << 16 | Component(index / 6 % 6) << 8 | Component(index % 6);
    }
    static readonly uint[] Palette = [0x0c0c0c, 0xc50f1f, 0x13a10e, 0xc19c00, 0x0037da, 0x881798, 0x3a96dd, 0xcccccc,
        0x767676, 0xe74856, 0x16c60c, 0xf9f1a5, 0x3b78ff, 0xb4009e, 0x61d6d6, 0xf2f2f2];
}
