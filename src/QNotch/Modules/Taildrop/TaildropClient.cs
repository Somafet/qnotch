using System.IO.Pipes;
using System.Net;
using System.Net.Http;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;

namespace QNotch.Modules.Taildrop;

/// <summary>What the Tailscale service reported, in the order the views check it.</summary>
public enum TaildropAvailability { Loading, NotInstalled, NotRunning, Stopped, NeedsLogin, Ready }

/// <summary>A device on the tailnet that can receive files (Tailscale's file targets: your own devices).</summary>
public sealed record TaildropDevice(string Id, string Name, string Os, bool Online);

/// <summary>A file that arrived through Taildrop and waits in the Tailscale inbox until an app saves it.</summary>
public sealed record TaildropWaitingFile(string Name, long Size);

/// <summary>An error the Tailscale service returned, with its own message.</summary>
public sealed class TaildropException(string message) : Exception(message);

/// <summary>
/// Talks to the local Tailscale service over its LocalAPI (HTTP on the current-user named pipe the Tailscale CLI uses). No process is
/// started and nothing leaves the machine except the file a send streams to the chosen device. Every call runs off the UI thread.
/// </summary>
public sealed class TaildropClient : IDisposable
{
    const string PipeName = @"ProtectedPrefix\Administrators\Tailscale\tailscaled";
    static readonly TimeSpan QueryTimeout = TimeSpan.FromSeconds(5);

    readonly HttpClient _http;

