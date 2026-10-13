using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QNotch.Modules.FileTray;

// `--dump <text> <mask>` prints the QR matrix, for comparing against a reference encoder.
if (args is ["--dump", var dumpText, var dumpMask])
{
    Console.Write(Rows(QrCode.Encode(dumpText, int.Parse(dumpMask))));
    return 0;
}

// `--serve <inbox> <minutes> [files...]` runs a loopback session for trying the phone page in a browser or with curl.
if (args is ["--serve", var serveInbox, var serveMinutes, .. var serveFiles])
{
    var (session, _, port) = Serve(serveFiles, serveInbox);
    Console.WriteLine($"http://127.0.0.1:{port}/s/{session.Token}/");
    await Task.Delay(TimeSpan.FromMinutes(double.Parse(serveMinutes)));
    session.Stop(waitMs: 1000);
    return 0;
}

Environment.SetEnvironmentVariable("QNOTCH_DATA_DIR", Path.Combine(Path.GetTempPath(), "QNotch phone share tests " + Guid.NewGuid().ToString("N")));
var failures = 0;
var checks = 0;

// ---------- QR code ----------

await Test("QR matrices match the reference encoder (Nayuki qrcodegen, level M)", () =>
{
    // SHA-256 of the rows as '0'/'1' lines, produced by qrcodegen with the same text and mask.
    Assert(Hash(QrCode.Encode("http://192.168.1.24:51327/s/AbCdEfGhIjKlMnOpQrStUv/", 2)) == "9c0a6d04c86ee3833f1a89145b47e9dafb5c3aa50ec62c439a72eeed0f18db8e");
    Assert(Hash(QrCode.Encode(new string('x', 200), 5)) == "4d9d35a0f7deae1bd699a42c52c7350938e780be208e22bef9247b2f87dd1a0c");
    Assert(Hash(QrCode.Encode("a", 0)) == "ad65f877bf9411d14b0b2efbc0ca7dfffd44b86e4c5f662689ac17016c5d1b0e");
    return Task.CompletedTask;
});
await Test("QR picks the smallest version and refuses text over version 10", () =>
{
    Assert(QrCode.Encode(new string('a', 14)).GetLength(0) == 21);
    Assert(QrCode.Encode(new string('a', 15)).GetLength(0) == 25);
    Assert(QrCode.Encode(new string('a', 213)).GetLength(0) == 57);
    Assert(QrCode.Encode("http://192.168.100.200:65535/s/AbCdEfGhIjKlMnOpQrStUv/").GetLength(0) == 33);
    Throws<ArgumentException>(() => QrCode.Encode(new string('a', 214)));
    return Task.CompletedTask;
});

// ---------- names ----------

