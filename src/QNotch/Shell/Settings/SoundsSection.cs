using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

/// <summary>Settings page: every sound the shell and the modules declared in <see cref="Sounds"/>, each with a file picker.</summary>
public static class SoundsSection
{
    public static FrameworkElement Create(Sounds sounds)
    {
        var page = UiKit.Page("Sounds");
        var intro = UiKit.Text("Each sound is one of your Windows sounds until you choose a file. Turn sounds on or off on each feature's page.");
        intro.Margin = new Thickness(0, -6, 0, 16);
        page.Children.Add(intro);
        foreach (var s in sounds.Items) page.Children.Add(UiKit.Row(s.Title, s.Hint.Length > 0 ? s.Hint : null, Picker(sounds, s)));
        if (sounds.Items.Count == 0) page.Children.Add(UiKit.Text("No feature that plays a sound is on."));
        return page;
    }

    static FrameworkElement Picker(Sounds sounds, Sound s)
    {
        var icon = (Style)Application.Current.FindResource("IconButton");
        var name = new TextBlock
        {
            Style = (Style)Application.Current.FindResource("Muted"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0),
            MaxWidth = 160, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var play = new Button { Style = icon, Content = Glyphs.Play, ToolTip = "Play" };
        var choose = new Button { Content = "Choose...", Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(4, 0, 0, 0) };
        var reset = new Button { Style = icon, Content = Glyphs.Refresh, ToolTip = "Use the Windows sound", Margin = new Thickness(4, 0, -6, 0) };

        void Update()
        {
            name.Text = s.File.Length > 0 ? Path.GetFileName(s.File) : "Windows sound";
            name.ToolTip = s.File.Length > 0 ? s.File : null;
            reset.Visibility = s.File.Length > 0 ? Visibility.Visible : Visibility.Hidden;
        }
        play.Click += (_, _) => sounds.Play(s);
        choose.Click += (_, _) =>
        {
            var dlg = new OpenFileDialog { Title = $"Choose a sound: {s.Title}", Filter = Sounds.Filter };
            if (dlg.ShowDialog(Window.GetWindow(choose)) != true) return;
            sounds.Set(s, dlg.FileName);
            Update();
            sounds.Play(s);
        };
        reset.Click += (_, _) => { sounds.Set(s, ""); Update(); };

        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(name);
        p.Children.Add(play);
        p.Children.Add(choose);
        p.Children.Add(reset);
        Update();
        return p;
    }
}
