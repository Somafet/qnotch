using System.ComponentModel;
using System.Windows;
using QNotch.Core;

namespace QNotch.Modules.NoteGithub;

/// <summary>
/// Keeps <see cref="NoteGithubState.NoteText"/> in sync with %APPDATA%\QNotch\note.txt. Loads on the thread pool at startup;
/// each edit arms a one-shot 500 ms timer (re-armed while typing), the write is atomic (temp file then move) and happens on the thread pool.
/// </summary>
internal sealed class NoteStore
{
    static readonly string NoteFile = Path.Combine(Paths.DataDir, "note.txt");
    const int DebounceMs = 500;

    readonly ModuleContext _ctx;
    readonly NoteGithubState _s;
    readonly Timer _timer;
    readonly object _gate = new();
    string? _pending;   // text not yet on disk
    bool _loaded;

    public NoteStore(ModuleContext ctx)
    {
        _ctx = ctx;
        _s = ctx.State.NoteGithub;
        _timer = new Timer(_ => Save(), null, Timeout.Infinite, Timeout.Infinite);
        _s.NoteDateText = DateText(DateTime.Now);
    }

    public void Start()
    {
        _s.PropertyChanged += OnChanged;
        Application.Current.Exit += (_, _) => Save();
        Task.Run(() =>
        {
            string text = ""; DateTime stamp = DateTime.Now;
            try { if (File.Exists(NoteFile)) { text = File.ReadAllText(NoteFile); stamp = File.GetLastWriteTime(NoteFile); } }
            catch (Exception ex) { Log.Warn("Note unreadable", ex); }
            _ctx.Bus.Run(() =>
            {
                _lastSaved = text;
                _loaded = true;
                _s.NoteDateText = DateText(stamp);
                // Typing before the load finished wins: never overwrite what the user already entered.
                if (_s.NoteText.Length == 0 && text.Length > 0) _s.NoteText = text;
                else if (_pending is not null) { _s.NoteStatus = NoteStatus.Editing; _timer.Change(DebounceMs, Timeout.Infinite); }
            });
        });
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(NoteGithubState.NoteText)) return;
        var text = _s.NoteText;
        _s.NoteWordsText = WordsText(text);
        if (!_loaded) { _pending = text; return; } // the load callback sets the status
        if (text == _lastSaved) return;
        lock (_gate) _pending = text;
        _s.NoteStatus = NoteStatus.Editing;
        _timer.Change(DebounceMs, Timeout.Infinite);
    }

    string? _lastSaved;

    /// <summary>Thread pool (or exit). Writes the pending text atomically and reports the outcome.</summary>
    void Save()
    {
        string? text;
        var ok = true;
        lock (_gate)
        {
            text = _pending;
            if (text is null || _ctx.Settings.ReadOnly) return;
            try
            {
                var tmp = NoteFile + ".tmp";
                File.WriteAllText(tmp, text);
                File.Move(tmp, NoteFile, true);
                _pending = null;
            }
            catch (Exception ex) { ok = false; Log.Warn("Note save failed", ex); }
        }
        if (ok) _lastSaved = text;
        if (Application.Current is null || Application.Current.Dispatcher.HasShutdownStarted) return;
        _ctx.Bus.Run(() =>
        {
            // A newer edit already re-armed the timer: stay in "Editing".
            if (!ok) _s.NoteStatus = NoteStatus.Failed;
            else if (_s.NoteText == text) { _s.NoteStatus = NoteStatus.Saved; _s.NoteDateText = DateText(DateTime.Now); }
        });
    }

    static string DateText(DateTime d) => d.ToString("ddd, MMM d");

    static string WordsText(string text)
    {
        int n = 0; bool inWord = false;
        foreach (var c in text)
        {
            var space = char.IsWhiteSpace(c);
            if (!space && !inWord) n++;
            inWord = !space;
        }
        return n == 1 ? "1 word" : $"{n} words";
    }
}
