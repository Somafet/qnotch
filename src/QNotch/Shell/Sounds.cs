using System.Windows.Media;
using QNotch.Core;
using QNotch.Interop;

namespace QNotch.Shell;

/// <summary>sounds.json: sound id to audio file, only for sounds the user changed.</summary>
public sealed class SoundSettings { public Dictionary<string, string> Files { get; set; } = new(); }

/// <summary>One sound the user can replace with a file in Settings, Sounds. Created with <see cref="Sounds.Add"/>.</summary>
public sealed class Sound
{
    internal Sound(string id, string title, string hint, string alias, int order) => (Id, Title, Hint, Alias, Order) = (id, title, hint, alias, order);

    public string Id { get; }
    public string Title { get; }
    public string Hint { get; }
    /// <summary>The Windows sound scheme alias played by default ("Notification.Default").</summary>
    public string Alias { get; }
    public int Order { get; }
    /// <summary>The user's audio file, empty for the Windows sound.</summary>
    public string File { get; internal set; } = "";
}

/// <summary>
/// The sounds of the shell and the modules: owns the saved files, the playback and what the Settings, Sounds page lists. By default
/// a sound is one of the user's Windows sound scheme, so a sound they turned off there stays off. UI thread only.
/// </summary>
public sealed class Sounds(SettingsStore store)
{
    const string FileName = "sounds";
    public const string Filter = "Audio files|*.wav;*.mp3;*.wma;*.m4a;*.aac;*.flac|All files|*.*";
    readonly List<Sound> _items = [];
    readonly SoundSettings _cfg = store.Get<SoundSettings>(FileName);
    MediaPlayer? _player; // only while a file plays

    public IReadOnlyList<Sound> Items => _items.OrderBy(s => s.Order).ToList();

    /// <summary>Declares a sound that plays <paramref name="alias"/> (a Windows sound scheme alias) until the user picks a file. Call once per id, in <c>Initialize</c>.</summary>
    public Sound Add(string id, string title, string hint, string alias, int order = 100)
    {
        var s = new Sound(id, title, hint, alias, order) { File = _cfg.Files.TryGetValue(id, out var f) ? f : "" };
        _items.Add(s);
        return s;
    }

    /// <summary>Changes and saves the file (empty goes back to the Windows sound).</summary>
    public void Set(Sound s, string file)
    {
        s.File = file;
        if (file.Length == 0) _cfg.Files.Remove(s.Id); else _cfg.Files[s.Id] = file;
        store.Save(FileName, _cfg);
    }

    /// <summary>Plays the user's file, or the Windows sound when there is none or it cannot be played. Asynchronous.</summary>
    public void Play(Sound s)
    {
        if (s.File.Length == 0 || !System.IO.File.Exists(s.File)) { PlayAlias(s.Alias); return; }
        Stop();
        var p = _player = new MediaPlayer { Volume = 1 };
        p.MediaEnded += (_, _) => { if (_player == p) Stop(); };
        p.MediaFailed += (_, e) => { Log.Warn($"Sound '{s.Id}' failed: {e.ErrorException?.Message}"); if (_player == p) Stop(); PlayAlias(s.Alias); };
        p.Open(new Uri(s.File));
        p.Play();
    }

    void Stop()
    {
        _player?.Close();
        _player = null;
    }

    static void PlayAlias(string alias)
    {
        const uint SND_ASYNC = 0x1, SND_NODEFAULT = 0x2, SND_ALIAS = 0x10000, SND_SYSTEM = 0x200000;
        // Resolving the alias reads the registry, so it starts on the thread pool. SND_SYSTEM: at the system sounds volume.
        Task.Run(() => Native.PlaySound(alias, 0, SND_ALIAS | SND_ASYNC | SND_NODEFAULT | SND_SYSTEM));
    }
}
