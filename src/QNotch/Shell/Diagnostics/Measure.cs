using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Threading;
using Microsoft.Win32;
using QNotch.Core;

namespace QNotch.Shell.Diagnostics;

/// <summary>
/// <c>QNotch.exe --measure &lt;dir&gt;</c> (spec/diagnostics.md, Measure): startup, then idle CPU and memory with the panel collapsed, against the
/// hard limits in ARCHITECTURE.md (Performance rules). Writes <c>performance.json</c>; exit 1 when a limit fails.
/// </summary>
internal static partial class Measure
{
    const double WarmupSeconds = 15, IntervalSeconds = 30;
    /// <summary>ARCHITECTURE.md, Performance rules (hard): idle CPU at or under 0.1% of one core while collapsed, resident memory under 80 MB.</summary>
    const double CpuLimit = 0.1;
    const long ResidentLimit = 80L * 1024 * 1024;

    public static async void Run(DiagnosticOptions o, DiagnosticHost h, Action<int> exit)
    {
        var code = 1;
        var dir = o.Dir!;
        try
        {
            Directory.CreateDirectory(dir);
            using var proc = Process.GetCurrentProcess();
            // App showed the window; Loaded priority runs after its first layout and render pass.
            await h.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
            var startup = (DateTime.Now - proc.StartTime).TotalSeconds;
            // Startup idle: the late modules, Game mode and the post-startup MemoryTrim (4 s later) are queued from here.
            await h.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            await Task.Delay(TimeSpan.FromSeconds(WarmupSeconds));

            var hz = CyclesPerSecond();
            // Thread list and calibration stay outside the interval: CPU is read last at the start and first at the end.
            proc.Refresh();
            var threads0 = Threads(proc);
            var (ws0, pb0, state0) = (proc.WorkingSet64, proc.PrivateMemorySize64, State(h));
            var (cycles0, cpu0) = (Cycles(), proc.TotalProcessorTime);
            var sw = Stopwatch.StartNew();
            await Task.Delay(TimeSpan.FromSeconds(IntervalSeconds));
            var (cycles1, cpu1) = (Cycles(), proc.TotalProcessorTime);
            var seconds = sw.Elapsed.TotalSeconds;
            proc.Refresh();
            var (ws1, pb1, state1, threads1) = (proc.WorkingSet64, proc.PrivateMemorySize64, State(h), Threads(proc));
            // Where the CPU went: the busiest threads over the interval (ui = the dispatcher thread), for a failed limit.
            var ui = GetCurrentThreadId();
            var busiest = string.Join(", ", threads1.Select(t => (t.Key, Ms: (t.Value - threads0.GetValueOrDefault(t.Key)).TotalMilliseconds))
                .Where(t => t.Ms >= 1).OrderByDescending(t => t.Ms).Take(5).Select(t => $"{(t.Key == ui ? "ui" : "thread " + t.Key)} {t.Ms:0} ms"));
            // Exact cycles (QueryProcessCycleTime) when calibrated; the tick-sampled CPU time (15.6 ms resolution) is kept as a second opinion.
            var tickSeconds = (cpu1 - cpu0).TotalSeconds;
            var cpuSeconds = hz > 0 ? (cycles1 - cycles0) / hz : tickSeconds;
            var cpu = cpuSeconds / seconds * 100;

            var limits = new List<(string Name, double Limit, double Measured, bool Ok)>
            {
                ("idle_cpu_percent_one_core", CpuLimit, Math.Round(cpu, 3), state0 == "collapsed" && state1 == "collapsed" && cpu <= CpuLimit),
                ("resident_bytes", ResidentLimit, Math.Max(ws0, ws1), Math.Max(ws0, ws1) < ResidentLimit),
            };
            var asm = typeof(Measure).Assembly;
            string? Meta(string key) => asm.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == key)?.Value;
            var dirty = Meta("QNotchSourceDirty");
            var modules = h.Modules.Select(m => m.Id).ToList();

            using (var fs = File.Create(Path.Combine(dir, "performance.json")))
            using (var w = new Utf8JsonWriter(fs, new JsonWriterOptions { Indented = true }))
            {
                w.WriteStartObject();
                w.WriteString("platform", "Windows");
                w.WriteString("app_version", asm.GetName().Version?.ToString(3));
                w.WriteString("source_revision", Meta("QNotchSourceRevision") is { Length: > 0 } rev ? rev : "unknown");
                if (dirty is null) w.WriteNull("source_dirty"); else w.WriteBoolean("source_dirty", dirty == "true");
                w.WriteString("os", Os());
                w.WriteString("architecture", RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant());
                w.WriteString("hardware_model", Hardware());
                w.WriteString("cpu_model", Reg(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString") ?? "unknown");
                w.WriteNumber("logical_processors", Environment.ProcessorCount);
                w.WriteNumber("physical_memory_bytes", PhysicalMemory());
                w.WriteString("method", $"In-process, read at both ends of the interval. CPU: QueryProcessCycleTime (exact cycles of every thread, user and kernel) divided by " +
                    $"the cycle rate calibrated on a 100 ms spin of one thread ({hz / 1e9:0.###} GHz); CPU percent of one core = CPU seconds / wall seconds * 100. " +
                    $"cpu_percent_one_core_ticks is the same from Process.TotalProcessorTime, which Windows samples on the 15.6 ms clock tick. " +
                    $"Memory: Process.WorkingSet64 (resident) and PrivateMemorySize64 after Refresh. Release build, tiered JIT off. " +
                    $"Every module the normal app loads ({modules.Count}, none turned off: fresh temporary settings), early modules before the first frame and the rest at startup idle, " +
                    $"Game mode on Auto, demo data: settings are read-only, so modules that honor it start no providers (media sessions, clipboard listener, mic and camera watchers, " +
                    $"weather, GitHub, AI usage, phone share, notification and agent pipes) while the System stats sampler, timers and the clock run as usual. No tray icon, no global hotkeys, " +
                    $"no network. The window is off screen (WPF still renders it; no pointer can hover it). Startup: process start to the dispatcher after Show and the first render pass. " +
                    $"Interval: starts {WarmupSeconds:0} s after startup idle, after the post-startup MemoryTrim.");
                w.WriteNumber("startup_seconds", Math.Round(startup, 3));
                w.WriteNumber("warmup_seconds", WarmupSeconds);
                w.WriteNumber("interval_seconds", Math.Round(seconds, 3));
                w.WriteString("state", state0 == state1 ? state0 : $"{state0} then {state1}");
                w.WriteNumber("cpu_percent_one_core", Math.Round(cpu, 3));
                w.WriteNumber("cpu_seconds", Math.Round(cpuSeconds, 4));
                w.WriteNumber("cpu_percent_one_core_ticks", Math.Round(tickSeconds / seconds * 100, 3));
                w.WriteNumber("resident_bytes_start", ws0);
                w.WriteNumber("resident_bytes_end", ws1);
                w.WriteNumber("private_bytes_start", pb0);
                w.WriteNumber("private_bytes_end", pb1);
                w.WriteNumber("gc_heap_bytes_end", GC.GetTotalMemory(false));
                w.WriteString("busiest_threads", busiest);
                w.WriteString("modules", string.Join(",", modules));
                w.WriteStartArray("limits");
                foreach (var (name, limit, measured, ok) in limits)
                {
                    w.WriteStartObject();
                    w.WriteString("name", name);
                    w.WriteNumber("limit", limit);
                    w.WriteNumber("measured", measured);
                    w.WriteBoolean("ok", ok);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteEndObject();
            }
            code = limits.All(l => l.Ok) ? 0 : 1;
            Log.Info($"Measure: startup {startup:0.000} s, CPU {cpu:0.000}% of one core over {seconds:0.0} s ({state0}), working set {ws0 >> 20} to {ws1 >> 20} MB");
        }
        catch (Exception ex)
        {
            Log.Error("Measure failed", ex);
            try { File.WriteAllText(Path.Combine(dir, "measure.log"), ex.ToString()); } catch { }
        }
        finally { exit(code); }
    }

    static string State(DiagnosticHost h) => h.Shell.Mode switch { ShellMode.Collapsed => "collapsed", ShellMode.Expanded => "open", _ => "game-bar" };

    static string? Reg(string key, string name)
    {
        try { return (Registry.LocalMachine.OpenSubKey(key)?.GetValue(name) as string)?.Trim(); }
        catch { return null; }
    }

    static string Os()
    {
        const string nt = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        var v = Environment.OSVersion.Version;
        // ProductName still says Windows 10 on Windows 11: the build number tells them apart.
        var name = (Reg(nt, "ProductName") ?? "Windows").Replace("Windows 10", v.Build >= 22000 ? "Windows 11" : "Windows 10");
        var release = Reg(nt, "DisplayVersion");
        var ubr = Registry.GetValue(@"HKEY_LOCAL_MACHINE\" + nt, "UBR", null);
        return $"{name}{(release is null ? "" : " " + release)} ({v.Major}.{v.Minor}.{v.Build}{(ubr is int u ? "." + u : "")})";
    }

    static string Hardware()
    {
        const string bios = @"HARDWARE\DESCRIPTION\System\BIOS";
        var model = $"{Reg(bios, "SystemManufacturer")} {Reg(bios, "SystemProductName")}".Trim();
        return model.Length > 0 ? model : "unknown";
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MemoryStatus { public uint Length, Load; public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual; }

    [LibraryImport("kernel32.dll", EntryPoint = "GlobalMemoryStatusEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalMemoryStatusEx(ref MemoryStatus status);

    [LibraryImport("kernel32.dll")]
    private static partial int GetCurrentThreadId();

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryProcessCycleTime(nint process, out ulong cycles);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryThreadCycleTime(nint thread, out ulong cycles);

    [LibraryImport("kernel32.dll")]
    private static partial nint GetCurrentThread();

    static double Cycles() => QueryProcessCycleTime(-1, out var c) ? c : 0; // -1: this process

    /// <summary>Cycles per second of thread time: the best of three 100 ms spins (a spin that got preempted reads low). 0 when unavailable.</summary>
    static double CyclesPerSecond()
    {
        var best = 0.0;
        for (var i = 0; i < 3; i++)
        {
            if (!QueryThreadCycleTime(GetCurrentThread(), out var c0)) return 0;
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < 100) { }
            QueryThreadCycleTime(GetCurrentThread(), out var c1);
            best = Math.Max(best, (c1 - c0) / sw.Elapsed.TotalSeconds);
        }
        return best;
    }

    static Dictionary<int, TimeSpan> Threads(Process p)
    {
        var d = new Dictionary<int, TimeSpan>();
        foreach (ProcessThread t in p.Threads)
            try { d[t.Id] = t.TotalProcessorTime; } catch { /* exited meanwhile */ }
        return d;
    }

    static long PhysicalMemory()
    {
        var m = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        return GlobalMemoryStatusEx(ref m) ? (long)m.TotalPhys : GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
    }
}
