using System.Runtime.InteropServices;
using System.Text;

namespace QNotch.Modules.Agents;

/// <summary>One thing an agent started (a dev server with its children, a test runner, a browser), summed and ready to render.</summary>
internal sealed record ProcGroup(int Root, string Session, string Project, string Label, (int Pid, long Created)[] Members, long Memory, double? Cpu, int[] Ports, bool LeftRunning)
{
    /// <summary>"412 MB · 1.2% · :3000"</summary>
    public string Meta => string.Join(" · ", new[] { ProcessTracker.Size(Memory), Cpu is { } c ? $"{c:0.#}%" : "", ProcessTracker.PortText(Ports) }.Where(s => s.Length > 0));
}

/// <summary>
/// The processes each agent started through its shell tools (Bash, PowerShell). Windows never reparents, so a dev server whose shell
/// or agent exited still names its dead parent: once a process is known, its descendants are found even after the chain above it ends.
/// Walks run on the thread pool, one at a time: while a shell tool runs, when an agent exits, and every 2 s while the Agents tab is visible.
/// </summary>
internal sealed class ProcessTracker
{
    /// <summary>A process seen below an agent. Root 0: a shell between the agent and what it ran, tracked but not shown.</summary>
    sealed class Node
    {
        public int Parent, Root, AgentPid;
        public long Created, ParentCreated, Cpu, CpuAt;
        public bool Agent, Dead;
        public string Project = "", Exe = "", Label = "";
    }

    static readonly HashSet<string> ToolShells = ["bash.exe", "sh.exe", "powershell.exe", "pwsh.exe"];
    static readonly HashSet<string> Shells = [.. ToolShells, "cmd.exe"];
    /// <summary>Younger roots are hook runs, git calls and the like: listing them would only make the tab flicker.</summary>
    static readonly long MinAge = 3 * TimeSpan.TicksPerSecond;

    readonly Dictionary<int, Node> _nodes = [];
    readonly object _gate = new();

    /// <summary>The parent this node was born under, or null once that pid ended or runs another process.</summary>
    Node? ParentOf(Node n) => _nodes.TryGetValue(n.Parent, out var p) && p.Created == n.ParentCreated ? p : null;

    /// <summary>Updates the tree below <paramref name="sessions"/> and returns what it found; memory, CPU and ports only when <paramref name="measure"/>.</summary>
    public List<ProcGroup> Walk((string Id, string Project, int Pid)[] sessions, bool measure)
    {
        lock (_gate)
        {
            var procs = ProcNative.Snapshot();
            var children = procs.ToLookup(p => p.Value.Parent, p => p.Key);
            var byAgent = new Dictionary<int, (string Id, string Project)>();
            foreach (var (id, project, pid) in sessions) byAgent[pid] = (id, project);

            // The agent keeps its process across /clear and /resume: only the session on top of it changes.
            foreach (var (pid, (_, project)) in byAgent)
                if (procs.TryGetValue(pid, out var p) && ProcNative.Created(pid) is var created && created > 0)
                {
                    if (_nodes.TryGetValue(pid, out var n) && n.Created == created) n.Project = project;
                    else _nodes[pid] = new Node { Agent = true, AgentPid = pid, Created = created, Project = project, Exe = p.Exe };
                }

            // Look for new children below the living, and below the newly dead once: after that their pid may be reused.
            var expand = new Queue<int>();
            foreach (var (pid, n) in _nodes.ToList())
            {
                if (procs.ContainsKey(pid))
                {
                    var created = ProcNative.Created(pid);
                    if (created != 0 && created != n.Created) { _nodes.Remove(pid); continue; } // reused: ours ended
                    expand.Enqueue(pid);
                }
                else if (!n.Dead) { n.Dead = true; expand.Enqueue(pid); }
            }
            while (expand.TryDequeue(out var pid))
            {
                var parent = _nodes[pid];
                foreach (var c in children[pid])
                {
                    if (_nodes.ContainsKey(c)) continue;
                    var exe = procs[c].Exe;
                    // Only what the agent ran through its shell tools: MCP servers and helpers it starts itself are its own business.
                    if (exe == "conhost.exe" || (parent.Agent && !ToolShells.Contains(exe))) continue;
                    var created = ProcNative.Created(c);
                    if (created == 0 || created < parent.Created) continue;
                    var root = parent.Agent || (parent.Root == 0 && Shells.Contains(exe)) ? 0 : parent.Root == 0 ? c : parent.Root;
                    _nodes[c] = new Node
                    {
                        Parent = pid, ParentCreated = parent.Created, Root = root, AgentPid = parent.AgentPid, Created = created, Exe = exe,
                        Label = root == c ? Label(ProcNative.CommandLine(c), exe) : "",
                    };
                    expand.Enqueue(c);
                }
            }

            // Keep the living and the dead that still lead to the living.
            var keep = new HashSet<Node>();
            foreach (var n in _nodes.Values.Where(n => !n.Dead))
                for (var x = n; x is not null && keep.Add(x);) x = ParentOf(x);
            foreach (var (pid, _) in _nodes.Where(kv => !keep.Contains(kv.Value)).ToList()) _nodes.Remove(pid);

            var ports = measure ? ProcNative.ListeningPorts() : Array.Empty<(int, int)>().ToLookup(p => p.Item1, p => p.Item2);
            var now = DateTime.UtcNow;
            var groups = new List<ProcGroup>();
            foreach (var g in _nodes.Where(kv => kv.Value.Root != 0 && !kv.Value.Dead).GroupBy(kv => kv.Value.Root))
            {
                var top = _nodes.TryGetValue(g.Key, out var r) ? r : g.MinBy(kv => kv.Value.Created).Value;
                if (now.ToFileTimeUtc() - top.Created < MinAge) continue;
                // Its shell or its agent is gone: nobody will stop it.
                var orphan = false;
                var x = top;
                while (!x.Agent && !orphan)
                {
                    var up = ParentOf(x);
                    if (x.Dead || up is null) orphan = true;
                    else x = up;
                }
                orphan |= x.Dead;
                var session = ("", _nodes.TryGetValue(top.AgentPid, out var agent) ? agent.Project : "");
                if (!orphan && !byAgent.TryGetValue(top.AgentPid, out session)) continue; // its row was cleared while the agent runs on

                long memory = 0;
                double? cpu = null;
                if (measure)
                    foreach (var (pid, n) in g)
                    {
                        var (ws, time) = ProcNative.Usage(pid);
                        memory += ws;
                        if (now.Ticks - n.CpuAt < 5 * TimeSpan.TicksPerSecond && time >= n.Cpu) cpu = (cpu ?? 0) + 100.0 * (time - n.Cpu) / (now.Ticks - n.CpuAt) / Environment.ProcessorCount;
                        (n.Cpu, n.CpuAt) = (time, now.Ticks);
                    }
                groups.Add(new ProcGroup(g.Key, session.Item1, session.Item2, top.Label.Length > 0 ? top.Label : Path.GetFileNameWithoutExtension(top.Exe),
                    [.. g.OrderBy(kv => kv.Key == g.Key ? 0 : 1).Select(kv => (kv.Key, kv.Value.Created))],
                    memory, cpu, [.. g.SelectMany(kv => ports[kv.Key]).Distinct().Order()], orphan));
            }
            return groups;
        }
    }