await Test("upload names are sanitized", () =>
{
    Assert(PhoneShareHttp.SanitizeName("IMG_2041.HEIC") == "IMG_2041.HEIC");
    Assert(PhoneShareHttp.SanitizeName("../../Windows/evil.exe") == "evil.exe");
    Assert(PhoneShareHttp.SanitizeName(@"..\..\evil.txt") == "evil.txt");
    Assert(PhoneShareHttp.SanitizeName("C:evil.txt") == "C_evil.txt");
    Assert(PhoneShareHttp.SanitizeName("a<b>c:d\"e|f?g*h.txt") == "a_b_c_d_e_f_g_h.txt");
    Assert(PhoneShareHttp.SanitizeName("photo‮gpj.exe") == "photogpj.exe");
    Assert(PhoneShareHttp.SanitizeName("tab\there.txt") == "tabhere.txt");
    Assert(PhoneShareHttp.SanitizeName("CON") == "_CON");
    Assert(PhoneShareHttp.SanitizeName("nul.txt") == "_nul.txt");
    Assert(PhoneShareHttp.SanitizeName("com1.jpg") == "_com1.jpg");
    Assert(PhoneShareHttp.SanitizeName("LPT9") == "_LPT9");
    Assert(PhoneShareHttp.SanitizeName("console.txt") == "console.txt");
    Assert(PhoneShareHttp.SanitizeName("report. . .") == "report");
    Assert(PhoneShareHttp.SanitizeName("  spaced.txt  ") == "spaced.txt");
    Assert(PhoneShareHttp.SanitizeName("..") == "upload");
    Assert(PhoneShareHttp.SanitizeName("") == "upload");
    Assert(PhoneShareHttp.SanitizeName(null) == "upload");
    Assert(PhoneShareHttp.SanitizeName("dir/") == "upload");
    Assert(PhoneShareHttp.SanitizeName("Fotó árvíztűrő.jpg") == "Fotó árvíztűrő.jpg");
    var longName = PhoneShareHttp.SanitizeName(new string('n', 300) + ".jpeg");
    Assert(longName.Length == PhoneShareHttp.MaxNameLength && longName.EndsWith(".jpeg"));
    var emoji = PhoneShareHttp.SanitizeName(string.Concat(Enumerable.Repeat("😀", 100)));
    Assert(emoji.Length <= PhoneShareHttp.MaxNameLength && !char.IsHighSurrogate(emoji[^1]));
    return Task.CompletedTask;
});
await Test("unique names never replace an existing file", () => InDirectory(dir =>
{
    Assert(FileTrayService.Unique(dir, "a.txt", false) == Path.Combine(dir, "a.txt"));
    File.WriteAllText(Path.Combine(dir, "a.txt"), "");
    Assert(FileTrayService.Unique(dir, "a.txt", false) == Path.Combine(dir, "a (2).txt"));
    File.WriteAllText(Path.Combine(dir, "a (2).txt"), "");
    Assert(FileTrayService.Unique(dir, "a.txt", false) == Path.Combine(dir, "a (3).txt"));
    Directory.CreateDirectory(Path.Combine(dir, "b.txt"));
    Assert(FileTrayService.Unique(dir, "b.txt", false) == Path.Combine(dir, "b (2).txt"));
    return Task.CompletedTask;
}));

// ---------- HTTP parsing ----------

