using System.Collections.ObjectModel;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace QNotch.Modules.Media;

public sealed record MediaSessionInfo(string Id, string Title);

/// <summary>Now playing. The Media module writes it (on the UI thread); only Media's own views and segments bind to it. Artwork must be a frozen ImageSource.</summary>
public sealed partial class MediaState : ObservableObject
{
    /// <summary>False when the OS media API cannot be used at all (render "unavailable"). True when it works even if nothing plays.</summary>
    [ObservableProperty] bool _isAvailable;
    [ObservableProperty] bool _hasSession;
    /// <summary>HasSession, playing and a title: what the glance strip and the game bar show. Kept in sync by the partials below.</summary>
    [ObservableProperty] bool _isNowPlaying;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(NowPlayingText))] string _title = "";
    [ObservableProperty, NotifyPropertyChangedFor(nameof(NowPlayingText))] string _artist = "";
    [ObservableProperty] ImageSource? _artwork;
    [ObservableProperty] bool _isPlaying;
    [ObservableProperty] TimeSpan _position;
    [ObservableProperty] TimeSpan _duration;
    /// <summary>When Position was last reported; interpolate with (now - LastTimelineUpdate) while IsPlaying.</summary>
    [ObservableProperty] DateTimeOffset _lastTimelineUpdate;
    [ObservableProperty] string? _selectedSessionId;

    // Added by the Media module (all set-if-changed, written on the UI thread).
    /// <summary>True once the first query to the OS finished. Before that views show "nothing playing", never "unavailable".</summary>
    [ObservableProperty] bool _isReady;
    [ObservableProperty] string _album = "";
    /// <summary>Friendly name of the app that owns the selected session ("Spotify", "Chrome").</summary>
    [ObservableProperty] string _appName = "";
    [ObservableProperty] bool _canPlayPause = true;
    [ObservableProperty] bool _canNext = true;
    [ObservableProperty] bool _canPrevious = true;
    [ObservableProperty] bool _canSeek;
    /// <summary>False for live streams or apps that report no duration: views hide the progress row.</summary>
    [ObservableProperty] bool _hasTimeline;
    /// <summary>0..1, interpolated locally by the Media module (1 Hz while the panel shows Home or Media, otherwise only on events).</summary>
    [ObservableProperty] double _progress;
    [ObservableProperty] string _elapsedText = "0:00";
    [ObservableProperty] string _durationText = "0:00";

    public ObservableCollection<MediaSessionInfo> Sessions { get; } = new();

    partial void OnHasSessionChanged(bool value) => UpdateNowPlaying();
    partial void OnIsPlayingChanged(bool value) => UpdateNowPlaying();
    partial void OnTitleChanged(string value) => UpdateNowPlaying();
    void UpdateNowPlaying() => IsNowPlaying = HasSession && IsPlaying && Title.Length > 0;

    public string NowPlayingText => string.IsNullOrEmpty(Artist) ? Title : $"{Title}  ·  {Artist}";

    public IRelayCommand PlayPauseCommand { get; }
    public IRelayCommand NextCommand { get; }
    public IRelayCommand PreviousCommand { get; }
    public IRelayCommand<string> SelectSessionCommand { get; }

    readonly MediaModule _controls;

    public MediaState(MediaModule controls)
    {
        _controls = controls;
        PlayPauseCommand = new RelayCommand(controls.PlayPause);
        NextCommand = new RelayCommand(controls.Next);
        PreviousCommand = new RelayCommand(controls.Previous);
        SelectSessionCommand = new RelayCommand<string>(id => { if (id is not null) controls.SelectSession(id); });
    }

    /// <summary>Seek to a fraction (0..1) of the duration.</summary>
    public void Seek(double fraction) => _controls.Seek(Duration * fraction);
}
