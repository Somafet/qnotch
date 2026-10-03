using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using QNotch.Core;

namespace QNotch.Modules.Notifications;

/// <summary>
/// The two doors into the module, both on the thread pool and both idle until someone connects (no polling):
/// a named pipe restricted to the current user (one JSON line in, one JSON line out) and a loopback HTTP endpoint
/// (<c>POST /notify</c>, <c>DELETE /notify/{id}</c>) that needs the bearer token. A waiting request keeps its connection open.
/// </summary>
internal sealed class NotifyServer(Func<NotifyRequest, Func<Task>, Task<Reply>> handle, Func<string> token, Action<string> pipeStatus, Action<string> httpStatus)
{
    const int MaxHeader = 8 * 1024, ReadTimeoutMs = 5000;
    TcpListener? _http;

    // ---------- named pipe ----------

    public void StartPipe() => Task.Run(PipeLoop);

    async Task PipeLoop()
    {
        var announced = false;
        for (var failures = 0; failures < 5;)
        {
            NamedPipeServerStream? s = null;
            try
            {
                s = new NamedPipeServerStream(Wire.PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                if (!announced) { announced = true; pipeStatus($@"Listening on \\.\pipe\{Wire.PipeName}"); }
                await s.WaitForConnectionAsync();
                var client = s;
                s = null;
                failures = 0;
                _ = Task.Run(() => ServePipe(client));
            }
            catch (Exception ex)
            {
                s?.Dispose();
                failures++;
                Log.Warn("Notification pipe failed", ex);
                await Task.Delay(1000);
            }
        }
        pipeStatus("Unavailable: the pipe could not be created. See logs.");
    }

    async Task ServePipe(NamedPipeServerStream s)
    {
        using (s)
        {
            try
            {
                Reply reply;
                try
                {
                    var line = await ReadLine(s);
                    reply = await Dispatch(JsonSerializer.Deserialize<NotifyRequest>(line, Wire.Json), s);
                }
                catch (JsonException) { reply = Reply.Fail(400, "Invalid JSON"); }
                await s.WriteAsync(Encoding.UTF8.GetBytes(reply.Json + "\n"));
                s.WaitForPipeDrain(); // closing first would throw away what the client has not read yet
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { /* client went away */ }
            catch (Exception ex) { Log.Warn("Notification pipe request failed", ex); }
        }
    }

    /// <summary>Bytes up to the first newline (or the end of the stream).</summary>
    static async Task<string> ReadLine(Stream s)
    {
        using var cts = new CancellationTokenSource(ReadTimeoutMs);
        var buf = new byte[4096];
        using var ms = new MemoryStream();
        while (true)
        {
            var n = await s.ReadAsync(buf, cts.Token);
            if (n == 0) break;
            var nl = Array.IndexOf(buf, (byte)'\n', 0, n);
            ms.Write(buf, 0, nl >= 0 ? nl : n);
            if (nl >= 0) break;
            if (ms.Length > Wire.MaxMessage) throw new JsonException();
        }
        return Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
    }

    async Task<Reply> Dispatch(NotifyRequest? req, Stream connection)
    {
        if (req is null) return Reply.Fail(400, "Invalid JSON");
        try { return await handle(req, () => Gone(connection)); }
        catch (NotifyException ex) { return Reply.Fail(400, ex.Message); }
    }

    /// <summary>Completes when the sender closes its end (or the connection breaks): a waiting request is then abandoned.</summary>
    static async Task Gone(Stream s)
    {
        var b = new byte[16];
        try { while (await s.ReadAsync(b) > 0) { } }
        catch { /* broken or disposed: gone either way */ }
    }

    // ---------- HTTP on loopback ----------

    /// <summary>Starts, restarts (new port) or stops (<paramref name="enabled"/> false) the HTTP endpoint.</summary>
    public void SetHttp(bool enabled, int port)
    {
        _http?.Stop();
        _http = null;
        if (!enabled) { httpStatus("Off"); return; }
        if (port is < 1024 or > 65535) { httpStatus("Off: the port must be between 1024 and 65535."); return; }
        try
        {
            var l = new TcpListener(IPAddress.Loopback, port);
            l.Start();
            _http = l;
            httpStatus($"Listening on http://127.0.0.1:{port}");
            Task.Run(() => HttpLoop(l));
        }
        catch (SocketException ex)
        {
            Log.Warn($"Notification HTTP port {port} unavailable", ex);
            httpStatus($"Off: port {port} is in use by another app.");
        }
    }

    async Task HttpLoop(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(); }
            catch { return; } // stopped
            _ = Task.Run(() => ServeHttp(c));
        }
    }