await Test("request heads are parsed and malformed ones refused", () =>
{
    var h = Head("PUT /s/tok/u?name=IMG%20(1).jpg&x HTTP/1.1\r\nHost: 192.168.1.2:5000\r\ncontent-length: 12\r\nX-A: 1\r\nX-A: 2");
    Assert(h is { Method: "PUT", Path: "/s/tok/u" });
    Assert(h!.QueryValue("name") == "IMG (1).jpg" && h.QueryValue("x") == "" && h.QueryValue("y") is null);
    Assert(h.Header("Content-Length") == "12" && h.Header("x-a") == "1, 2");
    Assert(Head("GET /s/tok/?name=%E0%A4%A HTTP/1.1")!.QueryValue("name") == "%E0%A4%A");
    Assert(Head("GET / HTTP/1.0") is { Method: "GET", Path: "/" });
    Assert(Head("GET /") is null);
    Assert(Head("GET http://evil/ HTTP/1.1") is null);
    Assert(Head("GET / SPDY/3") is null);
    Assert(Head("GET  / HTTP/1.1") is null);
    Assert(Head("GET / HTTP/1.1\r\nBad header") is null);
    Assert(Head("GET / HTTP/1.1\r\n folded: x") is null);
    Assert(Head("GET / HTTP/1.1\r\nBad name: x") is null);
    Assert(Head("PUT / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2") is null);
    Assert(Head("PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\ntransfer-encoding: identity") is null);
    return Task.CompletedTask;
});
await Test("byte ranges follow RFC 9110 for single ranges", () =>
{
    Assert(Range("bytes=0-99", 1000) == (RangeKind.Satisfiable, 0, 99));
    Assert(Range("bytes=500-", 1000) == (RangeKind.Satisfiable, 500, 999));
    Assert(Range("bytes=900-5000", 1000) == (RangeKind.Satisfiable, 900, 999));
    Assert(Range("bytes=-100", 1000) == (RangeKind.Satisfiable, 900, 999));
    Assert(Range("bytes=-5000", 1000) == (RangeKind.Satisfiable, 0, 999));
    Assert(Range("bytes=0-1", 1000) == (RangeKind.Satisfiable, 0, 1));
    Assert(Range("bytes=1000-", 1000).Kind == RangeKind.Unsatisfiable);
    Assert(Range("bytes=-0", 1000).Kind == RangeKind.Unsatisfiable);
    Assert(Range("bytes=0-", 0).Kind == RangeKind.Unsatisfiable);
    Assert(Range(null, 1000) == (RangeKind.None, 0, 999));
    Assert(Range("bytes=5-1", 1000).Kind == RangeKind.None);
    Assert(Range("bytes=0-1,5-6", 1000).Kind == RangeKind.None);
    Assert(Range("items=0-1", 1000).Kind == RangeKind.None);
    Assert(Range("bytes=a-b", 1000).Kind == RangeKind.None);
    Assert(Range("bytes=+1-2", 1000).Kind == RangeKind.None);
    return Task.CompletedTask;
});
await Test("download headers carry the exact name safely", () =>
{
    Assert(PhoneShareHttp.ContentDisposition("Fotó \"1\".jpg") == "attachment; filename=\"Fot_ _1_.jpg\"; filename*=UTF-8''Fot%C3%B3%20%221%22.jpg");
    Assert(PhoneShareHttp.ContentDisposition("a\r\nb%.txt") == "attachment; filename=\"a__b_.txt\"; filename*=UTF-8''a%0D%0Ab%25.txt");
    Assert(PhoneShareHttp.MimeType("X.JPG") == "image/jpeg" && PhoneShareHttp.MimeType("x.unknown") == "application/octet-stream");
    Assert(PhoneShareHttp.TokenMatches("abc", "abc") && !PhoneShareHttp.TokenMatches("abc", "abd") && !PhoneShareHttp.TokenMatches("abc", "ab"));
    return Task.CompletedTask;
});

// ---------- the server, end to end over loopback ----------

