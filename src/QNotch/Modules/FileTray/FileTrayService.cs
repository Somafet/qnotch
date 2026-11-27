using System.Collections.Concurrent;
using System.Diagnostics;
using System.Windows.Threading;
using QNotch.Core;

namespace QNotch.Modules.FileTray;

public sealed class FileTraySettings { public List<string> Paths { get; set; } = new(); }

/// <summary>
/// Owns the tray list. UI thread API; all file system and shell work (existence, size, thumbnails, copy, launching) runs off the UI thread
/// and reports back through the bus. Nothing here ever modifies or deletes a referenced file.
/// </summary>
public sealed class FileTrayService
{
    const int MaxItems = 60, RecentCount = 4, ThumbSize = 96;

    readonly ModuleContext _ctx;
    readonly FileTrayState _s;
    readonly FileTraySettings _cfg;
    readonly ConcurrentQueue<TrayItem> _queue = new();
    DispatcherTimer? _statusTimer;
    int _worker;

    public FileTrayService(ModuleContext ctx, FileTrayState state)
    {
        _ctx = ctx;
        _s = state;
        _cfg = ctx.Settings.Get<FileTraySettings>("filetray");
        foreach (var p in _cfg.Paths.Distinct(StringComparer.OrdinalIgnoreCase).Take(MaxItems)) _s.Items.Add(new TrayItem(p));
        Summarize();
    }

    // ---------- list ----------

    /// <summary>Adds references (newest first). Existing entries move to the front.</summary>
    public void Add(IEnumerable<string> paths)
    { QNotch.Core.Analytics.Track("files", "add", "ui");
        var added = new List<TrayItem>();
        var seen = 0;
        foreach (var raw in paths)
        {
            string p;
            try { p = Path.GetFullPath(raw); } catch { continue; }
            seen++;
            var existing = _s.Items.FirstOrDefault(i => string.Equals(i.Path, p, StringComparison.OrdinalIgnoreCase));
            if (existing is not null) { _s.Items.Remove(existing); added.Add(existing); }
            else added.Add(new TrayItem(p));
        }
        if (added.Count == 0) return;
        for (var i = 0; i < added.Count; i++) _s.Items.Insert(i, added[i]);
        while (_s.Items.Count > MaxItems) _s.Items.RemoveAt(_s.Items.Count - 1);
        Commit();
        Enqueue(added);
        SetStatus(added.Count == 1 ? L.F("Added {0}", added[0].Name) : L.F("Added {0} items", added.Count));
    }

    public void Remove(TrayItem item)
    { QNotch.Core.Analytics.Track("files", "remove", "ui");
        if (_s.Items.Remove(item)) Commit();
    }

    public void Clear()
    { QNotch.Core.Analytics.Track("files", "clear", "ui");
        if (_s.Items.Count == 0) return;
        _s.Items.Clear();
        Commit();
        SetStatus(L.T("Tray cleared. Your files were not touched."));
    }

    /// <summary>Re-check existence and size of every item (panel opened).</summary>
    public void Refresh() => Enqueue(_s.Items.ToArray());

    void Commit()
    {
        _cfg.Paths = _s.Items.Select(i => i.Path).ToList();
        _ctx.Settings.Save("filetray", _cfg);
        Summarize();
    }

    void Summarize()
    {
        var n = _s.Items.Count;
        var missing = _s.Items.Count(i => i.IsMissing);
        _s.Count = n;
        _s.IsEmpty = n == 0;
        _s.CountText = n == 0 ? L.T("No files") : n == 1 ? L.T("1 file") : L.F("{0} files", n);
        _s.MissingText = missing > 0 ? L.F("{0} missing", missing) : "";
        var recent = _s.Items.Take(RecentCount).ToList();
        if (!recent.SequenceEqual(_s.Recent))
        {
            _s.Recent.Clear();
            foreach (var r in recent) _s.Recent.Add(r);
        }
    }

    // ---------- status line ----------

