using System.Collections.ObjectModel;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace QNotch.Core;

public sealed record MediaSessionInfo(string Id, string Title);

/// <summary>Implemented by the Media module; the shell and views only talk to this.</summary>
public interface IMediaControls
{
    void PlayPause();
    void Next();
    void Previous();
    void SelectSession(string sessionId);
    void Seek(TimeSpan position);
}

/// <summary>Now playing. The Media module writes it (on the UI thread); shell views bind to it. Artwork must be a frozen ImageSource.</summary>
public sealed partial class MediaState : ObservableObject
{
    /// <summary>False when the OS media API cannot be used at all (render "unavailable"). True when it works even if nothing plays.</summary>
    [ObservableProperty] bool _isAvailable;
    [ObservableProperty] bool _hasSession;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(NowPlayingText))] string _title = "";
    [ObservableProperty, NotifyPropertyChangedFor(nameof(NowPlayingText))] string _artist = "";
    [ObservableProperty] ImageSource? _artwork;
    [ObservableProperty] bool _isPlaying;
    [ObservableProperty] TimeSpan _position;
    [ObservableProperty] TimeSpan _duration;
    /// <summary>When Position was last reported; interpolate with (now - LastTimelineUpdate) while IsPlaying.</summary>
    [ObservableProperty] DateTimeOffset _lastTimelineUpdate;
    [ObservableProperty] string? _selectedSessionId;
    [ObservableProperty] IMediaControls? _controls;

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

    public string NowPlayingText => string.IsNullOrEmpty(Artist) ? Title : $"{Title}  ·  {Artist}";

    public IRelayCommand PlayPauseCommand { get; }
    public IRelayCommand NextCommand { get; }
    public IRelayCommand PreviousCommand { get; }
    public IRelayCommand<string> SelectSessionCommand { get; }

    public MediaState()
    {
        PlayPauseCommand = new RelayCommand(() => Controls?.PlayPause());
        NextCommand = new RelayCommand(() => Controls?.Next());
        PreviousCommand = new RelayCommand(() => Controls?.Previous());
        SelectSessionCommand = new RelayCommand<string>(id => { if (id is not null) Controls?.SelectSession(id); });
    }
}
