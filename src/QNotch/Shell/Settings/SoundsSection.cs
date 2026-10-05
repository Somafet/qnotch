using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

/// <summary>Settings page: every sound the shell and the modules declared in <see cref="Sounds"/>, each with a file picker and a drop target.</summary>
public static class SoundsSection
{
    static readonly string[] Audio = [".wav", ".mp3", ".wma", ".m4a", ".aac", ".flac"];

    public static FrameworkElement Create(Sounds sounds)
    {
        var page = UiKit.Page("Sounds");
        var intro = UiKit.Text("Each sound is one of your Windows sounds until you choose a file or drop one on its row. Turn sounds on or off on each feature's page.");
        intro.Margin = new Thickness(0, -6, 0, 16);
        page.Children.Add(intro);
        foreach (var s in sounds.Items) page.Children.Add(Row(sounds, s));
        if (sounds.Items.Count == 0) page.Children.Add(UiKit.Text("No feature that plays a sound is on."));
        return page;
    }

    static FrameworkElement Row(Sounds sounds, Sound s)
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
        void Use(string file)
        {
            sounds.Set(s, file);
            Update();
            if (file.Length > 0) sounds.Play(s);
        }
        play.Click += (_, _) => sounds.Play(s);
        choose.Click += (_, _) =>
        {
            var dlg = new OpenFileDialog { Title = $"Choose a sound: {s.Title}", Filter = Sounds.Filter };
            if (dlg.ShowDialog(Window.GetWindow(choose)) == true) Use(dlg.FileName);
        };
        reset.Click += (_, _) => Use("");

        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(name);
        p.Children.Add(play);
        p.Children.Add(choose);
        p.Children.Add(reset);
        Update();

        // The whole row takes a dropped audio file. The border bleeds 8 DIPs out so the highlight has room without moving the content.
        var row = UiKit.Row(s.Title, s.Hint.Length > 0 ? s.Hint : null, p);
        row.Margin = new Thickness(0);
        var target = new Border { Child = row, CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(-8, -6, -8, 10), Background = Brushes.Transparent, AllowDrop = true };
        void Highlight(bool on)
        {
            if (on) target.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
            else target.Background = Brushes.Transparent;
        }
        target.DragEnter += (_, e) => Highlight(AudioFile(e) is not null);
        target.DragOver += (_, e) => { e.Effects = AudioFile(e) is not null ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        target.DragLeave += (_, _) => Highlight(false);
        target.Drop += (_, e) =>
        {
            Highlight(false);
            if (AudioFile(e) is { } file) Use(file);
            e.Handled = true;
        };
        return target;
    }

    /// <summary>The dragged file when it is exactly one audio file, otherwise null.</summary>
    static string? AudioFile(DragEventArgs e) =>
        e.Data.GetData(DataFormats.FileDrop) is string[] { Length: 1 } files && Audio.Contains(Path.GetExtension(files[0]).ToLowerInvariant()) ? files[0] : null;
}
