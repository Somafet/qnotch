using System.Security.Cryptography;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Core;
using Windows.Foundation;
using Windows.Media.Control;

namespace QNotch.Modules.Media;

// Events posted from the thread pool to the UI through the EventBus.
internal sealed record MediaUnavailable;
/// <summary>Sent last for every refresh. SelectedId null means no session at all.</summary>
internal sealed record MediaSessions(IReadOnlyList<MediaSessionInfo> List, string? SelectedId);
internal sealed record MediaProps(string Title, string Artist, string Album, string App, ImageSource? Artwork);
internal sealed record MediaPlayback(bool Playing, bool CanPlayPause, bool CanNext, bool CanPrevious, bool CanSeek, double Rate);
internal sealed record MediaTimeline(TimeSpan Position, TimeSpan Duration, DateTimeOffset Updated);

/// <summary>
/// Everything WinRT: session manager, per-session events, artwork decoding, transport commands. Runs on the thread pool only.
/// Event handlers just set dirty flags; one serialized pump coalesces bursts (a track change fires 3+ events) and does the reads.
/// </summary>
internal sealed class MediaProvider(EventBus bus)
{
    const int Props = 1, Playback = 2, Timeline = 4, Sessions = 8, All = 15;
    const int ArtPixels = 128;

    GlobalSystemMediaTransportControlsSessionManager? _mgr;
    readonly Dictionary<string, Tracked> _tracked = new(); // pump only
    string? _manual;
    string? _selectedId;
    volatile GlobalSystemMediaTransportControlsSession? _selected;
    volatile bool _fast;
    bool _relabeled; // pump only
    int _dirty, _running, _seq;
    ImageSource? _art;
    string? _artKey;

    public void Start() => Task.Run(async () =>
    {
        try
        {
            _mgr = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _mgr.CurrentSessionChanged += (_, _) => Mark(Sessions);
            _mgr.SessionsChanged += (_, _) => Mark(Sessions);
        }
        catch (Exception ex)
        {
            Log.Warn("Media session manager unavailable", ex);
            bus.Post(new MediaUnavailable());
            return;
        }
        Mark(All);
    });

    /// <summary>Panel open (fast) or not. Timeline events are ignored while collapsed; going fast re-reads the position once.</summary>
    public void SetFast(bool fast)
    {
        _fast = fast;
        if (fast && _mgr is not null) Mark(Timeline);
    }

    public void Select(string id) { _manual = id; Mark(All); }

    public void PlayPause() => Command(async s =>
    {
        var info = s.GetPlaybackInfo();
        if (info?.Controls.IsPlayPauseToggleEnabled == true) return await s.TryTogglePlayPauseAsync();
        return info?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing
            ? await s.TryPauseAsync() : await s.TryPlayAsync();
    });
    public void Next() => Command(s => s.TrySkipNextAsync().AsTask());
    public void Previous() => Command(s => s.TrySkipPreviousAsync().AsTask());
    public void Seek(TimeSpan pos) => Command(s => s.TryChangePlaybackPositionAsync((pos + s.GetTimelineProperties().StartTime).Ticks).AsTask());

    void Command(Func<GlobalSystemMediaTransportControlsSession, Task<bool>> f)
    {
        var s = _selected;
        if (s is null) return;
        Task.Run(async () =>
        {
            try { await f(s); }
            catch (Exception ex) { Log.Warn("Media command failed", ex); }
            Mark(Playback | Timeline); // reconcile any optimistic UI state with the truth
        });
    }

    // ---------- pump ----------

    void Mark(int flags)
    {
        Interlocked.Or(ref _dirty, flags);
        if (Interlocked.CompareExchange(ref _running, 1, 0) == 0) _ = Task.Run(Pump);
    }

    async Task Pump()
    {
        while (true)
        {
            try
            {
                await Task.Delay(40); // let a burst of events land, then read once
                var d = Interlocked.Exchange(ref _dirty, 0);
                if (d != 0) await Process(d);
            }
            catch (Exception ex) { Log.Warn("Media refresh failed", ex); }
            Volatile.Write(ref _running, 0);
            if (Volatile.Read(ref _dirty) == 0 || Interlocked.CompareExchange(ref _running, 1, 0) != 0) return;
        }
    }

    async Task Process(int d)
    {
        var post = await Reconcile((d & (Props | Sessions)) != 0);
        if (_relabeled) { _relabeled = false; d |= Props; }
        if (post.SelectedId != _selectedId) { _selectedId = post.SelectedId; d = All; }
        var s = _selected = post.SelectedId is { } id && _tracked.TryGetValue(id, out var t) ? t.Session : null;

        if (s is not null)
        {
            if ((d & Props) != 0) await ReadProps(s, post.SelectedId!);
            if ((d & (Playback | Timeline)) != 0) ReadPlayback(s);
            if ((d & Timeline) != 0 || ((d & Playback) != 0 && _fast)) ReadTimeline(s);
        }
        bus.Post(post); // last, so HasSession flips only after the first data for a new session arrived
    }

