using System.Windows.Threading;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Media;

/// <summary>
/// Now playing from Windows media sessions. The provider (thread pool, event driven) posts typed events; this class applies them
/// to <see cref="MediaState"/> on the UI thread and interpolates the progress locally at 1 Hz only while the panel shows Home or
/// Media. While collapsed there is no timer at all.
/// </summary>
public sealed class MediaModule : INotchModule, ICadenceAware
{
    ModuleContext _ctx = null!;
    readonly MediaState _m;
    MediaProvider _provider = null!;
    DispatcherTimer _ticker = null!;
    bool _fast, _canSeekCap;
    double _rate = 1;

    public MediaModule() => _m = new MediaState(this);

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _provider = new MediaProvider(ctx.Bus);
        _ticker = new DispatcherTimer(DispatcherPriority.Background, ctx.Dispatcher) { Interval = TimeSpan.FromSeconds(1) };
        _ticker.Tick += (_, _) => RefreshProgress();

        ctx.Tabs.Register(new TabDescriptor("media", "Media", Glyphs.Music, 10, () => new MediaTab(_m, ctx.Shell), () => !_m.HasSession));
        ctx.Cards.Register(new CardDescriptor("media", "Now playing", 20, () => new MediaCard(_m, ctx.Shell), ColumnSpan: 2));
        ctx.Segments.Register(new SegmentDescriptor("media.pill", SegmentSlot.PillLeft, 10, () => MediaSegments.Pill(_m)));
        ctx.Segments.Register(new SegmentDescriptor("media.glance", SegmentSlot.Glance, 10, () => MediaSegments.Glance(_m)));
        ctx.Segments.Register(new SegmentDescriptor("media.game", SegmentSlot.GameBar, 10, () => MediaSegments.Game(_m),
            "Now playing", "Title and artist, only while something plays."));

        ctx.Bus.Subscribe<MediaUnavailable>(_ => { Clear(); _m.IsAvailable = false; _m.IsReady = true; });
        ctx.Bus.Subscribe<MediaSessions>(Apply);
        ctx.Bus.Subscribe<MediaProps>(Apply);
        ctx.Bus.Subscribe<MediaPlayback>(Apply);
        ctx.Bus.Subscribe<MediaTimeline>(Apply);