    async Task ServeHttp(TcpClient c)
    {
        using (c)
        {
            try
            {
                c.NoDelay = true;
                var s = c.GetStream();
                var reply = await HandleHttp(s);
                var body = Encoding.UTF8.GetBytes(reply.Json);
                var head = $"HTTP/1.1 {reply.Status} {Reason(reply.Status)}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
                await s.WriteAsync(Encoding.ASCII.GetBytes(head));
                await s.WriteAsync(body);
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException or SocketException) { /* client went away */ }
            catch (Exception ex) { Log.Warn("Notification HTTP request failed", ex); }
        }
    }

    static string Reason(int status) => status switch
    {
        200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 411 => "Length Required", 413 => "Payload Too Large", _ => "Error",
    };

    async Task<Reply> HandleHttp(NetworkStream s)
    {
        using var cts = new CancellationTokenSource(ReadTimeoutMs);
        // Head: everything up to the blank line. Whatever follows in the buffer is the start of the body.
        var buf = new byte[MaxHeader];
        int len = 0, end = -1;
        while (end < 0)
        {
            if (len == buf.Length) return Reply.Fail(400, "Headers too large");
            var n = await s.ReadAsync(buf.AsMemory(len), cts.Token);
            if (n == 0) return Reply.Fail(400, "Incomplete request");
            len += n;
            end = buf.AsSpan(0, len).IndexOf("\r\n\r\n"u8);
        }
        var lines = Encoding.ASCII.GetString(buf, 0, end).Split("\r\n");
        var first = lines[0].Split(' ');
        if (first.Length < 2) return Reply.Fail(400, "Bad request line");
        string method = first[0], target = first[1];
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var l in lines.Skip(1))
        {
            var i = l.IndexOf(':');
            if (i > 0) headers[l[..i].Trim()] = l[(i + 1)..].Trim();
        }

        // A web page can reach localhost: browsers always send Origin on such requests, and a rebinding attack shows in Host.
        if (headers.ContainsKey("Origin")) return Reply.Fail(403, "Requests from web pages are not accepted");
        if (headers.TryGetValue("Host", out var host) && !host.StartsWith("127.0.0.1", StringComparison.Ordinal) && !host.StartsWith("localhost", StringComparison.OrdinalIgnoreCase))
            return Reply.Fail(403, "Unexpected Host header");
        if (!headers.TryGetValue("Authorization", out var auth) || !auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) || !NotifyToken.Matches(token(), auth[7..].Trim()))
            return Reply.Fail(401, "Missing or wrong bearer token (Settings, Notifications)");

        var query = "";
        var q = target.IndexOf('?');
        if (q >= 0) { query = target[(q + 1)..]; target = target[..q]; }
        target = target.TrimEnd('/');

        if (method == "DELETE" && target.StartsWith("/notify/", StringComparison.Ordinal))
            return await Dispatch(new NotifyRequest { Op = "dismiss", Id = Uri.UnescapeDataString(target["/notify/".Length..]) }, s);
        if (method != "POST" || target != "/notify") return Reply.Fail(404, "Use POST /notify or DELETE /notify/{id}");

        if (headers.ContainsKey("Transfer-Encoding") || !headers.TryGetValue("Content-Length", out var cl) || !int.TryParse(cl, out var size) || size < 0)
            return Reply.Fail(411, "Content-Length is required");
        if (size > Wire.MaxMessage) return Reply.Fail(413, "Message too large");
        if (headers.TryGetValue("Expect", out var expect) && expect.StartsWith("100", StringComparison.Ordinal))
            await s.WriteAsync("HTTP/1.1 100 Continue\r\n\r\n"u8.ToArray(), cts.Token);

        var body = new byte[size];
        var have = Math.Min(size, len - (end + 4));
        buf.AsSpan(end + 4, have).CopyTo(body);
        while (have < size)
        {
            var n = await s.ReadAsync(body.AsMemory(have), cts.Token);
            if (n == 0) return Reply.Fail(400, "Incomplete body");
            have += n;
        }

        NotifyRequest? req;
        try { req = JsonSerializer.Deserialize<NotifyRequest>(body, Wire.Json); }
        catch (JsonException) { return Reply.Fail(400, "Invalid JSON"); }
        if (req is null) return Reply.Fail(400, "Invalid JSON");
        req.Op = null; // the route decides
        if (query.Split('&').Any(p => p is "wait" or "wait=1" or "wait=true")) req.Wait = true;
        return await Dispatch(req, s);
    }
}
