using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace QNotch.Modules.Terminal;

/// <summary>One event-driven drawing surface. No cursor blink, cell controls, render loop or hidden rendering.</summary>
internal sealed class TerminalSurface : FrameworkElement, IExclusiveKeyboardInput
{
    const double FontSize = 12, CellWidth = 7.2, CellHeight = 17;
    readonly TerminalBuffer _buffer;
    readonly Action<string> _send, _status;
    readonly Action<int, int> _resize;
    readonly Action _takeKeyboard;
    readonly Typeface _font = new(new FontFamily("Cascadia Mono, Consolas"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    readonly Dictionary<uint, Brush> _brushes = new();
    volatile bool _visible;
    int _queued, _scroll;

    internal TerminalSurface(TerminalBuffer buffer, Action<string> send, Action<int, int> resize, Action takeKeyboard, Action<string> status)
    {
        _buffer = buffer; _send = send; _resize = resize; _takeKeyboard = takeKeyboard; _status = status;
        Focusable = true; ClipToBounds = true;
        AutomationProperties.SetName(this, "Terminal input and output");
        AutomationProperties.SetAutomationId(this, "terminal-input");
        IsVisibleChanged += (_, _) => { _visible = IsVisible; if (_visible) { UpdateSize(); InvalidateVisual(); } };
        SizeChanged += (_, _) => { if (IsVisible) UpdateSize(); };
        GotKeyboardFocus += (_, _) => InvalidateVisual();
        LostKeyboardFocus += (_, _) => InvalidateVisual();
        PreviewMouseLeftButtonDown += (_, e) => { _takeKeyboard(); Focus(); e.Handled = true; };
        PreviewMouseWheel += (_, e) => { _scroll = Math.Clamp(_scroll + Math.Sign(e.Delta) * 3, 0, _buffer.Capture().HistoryCount); InvalidateVisual(); e.Handled = true; };
        PreviewKeyDown += KeyDownInput;
        TextInput += (_, e) => { if (e.Text.Length > 0) { Send(e.Text); e.Handled = true; } };
        InputMethod.SetIsInputMethodEnabled(this, true);
    }

    void UpdateSize()
    {
        var columns = Math.Clamp((int)((ActualWidth - 12) / CellWidth), 20, 240);
        var rows = Math.Clamp((int)((ActualHeight - 8) / CellHeight), 2, 100);
        _buffer.Resize(columns, rows);
        _resize(columns, rows);
    }
    void Send(string text) { _scroll = 0; _send(text); }
    public string Text => string.Join(Environment.NewLine, _buffer.Capture(_scroll).Lines.Select(l => string.Concat(l.Select(c => c.Text)).TrimEnd()));
    public void InsertText(string text) => Send(text);

    void KeyDownInput(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;
        if (mods.HasFlag(ModifierKeys.Control) && !mods.HasFlag(ModifierKeys.Alt) && mods.HasFlag(ModifierKeys.Shift) && key == Key.C)
        {
            try { System.Windows.Clipboard.SetText(string.Join(Environment.NewLine, _buffer.Capture(_scroll).Lines.Select(l => string.Concat(l.Select(c => c.Text)).TrimEnd()))); }
            catch (Exception ex) { _status("Copy unavailable: " + ex.Message); }
            e.Handled = true; return;
        }
        if ((mods.HasFlag(ModifierKeys.Control) && !mods.HasFlag(ModifierKeys.Alt) && key == Key.V) || (mods == ModifierKeys.Shift && key == Key.Insert))
        {
            try
            {
                if (System.Windows.Clipboard.ContainsText())
                {
                    var text = System.Windows.Clipboard.GetText();
                    if (text.Length > 16000) _status("Paste is limited to 16,000 characters.");
                    else
                    {
                        text = text.Replace("\r\n", "\r").Replace('\n', '\r').Replace("\u001b", "");
                        Send(_buffer.BracketedPaste ? "\u001b[200~" + text + "\u001b[201~" : text);
                    }
                }
            }
            catch (Exception ex) { _status("Paste unavailable: " + ex.Message); }
            e.Handled = true; return;
        }
        if (mods == ModifierKeys.Shift && key is Key.PageUp or Key.PageDown)
        {
            _scroll = Math.Clamp(_scroll + (key == Key.PageUp ? _buffer.Rows : -_buffer.Rows), 0, _buffer.Capture().HistoryCount);
            InvalidateVisual(); e.Handled = true; return;
        }
        if (TerminalInput.KeyText(key, mods, _buffer.ApplicationCursor) is { } input) { Send(input); e.Handled = true; }
        // Printable keys reach TextInput, including the current Windows keyboard layout and composed Unicode text.
    }

    internal void OutputChanged()
    {
        if (!_visible || Interlocked.Exchange(ref _queued, 1) != 0) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () => { Interlocked.Exchange(ref _queued, 0); if (IsVisible) InvalidateVisual(); });
    }

    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        drawing.DrawRectangle((Brush)FindResource("SurfaceRaisedBrush"), null, new Rect(RenderSize));
        var frame = _buffer.Capture(_scroll);
        var foreground = (Brush)FindResource("TextPrimaryBrush");
        var background = (Brush)FindResource("SurfaceRaisedBrush");
        Brush Color(uint rgb, Brush fallback)
        {
            if (rgb == TerminalBuffer.DefaultColor) return fallback;
            if (_brushes.TryGetValue(rgb, out var found)) return found;
            if (_brushes.Count >= 256) _brushes.Clear();
            var brush = new SolidColorBrush(System.Windows.Media.Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
            brush.Freeze(); _brushes[rgb] = brush; return brush;
        }
        for (var y = 0; y < frame.Lines.Length; y++)
        {
            var line = frame.Lines[y];
            for (var x = 0; x < Math.Min(line.Length, _buffer.Columns); x++)
            {
                var cell = line[x];
                var point = new Point(6 + x * CellWidth, 4 + y * CellHeight);
                var fg = Color(cell.Foreground, foreground);
                var bg = Color(cell.Background, background);
                if (cell.Inverse) (fg, bg) = (bg, fg);
                if (cell.Background != TerminalBuffer.DefaultColor || cell.Inverse)
                    drawing.DrawRectangle(bg, null, new Rect(point, new Size(CellWidth, CellHeight)));
                if (cell.Text is " " or "" or null) continue;
                var font = cell.Bold ? new Typeface(_font.FontFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal) : _font;
                var text = new FormattedText(cell.Text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, font, FontSize, fg, VisualTreeHelper.GetDpi(this).PixelsPerDip);
                drawing.DrawText(text, point);
            }
        }
        if (frame.CursorVisible && IsKeyboardFocused)
            drawing.DrawRectangle((Brush)FindResource("AccentBrush"), null, new Rect(6 + frame.CursorX * CellWidth, 4 + (frame.CursorY + 1) * CellHeight - 2, CellWidth, 2));
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new TerminalPeer(this);
    sealed class TerminalPeer(TerminalSurface owner) : FrameworkElementAutomationPeer(owner), IValueProvider
    {
        protected override string GetClassNameCore() => "Terminal";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Edit;
        protected override string GetHelpTextCore() => "Interactive terminal. Ctrl+C interrupts. Ctrl+V pastes. Ctrl+Shift+C copies the visible screen. Shift+PageUp scrolls history. The panel shortcut closes the panel.";
        public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.Value ? this : base.GetPattern(pattern);
        public string Value => owner.Text;
        public bool IsReadOnly => true;
        public void SetValue(string value) => throw new InvalidOperationException("Use terminal keyboard input.");
    }
}
