using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using QNotch.Theme;

namespace QNotch.Modules.Media;

/// <summary>Pill, glance and game bar views of the Media module. Built in code: no XAML parse on the cold start path.</summary>
internal static class MediaSegments
{
    const string NoteGlyph = "";

    /// <summary>Pill, left cluster: artwork tile, title, artist. Collapsed without a session.</summary>
    public static FrameworkElement Pill(MediaState m)
    {
        var glyph = UiKit.Glyph(NoteGlyph, 11);
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var placeholder = new Border { CornerRadius = new CornerRadius(6), Child = glyph };
        placeholder.SetResourceReference(Border.BackgroundProperty, "ControlHoverBrush");
        var art = new ImageBrush { Stretch = Stretch.UniformToFill };
        UiKit.Bind(art, ImageBrush.ImageSourceProperty, m, nameof(MediaState.Artwork));
        var tile = new Grid { Width = 22, Height = 22 };
        tile.Children.Add(placeholder);
        tile.Children.Add(new Border { CornerRadius = new CornerRadius(6), Background = art });

        var title = new TextBlock { FontWeight = FontWeights.SemiBold, MaxWidth = 120, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        UiKit.Bind(title, TextBlock.TextProperty, m, nameof(MediaState.Title));
        var artist = new TextBlock { MaxWidth = 80, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        artist.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        UiKit.Bind(artist, TextBlock.TextProperty, m, nameof(MediaState.Artist));

        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(tile);
        p.Children.Add(title);
        p.Children.Add(artist);
        return UiKit.BindVisible(p, m, nameof(MediaState.HasSession));
    }

    /// <summary>Glance strip: accent note glyph and "Title  ·  Artist" while something plays.</summary>
    public static FrameworkElement Glance(MediaState m)
    {
        var glyph = UiKit.Glyph(NoteGlyph, 11, "AccentBrush");
        glyph.VerticalAlignment = VerticalAlignment.Center;
        glyph.Margin = new Thickness(0, 0, 7, 0);
        var text = new TextBlock { FontSize = 11, MaxWidth = 340, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        UiKit.Bind(text, TextBlock.TextProperty, m, nameof(MediaState.NowPlayingText));
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(glyph);
        p.Children.Add(text);
        return UiKit.BindVisible(p, m, nameof(MediaState.IsNowPlaying));
    }

    /// <summary>Game bar: the same text line, no artwork. Font size comes from the bar.</summary>
    public static FrameworkElement Game(MediaState m)
    {
        var t = new TextBlock { FontWeight = FontWeights.SemiBold, MaxWidth = 260, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        UiKit.Bind(t, TextBlock.TextProperty, m, nameof(MediaState.NowPlayingText));
        return UiKit.BindVisible(t, m, nameof(MediaState.IsNowPlaying));
    }
}