    public void SetStatus(string text)
    {
        _s.Status = text;
        if (_statusTimer is null)
        {
            _statusTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(4) };
            _statusTimer.Tick += (_, _) => { _statusTimer.Stop(); _s.Status = ""; };
        }
        _statusTimer.Stop();
        _statusTimer.Start();
    }

    // ---------- inspection worker (dedicated STA thread, alive only while the queue has work) ----------

    void Enqueue(IEnumerable<TrayItem> items)
    {
        foreach (var i in items) _queue.Enqueue(i);
        if (Interlocked.Exchange(ref _worker, 1) == 1) return;
        var t = new Thread(Work) { IsBackground = true, Name = "FileTray", Priority = ThreadPriority.BelowNormal };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
    }

    void Work()
    {
        try
        {
            while (_queue.TryDequeue(out var it))
            {
                try { Inspect(it); } catch (Exception ex) { Log.Warn($"FileTray inspect failed for {it.Path}", ex); }
            }
        }
        finally
        {
            Volatile.Write(ref _worker, 0);
            if (!_queue.IsEmpty && Interlocked.Exchange(ref _worker, 1) == 0)
            {
                var t = new Thread(Work) { IsBackground = true, Name = "FileTray" };
                t.SetApartmentState(ApartmentState.STA);
                t.Start();
            }
        }
    }

    void Inspect(TrayItem it)
    {
        var p = it.Path;
        var isDir = Directory.Exists(p);
        var exists = isDir || File.Exists(p);
        var size = !exists ? L.T("Missing") : isDir ? L.T("Folder") : FormatSize(new FileInfo(p).Length);
        var thumb = exists && it.Thumbnail is null ? ShellThumbnails.Get(p, ThumbSize) : null;
        _ctx.Bus.Run(() =>
        {
            it.IsFolder = isDir;
            it.IsMissing = !exists;
            it.SizeText = size;
            if (!exists) it.Thumbnail = null;
            else if (thumb is not null) it.Thumbnail = thumb;
            Summarize();
        });
    }

    public static string FormatSize(long b) => b switch
    {
        >= 1L << 30 => $"{b / 1073741824.0:0.0} GB",
        >= 1L << 20 => $"{b / 1048576.0:0.0} MB",
        >= 1L << 10 => $"{b / 1024.0:0} KB",
        _ => $"{b} B",
    };

    // ---------- actions (file work off the UI thread) ----------

    public void Open(TrayItem it) { QNotch.Core.Analytics.Track("files", "open", "ui");  Launch(new ProcessStartInfo(it.Path) { UseShellExecute = true }, $"open {it.Name}", L.F("Could not open {0}", it.Name)); }

    public void Reveal(TrayItem it) { QNotch.Core.Analytics.Track("files", "reveal", "ui");
        Launch(new ProcessStartInfo("explorer.exe") { Arguments = $"/select,\"{it.Path}\"" }, $"show {it.Name}", L.F("Could not show {0}", it.Name)); }

    void Launch(ProcessStartInfo psi, string what, string error) => Task.Run(() =>
    {
        try { Process.Start(psi)?.Dispose(); }
        catch (Exception ex)
        {
            Log.Warn($"FileTray: could not {what}", ex);
            _ctx.Bus.Run(() => SetStatus(error));
        }
    });

    /// <summary>Copies the items into <paramref name="folder"/> (never moves). Name clashes get a numeric suffix.</summary>
    public void Export(IReadOnlyList<TrayItem> items, string folder)
    {
        var paths = items.Where(i => !i.IsMissing).Select(i => i.Path).ToArray();
        if (paths.Length == 0) { SetStatus(L.T("Nothing to export: the files are missing")); return; }
        SetStatus(L.T("Exporting..."));
        Task.Run(() =>
        {
            string msg;
            try
            {
                foreach (var p in paths) CopyTo(p, folder);
                var leaf = Path.GetFileName(folder.TrimEnd('\\'));
                var to = leaf.Length > 0 ? leaf : folder;
                msg = paths.Length == 1 ? L.F("Exported {0} to {1}", Path.GetFileName(paths[0]), to) : L.F("Exported {0} items to {1}", paths.Length, to);
            }
            catch (Exception ex) { Log.Warn("FileTray export failed", ex); msg = L.F("Export failed: {0}", ex.Message); }
            _ctx.Bus.Run(() => SetStatus(msg));
        });
    }

    static void CopyTo(string src, string folder)
    {
        var isDir = Directory.Exists(src);
        var dest = Unique(folder, Path.GetFileName(src.TrimEnd('\\', '/')), isDir);
        if (!isDir) { File.Copy(src, dest); return; }
        Directory.CreateDirectory(dest);
        foreach (var d in Directory.EnumerateDirectories(src, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(dest, Path.GetRelativePath(src, d)));
        foreach (var f in Directory.EnumerateFiles(src, "*", SearchOption.AllDirectories))
            File.Copy(f, Path.Combine(dest, Path.GetRelativePath(src, f)));
    }

    /// <summary>A free path in <paramref name="folder"/>: the name itself, or "name (2).ext", "name (3).ext", ...</summary>
    internal static string Unique(string folder, string name, bool isDir)
    {
        var stem = isDir ? name : Path.GetFileNameWithoutExtension(name);
        var ext = isDir ? "" : Path.GetExtension(name);
        var p = Path.Combine(folder, name);
        for (var i = 2; File.Exists(p) || Directory.Exists(p); i++) p = Path.Combine(folder, $"{stem} ({i}){ext}");
        return p;
    }
}
