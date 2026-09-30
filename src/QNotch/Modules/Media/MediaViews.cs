using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Shell;
using QNotch.Theme;

namespace QNotch.Modules.Media;

/// <summary>Behaviour shared by the tab and the card: empty / unavailable switching, session picker, seek.</summary>
internal static class MediaViews
{
    /// <summary>Shows <paramref name="live"/> while a session exists, otherwise a placeholder: "nothing playing" (also while the first
    /// query is still running) or "unavailable" when the OS media API failed.</summary>
    public static void WireStates(MediaState m, UIElement live, ContentControl host, FrameworkElement nothing, FrameworkElement unavailable)
    {
        void Refresh()
        {
            live.Visibility = m.HasSession ? Visibility.Visible : Visibility.Collapsed;
            host.Visibility = m.HasSession ? Visibility.Collapsed : Visibility.Visible;
            host.Content = m.IsAvailable || !m.IsReady ? nothing : unavailable;
        }
        m.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MediaState.HasSession) or nameof(MediaState.IsAvailable) or nameof(MediaState.IsReady)) Refresh();
        };
        Refresh();
    }

    public static FrameworkElement Nothing(bool compact) => Placeholder.Create(Glyphs.Music, "Nothing playing",
        compact ? "Play something and it shows up here." : "Start music or a video in any app and it shows up here.");

    public static FrameworkElement Unavailable(bool compact) => Placeholder.Create(Glyphs.Warning, "Media controls unavailable",
        compact ? "Windows did not provide media sessions." : "Windows did not provide media sessions, so now playing cannot be shown.");

    /// <summary>Drop-down for choosing a session. Hidden unless more than one session exists. Holds the panel open while the list is showing.</summary>
    public static void WirePicker(ComboBox box, MediaState m, IShell shell)
    {
        var sync = false;
        IDisposable? hold = null;
        void Sync()
        {
            sync = true;
            try
            {
                box.Visibility = m.Sessions.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
                box.SelectedValue = m.SelectedSessionId;
            }
            finally { sync = false; }
        }
        box.ItemsSource = m.Sessions;
        box.SelectedValuePath = nameof(MediaSessionInfo.Id);
        box.SelectionChanged += (_, _) =>
        {
            if (!sync && box.SelectedValue is string id && id != m.SelectedSessionId) m.SelectSessionCommand.Execute(id);
        };
        box.DropDownOpened += (_, _) => hold ??= shell.HoldOpen();
        box.DropDownClosed += (_, _) => { hold?.Dispose(); hold = null; };
        m.Sessions.CollectionChanged += (_, _) => Sync();
        m.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(MediaState.SelectedSessionId)) Sync(); };
        Sync();
    }

    public static void Seek(MediaState m, double fraction) => m.Controls?.Seek(m.Duration * fraction);
}