    public TaildropClient()
    {
        var handler = new SocketsHttpHandler
        {
            // The service impersonates the caller to check who is asking, so the pipe allows identification.
            ConnectCallback = async (_, ct) =>
            {
                var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
                try { await pipe.ConnectAsync(1500, ct).ConfigureAwait(false); }
                catch { await pipe.DisposeAsync().ConfigureAwait(false); throw; }
                return pipe;
            },
            // Do not keep the pipe open between refreshes.
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(10),
            UseProxy = false,
            AllowAutoRedirect = false,
        };
        // The LocalAPI only answers this host name, and refuses requests that carry a Referer or Origin.
        _http = new HttpClient(handler) { BaseAddress = new Uri("http://local-tailscaled.sock/localapi/v0/"), Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>Whether Tailscale for Windows is installed, for telling "not installed" from "not running" when the pipe is missing.</summary>
    public static bool IsInstalled()
    {
        try
        {
            var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            if (File.Exists(Path.Combine(pf, "Tailscale", "tailscale-ipn.exe")) || File.Exists(Path.Combine(pf, "Tailscale", "tailscaled.exe"))) return true;
            using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\Tailscale");
            return key is not null;
        }
        catch { return false; }
    }

    /// <summary>The service state (Running, Stopped, NeedsLogin, ...). Throws when the service cannot be reached.</summary>
    public async Task<TaildropAvailability> GetAvailabilityAsync(CancellationToken ct)
    {
        using var doc = await GetJsonAsync("status?peers=false", ct).ConfigureAwait(false);
        var state = doc.RootElement.TryGetProperty("BackendState", out var s) ? s.GetString() : null;
        return ParseBackendState(state);
    }

    internal static TaildropAvailability ParseBackendState(string? state) => state switch
    {
        "Running" => TaildropAvailability.Ready,
        "Stopped" => TaildropAvailability.Stopped,
        "NeedsLogin" or "NeedsMachineAuth" or "NoState" => TaildropAvailability.NeedsLogin,
        "Starting" => TaildropAvailability.Loading,
        _ => TaildropAvailability.NotRunning,
    };

    /// <summary>Devices that can receive files, online ones first, then by name.</summary>
    public async Task<IReadOnlyList<TaildropDevice>> GetTargetsAsync(CancellationToken ct)
    {
        using var doc = await GetJsonAsync("file-targets", ct).ConfigureAwait(false);
        return ParseTargets(doc.RootElement);
    }

    internal static IReadOnlyList<TaildropDevice> ParseTargets(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Array) return [];
        var list = new List<TaildropDevice>();
        foreach (var t in root.EnumerateArray())
        {
            if (!t.TryGetProperty("Node", out var n) || n.ValueKind != JsonValueKind.Object) continue;
            var id = Str(n, "StableID");
            if (id.Length == 0) continue;
            var name = Str(n, "ComputedName");
            if (name.Length == 0) name = Str(n, "Name").Split('.')[0];
            if (name.Length == 0) name = Str(n, "HostName");
            var os = n.TryGetProperty("Hostinfo", out var hi) && hi.ValueKind == JsonValueKind.Object ? Str(hi, "OS") : "";
            var online = n.TryGetProperty("Online", out var o) && o.ValueKind == JsonValueKind.True;
            list.Add(new TaildropDevice(id, name, os, online));
        }
        return list.OrderByDescending(d => d.Online).ThenBy(d => d.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>Files waiting in the Tailscale inbox. Empty when the Tailscale app already saves them on its own.</summary>
    public async Task<IReadOnlyList<TaildropWaitingFile>> GetWaitingAsync(CancellationToken ct)
    {
        using var doc = await GetJsonAsync("files/", ct).ConfigureAwait(false);
        return ParseWaiting(doc.RootElement);
    }

    internal static IReadOnlyList<TaildropWaitingFile> ParseWaiting(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Array) return [];
        var list = new List<TaildropWaitingFile>();
        foreach (var f in root.EnumerateArray())
        {
            var name = Str(f, "Name");
            if (name.Length == 0 || !IsPlainFileName(name)) continue;
            list.Add(new TaildropWaitingFile(name, f.TryGetProperty("Size", out var s) && s.TryGetInt64(out var size) ? size : 0));
        }
        return list;
    }

    /// <summary>Streams one file to a device. <paramref name="progress"/> gets the bytes handed to the service so far.</summary>
    public async Task SendAsync(string deviceId, string path, Action<long> progress, CancellationToken ct)
    {
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var counted = new ProgressStream(file, progress);
        using var content = new StreamContent(counted, 81920);
        content.Headers.ContentLength = file.Length;
        using var req = new HttpRequestMessage(HttpMethod.Put, PutPath(deviceId, Path.GetFileName(path))) { Content = content };
        using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        await EnsureOk(res, ct).ConfigureAwait(false);
    }

    internal static string PutPath(string deviceId, string fileName) => $"file-put/{Uri.EscapeDataString(deviceId)}/{Uri.EscapeDataString(fileName)}";

    /// <summary>Moves one waiting file into <paramref name="folder"/> (a free name, never overwriting) and returns its path.</summary>
    public async Task<string> SaveWaitingAsync(string name, string folder, CancellationToken ct)
    {
        if (!IsPlainFileName(name)) throw new TaildropException("The file name is not valid.");
        var escaped = Uri.EscapeDataString(name);
        using (var res = await _http.GetAsync("files/" + escaped, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
        {
            await EnsureOk(res, ct).ConfigureAwait(false);
            Directory.CreateDirectory(folder);
            var target = FreePath(folder, name);
            var partial = target + ".partial";
            try
            {
                await using (var src = await res.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
                await using (var dst = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous))
                    await src.CopyToAsync(dst, ct).ConfigureAwait(false);
                File.Move(partial, target);
            }
            catch
            {
                try { File.Delete(partial); } catch { }
                throw;
            }
            using var del = await _http.DeleteAsync("files/" + escaped, ct).ConfigureAwait(false);
            await EnsureOk(del, ct).ConfigureAwait(false);
            return target;
        }
    }

    /// <summary>A name the inbox may hold: no folders, no reserved characters, not "." or "..".</summary>
    internal static bool IsPlainFileName(string name) =>
        name.Length is > 0 and <= 255 && name.Trim('.', ' ').Length > 0 && name.IndexOfAny(Path.GetInvalidFileNameChars()) < 0;

    /// <summary><paramref name="name"/> in <paramref name="folder"/>, or "name (2).ext" and up when it is taken.</summary>
    internal static string FreePath(string folder, string name)
    {
        var path = Path.Combine(folder, name);
        var stem = Path.GetFileNameWithoutExtension(name);
        var ext = Path.GetExtension(name);
        for (var i = 2; File.Exists(path) || Directory.Exists(path) || File.Exists(path + ".partial"); i++)
            path = Path.Combine(folder, $"{stem} ({i}){ext}");
        return path;
    }

    async Task<JsonDocument> GetJsonAsync(string path, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(QueryTimeout);
        using var res = await _http.GetAsync(path, cts.Token).ConfigureAwait(false);
        await EnsureOk(res, cts.Token).ConfigureAwait(false);
        await using var body = await res.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
        return await JsonDocument.ParseAsync(body, default, cts.Token).ConfigureAwait(false);
    }

    static async Task EnsureOk(HttpResponseMessage res, CancellationToken ct)
    {
        if (res.IsSuccessStatusCode) return;
        string text;
        try { text = (await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false)).Trim(); }
        catch { text = ""; }
        if (text.Length > 200) text = text[..200];
        throw new TaildropException(text.Length > 0 ? Sentence(text) : res.StatusCode == HttpStatusCode.Forbidden
            ? "Tailscale refused the request." : $"Tailscale answered {(int)res.StatusCode}.");
    }

    static string Sentence(string s) => char.ToUpperInvariant(s[0]) + s[1..] + (s.EndsWith('.') ? "" : ".");

    static string Str(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    public void Dispose() => _http.Dispose();

    /// <summary>Reports how many bytes were read, which is how far the upload got.</summary>
    sealed class ProgressStream(Stream inner, Action<long> progress) : Stream
    {
        long _done;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => inner.Length;
        public override long Position { get => _done; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => Count(inner.Read(buffer, offset, count));
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => Count(await inner.ReadAsync(buffer, ct).ConfigureAwait(false));
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        int Count(int n)
        {
            if (n > 0) { _done += n; progress(_done); }
            return n;
        }
    }
}
