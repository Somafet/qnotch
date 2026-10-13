using System.Buffers;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using QNotch.Core;

namespace QNotch.Modules.FileTray;

/// <summary>What the server reports, from thread-pool threads. Implementations must not block.</summary>
interface IPhoneShareEvents
{
    /// <summary>A device loaded the page or the file list.</summary>
    void Seen(IPAddress device);
    /// <summary>A transfer started; the returned id names it in the calls below.</summary>
    int Begin(string name, bool upload, long total);
    /// <summary>Called only when the whole percentage changes.</summary>
    void Progress(int id, int percent);
    /// <summary>Finished. <paramref name="savedPath"/> is the received file for an upload.</summary>
    void Done(int id, string? savedPath);
    void Failed(int id, string reason);
}

/// <summary>
/// The phone sharing endpoint: a minimal HTTP/1.1 server on all IPv4 interfaces, alive only while its session is. Every route sits under
/// <c>/s/&lt;token&gt;/</c>; anything else is 404. One request per connection. All work happens on the thread pool and is cancelled with
/// the session (stop, expiry or exit). Files are streamed in 128 KB chunks and never loaded whole.
/// </summary>
sealed class PhoneShareServer(PhoneShareSession session, IPhoneShareEvents events)
{
    const int MaxHead = 16 * 1024, HeadTimeoutMs = 10_000, IdleMs = 30_000, Chunk = 128 * 1024, MaxConnections = 24;
    /// <summary>Range responses smaller than this are probes (Safari asks for the first bytes of a video): no transfer row.</summary>
    const long ProbeBytes = 64 * 1024;
    /// <summary>Keep this much free on the target drive after an upload.</summary>
    const long DiskReserve = 64L * 1024 * 1024;

    int _connections;

    public int Port { get; private set; }

    /// <summary>Binds a free port on every IPv4 interface (tests pass loopback). Throws <see cref="SocketException"/> when that is impossible.</summary>
    public void Start(IPAddress? bind = null)
    {
        var l = new TcpListener(bind ?? IPAddress.Any, 0);
        l.Start();
        Port = ((IPEndPoint)l.LocalEndpoint).Port;
        session.Stopping.Register(l.Stop);
        _ = Task.Run(() => AcceptLoop(l));
    }