await Test("serves the page, the list and downloads only for the right token", () => InDirectory(async dir =>
{
    var data = RandomNumberGenerator.GetBytes(300_000);
    var path = Path.Combine(dir, "Fotó 1.jpg");
    File.WriteAllBytes(path, data);
    var (session, ev, port) = Serve([path, Path.Combine(dir, "gone.txt")], Path.Combine(dir, "in"));
    try
    {
        using var http = Client(port);
        var root = $"/s/{session.Token}/";

        using (var r = await http.GetAsync(root))
        {
            Assert(r.StatusCode == HttpStatusCode.OK && (await r.Content.ReadAsStringAsync()).Contains("<title>QNotch</title>"));
            Assert(r.Headers.CacheControl!.NoStore && r.Headers.GetValues("Referrer-Policy").Single() == "no-referrer");
            Assert(r.Content.Headers.ContentType!.MediaType == "text/html" && r.Headers.GetValues("Content-Security-Policy").Single().StartsWith("default-src 'none'"));
        }
        using (var r = await http.GetAsync($"/s/{session.Token}")) Assert(r.StatusCode == HttpStatusCode.MovedPermanently && r.Headers.Location!.OriginalString == root);
        foreach (var bad in new[] { "/", "/s/", "/s/x/", $"/s/{session.Token[..^1]}/", $"/s/{session.Token}x/", $"/s/{session.Token}/d/3", $"/s/{session.Token}/d/..%2F..%2Fwin.ini", $"/s/{session.Token}/nope" })
            using (var r = await http.GetAsync(bad)) Assert(r.StatusCode == HttpStatusCode.NotFound);
        Assert(ev.Devices.Count == 1 && IPAddress.IsLoopback(ev.Devices.Single()));

        using (var j = JsonDocument.Parse(await http.GetStringAsync(root + "api/files")))
        {
            var files = j.RootElement.GetProperty("files").EnumerateArray().ToList();
            Assert(files.Count == 2 && files[0].GetProperty("name").GetString() == "Fotó 1.jpg" && files[0].GetProperty("size").GetInt64() == data.Length);
            Assert(files[1].GetProperty("size").GetInt64() == -1 && j.RootElement.GetProperty("expiresIn").GetInt32() > 800);
        }

        using (var r = await http.GetAsync(root + "d/1"))
        {
            Assert(r.StatusCode == HttpStatusCode.OK && (await r.Content.ReadAsByteArrayAsync()).AsSpan().SequenceEqual(data));
            Assert(r.Content.Headers.ContentDisposition!.FileNameStar == "Fotó 1.jpg" && r.Content.Headers.ContentType!.MediaType == "image/jpeg");
        }
        using (var req = new HttpRequestMessage(HttpMethod.Get, root + "d/1"))
        {
            req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(100_000, 199_999);
            using var r = await http.SendAsync(req);
            Assert(r.StatusCode == HttpStatusCode.PartialContent && r.Content.Headers.ContentRange!.ToString() == $"bytes 100000-199999/{data.Length}");
            Assert((await r.Content.ReadAsByteArrayAsync()).AsSpan().SequenceEqual(data.AsSpan(100_000, 100_000)));
        }
        using (var req = new HttpRequestMessage(HttpMethod.Get, root + "d/1"))
        {
            req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, 1); // a probe: no transfer row
            using var r = await http.SendAsync(req);
            Assert(r.StatusCode == HttpStatusCode.PartialContent && (await r.Content.ReadAsByteArrayAsync()).Length == 2);
        }
        using (var req = new HttpRequestMessage(HttpMethod.Get, root + "d/1"))
        {
            req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(data.Length, null);
            using var r = await http.SendAsync(req);
            Assert(r.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable);
        }
        using (var r = await http.GetAsync(root + "d/2")) Assert(r.StatusCode == HttpStatusCode.NotFound);
        await ev.Settled();
        Assert(ev.Rows.Count == 2 && ev.Rows.Values.All(t => t is { Upload: false, Result: "done", Percent: 100 }));

        session.Deadline = DateTime.UtcNow.AddSeconds(-1);
        using (var r = await http.GetAsync(root + "api/files")) Assert(r.StatusCode == HttpStatusCode.Gone);
    }
    finally { session.Stop(); }
}));

