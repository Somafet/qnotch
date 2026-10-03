using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace QNotch.Modules.Notifications;

/// <summary>
/// <c>QNotch.exe notify ...</c>: a thin client for the running instance's pipe. Runs from Program.Main before WPF starts, so it must
/// not touch any WPF or shell type. Exit codes: 0 sent (or an action was clicked: its id is printed), 1 dismissed, 2 timed out,
/// 3 QNotch is not running, 4 bad arguments or a rejected request.
/// </summary>
internal static class NotifyCli
{
    const string Help = """
        QNotch.exe notify [title] [body] [options]

          -t, --title TEXT      Title (required unless --json, --stdin or --dismiss)
          -b, --body TEXT       Description
          -a, --app NAME        Sender name shown with the notification
          -i, --icon VALUE      Image path, exe or shortcut path, or a glyph name (bell, info, check, warning, error, chat, code, ...)
          -l, --level LEVEL     info (default), success, warning, error
              --id ID           Stable id: posting it again replaces the notification
              --ttl SECONDS     Toast time; 0 shows no toast
              --url URL         Adds a button that opens the link (--url-label TEXT, default "Open")
              --focus           Adds a button that brings the calling terminal or app forward (--focus-label TEXT, default "Show")
              --focus-pid PID   Same, for the window of that process (or of its nearest parent that has one)
              --action ID=TEXT  Adds an answer button and waits; the clicked id is printed. Repeatable (3 buttons at most)
              --wait            Wait until the notification is answered or dismissed
              --timeout SECONDS Give up waiting after this long
              --dismiss ID      Remove a notification
              --json JSON       Send this payload as is
              --stdin           Read the JSON payload from standard input

        Exit codes: 0 sent or answered, 1 dismissed, 2 timed out, 3 QNotch not running, 4 error.
        """;

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    public static int Run(string[] args)
    {
        AttachConsole(-1); // a GUI exe has no console: borrow the caller's, redirected handles are left alone
        try
        {
            if (args.Length == 0 || args.Contains("--help") || args.Contains("-h")) { Console.Out.WriteLine(Help); return args.Length == 0 ? 4 : 0; }
            return Send(Payload(args));
        }
        catch (ArgumentException ex) { Console.Error.WriteLine(ex.Message); return 4; }
    }

    /// <summary>One line of JSON for the pipe.</summary>
    static byte[] Payload(string[] args)
    {
        string? title = null, body = null, app = null, icon = null, level = null, id = null, dismiss = null, raw = null, url = null, urlLabel = null, focusLabel = null;
        string? ttl = null, timeout = null;
        int? focusPid = null;
        var wait = false;
        var answers = new List<(string Id, string Label)>();
        for (var i = 0; i < args.Length; i++)
        {
            var a = args[i];
            string Next() => ++i < args.Length ? args[i] : throw new ArgumentException($"{a} needs a value.");
            switch (a)
            {
                case "-t" or "--title": title = Next(); break;
                case "-b" or "--body": body = Next(); break;
                case "-a" or "--app": app = Next(); break;
                case "-i" or "--icon": icon = Path.GetFullPath(Next()) is var p && File.Exists(p) ? p : args[i]; break;
                case "-l" or "--level": level = Next(); break;
                case "--id": id = Next(); break;
                case "--ttl": ttl = Next(); break;
                case "--timeout": timeout = Next(); break;
                case "--url": url = Next(); break;
                case "--url-label": urlLabel = Next(); break;
                case "--focus": focusPid = Environment.ProcessId; break;
                case "--focus-label": focusLabel = Next(); break;
                case "--focus-pid": focusPid = int.TryParse(Next(), out var pid) ? pid : throw new ArgumentException("--focus-pid needs a process id."); break;
                case "--action":
                    var parts = Next().Split('=', 2);
                    answers.Add((parts[0], parts.Length > 1 ? parts[1] : parts[0]));
                    break;
                case "--wait": wait = true; break;
                case "--dismiss": dismiss = Next(); break;
                case "--json": raw = Next(); break;
                case "--stdin": raw = Console.In.ReadToEnd(); break;
                default:
                    if (a.StartsWith('-')) throw new ArgumentException($"Unknown option {a}. Try QNotch.exe notify --help.");
                    if (title is null) title = a; else if (body is null) body = a; else throw new ArgumentException($"Unexpected argument '{a}'.");
                    break;
            }
        }
        if (raw is not null) return Encoding.UTF8.GetBytes(raw.ReplaceLineEndings(" ") + "\n"); // raw line breaks are only whitespace in JSON

        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            if (dismiss is not null) { w.WriteString("op", "dismiss"); w.WriteString("id", dismiss); }
            else
            {
                if (string.IsNullOrWhiteSpace(title)) throw new ArgumentException("A title is required. Try QNotch.exe notify --help.");
                w.WriteString("title", title);
                if (body is not null) w.WriteString("body", body);
                if (app is not null) w.WriteString("app", app);
                if (icon is not null) w.WriteString("icon", icon);
                if (level is not null) w.WriteString("level", level);
                if (id is not null) w.WriteString("id", id);
                if (ttl is not null) w.WriteString("ttl", ttl);
                if (timeout is not null) w.WriteString("timeout", timeout);
                if (wait || answers.Count > 0) w.WriteBoolean("wait", true);
                w.WriteStartArray("actions");
                foreach (var (answerId, label) in answers) { w.WriteStartObject(); w.WriteString("id", answerId); w.WriteString("label", label); w.WriteEndObject(); }
                if (url is not null) { w.WriteStartObject(); w.WriteString("label", urlLabel ?? "Open"); w.WriteString("url", url); w.WriteEndObject(); }
                if (focusPid is { } fp) { w.WriteStartObject(); w.WriteString("label", focusLabel ?? "Show"); w.WriteNumber("focusPid", fp); w.WriteEndObject(); }
                w.WriteEndArray();
            }
            w.WriteEndObject();
        }
        ms.WriteByte((byte)'\n');
        return ms.ToArray();
    }

    static int Send(byte[] line)
    {
        using var pipe = new NamedPipeClientStream(".", Wire.PipeName, PipeDirection.InOut, PipeOptions.CurrentUserOnly);
        try { pipe.Connect(500); }
        catch (Exception ex) when (ex is TimeoutException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine("QNotch is not running, or Notifications is turned off.");
            return 3;
        }
        try
        {
            pipe.Write(line);
            pipe.Flush();
            using var reply = new MemoryStream();
            var buf = new byte[4096];
            for (int n; (n = pipe.Read(buf)) > 0;)
            {
                reply.Write(buf, 0, n);
                if (Array.IndexOf(buf, (byte)'\n', 0, n) >= 0) break;
            }
            using var doc = JsonDocument.Parse(reply.ToArray());
            var root = doc.RootElement;
            if (!root.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
            {
                Console.Error.WriteLine(root.TryGetProperty("error", out var err) ? err.GetString() : "QNotch rejected the request.");
                return 4;
            }
            switch (root.TryGetProperty("result", out var r) ? r.GetString() : null)
            {
                case "clicked":
                    if (root.TryGetProperty("action", out var action)) Console.Out.WriteLine(action.GetString());
                    return 0;
                case "dismissed": return 1;
                case "timeout": return 2;
                default: return 0;
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            Console.Error.WriteLine("QNotch closed the connection before answering.");
            return 3;
        }
    }
}
