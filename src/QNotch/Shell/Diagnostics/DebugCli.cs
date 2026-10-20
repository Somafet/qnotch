using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace QNotch.Shell.Diagnostics;

/// <summary>
/// <c>QNotch.exe debug &lt;cmd&gt; [--&lt;arg&gt; &lt;value&gt;...]</c>: one request to the debug channel of the instance named by <c>QNOTCH_INSTANCE</c>.
/// Runs from Program.Main before WPF starts, so it touches no WPF or shell type. Prints the result (stdout) or the error (stderr) as JSON.
/// Exit codes: 0 ok, 1 the command failed, 3 no instance with the channel open, 4 bad usage.
/// </summary>
internal static class DebugCli
{
    /// <summary>The pipe both ends agree on. <c>QNOTCH_INSTANCE</c> keeps parallel test runs apart, like the mutex.</summary>
    public static string PipeName => "QNotch.Debug" + (Environment.GetEnvironmentVariable("QNOTCH_INSTANCE") is { Length: > 0 } i ? "." + i : "");

    const string Help = """
        QNotch.exe debug <command> [--<arg> <value>...]

        Talks to an instance started with --debug-control (the one named by QNOTCH_INSTANCE).
        Commands: ping, state, open [--tab ID], close, select-tab --id ID, settings [--section ID] [--close true], onboarding [--close true],
          outline [--window panel|pill|settings|onboarding], snapshot --path ABS.png [--window ...], press --id ID, type --text TEXT [--id ID],
          key --name NAME [--modifiers ctrl,alt,shift,cmd], hotkey --action toggle|search|game-mode, game-mode --mode auto|on|off, quit
        Values are sent as strings; the channel reads true/false and numbers from them. A flag with no value means true.

        Exit codes: 0 ok, 1 the command failed, 3 no instance with the channel open, 4 bad usage.
        """;

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    public static int Run(string[] args)
    {
        AttachConsole(-1); // a GUI exe has no console: borrow the caller's, redirected handles are left alone
        if (args.Length == 0 || args[0] is "--help" or "-h" or "help") { Console.Out.WriteLine(Help); return args.Length == 0 ? 4 : 0; }
        byte[] line;
        try { line = Request(args); }
        catch (ArgumentException ex) { Console.Error.WriteLine(ex.Message); return 4; }
        string reply;
        try { reply = Exchange(PipeName, line, 2000); }
        catch (TimeoutException) { Console.Error.WriteLine($@"No QNotch instance has the debug channel open (\\.\pipe\{PipeName}). Start one with --debug-control."); return 3; }
        catch (IOException) { Console.Error.WriteLine("QNotch closed the connection before answering."); return 3; }
        try
        {
            using var doc = JsonDocument.Parse(reply);
            var root = doc.RootElement;
            if (root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True)
            {
                Print(Console.OpenStandardOutput(), root.TryGetProperty("result", out var r) ? r.GetRawText() : "{}");
                return 0;
            }
            Print(Console.OpenStandardError(), root.TryGetProperty("error", out var e) ? e.GetRawText() : "\"QNotch rejected the request.\"");
            return 1;
        }
        catch (JsonException) { Console.Error.WriteLine("QNotch sent an unreadable answer."); return 1; }
    }

    /// <summary>UTF-8 whatever the console code page: the JSON keeps its text as is.</summary>
    static void Print(Stream to, string json)
    {
        using (to) to.Write(Encoding.UTF8.GetBytes(json + Environment.NewLine));
    }

    /// <summary>The request line for <c>cmd --name value ...</c>; every value is a JSON string (a bare flag is "true").</summary>
    static byte[] Request(string[] args)
    {
        var cmd = args[0];
        if (cmd.StartsWith('-')) throw new ArgumentException($"Expected a command before {cmd}. Try QNotch.exe debug --help.");
        var values = new List<(string Name, string Value)>();
        for (var i = 1; i < args.Length; i++)
        {
            var a = args[i];
            if (!a.StartsWith("--") || a.Length < 3) throw new ArgumentException($"Unexpected argument '{a}'. Arguments are --name value.");
            var hasValue = i + 1 < args.Length && !(args[i + 1].StartsWith("--") && args[i + 1].Length > 2);
            values.Add((a[2..], hasValue ? args[++i] : "true"));
        }
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteNumber("id", 1);
            w.WriteString("cmd", cmd);
            w.WriteStartObject("args");
            foreach (var (name, value) in values) w.WriteString(name, value);
            w.WriteEndObject();
            w.WriteEndObject();
        }
        ms.WriteByte((byte)'\n');
        return ms.ToArray();
    }

    /// <summary>Sends one request line and returns the response line. <see cref="TimeoutException"/> when nothing listens on <paramref name="pipe"/>.</summary>
    public static string Exchange(string pipe, byte[] line, int connectMs)
    {
        if (!File.Exists($@"\\.\pipe\{pipe}")) throw new TimeoutException("no such pipe"); // nothing listens: fail at once
        using var s = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.CurrentUserOnly);
        try { s.Connect(connectMs); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { throw new TimeoutException(ex.Message, ex); }
        s.Write(line);
        s.Flush();
        using var reply = new MemoryStream();
        var buf = new byte[8192];
        for (int n; (n = s.Read(buf)) > 0;)
        {
            var nl = Array.IndexOf(buf, (byte)'\n', 0, n);
            reply.Write(buf, 0, nl >= 0 ? nl : n);
            if (nl >= 0) return Encoding.UTF8.GetString(reply.ToArray());
        }
        throw new IOException("closed");
    }

    /// <summary>Several request lines over one connection, the responses in order (the smoke test's <c>debug-channel</c> check). Await it, even on the UI thread,
    /// but never block on it there: the commands run on that thread.</summary>
    public static async Task<List<string>> ExchangeAsync(string pipe, IEnumerable<string> requests, int connectMs = 2000, CancellationToken cancel = default)
    {
        await using var s = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await s.ConnectAsync(connectMs, cancel);
        var replies = new List<string>();
        var pending = new MemoryStream();
        var buf = new byte[8192];
        foreach (var r in requests)
        {
            await s.WriteAsync(Encoding.UTF8.GetBytes(r.TrimEnd('\n') + "\n"), cancel);
            await s.FlushAsync(cancel);
            while (true)
            {
                var data = pending.GetBuffer();
                var nl = Array.IndexOf(data, (byte)'\n', 0, (int)pending.Length);
                if (nl >= 0)
                {
                    replies.Add(Encoding.UTF8.GetString(data, 0, nl));
                    var rest = data[(nl + 1)..(int)pending.Length];
                    pending.SetLength(0);
                    pending.Write(rest);
                    break;
                }
                var n = await s.ReadAsync(buf, cancel);
                if (n == 0) return replies;
                pending.Write(buf, 0, n);
            }
        }
        return replies;
    }
}