    /// <summary>
    /// Ends the group as it is now, children started since the last walk included, the top process first so it starts nothing new.
    /// Each one only while its pid still names the process we saw.
    /// </summary>
    public void Stop(int root)
    {
        lock (_gate)
        {
            var procs = ProcNative.Snapshot();
            var children = procs.ToLookup(p => p.Value.Parent, p => p.Key);
            var targets = _nodes.Where(kv => kv.Value.Root == root && !kv.Value.Dead && procs.ContainsKey(kv.Key))
                .OrderBy(kv => kv.Key == root ? 0 : 1).Select(kv => (Pid: kv.Key, kv.Value.Created)).ToList();
            for (var i = 0; i < targets.Count; i++)
                foreach (var c in children[targets[i].Pid])
                    if (!targets.Exists(t => t.Pid == c) && ProcNative.Created(c) is var created && created >= targets[i].Created) targets.Add((c, created));
            foreach (var (pid, created) in targets) ProcNative.Terminate(pid, created);
        }
    }

    /// <summary>"node npm-cli.js run dev": the command line with every path cut to its file name.</summary>
    static string Label(string commandLine, string exe)
    {
        var parts = new List<string>();
        var sb = new StringBuilder();
        var quoted = false;
        foreach (var ch in commandLine + " ")
        {
            if (ch == '"') quoted = !quoted;
            else if (ch == ' ' && !quoted) { if (sb.Length > 0) parts.Add(sb.ToString()); sb.Clear(); }
            else sb.Append(ch);
        }
        if (parts.Count == 0) return Path.GetFileNameWithoutExtension(exe);
        parts[0] = Path.GetFileNameWithoutExtension(parts[0]);
        for (var i = 1; i < parts.Count; i++)
            if (parts[i].IndexOfAny(['\\', '/']) > 0 && !parts[i].Contains("://")) parts[i] = Path.GetFileName(parts[i].TrimEnd('\\', '/'));
        var label = string.Join(' ', parts);
        return label.Length > 120 ? label[..120] : label;
    }

    public static string Size(long bytes) => bytes <= 0 ? "" : bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):0.0} GB" : $"{Math.Max(1, bytes >> 20)} MB";
    public static string PortText(int[] ports) => string.Join(", ", ports.Take(3).Select(p => $":{p}")) + (ports.Length > 3 ? $" +{ports.Length - 3}" : "");
}

