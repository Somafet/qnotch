using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using QNotch.Core;

namespace QNotch.Shell.Diagnostics;

/// <summary>
/// The debug channel (spec/diagnostics.md, Debug channel): a named pipe for the current user only, JSON lines each way, several requests per
/// connection and several connections. Started only by <c>--debug-control</c> (and the smoke test's <c>debug-channel</c> check): nothing exists
/// otherwise. Idle until someone connects; all I/O on the thread pool; one command at a time, run on the UI thread by <see cref="DebugCommands"/>.
/// </summary>
internal sealed class DebugChannel : IDisposable
{
    public const int MaxRequest = 64 * 1024;
    readonly DebugCommands _commands;
    readonly CancellationTokenSource _stop = new();
    readonly SemaphoreSlim _gate = new(1, 1);
    readonly HashSet<Stream> _open = [];

    public string PipeName { get; }

    DebugChannel(string pipe, DebugCommands commands) { PipeName = pipe; _commands = commands; }

    /// <summary>Opens <paramref name="pipeName"/> (default <see cref="DebugCli.PipeName"/>) on the UI thread; the pipe exists when this returns.
    /// Throws when it cannot be created. <see cref="Dispose"/> closes it and every connection.</summary>
    public static DebugChannel Start(DebugHost host, string? pipeName = null)
    {
        var c = new DebugChannel(pipeName ?? DebugCli.PipeName, new DebugCommands(host));
        var first = c.Listen();
        _ = Task.Run(() => c.Loop(first));
        Log.Info($@"Debug channel listening on \\.\pipe\{c.PipeName}");
        return c;
    }

    NamedPipeServerStream Listen() => new(PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    async Task Loop(NamedPipeServerStream? s)
    {
        for (var failures = 0; failures < 5 && !_stop.IsCancellationRequested;)
        {
            try
            {
                s ??= Listen();
                Track(s, true);
                await s.WaitForConnectionAsync(_stop.Token);
                var client = s;
                s = null;
                failures = 0;
                _ = Task.Run(() => Serve(client));
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                if (s is not null) { Track(s, false); s.Dispose(); s = null; }
                if (_stop.IsCancellationRequested) break;
                failures++;
                Log.Warn("Debug channel pipe failed", ex);
                try { await Task.Delay(500, _stop.Token); } catch (OperationCanceledException) { break; }
            }
        }
        if (s is not null) { Track(s, false); s.Dispose(); }
    }

    void Track(Stream s, bool add) { lock (_open) { if (add) _open.Add(s); else _open.Remove(s); } }

    async Task Serve(NamedPipeServerStream s)
    {
        try
        {
            var buf = new byte[8192];
            var line = new MemoryStream();
            while (!_stop.IsCancellationRequested)
            {
                var n = await s.ReadAsync(buf, _stop.Token);
                if (n == 0) break;
                var at = 0;
                while (at < n)
                {
                    var nl = Array.IndexOf(buf, (byte)'\n', at, n - at);
                    var end = nl >= 0 ? nl : n;
                    line.Write(buf, at, end - at);
                    at = end + 1;
                    if (line.Length > MaxRequest)
                    {
                        await Send(s, Error(null, $"request over {MaxRequest / 1024} KB refused"));
                        s.WaitForPipeDrain();
                        return;
                    }
                    if (nl < 0) break;
                    var text = Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length).Trim();
                    line.SetLength(0);
                    if (text.Length == 0) continue;
                    var (reply, after) = await Handle(text);
                    await Send(s, reply);
                    if (after is not null)
                    {
                        s.WaitForPipeDrain();
                        after();
                    }
                }
            }
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { /* client went away or the channel stopped */ }
        catch (Exception ex) { Log.Warn("Debug channel connection failed", ex); }
        finally { Track(s, false); s.Dispose(); }
    }

    async Task<(byte[] Reply, Action? After)> Handle(string text)
    {
        JsonElement id = default;
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return (Error(null, "a request is a JSON object"), null);
            if (root.TryGetProperty("id", out var i)) id = i.Clone();
            if (!root.TryGetProperty("cmd", out var c) || c.ValueKind != JsonValueKind.String || c.GetString() is not { Length: > 0 } cmd)
                return (Error(id, "missing cmd"), null);
            var args = root.TryGetProperty("args", out var a) && a.ValueKind == JsonValueKind.Object ? a.Clone() : default;
            await _gate.WaitAsync(_stop.Token);
            try
            {
                var (result, after) = await _commands.Dispatcher.InvokeAsync(() => _commands.Run(cmd, args)).Task.Unwrap();
                return (Ok(id, result), after);
            }
            catch (DebugException ex) { return (Error(id, ex.Message), null); }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Log.Warn($"Debug command '{cmd}' failed", ex);
                return (Error(id, $"{cmd} failed: {ex.Message}"), null);
            }
            finally { _gate.Release(); }
        }
        catch (JsonException ex) { return (Error(id, "invalid JSON: " + ex.Message), null); }
    }

    static byte[] Ok(JsonElement id, JsonNode result) => Write(id, w => { w.WriteBoolean("ok", true); w.WritePropertyName("result"); result.WriteTo(w); });

    static byte[] Error(JsonElement? id, string message) => Write(id ?? default, w => { w.WriteBoolean("ok", false); w.WriteString("error", message); });

    static byte[] Write(JsonElement id, Action<Utf8JsonWriter> body)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            w.WriteStartObject();
            if (id.ValueKind != JsonValueKind.Undefined) { w.WritePropertyName("id"); id.WriteTo(w); }
            body(w);
            w.WriteEndObject();
        }
        ms.WriteByte((byte)'\n');
        return ms.ToArray();
    }

    static async Task Send(Stream s, byte[] bytes)
    {
        await s.WriteAsync(bytes);
        await s.FlushAsync();
    }

    /// <summary>Stops listening and closes every connection. Safe to call twice.</summary>
    public void Dispose()
    {
        if (_stop.IsCancellationRequested) return;
        _stop.Cancel();
        Stream[] open;
        lock (_open) { open = [.. _open]; _open.Clear(); }
        foreach (var s in open) { try { s.Dispose(); } catch { } }
        _commands.Dispose();
    }
}

/// <summary>A command's own failure: its message goes back as the error.</summary>
internal sealed class DebugException(string message) : Exception(message);
