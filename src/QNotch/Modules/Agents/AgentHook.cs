using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace QNotch.Modules.Agents;

/// <summary>The pipe both ends agree on. <c>QNOTCH_INSTANCE</c> keeps parallel test runs apart, like the notify pipe.</summary>
internal static class AgentWire
{
    public static string PipeName => "QNotch.Agents" + (Environment.GetEnvironmentVariable("QNOTCH_INSTANCE") is { Length: > 0 } s ? "." + s : "");
}

/// <summary>
/// <c>QNotch.exe agent</c>: the hook Claude Code runs on every session event. Reads the event JSON from stdin, keeps the few fields the
/// notch needs, adds the agent's process id and the window it runs in, sends one line to the running instance and exits. Runs from
/// Program.Main before WPF starts, so it must not touch any WPF or shell type. Always exits 0: a hook must never get in the agent's way.
/// </summary>
internal static class AgentHook
{
    const int MaxMessage = 200;

    public static int Run(string[] args)
    {
        try
        {
            if (!File.Exists($@"\\.\pipe\{AgentWire.PipeName}")) return 0; // QNotch or the module is off: exit at once
            using var input = JsonDocument.Parse(Console.OpenStandardInput());
            var line = Line(input.RootElement);
            using var pipe = new NamedPipeClientStream(".", AgentWire.PipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(500);
            pipe.Write(line);
        }
        catch { /* nothing to report to: the agent ignores hook output */ }
        return 0;
    }

    static byte[] Line(JsonElement e)
    {
        string? Str(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        var evt = Str(e, "hook_event_name") ?? "";
        var tool = Str(e, "tool_name");
        var message = Str(e, "message");
        // AskUserQuestion is how Claude asks you something mid-task: its first question is the most useful line to show.
        if (tool == "AskUserQuestion" && e.TryGetProperty("tool_input", out var ti) && ti.TryGetProperty("questions", out var qs)
            && qs.ValueKind == JsonValueKind.Array && qs.GetArrayLength() > 0)
            message = Str(qs[0], "question");
        if (message?.Length > MaxMessage) message = message[..MaxMessage] + "…";

        var agent = AgentNative.AgentProcess(Environment.ProcessId);
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteString("agent", "claude");
            w.WriteString("event", evt);
            w.WriteString("session", Str(e, "session_id") ?? "");
            w.WriteString("cwd", Str(e, "cwd") ?? "");
            if (message is not null) w.WriteString("message", message);
            if (Str(e, "notification_type") is { } nt) w.WriteString("type", nt);
            if (tool is not null) w.WriteString("tool", tool);
            if (agent > 0) w.WriteNumber("pid", agent);
            // Only the first event of a session needs the window, but the hook cannot know which one that is. A few ms.
            w.WriteNumber("hwnd", (long)AgentNative.Window(agent > 0 ? agent : Environment.ProcessId));
            w.WriteNumber("at", DateTime.UtcNow.Ticks);
            w.WriteEndObject();
        }
        ms.WriteByte((byte)'\n');
        return ms.ToArray();
    }
}

/// <summary>Process tree and window lookups: which ancestor is the agent, and which window its "Show" button brings forward.</summary>
internal static class AgentNative
{
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const int GWL_EXSTYLE = -20, GW_OWNER = 4, SW_RESTORE = 9;
    const long WS_EX_TOOLWINDOW = 0x80;

    delegate bool EnumProc(nint hwnd, nint lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, nint lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll")] static extern nint GetWindow(nint hwnd, int cmd);
    [DllImport("user32.dll")] static extern int GetWindowTextLengthW(nint hwnd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLongPtr(nint hwnd, int index);
    [DllImport("user32.dll")] static extern bool ShowWindow(nint hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hwnd);

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION { public nint ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, ParentPid; }

    [DllImport("kernel32.dll")] static extern nint OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(nint process, int flags, StringBuilder name, ref int size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(nint process, int cls, ref PROCESS_BASIC_INFORMATION info, int size, out int returned);

    /// <summary>
    /// The nearest ancestor of <paramref name="pid"/> that is the agent (claude.exe, or node.exe for an npm install), so the notch can
    /// tell when the session ends without a SessionEnd event (terminal closed). 0 when there is none within a few hops.
    /// </summary>
    public static int AgentProcess(int pid)
    {
        var id = (uint)pid;
        for (var hop = 0; hop < 6 && id > 4; hop++)
        {
            var (parent, name) = Info(id);
            if (hop > 0 && name is "claude.exe" or "node.exe") return (int)id;
            id = parent;
        }
        return 0;
    }

    static (uint Parent, string Name) Info(uint pid)
    {
        var p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (p == 0) return (0, "");
        try
        {
            var info = new PROCESS_BASIC_INFORMATION();
            var parent = NtQueryInformationProcess(p, 0, ref info, Marshal.SizeOf<PROCESS_BASIC_INFORMATION>(), out _) == 0 ? (uint)info.ParentPid : 0;
            var sb = new StringBuilder(1024);
            var size = sb.Capacity;
            var name = QueryFullProcessImageNameW(p, 0, sb, ref size) ? Path.GetFileName(sb.ToString()).ToLowerInvariant() : "";
            return (parent, name);
        }
        finally { CloseHandle(p); }
    }

    /// <summary>The main window of <paramref name="pid"/> or of its nearest ancestor that has one: the terminal or editor the agent runs in.</summary>
    public static nint Window(int pid)
    {
        var id = (uint)pid;
        for (var hop = 0; hop < 8 && id > 4; hop++)
        {
            var h = MainWindow(id);
            if (h != 0) return h;
            id = Info(id).Parent;
        }
        return 0;
    }

    static nint MainWindow(uint pid)
    {
        nint found = 0;
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var owner);
            if (owner != pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER) != 0 || GetWindowTextLengthW(h) == 0) return true;
            if ((GetWindowLongPtr(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            found = h;
            return false;
        }, 0);
        return found;
    }

    /// <summary>Call from a click handler: Windows lets the process that received the last input set the foreground window.</summary>
    public static bool Focus(nint hwnd)
    {
        if (!IsWindow(hwnd)) return false;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        return SetForegroundWindow(hwnd);
    }
}