        _m.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MediaState.HasSession) or nameof(MediaState.IsPlaying) or nameof(MediaState.HasTimeline)) UpdateTicker();
        };
        ctx.Shell.TabChanged += _ => UpdateTicker();

        if (ctx.Settings.ReadOnly) { SeedDemo(); return; } // snapshot run: demo track, never touch the OS media sessions
        _provider.Start();
    }

    void SeedDemo()
    {
        _m.IsAvailable = _m.IsReady = _m.HasTimeline = true;
        _m.Title = "Midnight City";
        _m.Artist = "M83";
        _m.IsPlaying = true;
        _m.Position = TimeSpan.FromSeconds(72);
        _m.Duration = TimeSpan.FromSeconds(243);
        _m.LastTimelineUpdate = DateTimeOffset.Now;
        _rate = 0; // frozen at 1:12 so snapshots are stable
        _m.AppName = "Spotify";
        _m.Sessions.Add(new("spotify", "Spotify", "Spotify"));
        _m.Sessions.Add(new("ytm", "YouTube Music", "YouTube Music"));
        _m.Sessions.Add(new("chrome", "Chrome", "Chrome"));
        _m.SelectedSessionId = "spotify";
        _m.HasSession = true;
        RefreshProgress();
    }

    public void SetCadence(Cadence cadence)
    {
        _fast = cadence == Cadence.Fast;
        _provider.SetFast(_fast);
        if (_fast) RefreshProgress(); // interpolates from the last known timeline, so the first frame is already right
        UpdateTicker();
    }

    // ---------- transport commands, called by MediaState (UI thread) ----------

    public void PlayPause() { _m.IsPlaying = !_m.IsPlaying; _provider.PlayPause(); } // optimistic, corrected by the next playback event
    public void Next() => _provider.Next();
    public void Previous() => _provider.Previous();
    public void SelectSession(string sessionId) => _provider.Select(sessionId);

    public void Seek(TimeSpan position)
    {
        _m.Position = position;
        _m.LastTimelineUpdate = DateTimeOffset.Now;
        RefreshProgress();
        _provider.Seek(position);
    }

    // ---------- apply events (UI thread) ----------

    void Apply(MediaSessions e)
    {
        _m.IsAvailable = true;
        _m.IsReady = true;
        SyncSessions(e.List);
        _m.SelectedSessionId = e.SelectedId;
        if (e.SelectedId is null) Clear();
        _m.HasSession = e.SelectedId is not null;
    }

    void Apply(MediaProps e)
    {
        _m.Title = e.Title;
        _m.Artist = e.Artist;
        _m.Album = e.Album;
        _m.AppName = e.App;
        _m.Artwork = e.Artwork;
    }

    void Apply(MediaPlayback e)
    {
        _m.IsPlaying = e.Playing;
        _m.CanPlayPause = e.CanPlayPause;
        _m.CanNext = e.CanNext;
        _m.CanPrevious = e.CanPrevious;
        _canSeekCap = e.CanSeek;
        _rate = e.Rate > 0 ? e.Rate : 1;
        _m.CanSeek = _canSeekCap && _m.HasTimeline;
        RefreshProgress();
    }

    void Apply(MediaTimeline e)
    {
        _m.Position = e.Position;
        _m.Duration = e.Duration;
        _m.LastTimelineUpdate = e.Updated;
        _m.HasTimeline = e.Duration > TimeSpan.Zero;
        _m.CanSeek = _canSeekCap && _m.HasTimeline;
        RefreshProgress();
    }

    /// <summary>Back to the empty defaults so a closed player does not keep its artwork alive.</summary>
    void Clear()
    {
        _m.HasSession = false;
        _m.IsPlaying = false;
        _m.Title = _m.Artist = _m.Album = _m.AppName = "";
        _m.Artwork = null;
        _m.Position = _m.Duration = TimeSpan.Zero;
        _m.HasTimeline = _m.CanSeek = false;
        _canSeekCap = false;
        _m.SelectedSessionId = null;
        RefreshProgress();
    }

    void SyncSessions(IReadOnlyList<MediaSessionInfo> list)
    {
        var col = _m.Sessions;
        for (var i = 0; i < list.Count; i++)
        {
            if (i >= col.Count) col.Add(list[i]);
            else if (col[i] != list[i]) col[i] = list[i];
        }
        while (col.Count > list.Count) col.RemoveAt(col.Count - 1);
    }

    // ---------- local progress ----------

    void RefreshProgress()
    {
        if (!_m.HasSession || !_m.HasTimeline)
        {
            _m.Progress = 0;
            _m.ElapsedText = _m.DurationText = "0:00";
            return;
        }
        var pos = _m.Position;
        if (_m.IsPlaying)
        {
            var dt = DateTimeOffset.Now - _m.LastTimelineUpdate;
            if (dt > TimeSpan.Zero) pos += dt * _rate;
        }
        var dur = _m.Duration;
        if (pos > dur) pos = dur;
        if (pos < TimeSpan.Zero) pos = TimeSpan.Zero;
        _m.Progress = pos / dur;
        _m.ElapsedText = Fmt(pos);
        _m.DurationText = Fmt(dur);
    }

    void UpdateTicker()
    {
        var want = _fast && _m.HasSession && _m.IsPlaying && _m.HasTimeline && _ctx.Shell.ActiveTab is "home" or "media";
        if (want == _ticker.IsEnabled) return;
        if (want) { RefreshProgress(); _ticker.Start(); }
        else _ticker.Stop();
    }

    static string Fmt(TimeSpan t) => t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
}
