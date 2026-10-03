using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

/// <summary>Settings page: every shortcut the shell and the modules declared in <see cref="Shortcuts"/>, each with a recorder.</summary>
public static class HotkeysSection
{
    public static FrameworkElement Create(Shortcuts keys)
    {
        var page = UiKit.Page("Hotkeys");
        var intro = UiKit.Text("Click a box, then press the new shortcut. Esc cancels, Backspace turns the shortcut off.");
        intro.Margin = new Thickness(0, -6, 0, 16);
        page.Children.Add(intro);

        var refresh = new List<Action>();
        foreach (var s in keys.Items)
        {
            var (row, update) = Recorder(keys, s);
            page.Children.Add(UiKit.Row(s.Title, s.Hint.Length > 0 ? s.Hint : null, row));
            refresh.Add(update);
        }
        void Refresh() { foreach (var r in refresh) r(); }
        // Subscribe only while the page is in the tree: the settings window is recreated on every open.
        page.Loaded += (_, _) => { keys.Changed += Refresh; Refresh(); };
        page.Unloaded += (_, _) => { keys.Changed -= Refresh; keys.Suspended = false; };
        return page;
    }

    /// <summary>A read-only box that turns the next Ctrl/Alt chord into a gesture string. Global hotkeys are suspended while it has focus.</summary>
    static (FrameworkElement, Action) Recorder(Shortcuts keys, Shortcut s)
    {
        var box = new TextBox
        {
            Width = 150, IsReadOnly = true, IsReadOnlyCaretVisible = false, TextAlignment = TextAlignment.Center,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 12, Cursor = Cursors.Arrow, ToolTip = "Click, then press the new shortcut",
        };
        var note = new TextBlock { Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
        note.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
        var reset = new Button { Style = (Style)Application.Current.FindResource("IconButton"), Content = Glyphs.Refresh, Margin = new Thickness(4, 0, -6, 0) };
        string clash = ""; // "Used by ...": stays until the next attempt

        void Update()
        {
            if (!box.IsKeyboardFocused) box.Text = s.Gesture.Length > 0 ? s.Gesture : "None";
            note.Text = clash.Length > 0 ? clash : s.Taken ? "Taken by another app" : "";
            reset.ToolTip = $"Reset to {s.Default}";
            reset.Visibility = s.Gesture == s.Default ? Visibility.Hidden : Visibility.Visible;
        }
        void Set(string gesture)
        {
            clash = keys.Set(s, gesture) is { } other ? $"Used by {other.Title}" : "";
            Update();
        }

        reset.Click += (_, _) => Set(s.Default);
        box.GotKeyboardFocus += (_, _) => { keys.Suspended = true; clash = ""; box.Text = "Press shortcut"; };
        box.LostKeyboardFocus += (_, _) => { keys.Suspended = false; Update(); }; // re-registers and refreshes the "taken" notes
        box.PreviewKeyDown += (_, e) =>
        {
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key is Key.None or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin
                or Key.DeadCharProcessed or Key.ImeProcessed) return;
            var mods = Keyboard.Modifiers;
            if (mods == ModifierKeys.None && key is Key.Escape or Key.Back or Key.Delete)
            {
                if (key != Key.Escape) Set("");
                Keyboard.ClearFocus();
                return;
            }
            if ((mods & (ModifierKeys.Control | ModifierKeys.Alt)) == 0) { box.Text = "Add Ctrl or Alt"; return; }
            string gesture;
            try { gesture = new KeyGestureConverter().ConvertToInvariantString(new KeyGesture(key, mods)) ?? ""; }
            catch { box.Text = "Not supported"; return; }
            if (gesture.Length > 0 && gesture != s.Gesture) Set(gesture);
            Keyboard.ClearFocus();
        };

        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(note);
        p.Children.Add(box);
        p.Children.Add(reset);
        Update();
        return (p, Update);
    }
}
