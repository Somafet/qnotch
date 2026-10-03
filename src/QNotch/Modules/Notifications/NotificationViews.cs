using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using QNotch.Shell;
using QNotch.Theme;

namespace QNotch.Modules.Notifications;

/// <summary>Pill, glance and game bar views of the Notifications module. Built in code: no XAML parse on the cold start path.</summary>
internal static class NotificationSegments
{
    public static string LevelBrush(NoteLevel level) => level switch
    {
        NoteLevel.Success => "SuccessBrush", NoteLevel.Warning => "WarningBrush", NoteLevel.Error => "DangerBrush", _ => "AccentBrush",
    };

    /// <summary>Pill and game bar: bell and unread count. Collapsed while everything is read.</summary>
    public static FrameworkElement Unread(NotificationsState st)
    {
        var bell = UiKit.Glyph(NotifyIcons.Bell, 12, "AccentBrush");
        bell.VerticalAlignment = VerticalAlignment.Center;
        var count = new TextBlock { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(5, 0, 0, 0) };
        UiKit.Bind(count, TextBlock.TextProperty, st, nameof(NotificationsState.UnreadText));
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(bell);
        p.Children.Add(count);
        return UiKit.BindVisible(p, st, nameof(NotificationsState.HasUnread));
    }

    /// <summary>Glance strip: icon and "App: Title" of the current toast. Resting the pointer on it opens the panel on the Notifications tab.</summary>
    public static FrameworkElement Glance(NotificationsState st)
    {
        var image = new Image { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 7, 0) };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
        var glyph = UiKit.Glyph("", 11);
        glyph.VerticalAlignment = VerticalAlignment.Center;
        glyph.Margin = new Thickness(0, 0, 7, 0);
        var text = new TextBlock { FontSize = 11, MaxWidth = 340, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent };
        p.Children.Add(image);
        p.Children.Add(glyph);
        p.Children.Add(text);

        void Sync()
        {
            var n = st.Toast;
            p.Visibility = n is null ? Visibility.Collapsed : Visibility.Visible;
            if (n is null) { image.Source = null; return; }
            text.Text = $"{n.App}: {n.Title}";
            image.Source = n.Icon;
            image.Visibility = n.HasIcon ? Visibility.Visible : Visibility.Collapsed;
            glyph.Visibility = n.HasIcon ? Visibility.Collapsed : Visibility.Visible;
            glyph.Text = n.Glyph;
            glyph.SetResourceReference(TextBlock.ForegroundProperty, LevelBrush(n.Level));
        }
        st.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(NotificationsState.Toast)) Sync(); };
        Sync();
        return p;
    }
}

/// <summary>Home card body: the three newest notifications, one line each. A click opens the Notifications tab. Redraws only when the history changes.</summary>
internal sealed class NotificationsCard : Grid
{
    readonly NotificationsState _st;
    readonly IShell _shell;
    readonly StackPanel _rows = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly FrameworkElement _empty = Placeholder.Create(NotifyIcons.Bell, "", "No notifications.");

    public NotificationsCard(NotificationsState st, IShell shell)
    {
        _st = st;
        _shell = shell;
        Children.Add(_rows);
        Children.Add(_empty);
        st.Items.CollectionChanged += (_, _) => Refresh();
        // Read flags change the row weight; UnreadText changes exactly when they do.
        st.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(NotificationsState.UnreadText)) Refresh(); };
        Refresh();
    }

    void Refresh()
    {
        _rows.Children.Clear();
        foreach (var n in _st.Items.Take(3)) _rows.Children.Add(Row(n));
        _empty.Visibility = _st.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _rows.Visibility = _st.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    UIElement Row(Note n)
    {
        var line = new DockPanel();
        var g = UiKit.Glyph(n.Glyph, 12, NotificationSegments.LevelBrush(n.Level));
        g.Width = 14;
        g.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(g, Dock.Left);
        var t = new TextBlock { Text = n.Title, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        if (!n.Read) t.FontWeight = FontWeights.SemiBold;
        t.SetResourceReference(TextBlock.ForegroundProperty, n.Read ? "TextSecondaryBrush" : "TextPrimaryBrush");
        line.Children.Add(g);
        line.Children.Add(t);

        var b = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 4, 6, 4), Margin = new Thickness(-6, 0, -6, 1), Background = Brushes.Transparent, Cursor = Cursors.Hand, Child = line, ToolTip = $"{n.App}: {n.Title}" };
        b.MouseEnter += (_, _) => b.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        b.MouseLeave += (_, _) => b.Background = Brushes.Transparent;
        b.MouseLeftButtonUp += (_, _) => _shell.SelectTab(NotificationsModule.TabId);
        return b;
    }
}
