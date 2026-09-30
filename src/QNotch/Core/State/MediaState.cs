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