await Test("receives uploads under safe, unique names and nothing partial", () => InDirectory(async dir =>
{
    var inbox = Path.Combine(dir, "in");
    var (session, ev, port) = Serve([], inbox);
    try
    {
        using var http = Client(port);
        var data = RandomNumberGenerator.GetBytes(700_000);
        for (var i = 0; i < 2; i++)
        {
            using var r = await http.PutAsync($"/s/{session.Token}/u?name={Uri.EscapeDataString("../../evil.txt")}", new ByteArrayContent(data));
            Assert(r.StatusCode == HttpStatusCode.Created);
            Assert(JsonDocument.Parse(await r.Content.ReadAsStringAsync()).RootElement.GetProperty("name").GetString() == (i == 0 ? "evil.txt" : "evil (2).txt"));
        }
        Assert(File.ReadAllBytes(Path.Combine(inbox, "evil.txt")).AsSpan().SequenceEqual(data));
        Assert(File.ReadAllBytes(Path.Combine(inbox, "evil (2).txt")).AsSpan().SequenceEqual(data));
        Assert(!File.Exists(Path.Combine(dir, "evil.txt")));
        using (var r = await http.PutAsync($"/s/{session.Token}/u", new ByteArrayContent([])))
            Assert(r.StatusCode == HttpStatusCode.Created && File.Exists(Path.Combine(inbox, "upload")));
        using (var r = await http.PutAsync($"/s/wrong/u?name=x.txt", new ByteArrayContent([1, 2, 3]))) Assert(r.StatusCode == HttpStatusCode.NotFound);
        using (var r = await http.PostAsync($"/s/{session.Token}/u?name=x.txt", new ByteArrayContent([1, 2, 3]))) Assert(r.StatusCode == HttpStatusCode.NotFound);

        // Chunked bodies (no Content-Length) are refused.
        using (var c = new StreamContent(new MemoryStream([1, 2, 3])))
        {
            using var req = new HttpRequestMessage(HttpMethod.Put, $"/s/{session.Token}/u?name=chunked.txt") { Content = c };
            req.Headers.TransferEncodingChunked = true;
            using var r = await http.SendAsync(req);
            Assert(r.StatusCode == HttpStatusCode.LengthRequired);
        }

        // The phone gives up halfway: the part file goes away and the transfer fails.
        using (var raw = new TcpClient())
        {
            await raw.ConnectAsync(IPAddress.Loopback, port);
            var s = raw.GetStream();
            await s.WriteAsync(Encoding.ASCII.GetBytes($"PUT /s/{session.Token}/u?name=half.jpg HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n"));
            await s.WriteAsync(new byte[300_000]);
            await WaitFor(() => File.Exists(Path.Combine(inbox, "half.jpg.part")));
        }
        await WaitFor(() => ev.Rows.Values.Any(t => t is { Name: "half.jpg", Result: not null }));
        Assert(ev.Rows.Values.Single(t => t.Name == "half.jpg").Result == "failed: Cancelled on the phone");
        Assert(!File.Exists(Path.Combine(inbox, "half.jpg")) && !File.Exists(Path.Combine(inbox, "half.jpg.part")));

        var done = ev.Rows.Values.Where(t => t.Result == "done").ToList();
        Assert(done.Count == 3 && done.All(t => t.Upload && t.Saved is not null && File.Exists(t.Saved)));
        Assert(Directory.GetFiles(inbox).Length == 3);
    }
    finally { session.Stop(); }
}));

await Test("stop cancels transfers, deletes partial uploads and closes the port", () => InDirectory(async dir =>
{
    var inbox = Path.Combine(dir, "in");
    var big = Path.Combine(dir, "big.bin");
    File.WriteAllBytes(big, RandomNumberGenerator.GetBytes(8_000_000));
    var (session, ev, port) = Serve([big], inbox);

    using var upload = new TcpClient();
    await upload.ConnectAsync(IPAddress.Loopback, port);
    var us = upload.GetStream();
    await us.WriteAsync(Encoding.ASCII.GetBytes($"PUT /s/{session.Token}/u?name=photo.jpg HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000\r\n\r\n"));
    await us.WriteAsync(new byte[200_000]);
    await WaitFor(() => File.Exists(Path.Combine(inbox, "photo.jpg.part")));

    // A download the phone reads slowly, so the server is still sending when sharing stops.
    using var download = new TcpClient { ReceiveBufferSize = 4096 };
    await download.ConnectAsync(IPAddress.Loopback, port);
    var ds = download.GetStream();
    await ds.WriteAsync(Encoding.ASCII.GetBytes($"GET /s/{session.Token}/d/1 HTTP/1.1\r\nHost: x\r\n\r\n"));
    _ = await ds.ReadAsync(new byte[4096]); // any amount: the transfer has started
    await WaitFor(() => ev.Rows.Values.Any(t => !t.Upload));

    session.Stop(waitMs: 2000);
    await ev.Settled();
    Assert(!File.Exists(Path.Combine(inbox, "photo.jpg.part")) && !File.Exists(Path.Combine(inbox, "photo.jpg")));
    Assert(ev.Rows.Values.All(t => t.Result == "failed: Stopped"));
    Assert(ev.Rows.Count == 2);
    using var after = new TcpClient();
    Assert(await Refused(() => after.ConnectAsync(IPAddress.Loopback, port)));
}));

