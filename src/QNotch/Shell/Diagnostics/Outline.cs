using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace QNotch.Shell.Diagnostics;

/// <summary>
/// The outline of a view (spec/diagnostics.md, Outline format): visible controls with role, name, id, value and state, nested by
/// containment, plus their text. What an agent reads instead of a screenshot.
/// </summary>
internal static class Outline
{
    /// <summary>Outline of <paramref name="root"/>; elements entirely outside <paramref name="crop"/> (root DIPs) are left out.</summary>
    public static string Of(FrameworkElement root, Rect? crop = null)
    {
        var sb = new StringBuilder();
        var styles = Application.Current;
        Style? Find(string key) => styles?.TryFindResource(key) as Style;
        Style? tab = Find("TabButton"), nav = Find("NavButton");
        Walk(root, 0, crop ?? new Rect(0, 0, root.ActualWidth, root.ActualHeight), null);
        return sb.ToString();

        void Walk(DependencyObject o, int depth, Rect clip, string? title)
        {
            if (o is UIElement ui)
            {
                if (ui.Visibility != Visibility.Visible || ui.Opacity <= 0 || o is ScrollBar) return;
                if (o is FrameworkElement fe && fe != root)
                {
                    if (fe.ActualWidth <= 0 || fe.ActualHeight <= 0) return;
                    if (Bounds(fe) is not { } b || !b.IntersectsWith(clip)) return;
                    if (o is ScrollContentPresenter) clip = Rect.Intersect(clip, b);
                }
            }
            var line = Line(o);
            if (line is var (role, value, states))
            {
                var c = (FrameworkElement)o;
                var name = Name(c);
                sb.Append(' ', depth * 2).Append('[').Append(role).Append(']');
                if (name is not null) sb.Append(' ').Append(Quote(name));
                if (AutomationProperties.GetAutomationId(c) is { Length: > 0 } id) sb.Append(" #").Append(id);
                if (value is not null) sb.Append(' ').Append(value);
                foreach (var s in states) sb.Append(' ').Append(s);
                sb.Append('\n');
                if (role is "Field" or "SecureField" or "Slider" or "Progress" or "PopUp") return;
                depth++;
                title = name;
            }
            else if (o is TextBlock or TextBox)
            {
                var text = o is TextBlock t ? t.Text : ((TextBox)o).Text; // a read-only box is text
                if (!Glyphs(text) && text != title) sb.Append(' ', depth * 2).Append(Quote(text)).Append('\n');
                return;
            }
            for (int i = 0, n = VisualTreeHelper.GetChildrenCount(o); i < n; i++) Walk(VisualTreeHelper.GetChild(o, i), depth, clip, title);
        }

        Rect? Bounds(FrameworkElement fe)
        {
            try { return fe.TransformToAncestor(root).TransformBounds(new Rect(fe.RenderSize)); }
            catch (InvalidOperationException) { return null; }
        }

        (string Role, string? Value, List<string> States)? Line(DependencyObject o)
        {
            var states = new List<string>();
            string role;
            string? value = null;
            switch (o)
            {
                case PasswordBox: role = "SecureField"; break;
                case Modules.IExclusiveKeyboardInput input: role = "Field"; value = $"value={Quote(input.Text)}"; break;
                case TextBox { IsReadOnly: false } box: role = "Field"; value = $"value={Quote(box.Text)}"; break;
                case ComboBox combo: role = "PopUp"; value = $"value={Quote(combo.Text is { Length: > 0 } ct ? ct : combo.SelectionBoxItem as string ?? "")}"; break;
                case ProgressBar p: role = "Progress"; value = Range(p); break;
                case RangeBase r: role = "Slider"; value = Range(r); break;
                case CardResizeHandle handle:
                    role = "Slider";
                    value = $"{handle.Columns} of {handle.MaximumColumns}";
                    break;
                case RadioButton rb when rb.Style == tab || rb.Style == nav:
                    role = rb.Style == tab ? "Tab" : "Item";
                    if (rb.IsChecked == true) states.Add("selected");
                    break;
                case ToggleButton tb: role = "Toggle"; if (tb.IsChecked == true) states.Add("checked"); break;
                case ButtonBase: role = "Button"; break;
                case TabItem ti: role = "Tab"; if (ti.IsSelected) states.Add("selected"); break;
                case ListBoxItem li: role = "Item"; if (li.IsSelected) states.Add("selected"); break;
                case TreeViewItem tv: role = "Item"; if (tv.IsSelected) states.Add("selected"); break;
                default: return null;
            }
            var c = (UIElement)o;
            if (c.IsKeyboardFocused) states.Add("focused");
            if (!c.IsEnabled) states.Add("disabled");
            return (role, value, states);
        }
    }

    /// <summary>The accessible name, else the visible title (string content or the first text inside), else the tooltip.</summary>
    static string? Name(FrameworkElement c)
    {
        if (AutomationProperties.GetName(c) is { Length: > 0 } n) return n;
        if (c is ContentControl { Content: string s } && !Glyphs(s)) return s.Replace("_", "");
        if (c is not TextBoxBase and not PasswordBox and not RangeBase and not ComboBox && FirstText(c) is { } t) return t;
        return c.ToolTip as string is { Length: > 0 } tip ? tip : null;
    }

    static string? FirstText(DependencyObject o)
    {
        for (int i = 0, n = VisualTreeHelper.GetChildrenCount(o); i < n; i++)
        {
            var child = VisualTreeHelper.GetChild(o, i);
            if (child is UIElement { Visibility: not Visibility.Visible }) continue;
            if (child is TextBlock t) { if (!Glyphs(t.Text)) return t.Text; continue; }
            if (FirstText(child) is { } found) return found;
        }
        return null;
    }

    /// <summary>Empty text and icon-font glyphs (Private Use Area) are not text lines.</summary>
    static bool Glyphs(string text) => string.IsNullOrWhiteSpace(text) || text.All(c => c is >= '' and <= '' || char.IsWhiteSpace(c));

    static string Range(RangeBase r)
    {
        double min = Math.Min(0, r.Minimum); // a negative minimum shifts both ends, so the numbers stay unsigned
        static string F(double v) => Math.Round(v, 2).ToString("0.##", CultureInfo.InvariantCulture);
        return $"{F(r.Value - min)} of {F(r.Maximum - min)}";
    }

    /// <summary>Quotes <paramref name="s"/>: backslash, quote, line break and tab escaped.</summary>
    public static string Quote(string s)
    {
        var sb = new StringBuilder(s.Length + 2).Append('"');
        foreach (var c in s)
            sb.Append(c switch { '\\' => @"\\", '"' => "\\\"", '\n' => @"\n", '\t' => @"\t", '\r' => "", _ => c.ToString() });
        return sb.Append('"').ToString();
    }
}