    /// <summary>Syncs tracked sessions with the OS and picks the selected one: manual pick while it lives, else Windows' current.</summary>
    async Task<MediaSessions> Reconcile(bool detect)
    {
        // Sessions are keyed by object identity: two tabs of one app share an AUMID. The id is "aumid#n", stable while the session lives.
        var live = new List<Tracked>();
        foreach (var s in _mgr!.GetSessions())
        {
            var t = _tracked.Values.FirstOrDefault(x => ReferenceEquals(x.Session, s));
            if (t is null) { var id = $"{s.SourceAppUserModelId}#{++_seq}"; _tracked[id] = t = new Tracked(this, id, s); }
            live.Add(t);
        }
        foreach (var id in _tracked.Keys.Where(k => !live.Any(t => t.Id == k)).ToList()) { _tracked[id].Detach(); _tracked.Remove(id); }

        var sel = _manual is not null && live.Any(t => t.Id == _manual) ? _manual : null;
        if (sel is null)
        {
            _manual = null;
            var cur = _mgr.GetCurrentSession();
            sel = (live.FirstOrDefault(t => ReferenceEquals(t.Session, cur)) ?? live.FirstOrDefault())?.Id;
        }

        if (detect) await DetectYtm(live);

        // Labels are the app name; two sessions of one app (two tabs, two browsers) get the track title to tell them apart.
        var dup = live.GroupBy(Label).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        var list = new List<MediaSessionInfo>();
        foreach (var t in live)
        {
            var app = Label(t);
            var label = dup.Contains(app) ? $"{app}: {(await TitleOf(t) is { Length: > 0 } title ? title : "session")}" : app;
            list.Add(new MediaSessionInfo(t.Id, label, app));
        }
        return new MediaSessions(list, sel);
    }

    /// <summary>
    /// A browser tab reports only the browser, so YouTube Music is recognized by a window of that browser with "YouTube Music" in its
    /// title (the tab is in front). The flag sticks while the tab is in the background and is dropped once a window of that browser
    /// shows the current track under another site.
    /// </summary>
    async Task DetectYtm(List<Tracked> live)
    {
        var wins = MediaNative.Windows();
        foreach (var t in live)
        {
            var app = AppName(t.Aumid);
            bool Has(string text) => wins.Any(w => w.Title.Contains(text, StringComparison.OrdinalIgnoreCase) && ProcessApp(w.Pid) == app);
            var ytm = t.Ytm;
            if (Has(Ytm)) ytm = true;
            else if (ytm && await TitleOf(t) is { Length: > 0 } title && Has(title)) ytm = false;
            if (ytm != t.Ytm) { t.Ytm = ytm; _relabeled = true; }
        }
    }

    static string ProcessApp(uint pid)
    {
        try { using var p = System.Diagnostics.Process.GetProcessById((int)pid); return AppName(p.ProcessName); }
        catch { return ""; }
    }

    static async Task<string?> TitleOf(Tracked t)
    {
        try { return (await t.Session.TryGetMediaPropertiesAsync())?.Title; }
        catch { return null; }
    }

    async Task ReadProps(GlobalSystemMediaTransportControlsSession s, string id)
    {
        string title = "", artist = "", album = "";
        byte[]? img = null;
        try
        {
            var p = await s.TryGetMediaPropertiesAsync();
            if (p is not null)
            {
                title = p.Title ?? "";
                artist = string.IsNullOrEmpty(p.Artist) ? p.AlbumArtist ?? "" : p.Artist;
                album = p.AlbumTitle ?? "";
                if (p.Thumbnail is { } th)
                {
                    using var rs = await th.OpenReadAsync();
                    if (rs.Size is > 0 and < 8_000_000)
                    {
                        using var ms = new MemoryStream((int)rs.Size);
                        await rs.AsStreamForRead().CopyToAsync(ms);
                        img = ms.ToArray();
                    }
                }
            }
        }
        catch (Exception ex) { Log.Warn("Media properties read failed", ex); }

        var key = img is null ? null : $"{img.Length}:{Convert.ToHexString(SHA1.HashData(img))}";
        if (key != _artKey) { _art = img is null ? null : Decode(img); _artKey = key; }
        var app = _tracked.TryGetValue(id, out var tr) ? Label(tr) : AppName(id);
        bus.Post(new MediaProps(title.Length > 0 ? title : app, artist, album, app, _art));
    }