Console.WriteLine($"{checks - failures}/{checks} phone sharing checks passed.");
return failures == 0 ? 0 : 1;

// ---------- helpers ----------

async Task Test(string name, Func<Task> test)
{
    checks++;
    try { await test(); Console.WriteLine("PASS " + name); }
    catch (Exception ex) { failures++; Console.WriteLine("FAIL " + name + ": " + ex); }
}

static void Assert(bool condition, [System.Runtime.CompilerServices.CallerArgumentExpression(nameof(condition))] string? what = null)
{
    if (!condition) throw new Exception("Assertion failed: " + what);
}

static void Throws<T>(Action a) where T : Exception
{
    try { a(); }
    catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}");
}

static async Task<bool> Refused(Func<Task> a)
{
    try { await a(); return false; }
    catch (SocketException) { return true; }
}

static string Rows(bool[,] m)
{
    var sb = new StringBuilder();
    for (var y = 0; y < m.GetLength(0); y++)
    {
        if (y > 0) sb.Append('\n');
        for (var x = 0; x < m.GetLength(1); x++) sb.Append(m[y, x] ? '1' : '0');
    }
    return sb.ToString();
}

static string Hash(bool[,] m) => Convert.ToHexStringLower(SHA256.HashData(Encoding.ASCII.GetBytes(Rows(m))));

static HttpHead? Head(string s) => PhoneShareHttp.ParseHead(Encoding.Latin1.GetBytes(s));

static (RangeKind Kind, long Start, long End) Range(string? h, long length)
{
    var k = PhoneShareHttp.ParseRange(h, length, out var s, out var e);
    return (k, s, e);
}

static (PhoneShareSession, Recorder, int) Serve(string[] paths, string inbox)
{
    var session = new PhoneShareSession(paths, inbox, DateTime.UtcNow.AddMinutes(15));
    var ev = new Recorder();
    var server = new PhoneShareServer(session, ev);
    server.Start(IPAddress.Loopback); // all interfaces would ask for a firewall exception
    return (session, ev, server.Port);
}

static HttpClient Client(int port) => new(new SocketsHttpHandler { AllowAutoRedirect = false, UseProxy = false })
{
    BaseAddress = new Uri($"http://127.0.0.1:{port}"),
    Timeout = TimeSpan.FromSeconds(20),
};

static async Task WaitFor(Func<bool> condition)
{
    for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(25);
    if (!condition()) throw new TimeoutException("Condition not reached");
}

static async Task InDirectory(Func<string, Task> test)
{
    var dir = Path.Combine(Path.GetTempPath(), "QNotch phone share " + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(dir);
    try { await test(dir); }
    finally { Directory.Delete(dir, true); } // exact test-owned directory created above
}

sealed class Row(string name, bool upload)
{
    public string Name { get; } = name;
    public bool Upload { get; } = upload;
    public int Percent;
    public string? Result;
    public string? Saved;
}

sealed class Recorder : IPhoneShareEvents
{
    int _id;
    public ConcurrentBag<IPAddress> Devices { get; } = new();
    public ConcurrentDictionary<int, Row> Rows { get; } = new();

    public void Seen(IPAddress device) => Devices.Add(device);
    public int Begin(string name, bool upload, long total) { var id = Interlocked.Increment(ref _id); Rows[id] = new Row(name, upload); return id; }
    public void Progress(int id, int percent) => Rows[id].Percent = percent;
    public void Done(int id, string? savedPath) { Rows[id].Saved = savedPath; Rows[id].Result = "done"; }
    public void Failed(int id, string reason) => Rows[id].Result = "failed: " + reason;
    /// <summary>Every started transfer has finished one way or the other.</summary>
    public Task Settled() => WaitForAll(() => Rows.Values.All(r => r.Result is not null));

    static async Task WaitForAll(Func<bool> condition)
    {
        for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(25);
        if (!condition()) throw new TimeoutException("Transfers did not settle");
    }
}