internal static class ProcNative
{
    const uint TH32CS_SNAPPROCESS = 2, PROCESS_TERMINATE = 0x0001, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const int ProcessCommandLineInformation = 60, AF_INET = 2, AF_INET6 = 23, TCP_TABLE_OWNER_PID_LISTENER = 3;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W
    {
        public int dwSize, cntUsage, th32ProcessID;
        public nint th32DefaultHeapID;
        public int th32ModuleID, cntThreads, th32ParentProcessID, pcPriClassBase, dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_MEMORY_COUNTERS
    {
        public int cb, PageFaultCount;
        public nint PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern nint CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(nint snapshot, ref PROCESSENTRY32W entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(nint snapshot, ref PROCESSENTRY32W entry);
    [DllImport("kernel32.dll")] static extern nint OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(nint process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(nint process, uint exitCode);
    [DllImport("kernel32.dll")] static extern bool K32GetProcessMemoryInfo(nint process, ref PROCESS_MEMORY_COUNTERS counters, int size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(nint process, int cls, nint info, int size, out int returned);
    [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(nint table, ref int size, bool order, int af, int cls, uint reserved);

    /// <summary>Every process: pid to parent pid and lower-case exe name.</summary>
    public static Dictionary<int, (int Parent, string Exe)> Snapshot()
    {
        var all = new Dictionary<int, (int, string)>();
        var snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == -1) return all;
        try
        {
            var e = new PROCESSENTRY32W { dwSize = Marshal.SizeOf<PROCESSENTRY32W>() };
            for (var ok = Process32FirstW(snap, ref e); ok; ok = Process32NextW(snap, ref e))
                all[e.th32ProcessID] = (e.th32ParentProcessID, e.szExeFile.ToLowerInvariant());
        }
        finally { CloseHandle(snap); }
        return all;
    }

    static T With<T>(int pid, uint access, Func<nint, T> f, T fallback)
    {
        var h = OpenProcess(access, false, pid);
        if (h == 0) return fallback;
        try { return f(h); }
        finally { CloseHandle(h); }
    }

    /// <summary>Creation time (FILETIME ticks), 0 when the process is gone or out of reach. With the pid it names one process for good.</summary>
    public static long Created(int pid) => With(pid, PROCESS_QUERY_LIMITED_INFORMATION, h => GetProcessTimes(h, out var c, out _, out _, out _) ? c : 0, 0L);

    /// <summary>Working set in bytes and CPU time used so far (100 ns units).</summary>
    public static (long WorkingSet, long Cpu) Usage(int pid) => With(pid, PROCESS_QUERY_LIMITED_INFORMATION, h =>
    {
        var m = new PROCESS_MEMORY_COUNTERS { cb = Marshal.SizeOf<PROCESS_MEMORY_COUNTERS>() };
        var ws = K32GetProcessMemoryInfo(h, ref m, m.cb) ? (long)m.WorkingSetSize : 0;
        return (ws, GetProcessTimes(h, out _, out _, out var k, out var u) ? k + u : 0);
    }, (0L, 0L));

    public static string CommandLine(int pid) => With(pid, PROCESS_QUERY_LIMITED_INFORMATION, h =>
    {
        var size = 2048;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var buf = Marshal.AllocHGlobal(size);
            try
            {
                var status = NtQueryInformationProcess(h, ProcessCommandLineInformation, buf, size, out var needed);
                if (status == 0)
                {
                    var length = (ushort)Marshal.ReadInt16(buf); // UNICODE_STRING: length in bytes, then a pointer into the same buffer
                    return Marshal.PtrToStringUni(Marshal.ReadIntPtr(buf, nint.Size), length / 2);
                }
                size = Math.Max(needed, size * 2);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        return "";
    }, "");

    public static void Terminate(int pid, long created) => With(pid, PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, h =>
        GetProcessTimes(h, out var c, out _, out _, out _) && c == created && TerminateProcess(h, 1), false);

    /// <summary>TCP ports each process listens on, IPv4 and IPv6.</summary>
    public static ILookup<int, int> ListeningPorts()
    {
        var found = new List<(int Pid, int Port)>();
        foreach (var (af, rowSize, portAt, pidAt) in new[] { (AF_INET, 24, 8, 20), (AF_INET6, 56, 20, 52) })
        {
            var size = 0;
            GetExtendedTcpTable(0, ref size, false, af, TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (size == 0) continue;
            size += 1024; // room for listeners opened since
            var buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedTcpTable(buf, ref size, false, af, TCP_TABLE_OWNER_PID_LISTENER, 0) != 0) continue;
                var count = Marshal.ReadInt32(buf);
                for (var i = 0; i < count; i++)
                {
                    var row = buf + 4 + i * rowSize;
                    var port = Marshal.ReadInt32(row, portAt);
                    found.Add((Marshal.ReadInt32(row, pidAt), ((port & 0xFF) << 8) | ((port >> 8) & 0xFF)));
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        return found.ToLookup(f => f.Pid, f => f.Port);
    }
}