    void ReadPlayback(GlobalSystemMediaTransportControlsSession s)
    {
        var i = s.GetPlaybackInfo();
        if (i is null) return;
        var c = i.Controls;
        var playing = i.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        var canPlayPause = c.IsPlayPauseToggleEnabled || (playing ? c.IsPauseEnabled : c.IsPlayEnabled);
        bus.Post(new MediaPlayback(playing, canPlayPause, c.IsNextEnabled, c.IsPreviousEnabled, c.IsPlaybackPositionEnabled, i.PlaybackRate ?? 1));
    }

    void ReadTimeline(GlobalSystemMediaTransportControlsSession s)
    {
        var t = s.GetTimelineProperties();
        if (t is null) return;
        var updated = t.LastUpdatedTime.Year < 2000 ? DateTimeOffset.Now : t.LastUpdatedTime;
        bus.Post(new MediaTimeline(t.Position - t.StartTime, t.EndTime - t.StartTime, updated));
    }

    /// <summary>Frozen bitmap, scaled so the SHORT side is ArtPixels (wide video thumbnails stay sharp after the square crop).</summary>
    static BitmapImage? Decode(byte[] bytes)
    {
        try
        {
            var f = BitmapFrame.Create(new MemoryStream(bytes), BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            int w = Math.Max(1, f.PixelWidth), h = Math.Max(1, f.PixelHeight);
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.DecodePixelWidth = Math.Min(ArtPixels * 2, w <= h ? ArtPixels : ArtPixels * w / h);
            bi.StreamSource = new MemoryStream(bytes);
            bi.EndInit();
            bi.Freeze();
            return bi;
        }
        catch (Exception ex) { Log.Warn("Artwork decode failed", ex); return null; }
    }

    // ---------- naming ----------

    static readonly Dictionary<string, string> Known = new(StringComparer.OrdinalIgnoreCase)
    {
        ["chrome"] = "Chrome", ["msedge"] = "Edge", ["microsoftedge"] = "Edge", ["308046B0AF4A39CB"] = "Firefox", ["firefox"] = "Firefox",
        ["vlc"] = "VLC", ["zunemusic"] = "Media Player", ["zunevideo"] = "Movies & TV", ["spotify"] = "Spotify",
        ["_crx_cinhimbnkkaeohfgghhklpknlkffjgod"] = Ytm, // installed from Chrome as an app
    };

    const string Ytm = "YouTube Music";

    static string Label(Tracked t) => t.Ytm ? Ytm : AppName(t.Aumid);

    static string AppName(string id)
    {
        var s = id.Contains('!') ? id[(id.LastIndexOf('!') + 1)..] : id;
        if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) s = s[..^4];
        if (s.LastIndexOf('.') is >= 0 and var dot) s = s[(dot + 1)..];
        if (Known.TryGetValue(s, out var k)) return k;
        return s.Length == 0 ? "Media" : char.ToUpperInvariant(s[0]) + s[1..];
    }

    // ---------- per-session subscriptions ----------

    sealed class Tracked
    {
        public GlobalSystemMediaTransportControlsSession Session { get; }
        public string Id { get; }
        public string Aumid { get; }
        public bool Ytm; // pump only
        readonly TypedEventHandler<GlobalSystemMediaTransportControlsSession, MediaPropertiesChangedEventArgs> _props;
        readonly TypedEventHandler<GlobalSystemMediaTransportControlsSession, PlaybackInfoChangedEventArgs> _play;
        readonly TypedEventHandler<GlobalSystemMediaTransportControlsSession, TimelinePropertiesChangedEventArgs> _time;

        public Tracked(MediaProvider p, string id, GlobalSystemMediaTransportControlsSession s)
        {
            Session = s;
            Id = id;
            Aumid = s.SourceAppUserModelId;
            _props = (_, _) => p.Mark(id == p._selectedId ? Props | Sessions : Sessions); // Sessions: labels and the YouTube Music check
            _play = (_, _) => { if (id == p._selectedId) p.Mark(Playback); };
            _time = (_, _) => { if (id == p._selectedId && p._fast) p.Mark(Timeline); };
            s.MediaPropertiesChanged += _props;
            s.PlaybackInfoChanged += _play;
            s.TimelinePropertiesChanged += _time;
        }

        public void Detach()
        {
            try
            {
                Session.MediaPropertiesChanged -= _props;
                Session.PlaybackInfoChanged -= _play;
                Session.TimelinePropertiesChanged -= _time;
            }
            catch { /* session already gone */ }
        }
    }
}
