using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using QNotch.Core;

namespace QNotch.Modules.FileTray;

/// <summary>A file offered to the phone. Requests name it by <see cref="Id"/> only, never by path.</summary>
sealed record SharedFile(string Id, string Path, string Name);

/// <summary>
/// One sharing session: a fresh random token, the frozen list of shared files, the deadline and the cancellation that ends the
/// listener and every transfer. Thread safe: the server reads it from the thread pool, the service writes the deadline on the UI thread.
/// </summary>
sealed class PhoneShareSession
{
    readonly CancellationTokenSource _cts = new();
    readonly Dictionary<string, SharedFile> _files;
    readonly ConcurrentDictionary<string, byte> _parts = new(StringComparer.OrdinalIgnoreCase);
    long _deadline;
    int _uploads;

    public PhoneShareSession(IEnumerable<string> paths, string uploadFolder, DateTime deadlineUtc)
    {
        Token = Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(16));
        Files = paths.Select((p, i) => new SharedFile((i + 1).ToString(), p, Path.GetFileName(p))).ToList();
        _files = Files.ToDictionary(f => f.Id);
        UploadFolder = uploadFolder;
        Deadline = deadlineUtc;
    }

    /// <summary>22 URL-safe characters (128 random bits).</summary>
    public string Token { get; }
    public IReadOnlyList<SharedFile> Files { get; }
    /// <summary>Where received files go (<c>Downloads\QNotch</c>).</summary>
    public string UploadFolder { get; }
    public CancellationToken Stopping => _cts.Token;
    public bool IsStopped => _cts.IsCancellationRequested;

    public DateTime Deadline
    {
        get => new(Interlocked.Read(ref _deadline), DateTimeKind.Utc);
        set => Interlocked.Exchange(ref _deadline, value.Ticks);
    }

    public bool IsLive => !IsStopped && DateTime.UtcNow < Deadline;

    public SharedFile? Find(string id) => _files.GetValueOrDefault(id);

    // ---------- partial uploads ----------

    public void BeginUpload(string part) { Interlocked.Increment(ref _uploads); _parts[part] = 0; }

    /// <summary>The part file is gone: renamed to its final name or deleted.</summary>
    public void EndUpload(string part) { _parts.TryRemove(part, out _); Interlocked.Decrement(ref _uploads); }

    /// <summary>
    /// Stops listening and cancels every transfer. Uploads delete their own part files when they see the cancellation; with
    /// <paramref name="waitMs"/> (application exit) this waits briefly for them, then deletes whatever is left.
    /// </summary>
    public void Stop(int waitMs = 0)
    {
        if (_cts.IsCancellationRequested) return;
        _cts.Cancel();
        if (waitMs <= 0) return;
        var until = Environment.TickCount64 + waitMs;
        while (Volatile.Read(ref _uploads) > 0 && Environment.TickCount64 < until) Thread.Sleep(20);
        foreach (var part in _parts.Keys)
        {
            try { File.Delete(part); }
            catch (Exception ex) { Log.Warn($"Phone sharing: could not delete {part}", ex); }
        }
    }
}