    async Task AcceptLoop(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(session.Stopping); }
            catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or SocketException) { return; }
            if (Interlocked.Increment(ref _connections) > MaxConnections)
            {
                Interlocked.Decrement(ref _connections);
                c.Dispose();
                continue;
            }
            _ = Task.Run(async () =>
            {
                try { await Serve(c); }
                finally { Interlocked.Decrement(ref _connections); }
            });
        }
    }

    async Task Serve(TcpClient c)
    {
        using (c)
        using (session.Stopping.Register(c.Dispose))
        {
            try
            {
                c.NoDelay = true;
                var s = c.GetStream();
                var device = (c.Client.RemoteEndPoint as IPEndPoint)?.Address ?? IPAddress.None;
                var buf = new byte[MaxHead];
                int len = 0, end = -1;
                using (var cts = CancellationTokenSource.CreateLinkedTokenSource(session.Stopping))
                {
                    cts.CancelAfter(HeadTimeoutMs);
                    while (end < 0)
                    {
                        if (len == buf.Length) { await Send(s, 431, "Headers too large"); return; }
                        var n = await s.ReadAsync(buf.AsMemory(len), cts.Token);
                        if (n == 0) return;
                        len += n;
                        end = buf.AsSpan(0, len).IndexOf("\r\n\r\n"u8);
                    }
                }
                if (PhoneShareHttp.ParseHead(buf.AsSpan(0, end)) is not { } req) { await Send(s, 400, "Bad request"); return; }
                await Route(req, s, device, buf.AsMemory(end + 4, len - end - 4));
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException or SocketException) { /* gone */ }
            catch (Exception ex) { Log.Warn("Phone sharing request failed", ex); }
        }
    }

    async Task Route(HttpHead req, NetworkStream s, IPAddress device, ReadOnlyMemory<byte> early)
    {
        var path = req.Path;
        if (!path.StartsWith("/s/", StringComparison.Ordinal)) { await Send(s, 404, "Not found"); return; }
        var slash = path.IndexOf('/', 3);
        var token = slash < 0 ? path[3..] : path[3..slash];
        if (!PhoneShareHttp.TokenMatches(session.Token, token)) { await Send(s, 404, "Not found"); return; }
        if (!session.IsLive) { await Send(s, 410, "Sharing has ended"); return; }

        var sub = slash < 0 ? "" : path[slash..];
        var get = req.Method is "GET" or "HEAD";
        switch (sub)
        {
            case "" when get:
                await Send(s, 301, "", extra: $"Location: /s/{session.Token}/\r\n");
                return;
            case "/" when get:
                events.Seen(device);
                await Send(s, 200, PhoneSharePage.Html, "text/html; charset=utf-8", req.Method == "HEAD", PhoneSharePage.Policy);
                return;
            case "/api/files" when req.Method == "GET":
                events.Seen(device);
                await Send(s, 200, FileList(), "application/json; charset=utf-8");
                return;
            case "/u" when req.Method == "PUT":
                await Upload(req, s, early);
                return;
        }
        if (get && sub.StartsWith("/d/", StringComparison.Ordinal) && session.Find(sub[3..]) is { } file)
        {
            await Download(req, s, file);
            return;
        }
        await Send(s, 404, "Not found");
    }

    string FileList()
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteString("pc", Environment.MachineName);
            w.WriteNumber("expiresIn", Math.Max(0, (int)(session.Deadline - DateTime.UtcNow).TotalSeconds));
            w.WriteStartArray("files");
            foreach (var f in session.Files)
            {
                long size;
                try { size = new FileInfo(f.Path) is { Exists: true } fi ? fi.Length : -1; }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { size = -1; }
                w.WriteStartObject();
                w.WriteString("id", f.Id);
                w.WriteString("name", f.Name);
                w.WriteNumber("size", size);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
    }

    // ---------- PC to phone ----------

    async Task Download(HttpHead req, NetworkStream s, SharedFile file)
    {
        FileStream fs;
        try { fs = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.Asynchronous | FileOptions.SequentialScan); }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { await Send(s, 404, "This file is no longer on the PC"); return; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { await Send(s, 500, "The PC could not open this file"); return; }

        await using (fs)
        {
            var length = fs.Length;
            var range = PhoneShareHttp.ParseRange(req.Header("Range"), length, out var start, out var end);
            if (range == RangeKind.Unsatisfiable)
            {
                await Send(s, 416, "", extra: $"Content-Range: bytes */{length}\r\n");
                return;
            }
            var partial = range == RangeKind.Satisfiable;
            var count = length == 0 ? 0 : end - start + 1;
            var head = new StringBuilder();
            head.Append($"Content-Type: {PhoneShareHttp.MimeType(file.Name)}\r\n");
            head.Append($"Content-Disposition: {PhoneShareHttp.ContentDisposition(file.Name)}\r\n");
            head.Append("Accept-Ranges: bytes\r\n");
            if (partial) head.Append($"Content-Range: bytes {start}-{end}/{length}\r\n");
            await WriteHead(s, partial ? 206 : 200, count, head.ToString());
            if (req.Method == "HEAD" || count == 0) return;

            var id = !partial || count >= ProbeBytes ? events.Begin(file.Name, false, count) : 0;
            var buf = ArrayPool<byte>.Shared.Rent(Chunk);
            try
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(session.Stopping);
                fs.Position = start;
                long sent = 0;
                var last = 0;
                while (sent < count)
                {
                    var n = await fs.ReadAsync(buf.AsMemory(0, (int)Math.Min(Chunk, count - sent)), session.Stopping);
                    if (n == 0) throw new IOException("The file got shorter while it was being sent");
                    idle.CancelAfter(IdleMs);
                    await s.WriteAsync(buf.AsMemory(0, n), idle.Token);
                    sent += n;
                    var pct = (int)(sent * 100 / count);
                    if (id != 0 && pct != last) { last = pct; events.Progress(id, pct); }
                }
                if (id != 0) events.Done(id, null);
            }
            catch (Exception ex)
            {
                if (id != 0) events.Failed(id, Why(ex, "Interrupted"));
                if (ex is IOException { InnerException: null } && !session.IsStopped) Log.Warn($"Phone sharing: sending {file.Name} failed", ex);
                throw;
            }
            finally { ArrayPool<byte>.Shared.Return(buf); }
        }
    }

    // ---------- phone to PC ----------

    async Task Upload(HttpHead req, NetworkStream s, ReadOnlyMemory<byte> early)
    {
        var name = PhoneShareHttp.SanitizeName(req.QueryValue("name"));
        if (req.Header("Transfer-Encoding") is not null || !long.TryParse(req.Header("Content-Length"), out var size) || size < 0)
        {
            await Send(s, 411, "Content-Length is required");
            return;
        }
        var folder = session.UploadFolder;
        try
        {
            Directory.CreateDirectory(folder);
            if (new DriveInfo(Path.GetPathRoot(Path.GetFullPath(folder))!).AvailableFreeSpace < size + DiskReserve)
            {
                await Send(s, 507, "Not enough free space on the PC");
                return;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Log.Warn($"Phone sharing: {folder} is not writable", ex);
            await Send(s, 500, "The PC cannot save files to Downloads\\QNotch");
            return;
        }
        if (req.Header("Expect") is { } expect && expect.StartsWith("100", StringComparison.Ordinal))
            await s.WriteAsync("HTTP/1.1 100 Continue\r\n\r\n"u8.ToArray(), session.Stopping);

        // Claim a part file next to where the upload will land. CreateNew makes the claim atomic between concurrent uploads.
        string part = "";
        FileStream? fs = null;
        for (var attempt = 0; fs is null; attempt++)
        {
            part = FileTrayService.Unique(folder, name + ".part", false);
            try { fs = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.Asynchronous); }
            catch (IOException) when (attempt < 20 && File.Exists(part)) { }
        }
        session.BeginUpload(part);
        var id = events.Begin(name, true, size);
        string? saved = null;
        var buf = ArrayPool<byte>.Shared.Rent(Chunk);
        try
        {
            await using (fs!)
            {
                long got = Math.Min(size, early.Length);
                await fs.WriteAsync(early[..(int)got], session.Stopping);
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(session.Stopping);
                var last = -1;
                while (got < size)
                {
                    idle.CancelAfter(IdleMs);
                    var n = await s.ReadAsync(buf.AsMemory(0, (int)Math.Min(Chunk, size - got)), idle.Token);
                    if (n == 0) throw new EndOfStreamException();
                    await fs.WriteAsync(buf.AsMemory(0, n), session.Stopping);
                    got += n;
                    var pct = (int)(got * 100 / Math.Max(1, size));
                    if (pct != last) { last = pct; events.Progress(id, pct); }
                }
                await fs.FlushAsync(session.Stopping);
            }
            session.Stopping.ThrowIfCancellationRequested();
            for (var attempt = 0; saved is null; attempt++)
            {
                var dest = FileTrayService.Unique(folder, name, false);
                try { File.Move(part, dest); saved = dest; }
                catch (IOException) when (attempt < 20 && File.Exists(dest)) { }
            }
        }
        catch (Exception ex)
        {
            await fs!.DisposeAsync();
            TryDelete(part);
            events.Failed(id, Why(ex, "Interrupted: the partial file was deleted"));
            if (ex is not (EndOfStreamException or OperationCanceledException or IOException or SocketException or ObjectDisposedException))
                Log.Warn($"Phone sharing: receiving {name} failed", ex);
            if (!session.IsStopped && ex is not (EndOfStreamException or OperationCanceledException)) await Send(s, 500, "The PC could not save this file");
            return;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buf);
            session.EndUpload(part);
        }
        events.Done(id, saved);
        await Send(s, 201, JsonSerializer.Serialize(new Dictionary<string, string> { ["name"] = Path.GetFileName(saved) }), "application/json; charset=utf-8");
    }

    string Why(Exception ex, string otherwise) => session.IsStopped ? "Stopped" : ex switch
    {
        OperationCanceledException => "Timed out: the phone stopped sending",
        EndOfStreamException => "Cancelled on the phone",
        _ => otherwise,
    };

    static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception ex) { Log.Warn($"Phone sharing: could not delete {path}", ex); }
    }

    // ---------- responses ----------

    static Task Send(NetworkStream s, int status, string body, string type = "text/plain; charset=utf-8", bool headOnly = false, string? extra = null)
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        return SendBytes(s, status, bytes, type, headOnly, extra);
    }

    static async Task SendBytes(NetworkStream s, int status, byte[] body, string type, bool headOnly, string? extra)
    {
        await WriteHead(s, status, body.Length, $"Content-Type: {type}\r\n{extra}");
        if (!headOnly && body.Length > 0) await s.WriteAsync(body);
    }

    static Task WriteHead(NetworkStream s, int status, long length, string headers)
    {
        var head = $"HTTP/1.1 {status} {PhoneShareHttp.Reason(status)}\r\n{headers}Content-Length: {length}\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n";
        return s.WriteAsync(Encoding.UTF8.GetBytes(head)).AsTask();
    }
}
